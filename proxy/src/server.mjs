import http from 'node:http';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {existsSync} from 'node:fs';
import {WebSocket,WebSocketServer} from 'ws';
import {settings,sanitize,opaqueLeaks,sealGrant,openGrant,privateURL,PROXY_GRANT_LIMIT} from './privacy.mjs';
const rules=[
 ['POST',/^\/v1\/invites\/redeem$/],['GET',/^\/v1\/(me|mail\/connections|setup\/reply-thread)$/],
 ['DELETE',/^\/v1\/me\/device$/],['POST',/^\/v1\/speech\/(grants|vocabulary)$/],
 ['POST',/^\/v1\/writing\/drafts$/],['GET',/^\/v1\/writing\/drafts\/[a-f\d-]{36}$/i],
 ['DELETE',/^\/v1\/writing\/drafts\/[a-f\d-]{36}$/i],['POST',/^\/v1\/writing\/drafts\/[a-f\d-]{36}\/(accept|shown)$/i],
];
const knownErrors=new Set(['unauthorized','forbidden','not_found','invalid_input','invalid_request','invalid_invite','invite_expired','invite_exhausted','invite_missing','invite_invalid','invite_used','device_revoked','writing_disabled','writing_not_configured','writing_excluded','mail_policy_unconfigured','storage_unavailable','proposal_limit','recipients_outside_thread','mail_not_configured','mail_connect_failed','mail_connect_unavailable','speech_not_configured','too_many_grants','internal','bad_start','bad_message','audio_incomplete','too_long','timeout','recognizer_failed','recognizer_stalled','language_unsupported']);
const jsonHeaders={'Content-Type':'application/json','Cache-Control':'no-store','Referrer-Policy':'no-referrer'};
function send(res,status,value,headers={}){res.writeHead(status,{...jsonHeaders,...headers});res.end(value===null?'':JSON.stringify(value));}
function fail(res,status,detail='unavailable'){send(res,status,{detail});}
function forwardHeaders(req){const h={};for(const key of ['authorization','content-type','accept','accept-language'])if(req.headers[key])h[key]=req.headers[key];return h;}
async function boundedBody(stream,limit){const chunks=[];let size=0;for await(const b of stream){size+=b.length;if(size>limit)throw Error('too_large');chunks.push(b);}return Buffer.concat(chunks);}
function allowed(req,origin,config){return req.headers.host===new URL(origin).host&&(!req.headers.origin||config.origins.includes(req.headers.origin));}
export const MAX_QUEUED_BYTES=1024*1024;
export function createBoundedForwarder(target,abort,stallTimeoutMs=5000) {
 let pending=0,timer,disposed=false;
 const dispose=()=>{disposed=true;clearTimeout(timer);};
 const failed=code=>{dispose();abort(code);};
 const watch=()=>{
  clearTimeout(timer);
  if(pending>0){timer=setTimeout(()=>failed(1011),stallTimeoutMs);timer.unref?.();}
 };
 return {
  dispose,
  send(data,binary) {
   if(disposed)return;
   const bytes=Buffer.byteLength(data);
   if(pending+bytes>MAX_QUEUED_BYTES||target.bufferedAmount+bytes>MAX_QUEUED_BYTES)return failed(1009);
   const wasEmpty=pending===0;pending+=bytes;if(wasEmpty)watch();
   try{target.send(data,{binary},error=>{
    if(disposed)return;
    pending-=bytes;
    if(error)return failed(1011);
    watch();
   });}catch{failed(1011);}
  }
 };
}
export function createProxy(env,{fetchImpl=fetch,webSocketFactory=(url,options)=>new WebSocket(url,options),stallTimeoutMs=5000}={}){
 let config;try{config=settings(env);}catch{}
 const port=Number(env.PROXY_PORT||8787),origin=`http://127.0.0.1:${port}`;
 const wss=new WebSocketServer({noServer:true,maxPayload:128*1024,perMessageDeflate:false});
 const server=http.createServer(async(req,res)=>{
  try{
   const url=new URL(req.url,origin);
   if(req.headers.host!==new URL(origin).host)return fail(res,403,'forbidden');
   if(req.method==='GET'&&url.pathname==='/health')return send(res,200,{status:'ok',configured:!!config});
   if(!config)return fail(res,503,'not_configured');
   if(!allowed(req,origin,config))return fail(res,403,'forbidden');
   if(req.method==='OPTIONS'){
    if(!req.headers.origin)return fail(res,403,'forbidden');
    res.writeHead(204,{'Access-Control-Allow-Origin':req.headers.origin,'Access-Control-Allow-Headers':'Authorization, Content-Type','Access-Control-Allow-Methods':'GET, POST, DELETE, OPTIONS','Vary':'Origin'});return res.end();
   }
   if(/^\/v1\/mail\/(gmail|outlook)\/(connect|complete|callback)$/.test(url.pathname))return fail(res,503,'mail_not_configured');
   if(!rules.some(([method,pattern])=>method===req.method&&pattern.test(url.pathname)))return fail(res,404,'not_found');
   if(url.search)return fail(res,400,'invalid_request');
   if(url.pathname!=='/v1/invites/redeem'&&!/^Bearer [^\s]+$/.test(req.headers.authorization||''))return fail(res,401,'unauthorized');
   let body=['GET','HEAD'].includes(req.method)?undefined:await boundedBody(req,1024*1024);
   if(req.method==='POST'&&url.pathname==='/v1/writing/drafts'){
    let input;try{input=JSON.parse(body);}catch{return fail(res,422,'invalid_input');}
    if(!input||typeof input!=='object'||Array.isArray(input))return fail(res,422,'invalid_input');
    if(input.compose&&typeof input.compose==='object'&&!Array.isArray(input.compose)){
     delete input.compose.add_signature;
     if(config.footerField)input.compose[config.footerField]=false;
    }
    body=JSON.stringify(input);
   }
   const target=new URL(config.api);target.pathname=config.api.pathname.replace(/\/$/,'')+url.pathname;target.search='';
   const response=await fetchImpl(target,{method:req.method,headers:forwardHeaders(req),body,redirect:'manual',signal:AbortSignal.timeout(120000)});
   const headers={};for(const name of ['retry-after','content-language']){const value=response.headers.get(name);if(value&&!opaqueLeaks(value,config))headers[name]=value;}
   if(req.headers.origin){headers['Access-Control-Allow-Origin']=req.headers.origin;headers.Vary='Origin';}
   if(response.status>=300&&response.status<400){const location=privateURL(response.headers.get('location')||'',config,origin);if(!location)return fail(res,502,'unsafe_redirect');res.writeHead(response.status,{...jsonHeaders,...headers,Location:location});return res.end();}
   if([204,205,304].includes(response.status)){res.writeHead(response.status,headers);return res.end();}
   const raw=response.body?await boundedBody(response.body,8*1024*1024):Buffer.alloc(0);
   if(!(response.headers.get('content-type')||'').includes('json'))return fail(res,response.status>=400?response.status:502,'upstream_unavailable');
   let value;try{value=JSON.parse(raw);}catch{return fail(res,502,'invalid_response');}
   if(response.status>=400)return send(res,response.status,{detail:knownErrors.has(value?.detail)?value.detail:'upstream_unavailable'},headers);
   if(url.pathname==='/v1/speech/grants'){
    if(typeof value.grant!=='string'||!Number.isInteger(value.expires_in)||value.expires_in<1||value.expires_in>900)return fail(res,502,'invalid_response');
    value.grant=sealGrant(value.grant,value.expires_in,config,origin);if(value.grant.length>PROXY_GRANT_LIMIT)return fail(res,502,'invalid_response');
    value.speech_url=origin.replace(/^http/,'ws')+'/speech';
   }
   value=sanitize(value,config,origin);send(res,response.status,value,headers);
  }catch{if(!res.headersSent)fail(res,502,'upstream_unavailable');else res.destroy();}
 });
 server.on('upgrade',(req,socket,head)=>{
  let rejected=false;
  socket.on('error',()=>{});
  const reject=(code=401)=>{if(rejected||socket.destroyed)return;rejected=true;socket.end(`HTTP/1.1 ${code} Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);};
  if(!config||!allowed(req,origin,config)||req.url!=='/speech')return reject(403);
  let grant;try{if(!/^Bearer [^\s]+$/.test(req.headers.authorization||''))return reject();grant=openGrant(req.headers.authorization.slice(7),config,origin);}catch{return reject();}
  let upstream;try{upstream=webSocketFactory(config.speech.href,{headers:{Authorization:'Bearer '+grant},followRedirects:false,handshakeTimeout:10000,maxPayload:1024*1024,perMessageDeflate:false});}catch{return reject(502);}
  let accepted=false,downstream;
  upstream.once('open',()=>{
   try{wss.handleUpgrade(req,socket,head,ws=>{
    accepted=true;downstream=ws;
    let closed=false,toUpstream,toDownstream,termination;
    const dispose=()=>{toUpstream?.dispose();toDownstream?.dispose();clearTimeout(termination);};
    const abort=(code=1011)=>{
     if(closed)return;closed=true;dispose();
     // Drop the congested upstream immediately; a close frame can itself be queued.
     upstream.terminate();
     try{ws.close(code);}catch{ws.terminate();}
     termination=setTimeout(()=>ws.terminate(),250);termination.unref?.();
    };
    toUpstream=createBoundedForwarder(upstream,abort,stallTimeoutMs);
    toDownstream=createBoundedForwarder(ws,abort,stallTimeoutMs);
    ws.on('message',(data,binary)=>{try{
     if(binary){toUpstream.send(data,true);return;}
     const value=JSON.parse(data);if(!['start','stop','cancel'].includes(value?.type))return abort(1008);
     if(value.type==='start')value.retention=false;
     toUpstream.send(JSON.stringify(value),false);
    }catch{abort(1008);}});
    upstream.on('message',(data,binary)=>{try{
     if(binary)return abort(1003);
     let value=JSON.parse(data);if(['retention','evidence'].includes(value?.type))return;
     if(value?.type==='error')value={type:'error',reason:knownErrors.has(value.reason)?value.reason:'internal'};
     else if(!['text','transcript'].includes(value?.type))return abort(1008);
     toDownstream.send(JSON.stringify(sanitize(value,config,origin)),false);
    }catch{abort(1008);}});
    ws.on('close',()=>{closed=true;dispose();upstream.terminate();});
    ws.on('error',()=>abort(1011));
    upstream.on('close',()=>{dispose();if(!closed){closed=true;try{ws.close();}catch{ws.terminate();}}});
   });}catch{upstream.terminate();reject(400);}
  });
  upstream.on('unexpected-response',(_request,response)=>{response.resume();reject([401,403,429].includes(response.statusCode)?response.statusCode:502);upstream.terminate();});
  upstream.on('error',()=>{if(!accepted)reject(502);else downstream?.close(1011);});
  socket.on('close',()=>{if(!accepted)upstream.terminate();});
 });
 server.requestTimeout=125000;server.headersTimeout=15000;
 return {server,wss,origin,configured:!!config};
}
if(process.argv[1]&&fileURLToPath(import.meta.url)===resolve(process.argv[1])){
 const envFile=process.env.PROXY_ENV_FILE||fileURLToPath(new URL('../../.env',import.meta.url));
 if(existsSync(envFile))process.loadEnvFile(envFile);
 const proxy=createProxy(process.env);proxy.server.listen(Number(process.env.PROXY_PORT||8787),'127.0.0.1',()=>console.log(`Local proxy listening at ${proxy.origin}; configured=${proxy.configured}`));
}
