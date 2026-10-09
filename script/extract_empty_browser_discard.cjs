const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [input, output] = process.argv.slice(2);
const source = fs.readFileSync(input, 'utf8');
const sourceSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (sourceSHA256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified source');
function method(name, next) {
  const start = source.indexOf(`${name}(e,t){`), end = source.indexOf(`${next}(e,t){`, start);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end);
}
function fn(name) {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end);
}
const predicate = `({${method('canReplaceNewTab','isDisposableEmptyNewTab')},${method('isDisposableEmptyNewTab','canUndoClose')}})`;
const cases = [];
for (const name of ['empty','address-draft','cleared-address-draft','pinned','multiple','web','loading','back-history','forward-history','zoom','comment-mode','comments','agent','capture','pending-transfer','custom-title','missing-snapshot']) {
  const tab = {tabId: 'tab', browserID: 'browser'}, tabs = name === 'multiple' ? [tab, {tabId:'second'}] : [tab];
  const snapshot = {tabType: 'new', url: '', zoomPercent:100, interactionMode:'browse', comments:[]};
  if (name === 'web') snapshot.tabType = 'web';
  if (name === 'loading') snapshot.isLoading = true;
  if (name === 'back-history') snapshot.canGoBack = true;
  if (name === 'forward-history') snapshot.canGoForward = true;
  if (name === 'zoom') snapshot.zoomPercent = 150;
  if (name === 'comment-mode') snapshot.interactionMode = 'comment';
  if (name === 'comments') snapshot.comments = ['comment'];
  const defaults = {isEnabled:false, presetId:'default', width:0, height:0};
  const closed = [], removed = [];
  const context = {HH: () => 'key', NH: () => '', ah: s => s.trim(), i4r: () => null, a4r: () => null,
    Yp:{NEW_TAB_PAGE:'new'}, ooe:{BATCH:'batch'}, bYe:defaults,
    Tg: () => 'conversation', ws: t => t.browserID ?? null,
    pM: () => name === 'pinned', y4r: () => {},
    jM:{tabs$:'tabs', closeTab: (_, id, options) => {closed.push({id, ...options}); tabs.splice(0, 1);},
      isCurrentTabInstance: (_, t) => tabs.includes(t)}};
  vm.createContext(context);
  const host = vm.runInContext(predicate, context);
  Object.assign(host, {snapshots:new Map(name === 'missing-snapshot' ? [] : [['key', snapshot]]),
    addressInputDrafts:new Map(['address-draft','cleared-address-draft'].includes(name) ? [['key', name === 'address-draft' ? 'input' : '']] : []),
    browserUseTabKeys:new Set(name === 'agent' ? ['key'] : []), tabCaptureActiveKeys:new Set(name === 'capture' ? ['key'] : []),
    pendingElectronTransfers:new Set(name === 'pending-transfer' ? ['key'] : []),
    getDeviceToolbarTabState: () => ({responsiveViewportSize:null, toolbarState:defaults}),
    getCustomTitle: () => name === 'custom-title' ? 'Custom' : null,
    removeTab: (_, id) => removed.push(id)});
  context.UH = host;
  vm.runInContext(fn('kCa') + fn('ACa'), context);
  const disposable = host.isDisposableEmptyNewTab('conversation', 'browser');
  const discarded = context.ACa({get: () => tabs});
  cases.push({name, disposable, discarded, closed, removed});
}
fs.writeFileSync(output, JSON.stringify({version:'26.930.51102', build:13100, sourceSHA256,
  boundary:'Actual canReplaceNewTab/isDisposableEmptyNewTab/kCa/ACa, explicit host state and inert close adapter. No application initialization/native bridge. Cases do not assert native media or transfer support in ShipiOS.', cases}, null, 2)+'\n');
console.log(`Extracted ${cases.length} empty-browser discard cases`);
