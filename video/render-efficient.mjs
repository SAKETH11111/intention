import {renderMedia,renderStill} from '@remotion/renderer';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {spawn,spawnSync} from 'node:child_process';
import path from 'node:path';
const base=process.env.VIDEO_OUTPUT_DIR || '/tmp/intention-evidence/remotion';
const prepared=JSON.parse(await readFile(path.join(base,'prepared.json'),'utf8'));
const {serveUrl,composition}=prepared;
const work=path.join(base,'segments');await mkdir(work,{recursive:true});
const started=Date.now();
const data=JSON.parse(await readFile(path.join(prepared.frozenAssets,'stage/scenes.json'),'utf8'));
const fps=60,total=16200;
const intervals=[];
for(const [index,sc] of data.scenes.entries()){
 const start=data.timeline.starts[sc.id];
 if(index>0)intervals.push([Math.round(start*fps),Math.ceil((start+data.timing.swap)*fps)]);
 if(sc.said){const n=sc.said.split(/\s+/).filter(Boolean).length;const length=data.timing.firstWord+(n-1)*data.timing.word+data.timing.beat+data.timing.write+data.timing.insert+data.timing.land;const at=start+sc.readyHold;intervals.push([Math.round(at*fps),Math.ceil((at+length)*fps)]);}
 else if(sc.id==='savings'){const at=start+sc.readyHold;intervals.push([Math.round(at*fps),Math.ceil((at+data.timing.count)*fps)]);}
}
intervals.sort((a,b)=>a[0]-b[0]);
const segments=[];let cursor=0;
for(const [start,end] of intervals){if(start>cursor)segments.push({start:cursor,end:start,dynamic:false});segments.push({start,end,dynamic:true});cursor=end;}
if(cursor<total)segments.push({start:cursor,end:total,dynamic:false});
const cmd=(args)=>new Promise((resolve,reject)=>{const p=spawn('ffmpeg',args,{stdio:['ignore','ignore','pipe']});let err='';p.stderr.on('data',d=>err+=d);p.on('exit',code=>code===0?resolve():reject(new Error(err)));});
await writeFile(path.join(base,'efficient-plan.json'),JSON.stringify({prepared,segments,totalFrames:total,dynamicFrames:segments.filter(s=>s.dynamic).reduce((n,s)=>n+s.end-s.start,0)},null,2)+'\n');
for(const [index,seg]of segments.entries()){
 const out=path.join(work,`${String(index).padStart(2,'0')}.mp4`);seg.output=out;
 if(seg.dynamic){await renderMedia({composition,serveUrl,codec:'h264',pixelFormat:'yuv420p',crf:18,x264Preset:'ultrafast',audioCodec:null,muted:true,outputLocation:out,concurrency:4,frameRange:[seg.start,seg.end-1],chromiumOptions:{gl:'angle'}});}
 else {const png=path.join(work,`${index}.png`);await renderStill({composition,serveUrl,output:png,frame:seg.start,chromiumOptions:{gl:'angle'}});await cmd(['-hide_banner','-loglevel','error','-y','-loop','1','-framerate','60','-i',png,'-frames:v',String(seg.end-seg.start),'-an','-c:v','libx264','-preset','ultrafast','-crf','18','-threads','2','-pix_fmt','yuv420p','-video_track_timescale','90000','-map_metadata','-1',out]);}
 console.log(JSON.stringify({time:new Date().toISOString(),index,start:seg.start,end:seg.end,dynamic:seg.dynamic,elapsedSeconds:(Date.now()-started)/1000}));
}
const concat=path.join(work,'concat.txt');await writeFile(concat,segments.map(s=>`file '${s.output}'`).join('\n')+'\n');
const output=path.join(base,'intention-demo.mp4');await cmd(['-hide_banner','-loglevel','error','-y','-f','concat','-safe','0','-i',concat,'-map','0:v:0','-c','copy','-an','-map_metadata','-1','-movflags','+faststart',output]);
const check=spawnSync('ffprobe',['-v','error','-count_frames','-show_entries','stream=codec_name,codec_type,width,height,pix_fmt,r_frame_rate,nb_read_frames:format=duration','-of','json',output],{encoding:'utf8'});
if(check.status!==0)throw new Error(check.stderr);
const probe=JSON.parse(check.stdout);
if(probe.streams.length!==1 || probe.streams[0].nb_read_frames!=='16200' || Number(probe.format.duration)!==270)throw new Error('Encoded movie failed duration/frame-count verification');
await writeFile(path.join(base,'ffprobe.json'),check.stdout);
const report={outputLocation:output,remotionVersion:'4.0.534',durationSeconds:270,fps:60,width:1920,height:1080,codec:'h264',pixelFormat:'yuv420p',silent:true,renderWallSeconds:(Date.now()-started)/1000,concurrency:4,totalFrames:total,dynamicFrames:segments.filter(s=>s.dynamic).reduce((n,s)=>n+s.end-s.start,0),source:prepared,method:'Remotion renders every moving frame; static holds repeat their exact Remotion still. FFmpeg concatenates the encoded segments.'};
await writeFile(path.join(base,'render.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
