// Evaluate only the pinned numeric selector with explicit state and inert UI hooks.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sourceSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (sourceSHA256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified public source');
const start = source.indexOf('function swa('), end = source.indexOf('function ', start + 10);
if (start < 0 || end < 0) throw Error('Missing numeric selector');
const selector = source.slice(start, end).replace(/var [^;]+;$/, '');
const selections = [];
for (const mode of ['full', 'split']) for (const direction of ['ltr', 'rtl']) for (const count of [0, 1, 3, 11]) {
  const ids = Array.from({length: count}, (_, index) => 'file-' + (index + 1));
  for (const current of count ? [null, ids.at(-1)] : [null]) for (let index = -1; index <= 10; index++) {
    const content = ids.map(id => ({kind: 'content', tab: {tabId: id, dndId: id}}));
    const chat = {kind: 'chat'};
    const values = {layout: {chat, content, auxiliary: content}, primary: false,
      mode: {mode}, active: content.find(item => item.tab.tabId === current)?.tab ?? null,
      includeChat: true, primaryMode: mode, kind: current == null ? 'chat' : 'content',
      locale: {locale: direction === 'rtl' ? 'ar' : 'en'}, ordered: [chat, ...content]};
    const selected = [];
    const context = {HV: 'layout', Xx: 'primary', ZM: 'mode', XM: 'active', cM: 'includeChat',
      $M: 'primaryMode', eN: 'kind', En: 'locale', _Jr: 'ordered', Zx: 'kind', jM: {activeTab$: 'active'},
      qe: locale => locale === 'ar' ? 'rtl' : 'ltr',
      cwa: (_, item) => selected.push(item.kind === 'chat' ? 'chat' : item.tab.tabId),
      DM: id => id, document: {getElementById: () => null}, requestAnimationFrame: () => {}};
    vm.createContext(context); vm.runInContext(selector, context);
    const handled = context.swa({get: key => values[key]}, index, 'chat-panel');
    selections.push({mode, direction, ids, current, index, handled, selected});
  }
}
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256,
  boundary: 'Actual swa numeric selector; ordinary chat primary surface with chat tab enabled. Explicit locale direction and inert focus hooks, no application initialization or native bridge. Primary-workspace and hidden-chat-tab states remain separate requirements.',
  selections}, null, 2) + '\n');
console.log(`Extracted ${selections.length} numeric selection traces`);
