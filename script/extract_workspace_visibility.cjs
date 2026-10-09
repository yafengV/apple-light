// Execute pinned layout functions only, with explicit atoms and inert native/UI hooks.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [input, output] = process.argv.slice(2);
const source = fs.readFileSync(input, 'utf8');
const sourceSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (sourceSHA256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified source');
const functions = ['fwa', 'pwa', 'mwa', 'QJ', '$J', 'cwa', 'dwa', 'kM', 'SHn', 'mHn', 'KM', 'GM', 'pHn', 'fHn', 'aHn', 'iVn', 'aC'];
const code = functions.map(name => {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end).replace(/var [^;]+;$/, '');
}).join('\n');
const traces = [];
for (const mode of ['full', 'split']) for (const visible of [false, true])
for (const focus of ['chat', 'content']) for (const count of [0, 1, 3]) {
  if (!visible && focus === 'content' || visible && count === 0 || mode === 'full' && visible && focus === 'chat') continue;
  const tabs = Array.from({length: count}, (_, i) => ({tabId: `content-${i+1}`, dndId: `content-${i+1}`, tabType: {}}));
  const initial = {mode, visible, focus, ids: tabs.map(t => t.tabId), selected: tabs.at(-1)?.tabId ?? null};
  const values = {qS: true, KS: false, Xx: false, aS: {}, bi: false, tS: mode,
    nS: false, yC: visible, Yx: visible && mode === 'full', $x: focus,
    oS: 'right', cS: focus === 'chat' ? 'main' : 'right-panel', lS: 'main',
    active: tabs.at(-1) ?? null, tabs, HV: {chat: {kind: 'chat'}},
    Tc: {isCapable: true}, vC: {get: () => 1}, sS: 0, YM: null};
  const scope = {get(key, parameter) {
    if (key === '$M') return values.nS ? 'chat' : values.tS === 'full' ? 'full' : this.get('QM') ? 'split' : 'chat';
    if (key === 'QM') return values.yC && values.active != null;
    if (key === 'eN') return this.get('QM') && (values.Yx || values.$x === 'content') ? 'content' : 'chat';
    if (key === 'byID') return tabs.find(t => t.tabId === parameter);
    return values[key];
  }, set(key, value) { values[key] = typeof value === 'function' ? value(values[key]) : value; }};
  const jM = {activeTab$: 'active', tabs$: 'tabs', tabById$: 'byID',
    activateTab(e, id) { e.set('active', tabs.find(t => t.tabId === id) ?? null); e.set('$x', 'content'); }};
  const context = {jM, hwa: {flushSync: f => f()}, document: {activeElement: null},
    requestAnimationFrame: () => {}, I: () => {}, dte: {}, I_e: {}, Y$r: {},
    Jx: (e, area) => e.set('cS', area), xMt: () => null, aVn: () => {}, iC: () => {},
    gHn: () => {}, cHn: () => {}, hHn: () => null, FM: () => {},
    UM: () => jM, pM: () => false,
    XJ(e) { const tab = {tabId: 'new-browser', dndId: 'new-browser', tabType: {}}; tabs.push(tab); e.set('active', tab); return tab; }};
  for (const atom of ['qS','KS','Xx','aS','bi','tS','nS','yC','Yx','$x','oS','cS','lS','HV','Tc','vC','sS','YM','$M','QM','eN','uS','Zx','XM','eS','YMt']) context[atom] = atom;
  vm.createContext(context); vm.runInContext(code, context);
  const states = [];
  for (let step = 0; step < 3; step++) {
    context.fwa(scope);
    states.push({mode: values.tS, visible: values.yC,
      focus: values.cS === 'main' ? 'chat' : 'content', selected: values.active?.tabId ?? null,
      ids: tabs.map(t => t.tabId)});
  }
  traces.push({initial, states});
}
fs.writeFileSync(output, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256,
  functions, boundary: 'Ordinary chat only; retained nonempty content, no discard callbacks. Actual pinned layout functions; explicit atoms, inert animations/telemetry/native focus. No application initialization or native bridge. Primary workspace, empty-tab discard, native focus timing and paired foreground acceptance remain separate.', traces}, null, 2)+'\n');
console.log(`Extracted ${traces.length} three-command traces`);
