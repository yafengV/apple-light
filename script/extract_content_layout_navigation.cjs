// Execute pinned public pure selectors with explicit state and inert UI hooks.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sha256 = crypto.createHash('sha256').update(source).digest('hex');
if (sha256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified public source');
function component(name) {
  const i = source.indexOf(`function ${name}(`), j = source.indexOf('function ', i + 10);
  if (i < 0 || j < 0) throw Error('Missing ' + name);
  return source.slice(i, j).replace(/var [^;]+;$/, '');
}
const chatTransitions = [];
for (const mode of ['full', 'split']) for (const visible of [true, false]) {
  const values = {primary: false, restricted: false, chatAvailable: true, mode,
    visible, full: mode === 'full', disabled: false, serial: 0, kind: 'content', active: {tabId: 'first', tabType: {}}};
  const scope = {get: key => values[key], set: (key, value) => { values[key] = typeof value === 'function' ? value(values[key]) : value; }};
  const context = {Xx: 'primary', KS: 'restricted', cM: 'chatAvailable', tS: 'mode', yC: 'visible', Yx: 'full', bi: 'disabled', sS: 'serial', $x: 'kind', eS: 'auxChat', Zx: 'auxKind', qS: 'allowsSplit',
    jM: {activeTab$: 'active'}, Jx: (scope, area) => {values.focus = area;},
    cHn: () => {}, iC: () => {}, mHn: () => {throw Error('Unexpected primary activation');}};
  vm.createContext(context);
  vm.runInContext(['aC', 'iVn', 'SHn'].map(component).join('\n'), context);
  context.SHn(scope);
  chatTransitions.push({mode, visible, resultingMode: values.mode, resultingKind: values.kind, resultingVisible: values.visible, focus: values.focus});
}
const fullChatSelections = [];
for (const ids of [['first', 'second'], ['only'], []]) for (const direction of ['next', 'previous']) {
  const content = ids.map(id => ({kind: 'content', tab: {tabId: id, dndId: id}})), chat = {kind: 'chat'}, selected = [];
  const values = {layout: {chat, content, auxiliary: content}, primary: false, mode: {mode: 'full'}, active: content[0]?.tab ?? null,
    includeChat: true, primaryMode: 'full', kind: 'chat', locale: {locale: 'en'}, ordered: [chat, ...content]};
  const context = {HV: 'layout', Xx: 'primary', ZM: 'mode', XM: 'active', cM: 'includeChat', $M: 'primaryMode', eN: 'kind', En: 'locale', _Jr: 'ordered', Zx: 'kind', jM: {activeTab$: 'active'},
    qe: () => 'ltr', cwa: (scope, item) => selected.push(item.kind === 'chat' ? 'chat' : item.tab.tabId), DM: id => id,
    document: {getElementById: () => null}, requestAnimationFrame: () => {}};
  vm.createContext(context); vm.runInContext(component('swa'), context);
  const handled = context.swa({get: key => values[key]}, direction, 'chat-panel');
  fullChatSelections.push({ids, direction, handled, selected});
}
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256: sha256,
  boundary: 'Actual SHn/iVn/aC and swa with inert explicit state; no native bridge, application initialization or primary content workspace claims.', chatTransitions, fullChatSelections}, null, 2) + '\n');
console.log('Extracted persistent layout transitions and full-view chat selection traces');
