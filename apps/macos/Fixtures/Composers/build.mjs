import { build } from 'esbuild';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const output = new URL('../../.build/caret-lab/composers/', import.meta.url);
await mkdir(output, { recursive: true });
await build({ entryPoints: [new URL('editors.mjs', import.meta.url).pathname], bundle: true,
  format: 'iife', outfile: new URL('editors.js', output).pathname, platform: 'browser',
  target: 'chrome150', sourcemap: false, legalComments: 'eof' });
const bytes = await readFile(new URL('editors.js', output));
const lock = await readFile(new URL('package-lock.json', import.meta.url));
await writeFile(new URL('provenance.json', output), JSON.stringify({
  bundle_sha256: createHash('sha256').update(bytes).digest('hex'),
  lock_sha256: createHash('sha256').update(lock).digest('hex'),
  note: 'Synthetic Tiptap and Lexical editors. No target application code or accounts.'
}, null, 2));
