import {bundle} from '@remotion/bundler';
import {renderMedia, renderStill, selectComposition} from '@remotion/renderer';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {snapshotStage} from './snapshot.mjs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const evidence = process.env.VIDEO_OUTPUT_DIR || '/tmp/intention-evidence/remotion';
const test = process.argv.includes('--test');
const prepareOnly = process.argv.includes('--prepare-only');
const stillsOnly = process.argv.includes('--stills');
const frozenIndex = process.argv.indexOf('--frozen');
const started = Date.now();
await mkdir(evidence,{recursive:true});
let serveUrl;
let composition;
let prepared;
if(frozenIndex >= 0) {
  prepared = JSON.parse(await readFile(process.argv[frozenIndex+1],'utf8'));
  ({serveUrl,composition} = prepared);
} else {
  const runId = new Date().toISOString().replace(/[^0-9]/g,'');
  const frozenAssets = path.join(evidence,'snapshots',runId);
  const manifestDirectory = path.join(evidence,'manifests',runId);
  await mkdir(manifestDirectory,{recursive:true});
  await snapshotStage(path.join(root,'site'),frozenAssets,manifestDirectory);
  serveUrl = await bundle({entryPoint:path.join(here,'src/index.tsx'),publicDir:frozenAssets,outDir:path.join(evidence,'bundles',runId)});
  composition = await selectComposition({serveUrl,id:'IntentionDemo'});
  prepared = {serveUrl,composition,frozenAssets,manifest:path.join(manifestDirectory,'stage-snapshot.json')};
  await writeFile(path.join(evidence,'prepared.json'),JSON.stringify(prepared,null,2)+'\n');
}
if(prepareOnly || stillsOnly || test) {
  for(const frame of [0,3300,3900,4200,5520,5880,7560,8100,10320,10800,12600,14520,16199]) {
    await renderStill({composition,serveUrl,output:path.join(evidence,`stage-${String(frame).padStart(5,'0')}.png`),frame,chromiumOptions:{gl:'angle'}});
  }
  console.log(JSON.stringify({prepared,stills:true}));
}
if(prepareOnly || stillsOnly) process.exit(0);
const outputLocation = path.join(evidence,test?'intention-test.mp4':'intention-demo.mp4');
let lastLog = 0;
await renderMedia({composition,serveUrl,codec:'h264',pixelFormat:'yuv420p',crf:18,audioCodec:null,muted:true,outputLocation,concurrency:2,frameRange:test?[3600,3899]:undefined,chromiumOptions:{gl:'angle'},onProgress:({progress,renderedFrames,encodedFrames})=>{if(Date.now()-lastLog>10000){console.log(JSON.stringify({time:new Date().toISOString(),progress,renderedFrames,encodedFrames}));lastLog=Date.now();}}});
const report={outputLocation,remotionVersion:'4.0.534',durationSeconds:test?5:270,fps:60,width:1920,height:1080,codec:'h264',pixelFormat:'yuv420p',silent:true,renderWallSeconds:(Date.now()-started)/1000,concurrency:2,source:prepared};
await writeFile(path.join(evidence,test?'test-render.json':'render.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
