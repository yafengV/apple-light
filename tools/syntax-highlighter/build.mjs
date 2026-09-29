import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, rm, readdir } from 'node:fs/promises';
import path from 'node:path';

const destination = '../../apps/macos/Sources/ShipiOS/Resources/SyntaxHighlighting';
await mkdir(destination, { recursive: true });
const result = await build({ entryPoints: ['engine.mjs'], bundle: true, minify: true,
  format: 'iife', platform: 'browser', target: 'safari17', write: false, metafile: true,
  outfile: path.join(destination, 'engine.js'),
  legalComments: 'external' });
if (Object.values(result.metafile.outputs).some(output => output.imports.length)) {
  throw Error('Offline highlighting bundle must not contain external imports');
}
const javascript = result.outputFiles.find(file => !file.path.endsWith('.LEGAL.txt'));
await writeFile(path.join(destination, 'engine.js'), javascript.contents);
const legal = result.outputFiles.find(file => file.path.endsWith('.LEGAL.txt'));
if (legal) await writeFile(path.join(destination, 'engine.js.LEGAL.txt'), legal.contents);
const packages = new Set(Object.keys(result.metafile.inputs).flatMap(file => {
  const match = file.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/);
  return match ? [match[1]] : [];
}));
await rm(path.join(destination, 'Licenses'), { force: true, recursive: true });
await mkdir(path.join(destination, 'Licenses'));
const components = [];
for (const name of [...packages].sort()) {
  const directory = path.join('node_modules', name);
  const info = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
  const licenses = (await readdir(directory)).filter(file => /^licen[cs]e|^notice/i.test(file));
  if (!licenses.length) throw Error('Missing license for ' + name);
  for (const file of licenses) await writeFile(path.join(destination, 'Licenses', name.replaceAll('/', '_') + '-' + file),
    await readFile(path.join(directory, file)));
  components.push({ name, version: info.version, license: info.license });
}
const sha256 = createHash('sha256').update(javascript.contents).digest('hex');
await writeFile(path.join(destination, 'manifest.json'), JSON.stringify({ format: 1, sha256,
  bytes: javascript.contents.length, components }, null, 2) + '\n');
console.log(JSON.stringify({ bytes: javascript.contents.length, sha256, components }, null, 2));
