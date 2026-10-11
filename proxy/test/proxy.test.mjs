import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import {generateKeyPairSync,sign,createHmac,createHash} from 'node:crypto';
import {once} from 'node:events';
import {writeFile} from 'node:fs/promises';
import {WebSocket,WebSocketServer} from 'ws';
import {createProxy,createBoundedForwarder} from '../src/server.mjs';
import {settings,sanitize,cleanText,leaks,opaqueLeaks,sealGrant,openGrant} from '../src/privacy.mjs';
const env={UPSTREAM_API:'https://api.legacy.example',UPSTREAM_SPEECH:'wss://speech.legacy.example/asr',ORIGINAL_PRODUCT_NAME:'LegacyBrand',ORIGINAL_PRODUCT_ALIASES:'LegacyOrg',PRIVATE_HOSTS:'other.legacy.example',PRIVATE_TERMS:'com.legacy.example',UPSTREAM_FOOTER_FIELD:'add_legacy_footer',PROXY_TOKEN_KEY:Buffer.alloc(32,7).toString('base64url'),ALLOWED_ORIGINS:'https://demo.example'};
const config=settings(env),captures=[];
let proxy,fixture,fixturePort,port,mode='identity',forwarded,currentGrant='fixture-grant',nextResponse,nextHeaders={};
const upstreams=[];let speechFields={};
const json=(v,status=200,headers={})=>new Response(JSON.stringify(v),{status,headers:{'Content-Type':'application/json',...headers}});
async function freePort(){const s=net.createServer();s.listen(0,'127.0.0.1');await once(s,'listening');const p=s.address().port;await new Promise(r=>s.close(r));return p;}
before(async()=>{
 fixture=new WebSocketServer({port:0,host:'127.0.0.1',verifyClient:(_info,done)=>mode==='refused'?done(false,401):done(true)});await once(fixture,'listening');fixturePort=fixture.address().port;
 fixture.on('connection',(ws,req)=>{
  assert.equal(req.headers.authorization,'Bearer '+currentGrant);let frames=0,bytes=0,retention;const hash=createHash('sha256');
  if(mode==='paused'){ws.pause();return;}
  ws.on('message',(data,binary)=>{
   if(binary){frames++;bytes+=data.length;hash.update(data);return;}
   const msg=JSON.parse(data);
   if(msg.type==='start')retention=msg.retention;
   if(msg.type==='stop'){
    if(mode==='binary'){ws.send(Buffer.from([1,2,3]));return;}
    ws.send(JSON.stringify({type:'transcript',text:mode==='unsafe-text'?'I will deliver the LegacyBrand integration on Thursday':'Synthetic speech.',service_name:'LegacyBrand',frames,bytes,retention,audio_hash:hash.digest('hex'),...speechFields}));
    ws.send(JSON.stringify({type:'text',text:'Synthetic speech.',cleaned:true}));
   }
  });
 });
 port=await freePort();
 proxy=createProxy({...env,PROXY_PORT:String(port)},{
  webSocketFactory:(_url,opts)=>{const ws=new WebSocket(`ws://127.0.0.1:${fixturePort}`,opts);upstreams.push(ws);return ws;},
  fetchImpl:async(url,opts)=>{
   forwarded={url:String(url),...opts};
   if(mode==='custom')return json(nextResponse,200,nextHeaders);
   if(mode==='redirect')return new Response(null,{status:303,headers:{Location:'https://api.legacy.example/v1/me'}});
   if(mode==='unsafe-redirect')return new Response(null,{status:303,headers:{Location:'https://outside.example/steal'}});
   if(mode==='html')return new Response('<html>LegacyBrand https://api.legacy.example/private</html>',{status:500,headers:{'Content-Type':'text/html','Server':'LegacyBrand','Via':'private','X-Provider':'LegacyOrg','Set-Cookie':'s=private'}});
   if(mode==='error')return json({detail:'LegacyBrand failed',trace:'api.legacy.example'},503,{'Retry-After':'4'});
   if(mode==='safe-error')return json({detail:'proposal_limit'},409,{'Retry-After':'4'});
   if(mode==='shown')return new Response(null,{status:204});
   if(mode==='grant')return json({grant:currentGrant,expires_in:300,speech_url:env.UPSTREAM_SPEECH},201);
   if(mode==='throw')throw Error('Private LegacyBrand credential');
   return json({account_id:'00000000-0000-0000-0000-000000000001',device_id:'00000000-0000-0000-0000-000000000002',service_name:'LegacyBrand',nested:{body:'Synthetic body.',text:'Synthetic text.',subject:'Synthetic subject.'},upload_url:'https://other.legacy.example/upload'},200,{'Server':'LegacyBrand','Via':'private','X-Provider':'LegacyOrg','Set-Cookie':'s=private'});
  }
 });
 proxy.server.listen(port,'127.0.0.1');await once(proxy.server,'listening');
});
after(async()=>{
 for(const client of fixture.clients)client.terminate();for(const client of proxy.wss.clients)client.terminate();
 await new Promise(r=>fixture.close(r));await new Promise(r=>proxy.server.close(r));
});
async function request(path,options={}){return fetch(proxy.origin+path,{headers:{Authorization:'Bearer opaque-device','Content-Type':'application/json'},...options,redirect:'manual'});}
async function capture(response){const x={status:response.status,headers:Object.fromEntries(response.headers),body:await response.text()};captures.push(x);return x;}
test('HTTP routing preserves prefix, body content and only approved auth headers',async()=>{
 mode='identity';const body={cue:'User input mentioning LegacyBrand',compose:{subject:'Test',add_signature:true}};
 const r=await request('/v1/writing/drafts',{method:'POST',body:JSON.stringify(body),headers:{Authorization:'Bearer opaque-device','Content-Type':'application/json','X-Provider':'private','CF-Connecting-IP':'1.2.3.4',Cookie:'private'}});
 assert.equal(r.status,200);assert.equal(forwarded.url,'https://api.legacy.example/v1/writing/drafts');
 assert.equal(forwarded.headers.authorization,'Bearer opaque-device');assert.equal(forwarded.headers['content-type'],'application/json');assert.ok(!('cookie' in forwarded.headers));assert.ok(!('x-provider' in forwarded.headers));assert.ok(!('cf-connecting-ip' in forwarded.headers));
 assert.deepEqual(JSON.parse(forwarded.body),{cue:body.cue,compose:{subject:'Test',add_legacy_footer:false}});
 const x=await capture(r);assert.ok(!leaks(JSON.stringify(x),config));
 for(const k of Object.keys(x.headers))assert.ok(!/^x-|^(server|via|set-cookie)$/i.test(k));
});
test('only explicit presentation metadata is rebranded',()=>{
 const result=sanitize({service_name:'LegacyBrand at api.legacy.example',nested:{product_name:'LegacyOrg'},untouched:'Intention intentional'},config,proxy.origin);
 assert.ok(!leaks(JSON.stringify(result),config));assert.equal(result.service_name,'Intention at [private service]');assert.equal(result.untouched,'Intention intentional');
 for(const field of ['text','transcript','body','subject','message','cue','plain_text','html','edited_draft','source_id','revision','unknown'])assert.throws(()=>sanitize({[field]:'LegacyBrand'},config,proxy.origin));
 assert.throws(()=>sanitize({'%4cegacyBrand':'value'},config,proxy.origin));
 assert.throws(()=>sanitize({device_key:Buffer.from('LegacyBrand').toString('base64url')},config,proxy.origin));
 assert.equal(cleanText('LegacyBrand LegacyBranding Intention',config),'Intention LegacyBranding Intention');assert.equal(cleanText('A%20user%20subject',config),'A%20user%20subject');
});
test('redirects are restricted and errors, HTML, cookies stay private',async()=>{
 mode='redirect';let r=await request('/v1/me');assert.equal(r.status,303);assert.equal(r.headers.get('location'),proxy.origin+'/v1/me');await capture(r);
 mode='unsafe-redirect';r=await request('/v1/me');assert.equal(r.status,502);await capture(r);
 for(const m of ['html','error','safe-error','throw']){mode=m;const x=await capture(await request('/v1/me'));assert.ok(!leaks(JSON.stringify(x),config));if(m==='safe-error')assert.equal(JSON.parse(x.body).detail,'proposal_limit');}
});
test('disabled routes, queries, arbitrary targets and browser origins never reach upstream',async()=>{
 mode='identity';
 for(const [path,method] of [['/v1/mail/gmail/connect','POST'],['/v1/mail/outlook/complete','POST'],['/v1/mail/gmail/callback','GET'],['/v1/mail/connections/00000000-0000-0000-0000-000000000000','DELETE'],['/v1/retention/events','POST'],['/v1/problem-reports','POST'],['/v1/objects/audio','POST'],['/https://outside.example','GET'],['/v1/me?target=outside','GET']]){
 forwarded=null;const r=await request(path,{method});assert.ok(r.status>=400);assert.equal(forwarded,null);await capture(r);
 }
 const r=await request('/v1/me',{headers:{Origin:'https://outside.example'}});assert.equal(r.status,403);
});
test('204 admission remains empty',async()=>{mode='shown';const r=await request('/v1/writing/drafts/00000000-0000-0000-0000-000000000000/shown',{method:'POST',body:'{"revision":1}'});assert.equal(r.status,204);assert.equal(await r.text(),'');});
test('speech token hides raw and decoded identity, respects expiry and rejects tampering',()=>{
 const grant='v1.'+Buffer.from(JSON.stringify({aud:'LegacyBrand-speech',exp:1700000300})).toString('base64url')+'.opaque';
 const token=sealGrant(grant,300,config,proxy.origin,1700000000000);assert.ok(!opaqueLeaks(token,config));assert.equal(openGrant(token,config,proxy.origin,1700000000000),grant);
 assert.throws(()=>openGrant(token,config,'http://other.example',1700000000000));assert.throws(()=>openGrant(token,config,proxy.origin,1700000301000));assert.throws(()=>openGrant(token.slice(0,-4)+'AAAA',config,proxy.origin,1700000000000));
});
test('real WebSocket upgrade forwards binary audio and sanitizes response text',async()=>{
 mode='grant';const grant=await (await request('/v1/speech/grants',{method:'POST'})).json();assert.ok(grant.grant.startsWith('sg1.'));assert.ok(!opaqueLeaks(grant.grant,config));
 const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+grant.grant}});await once(ws,'open');
 const messages=[];const done=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('timeout')),5000);ws.on('message',data=>{messages.push(JSON.parse(data));if(messages.length===2){clearTimeout(timer);resolve();}});});
 ws.send('{"type":"start","app":"other","retention":true}');const pcm=Buffer.alloc(3200);for(let i=0;i<1600;i++)pcm.writeInt16LE(i-800,i*2);for(let i=0;i<64;i++)ws.send(pcm);ws.send('{"type":"stop","frames":64}');await done;
 assert.equal(messages[0].frames,64);assert.equal(messages[0].bytes,204800);assert.equal(messages[0].audio_hash,createHash('sha256').update(Buffer.concat(Array(64).fill(pcm))).digest('hex'));assert.equal(messages[0].retention,false);assert.equal(messages[0].text,'Synthetic speech.');assert.equal(messages[0].service_name,'Intention');assert.ok(!leaks(JSON.stringify(messages),config));captures.push({ws:messages});ws.close();await once(ws,'close');
});
test('unknown binary reply closes safely',async()=>{
 mode='grant';const grant=await (await request('/v1/speech/grants',{method:'POST'})).json();mode='binary';
 const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+grant.grant}});await once(ws,'open');ws.send('{"type":"start"}');ws.send('{"type":"stop","frames":0}');
 const [code]=await once(ws,'close');assert.equal(code,1003);
});
test('upstream WebSocket refusal stays generic and leaves server healthy',async()=>{
 mode='grant';const grant=await (await request('/v1/speech/grants',{method:'POST'})).json();mode='refused';
 const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+grant.grant}});
 const status=await new Promise((resolve,reject)=>{ws.once('unexpected-response',(_req,res)=>{res.resume();ws.terminate();resolve(res.statusCode);});ws.on('error',()=>{});setTimeout(()=>reject(Error('timeout')),1000).unref();});
 assert.equal(status,401);assert.equal((await request('/health')).status,200);
});
function signedGrant(kind) {
 const now=Math.floor(Date.now()/1000),claims={aud:'LegacyBrand-speech',sub:'00000000-0000-0000-0000-000000000001',iat:now,exp:now+300};
 if(kind==='ed25519'){
  const payload=Buffer.from(JSON.stringify(claims)).toString('base64url');const {privateKey}=generateKeyPairSync('ed25519');
  return 'v1.'+payload+'.'+sign(null,Buffer.from('LegacyBrand-speech-grant.v1.'+payload),privateKey).toString('base64url');
 }
 const header=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
 const payload=Buffer.from(JSON.stringify({...claims,device_id:'00000000-0000-0000-0000-000000000002',nonce:'synthetic-nonce-0000000000000000'})).toString('base64url');
 return header+'.'+payload+'.'+createHmac('sha256','synthetic-only-key').update(header+'.'+payload).digest('base64url');
}
test('realistic signed grants cross HTTP and WebSocket within the new bounded wrapper limit',async()=>{
 for(const kind of ['ed25519','hs256']){
  currentGrant=signedGrant(kind);assert.ok(currentGrant.length<=512);mode='grant';
  const response=await request('/v1/speech/grants',{method:'POST'});assert.equal(response.status,201);const value=await response.json();
  assert.ok(value.grant.length<=2048);if(kind==='hs256')assert.ok(value.grant.length>512);
  assert.ok(!opaqueLeaks(value.grant,config));assert.equal(openGrant(value.grant,config,proxy.origin),currentGrant);
  const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+value.grant}});await once(ws,'open');
  const done=once(ws,'message');ws.send('{"type":"start"}');ws.send(Buffer.alloc(3200));ws.send('{"type":"stop","frames":1}');const [data]=await done;assert.equal(JSON.parse(data).bytes,3200);ws.close();await once(ws,'close');
 }
 currentGrant='fixture-grant';
 assert.throws(()=>sealGrant('x'.repeat(513),300,config,proxy.origin));
 assert.throws(()=>openGrant('x'.repeat(2049),config,proxy.origin));
});
test('private commitments and source bindings fail closed without a modified accepted receipt',async()=>{
 mode='custom';
 for(const value of [{accepted:true,text:'I will deliver the LegacyBrand integration on Thursday'},{accepted:true,sources:[{source_id:'LegacyBrand-source',revision:'unchanged'}]},{accepted:true,sources:[{source_id:'unchanged',revision:'LegacyBrand-revision'}]}]){
  nextResponse=value;const response=await request('/v1/writing/drafts/00000000-0000-0000-0000-000000000000');assert.equal(response.status,502);const result=await capture(response);assert.deepEqual(JSON.parse(result.body),{detail:'upstream_unavailable'});
 }
 nextResponse={accepted:true,text:'I will deliver the integration on Thursday',sources:[{source_id:'source-123',revision:'revision-456'}]};
 assert.deepEqual(await (await request('/v1/writing/drafts/00000000-0000-0000-0000-000000000000')).json(),nextResponse);
});
test('encoded signed payloads and JWTs are rejected without rewriting signed documents',async()=>{
 const token=signedGrant('hs256');mode='custom';
 for(const field of ['jwt','signed_payload','%6awt']){
  nextResponse={[field]:token};assert.throws(()=>sanitize(nextResponse,config,proxy.origin));const response=await request('/v1/me');assert.equal(response.status,502);await capture(response);
 }
 assert.throws(()=>sanitize({signature:'safe',body:{token}},config,proxy.origin));
 const safe={signature:'opaque',body:'Safe signed content',retention:false};assert.equal(sanitize(safe,config,proxy.origin),safe);
});
test('private path identifiers are rejected after recognizing the upstream host',async()=>{
 mode='custom';for(const suffix of ['LegacyBrand','%4cegacyBrand']){
  nextResponse={resource_url:'https://api.legacy.example/v1/writing/'+suffix};const response=await request('/v1/me');assert.equal(response.status,502);await capture(response);
 }
});
test('unsafe speech content closes instead of rewriting the transcript',async()=>{
 currentGrant='fixture-grant';mode='grant';const value=await (await request('/v1/speech/grants',{method:'POST'})).json();mode='unsafe-text';
 const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+value.grant}});await once(ws,'open');let received=0;ws.on('message',()=>received++);ws.send('{"type":"start"}');ws.send('{"type":"stop","frames":0}');const [code]=await once(ws,'close');assert.equal(code,1008);assert.equal(received,0);
});
test('a paused upstream cannot accumulate more than the one MiB send ceiling',async()=>{
 currentGrant='fixture-grant';mode='grant';const value=await (await request('/v1/speech/grants',{method:'POST'})).json();mode='paused';
 const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+value.grant}});await once(ws,'open');
 const target=upstreams.at(-1);let peak=0;const sample=setInterval(()=>{peak=Math.max(peak,target.bufferedAmount);},1);
 const closed=once(ws,'close');for(let i=0;i<512;i++)ws.send(Buffer.alloc(32768));
 const [code]=await Promise.race([closed,new Promise((_,reject)=>setTimeout(()=>reject(Error('queue ceiling did not close')),3000).unref())]);clearInterval(sample);
 assert.equal(code,1009);assert.ok(peak<=1024*1024);assert.ok(target.readyState===WebSocket.CLOSED||target.readyState===WebSocket.CLOSING);
});
test('queued sends stop at one MiB even before the transport reports backpressure',()=>{
 let calls=0,aborted;const target={bufferedAmount:0,send(){calls++;}};
 const relay=createBoundedForwarder(target,code=>{aborted=code;});for(let i=0;i<65;i++)relay.send(Buffer.alloc(16384),true);
 assert.equal(calls,64);assert.equal(aborted,1009);relay.dispose();
});
test('a stalled send callback is terminated even when new messages trickle in',async()=>{
 let aborted;const target={bufferedAmount:0,send(){}};const relay=createBoundedForwarder(target,code=>{aborted=code;},60);
 relay.send(Buffer.alloc(16),true);const trickle=setInterval(()=>relay.send(Buffer.alloc(16),true),10);await new Promise(resolve=>setTimeout(resolve,100));clearInterval(trickle);relay.dispose();assert.equal(aborted,1011);
});
test('a rejected downstream upgrade leaves no orphan upstream',async()=>{
 currentGrant='fixture-grant';mode='grant';const value=await (await request('/v1/speech/grants',{method:'POST'})).json();const start=upstreams.length;
 const socket=net.connect(port,'127.0.0.1');await once(socket,'connect');let response='';socket.on('data',chunk=>{response+=chunk;});
 socket.write('GET /speech HTTP/1.1\r\nHost: 127.0.0.1:'+port+'\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer '+value.grant+'\r\n\r\n');
 await once(socket,'close');assert.match(response,/HTTP\/1\.1 400/);await new Promise(resolve=>setTimeout(resolve,50));
 assert.equal(upstreams.length,start+1);assert.equal(upstreams.at(-1).readyState,WebSocket.CLOSED);assert.equal(proxy.wss.clients.size,0);
});
test('percent-encoded token separators cannot hide private signed claims',async()=>{
 const payload=Buffer.from(JSON.stringify({aud:'LegacyBrand-speech',sub:'synthetic-account'})).toString('base64url');
 const jwt=Buffer.from('{"alg":"HS256"}').toString('base64url')+'.'+payload+'.synthetic-signature';
 mode='custom';
 for(const field of ['jwt','signed_payload','access_token']){
  for(const token of [jwt,jwt.replaceAll('.','%2E'),jwt.replaceAll('.','%252e')]){
   nextResponse={[field]:token};const response=await request('/v1/me');
   assert.equal(response.status,502,field+' must reject private decoded claims');
   const result=await capture(response);assert.deepEqual(JSON.parse(result.body),{detail:'upstream_unavailable'});
  }
 }
});
test('safe opaque tokens retain their original percent encoding and bytes',async()=>{
 const payload=Buffer.from(JSON.stringify({aud:'Intention-speech',sub:'synthetic-account'})).toString('base64url');
 const safe=Buffer.from('{"alg":"HS256"}').toString('base64url')+'%2e'+payload+'%2Esynthetic_signature';
 mode='custom';
 for(const field of ['jwt','signed_payload','access_token']){
  nextResponse={[field]:safe};const response=await request('/v1/me');assert.equal(response.status,200);assert.deepEqual(await response.json(),nextResponse);
 }
});
test('underscore-separated private identifiers fail closed in complete receipts and mapped URLs',async()=>{
 mode='custom';
 const receipt={request_id:'00000000-0000-0000-0000-000000000000',status:'ready',revision:1,accepted:true,text:'I will deliver the integration on Thursday.',sources:[{source_id:'LegacyBrand_source',revision:'revision_1'}]};
 const values=[receipt,{...receipt,sources:[{source_id:'safe_source',revision:'revision_LegacyBrand'}]},{...receipt,sources:[{source_id:'%4cegacyBrand_source',revision:'revision_1'}]},{resource_url:'https://api.legacy.example/v1/writing/LegacyBrand_source'},{resource_url:'https://api.legacy.example/v1/writing/%4cegacyBrand_source'},{LegacyBrand_status:'ready'}];
 for(const value of values){
  nextResponse=value;const response=await request('/v1/writing/drafts/00000000-0000-0000-0000-000000000000');assert.equal(response.status,502);const result=await capture(response);assert.deepEqual(JSON.parse(result.body),{detail:'upstream_unavailable'});
 }
 assert.equal(cleanText('LegacyBrand_service',config),'Intention_service');
 nextResponse={...receipt,text:'Intention is intentional.',sources:[{source_id:'Intention_source',revision:'revision_Intention'}]};
 const safe=await request('/v1/writing/drafts/00000000-0000-0000-0000-000000000000');assert.equal(safe.status,200);assert.deepEqual(await safe.json(),nextResponse);
});
function privateToken() {
 return Buffer.from('{"alg":"HS256"}').toString('base64url')+'.'+Buffer.from(JSON.stringify({aud:'LegacyBrand-speech',iss:'https://api.legacy.example'})).toString('base64url')+'.synthetic_signature';
}
async function probeSpeech(fields) {
 currentGrant='fixture-grant';mode='grant';const grant=await (await request('/v1/speech/grants',{method:'POST'})).json();speechFields=fields;
 const ws=new WebSocket(proxy.origin.replace(/^http/,'ws')+'/speech',{headers:{Authorization:'Bearer '+grant.grant}});await once(ws,'open');
 const messages=[];ws.on('message',data=>messages.push(JSON.parse(data)));
 const close=once(ws,'close'),timer=setTimeout(()=>ws.close(),60);
 ws.send('{"type":"start"}');ws.send('{"type":"stop","frames":0}');const [code]=await close;clearTimeout(timer);speechFields={};return {code,messages};
}
test('unknown token fields and nested token containers receive the same encoded inspection over HTTP and WS',async()=>{
 const token=privateToken();
 for(const fields of [{id_token:token},{refresh_token:token},{access_token:{value:token}},{future_credentials:[{value:token}]}]){
  mode='custom';nextResponse=fields;const response=await request('/v1/me');assert.equal(response.status,502);await capture(response);
  const speech=await probeSpeech(fields);assert.equal(speech.code,1008);assert.equal(speech.messages.length,0);
 }
});
test('valid percent runs are inspected even beside literal percent characters',async()=>{
 mode='custom';nextResponse={text:'Legacy%42rand launch is 90% complete'};
 let response=await request('/v1/me');assert.equal(response.status,502);await capture(response);
 assert.equal(cleanText('Legacy%42rand launch is 90% complete',config),'Intention launch is 90% complete');
 const token=privateToken().replaceAll('.','%2E')+'%';nextResponse={id_token:token};response=await request('/v1/me');assert.equal(response.status,502);await capture(response);
 const speech=await probeSpeech({id_token:token});assert.equal(speech.code,1008);assert.equal(speech.messages.length,0);
});
test('signed documents cannot bypass disabled capability policy through direct or nested fields',async()=>{
 for(const fields of [{signature:'opaque',oauth_url:'https://external.example/authorize'},{signature:'opaque',upload_url:'https://external.example/upload'},{signature:'opaque',body:{upload_url:'https://external.example/upload'}},{signature:'opaque',body:[{authorization_url:'https://external.example/authorize'}]}]){
  mode='custom';nextResponse=fields;const response=await request('/v1/me');assert.equal(response.status,502);await capture(response);
  const speech=await probeSpeech(fields);assert.equal(speech.code,1008);assert.equal(speech.messages.length,0);
 }
});
test('safe unknown token fields retain original bytes and signed disabled capabilities remain inert',async()=>{
 const safe=Buffer.from('{"aud":"Intention-speech"}').toString('base64url')+'%2Eopaque%';
 const fields={id_token:safe,refresh_token:safe,nested:{access_token:{value:safe}},text:'Launch is 90% complete'};
 mode='custom';nextResponse=fields;const response=await request('/v1/me');assert.equal(response.status,200);assert.deepEqual(await response.json(),fields);
 const speech=await probeSpeech(fields);assert.equal(speech.messages[0].id_token,safe);assert.deepEqual(speech.messages[0].nested,fields.nested);
 const signed={signature:'safe',upload_url:null,oauth_url:null,retention:false};assert.equal(sanitize(signed,config,proxy.origin),signed);
});
test('retained response headers drop encoded private identities individually',async()=>{
 mode='custom';nextResponse={status:'ok'};
 const encoded=[Buffer.from('LegacyBrand').toString('base64'),Buffer.from('https://api.legacy.example/private').toString('base64url')];
 for(const name of ['content-language','retry-after']){
  for(const value of encoded){
   nextHeaders={'Content-Language':'en-US','Retry-After':'120',[name]:value};
   const response=await request('/v1/me');assert.equal(response.status,200);assert.equal(response.headers.get(name),null);
   const kept=name==='content-language'?'retry-after':'content-language';assert.equal(response.headers.get(kept),kept==='retry-after'?'120':'en-US');await capture(response);
  }
 }
 nextHeaders={};
});
test('retained safe headers keep their original values',async()=>{
 mode='custom';nextResponse={status:'ok'};nextHeaders={'Content-Language':'en-US, fr','Retry-After':'Wed, 21 Oct 2026 07:28:00 GMT'};
 const response=await request('/v1/me');assert.equal(response.status,200);assert.equal(response.headers.get('content-language'),'en-US, fr');assert.equal(response.headers.get('retry-after'),'Wed, 21 Oct 2026 07:28:00 GMT');await capture(response);nextHeaders={};
});
test('captured synthetic responses have zero configured private identifiers',async()=>{assert.ok(!leaks(JSON.stringify(captures),config));if(process.env.PROXY_TEST_EVIDENCE)await writeFile(process.env.PROXY_TEST_EVIDENCE,JSON.stringify({fixtureOnly:true,privateIdentifierMatches:0,captures},null,2));});
