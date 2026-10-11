import {createHash} from 'node:crypto';
import {readFile, writeFile, mkdir, cp, rm} from 'node:fs/promises';
import path from 'node:path';

export async function snapshotStage(site, destination, evidence) {
  await rm(destination, {recursive:true, force:true});
  await mkdir(destination, {recursive:true});
  const required = new Set(['stage/index.html','stage/stage.js','stage/stage.css','stage/scenes.json','stage/notes-icon.svg','windows.css','windows2.css']);
  for (const file of [...required]) {
    const text = await readFile(path.join(site,file),'utf8');
    for (const match of text.matchAll(/["']([^"'\s]+\.(?:avif|webp|png|svg|woff2|ttf)(?:\?[^"']*)?)["']/g)) {
      const relative = path.normalize(path.join(path.dirname(file),match[1].split('?')[0]));
      if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Asset escapes site directory');
      required.add(relative);
    }
  }
  for (const license of ['assets/OFL.txt','assets/BreeSerif-OFL.txt']) required.add(license);
  const files = [];
  for (const file of [...required].sort()) {
    const source = path.join(site,file);
    await mkdir(path.dirname(path.join(destination,file)),{recursive:true});
    await cp(source,path.join(destination,file));
    files.push({file,sha256:createHash('sha256').update(await readFile(source)).digest('hex')});
  }
  const canonical = JSON.parse(await readFile(path.join(site,'stage/scenes.json'),'utf8'));
  const timeline = JSON.parse(await readFile(new URL('./timeline.json',import.meta.url),'utf8'));
  for(const chapter of timeline.chapters) {
    if(canonical.timeline.starts[chapter.id]!==chapter.start) throw new Error(`Timeline mismatch for ${chapter.id}`);
  }
  if(canonical.timeline.duration!==timeline.durationSeconds) throw new Error('Timeline duration mismatch');
  await writeFile(path.join(evidence,'stage-snapshot.json'),JSON.stringify({files},null,2)+'\n');
}
