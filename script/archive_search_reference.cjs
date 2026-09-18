// Generate expected results using the upstream, unmodified Fuse 7.1.0 basic CJS
// build downloaded from https://github.com/krisk/Fuse/tree/v7.1.0.
// Usage: node script/archive_search_reference.cjs /absolute/path/fuse.basic.cjs
const fs = require('node:fs');
const Fuse = require(process.argv[2]);
if (Fuse.version !== '7.1.0') throw new Error('Expected Fuse 7.1.0');
const cases = [];
function add(query, fields) {
  const search = new Fuse([{ searchValues: fields }], { ignoreLocation: true, keys: ['searchValues'], threshold: 0.4 });
  cases.push({ query, fields, matches: !query.trim() || search.search(query.trim()).length > 0 });
}
for (const query of ['', ' ', '\uFEFF', '\u0085', '\uFEFFAlpha\uFEFF', 'a', 'e', 'é', 'abc', 'alpha same', 'alhpa', '设置页免', '👨‍💻', 'İ', 'ΟΣ', 'e\u0301']) {
  for (const fields of [[''], ['Alpha', 'Same'], ['é'], ['设置页面交互'], ['👨‍💻 coding'], ['İstanbul'], ['ΟΣ'], ['e\u0301'], ['xx abc yy']]) add(query, fields);
}
let seed = 271828;
function random(max) { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % max; }
const alphabet = Array.from('abcxyz ABCXYZ/.-设置页面任务😀é');
function word(length) { return Array.from({ length }, () => alphabet[random(alphabet.length)]).join(''); }
for (let index = 0; index < 800; index++) {
  const query = word(1 + random(100));
  let text = query;
  for (let edit = 0, count = random(35); edit < count; edit++) {
    const points = Array.from(text), at = random(points.length + 1), mutation = random(3);
    text = points.slice(0, at).join('') + (mutation === 0 ? '' : word(1)) + points.slice(at + (mutation === 2 ? 0 : 1)).join('');
  }
  add(query, [word(random(60)) + text + word(random(20)), word(random(60))]);
  if (index % 4 === 0) add(query, [word(random(70))]);
}
const output = 'apps/macos/Tests/ShipiOSTests/Fixtures/archive-search-fuse-7.1.0.json';
fs.mkdirSync(require('node:path').dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify(cases, null, 2) + '\n');
process.stdout.write(`${cases.length} reference cases\n`);
