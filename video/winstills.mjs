import {bundle} from '@remotion/bundler';import {renderStill,selectComposition} from '@remotion/renderer';import path from 'node:path';
const root=process.cwd();const serveUrl=await bundle({entryPoint:path.join(root,'src/index.tsx'),publicDir:path.join(root,'public')});
const composition=await selectComposition({serveUrl,id:'IntentionDemo'});
for(const [n,s] of [['msg',80],['slack',110],['gmail',155],['notes',190]]){await renderStill({composition,serveUrl,frame:s*60,output:`/tmp/intention-evidence/v2/${n}-faces.png`,chromiumOptions:{gl:'angle'}});console.log(n);}
