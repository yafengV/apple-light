// Evaluate only pinned public selectors with explicit state and inert UI hooks.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sourceSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (sourceSHA256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified public source');
function component(name) {
  const i = source.indexOf(`function ${name}(`), j = source.indexOf('function ', i + 10);
  if (i < 0 || j < 0) throw Error('Missing ' + name);
  return source.slice(i, j).replace(/var [^;]+;$/, '');
}
const selections = [];
for (const ids of [['left', 'right', 'last'], ['only'], []]) {
  for (const current of ids.length ? ids : [null]) for (const direction of ['next', 'previous']) {
    const content = ids.map(id => ({kind: 'content', tab: {tabId: id, dndId: id}}));
    const values = {layout: {chat: {kind: 'chat'}, content, auxiliary: content}, primary: false,
      mode: {mode: 'split'}, active: content.find(item => item.tab.tabId === current)?.tab ?? null,
      includeChat: true, primaryMode: 'split', kind: 'content', locale: {locale: 'en'}, ordered: []};
    const selected = [];
    const context = {HV: 'layout', Xx: 'primary', ZM: 'mode', XM: 'active', cM: 'includeChat',
      $M: 'primaryMode', eN: 'kind', En: 'locale', _Jr: 'ordered', Zx: 'kind', jM: {activeTab$: 'active'},
      qe: () => 'ltr', cwa: (_, item) => selected.push(item.kind === 'chat' ? 'chat' : item.tab.tabId),
      DM: id => id, document: {getElementById: () => null}, requestAnimationFrame: () => {}};
    vm.createContext(context); vm.runInContext(component('swa'), context);
    const handled = context.swa({get: key => values[key]}, direction, 'chat-panel');
    selections.push({ids, current, direction, handled, selected});
  }
}
const dispatches = [];
for (const mode of ['full', 'split']) for (const origin of ['main', 'right', 'bottom']) for (const visible of [true, false]) {
  const calls = [], controller = {mode, isVisible: visible, selectAdjacentTab: direction => {calls.push('content:' + direction); return true;}};
  const values = {origin: 'main', bottom: true, controller};
  const context = {cS: 'origin', gC: 'bottom', aS: 'controller',
    MM: {activateAdjacentTab: (_, direction) => {calls.push('bottom:' + direction); return true;}}};
  vm.createContext(context); vm.runInContext(component('Bsc'), context);
  const handled = context.Bsc({routeScope: {get: key => values[key]}, direction: 'next', originPanel: origin});
  dispatches.push({mode, origin, visible, handled, calls});
}
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256,
  boundary: 'Actual swa and Bsc selectors, ordinary chat primary surface only; inert explicit state, no application initialization or native bridge.',
  selections, dispatches}, null, 2) + '\n');
console.log('Extracted ordinary split selection and panel dispatch traces');
