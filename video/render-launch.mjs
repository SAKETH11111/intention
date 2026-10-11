import {bundle} from '@remotion/bundler';
import {renderMedia,renderStill,selectComposition} from '@remotion/renderer';
import path from 'node:path';
const root=process.argv[2];const id=process.argv[4]||'IntentionLaunch';const out=process.argv[5]||'/tmp/intention-evidence/launch';
const serveUrl=await bundle({entryPoint:path.join(root,'src/index.tsx'),publicDir:path.join(root,'public')});
const composition=await selectComposition({serveUrl,id});
if(process.argv[3]==='stills'){for(const sec of (process.env.STILLS||'2,5,9.5,13,17,25,34,44,50.5,55,60,68').split(',').map(Number)){await renderStill({composition,serveUrl,frame:Math.round(sec*30),output:`${out}/still-${sec}.png`,scale:0.5,chromiumOptions:{gl:'angle'}});console.log('still',sec);}}
else{const t=Date.now();await renderMedia({composition,serveUrl,codec:'h264',pixelFormat:'yuv420p',crf:18,outputLocation:`${out}/${id==='IntentionLaunch'?'intention-launch':id==='IntentionLaunch3'?'intention-launch-v3':'intention-launch-v2'}.mp4`,concurrency:8,muted:id==='IntentionLaunch',chromiumOptions:{gl:'angle'},onProgress:({progress})=>{if(Math.round(progress*100)%10===0)process.stdout.write(`${Math.round(progress*100)}% `)}});console.log('\ndone',(Date.now()-t)/1000);}
