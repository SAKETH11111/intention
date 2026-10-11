import {createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
const escape=s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
const list=s=>String(s||'').split(',').map(x=>x.trim()).filter(Boolean);
export function settings(env) {
  const api=new URL(env.UPSTREAM_API),speech=new URL(env.UPSTREAM_SPEECH);
  if(api.protocol!=='https:'||speech.protocol!=='wss:'||[api,speech].some(u=>u.username||u.password||u.search||u.hash))throw Error('configuration');
  const key=Buffer.from(env.PROXY_TOKEN_KEY||'','base64url');if(key.length!==32)throw Error('configuration');
  const names=[env.ORIGINAL_PRODUCT_NAME,...list(env.ORIGINAL_PRODUCT_ALIASES)].filter(Boolean);
  if(!names.length)throw Error('configuration');
  return {api,speech,key,names,hosts:[api.hostname,speech.hostname,...list(env.PRIVATE_HOSTS)],terms:list(env.PRIVATE_TERMS),footerField:env.UPSTREAM_FOOTER_FIELD,origins:list(env.ALLOWED_ORIGINS)};
}
function decoded(text) {
  // Decode valid runs independently so a literal percent sign cannot hide another run.
  for(let i=0;i<8;i++){
    const next=text.replace(/(?:%[a-f0-9]{2})+/gi,run=>Buffer.from(run.replaceAll('%',''),'hex').toString('utf8'));
    if(next===text)return text;
    text=next;
  }
  if(/%[a-f0-9]{2}/i.test(text))throw Error('encoding_depth');
  return text;
}
export function cleanText(input,config) {
  const candidate=decoded(input);
  let text=leaks(candidate,config)?candidate:input;
  for(const host of config.hosts){
    text=text.replace(new RegExp('(?:https?|wss?):\\/\\/'+escape(host)+'(?::\\d+)?[^\\s<>"\']*','gi'),'[private service]');
    text=text.replace(new RegExp(escape(host),'gi'),'[private service]');
  }
  for(const term of config.terms)text=text.replace(new RegExp(escape(term),'gi'),'[private service]');
  for(const name of config.names)text=text.replace(new RegExp('(?<![a-zA-Z0-9])'+escape(name)+'(?![a-zA-Z0-9])','gi'),'Intention');
  return text;
}
export function leaks(text,config) {
  text=decoded(String(text));
  return config.hosts.some(x=>text.toLowerCase().includes(x.toLowerCase()))||config.terms.some(x=>text.toLowerCase().includes(x.toLowerCase()))||config.names.some(x=>new RegExp('(?<![a-zA-Z0-9])'+escape(x)+'(?![a-zA-Z0-9])','i').test(text));
}
export function opaqueLeaks(input,config) {
  // The same bounded inspection applies to every leaf, regardless of its field name.
  const seen=new Set();
  function inspect(value,depth) {
    const text=decoded(value);
    if(seen.has(text))return false;
    seen.add(text);
    if(leaks(text,config))return true;
    for(const [part] of text.matchAll(/[A-Za-z0-9_+\/-]{8,}={0,2}/g)){
      const inner=Buffer.from(part,'base64url').toString('utf8');
      if(!inner||inner===text)continue;
      if(depth>=6)return true;
      if(inspect(inner,depth+1))return true;
    }
    return false;
  }
  return inspect(String(input),0);
}
const presentation=new Set(['service_name','product_name','brand_name','service']);
const signedFields=new Set(['signature','signed_payload','jwt']);
const disabledURLs=new Set(['upload_url','presigned_url','download_url','signed_url','authorization_url','oauth_url']);
const disabledFlags=new Set(['retention','retention_follows']);
function prohibitedCapability(value) {
  if(Array.isArray(value))return value.some(prohibitedCapability);
  if(!value||typeof value!=='object')return false;
  return Object.entries(value).some(([key,item])=>{
    const name=decoded(key).toLowerCase();
    return (disabledURLs.has(name)&&item!==null)||(disabledFlags.has(name)&&item!==false)||prohibitedCapability(item);
  });
}
function documentLeaks(value,config) {
  if(typeof value==='string')return opaqueLeaks(value,config);
  if(Array.isArray(value))return value.some(item=>documentLeaks(item,config));
  return !!value&&typeof value==='object'&&Object.entries(value).some(([key,item])=>opaqueLeaks(key,config)||documentLeaks(item,config));
}
export function privateURL(value,config,origin) {
  let url;try{url=new URL(value);}catch{return null;}
  // Paths and query values may bind a resource or a signed request. Never rename them.
  if(opaqueLeaks(url.pathname+url.search+url.hash,config))return null;
  if(url.hostname===config.speech.hostname&&['https:','wss:'].includes(url.protocol))return origin.replace(/^http/,'ws')+'/speech';
  if(url.origin===config.api.origin){
    const prefix=config.api.pathname.replace(/\/$/,'');
    const path=url.pathname.startsWith(prefix+'/')?url.pathname.slice(prefix.length):url.pathname;
    if(!/^\/v1\/(me|speech|mail|setup|writing)(?:\/|$)/.test(path)||url.search)return null;
    const mapped=origin+path;
    return opaqueLeaks(mapped,config)?null:mapped;
  }
  return null;
}
export function sanitize(value,config,origin,key='') {
  const field=decoded(key).toLowerCase();
  if(value&&typeof value==='object'&&Object.keys(value).some(k=>signedFields.has(decoded(k).toLowerCase()))) {
    if(prohibitedCapability(value))throw Error('signed_capability');
    if(documentLeaks(value,config))throw Error('private_signed_response');
    return value;
  }
  if(Array.isArray(value))return value.map(v=>sanitize(v,config,origin,key));
  if(value&&typeof value==='object'){
    const out=Object.create(null);
    for(const [k,v] of Object.entries(value)){
      // Renaming a key can change a protocol or source binding.
      if(opaqueLeaks(k,config))throw Error('private_key');
      const name=decoded(k).toLowerCase();
      if(disabledURLs.has(name)){out[k]=null;continue;}
      if(disabledFlags.has(name)){out[k]=false;continue;}
      out[k]=sanitize(v,config,origin,k);
    }
    return out;
  }
  if(typeof value!=='string')return value;
  if(/^speech_(url|endpoint)$/.test(field)){
    const local=origin.replace(/^http/,'ws')+'/speech';if(value===local)return local;
    const mapped=privateURL(decoded(value),config,origin);
    if(!mapped)throw Error('unsafe_speech_url');
    return mapped;
  }
  if(/url|uri|location|endpoint/.test(field)){
    const mapped=privateURL(decoded(value),config,origin);if(mapped)return mapped;
  }
  if(presentation.has(field)){
    const cleaned=cleanText(value,config);if(opaqueLeaks(cleaned,config))throw Error('private_presentation');return cleaned;
  }
  // User text, accepted commitments, identifiers and unknown fields retain their bytes.
  if(opaqueLeaks(value,config))throw Error('private_content');
  return value;
}
export const UPSTREAM_GRANT_LIMIT=512;
export const PROXY_GRANT_LIMIT=2048;
function validGrant(grant) {return typeof grant==='string'&&grant.length>0&&grant.length<=UPSTREAM_GRANT_LIMIT&&/^[\x21-\x7e]+$/.test(grant);}
export function sealGrant(grant,lifetime,config,origin,now=Date.now()) {
  if(!validGrant(grant)||!Number.isInteger(lifetime)||lifetime<1||lifetime>900)throw Error('grant');
  let expires=Math.floor(now/1000)+Math.min(lifetime,900);
  try{const claims=JSON.parse(Buffer.from(grant.split('.')[1],'base64url'));if(Number.isInteger(claims.exp))expires=Math.min(expires,claims.exp);}catch{}
  const nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',config.key,nonce);cipher.setAAD(Buffer.from('speech-grant-v1'));
  const ciphertext=Buffer.concat([cipher.update(JSON.stringify({g:grant,e:expires,o:origin})),cipher.final(),cipher.getAuthTag()]);
  const token='sg1.'+nonce.toString('base64url')+'.'+ciphertext.toString('base64url');
  if(token.length>PROXY_GRANT_LIMIT)throw Error('token');
  return token;
}
export function openGrant(token,config,origin,now=Date.now()) {
  if(typeof token!=='string'||token.length>PROXY_GRANT_LIMIT)throw Error('token');
  const [version,iv,data,...extra]=token.split('.');if(version!=='sg1'||!/^[A-Za-z0-9_-]{16}$/.test(iv||'')||!/^[A-Za-z0-9_-]+$/.test(data||'')||extra.length)throw Error('token');
  const bytes=Buffer.from(data,'base64url'),cipher=createDecipheriv('aes-256-gcm',config.key,Buffer.from(iv,'base64url'));cipher.setAAD(Buffer.from('speech-grant-v1'));cipher.setAuthTag(bytes.subarray(-16));
  const clear=Buffer.concat([cipher.update(bytes.subarray(0,-16)),cipher.final()]);const value=JSON.parse(clear);
  if(value.o!==origin||!Number.isInteger(value.e)||value.e<=Math.floor(now/1000)||value.e>Math.floor(now/1000)+900||!validGrant(value.g))throw Error('expired');
  return value.g;
}
