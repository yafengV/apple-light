// Execute shipped component callbacks with local hooks and deferred results.
// No DOM, native application, credentials, network or real persistence is used.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [generalPath, shortcutsPath, outputPath] = process.argv.slice(2);
const general = fs.readFileSync(generalPath, 'utf8'), shortcuts = fs.readFileSync(shortcutsPath, 'utf8');
const sha = text => crypto.createHash('sha256').update(text).digest('hex');
if (sha(general) !== '91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535'
  || sha(shortcuts) !== '2ce95962d64bba7ecaf128cfd4d4e4ec5704f232e0309c6d60a1ffdb7f78e0fb') throw Error('Unverified reference');
const deferred = () => {let resolve, reject; const promise = new Promise((a, b) => {resolve = a; reject = b}); return {promise, resolve, reject}};
function fixture() {
  let cursor = 0, pending = false, saved = 'Control+Alt+P'; const slots = [], writes = [], requests = [];
  const jsx = (type, props) => type === 'Message' ? props.defaultMessage ?? 'Popout Window hotkey' : {type, props};
  const context = {Q: {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
    pc: {useState: value => {const i = cursor++; if (!(i in slots)) slots[i] = value; return [slots[i], value => {slots[i] = typeof value === 'function' ? value(slots[i]) : value}]}},
    z: () => ({query: {setData: (_, state) => {saved = state.hotkey}}}), k: 0,
    P: () => ({formatMessage: value => value.defaultMessage ?? 'Popout Window hotkey'}), Gt: () => () => Promise.resolve(),
    B: () => ({data: {supported: true}}), Vn: 'state', St: () => saved, rr: 0, pr: 'window', m: x => x,
    Ne: ({mutationFn, onSuccess}) => ({get isPending() {return pending}, mutateAsync: async input => {
      pending = true; writes.push(input); try {const result = await mutationFn(input); await onSuccess(result); return result}
      finally {pending = false}}}),
    xe: x => x, M: 'Message', U: {popoutWindowHotkey: {}}, $: {jsx, jsxs: jsx}, H: 'Card', Qr: 'Capture', N: 'Row',
    Error, Promise};
  vm.createContext(context);
  const begin = general.indexOf('function Ps('), end = general.indexOf('function Fs(', begin);
  if (begin < 0 || end < 0) throw Error('Missing actual Ps component');
  vm.runInContext(general.slice(begin, end), context);
  const render = () => {cursor = 0; return context.Ps({hotkeyWindowHotkeys: {setHotkey: () => requests.shift().promise}})};
  const snapshot = () => {const tree = render(), control = tree.props.control.props;
    const error = tree.props.description.props.children[1]; return {accelerator: control.accelerator,
      capturing: control.isCapturing, disabled: control.disabled, error: error?.props.children ?? null}};
  return {render, snapshot, requests, writes};
}
(async () => {
  const traces = [];
  for (const kind of ['response-error', 'transport-error', 'unknown-error']) {
    const f = fixture(), first = deferred(), second = deferred(); f.requests.push(first, second);
    f.render().props.control.props.onStartCapture();
    f.render().props.control.props.onCapture('Control+Alt+P'); const pending = f.snapshot();
    if (kind === 'response-error') first.resolve({success: false, error: 'Native registration failed', state: {hotkey: 'Control+Alt+P'}});
    else first.reject(kind === 'transport-error' ? new Error('Transport failed') : 7);
    await new Promise(setImmediate); const failed = f.snapshot();
    f.render().props.control.props.onStartCapture(); const restarted = f.snapshot();
    f.render().props.control.props.onCapture('Control+Alt+P');
    second.resolve({success: true, state: {hotkey: 'Control+Alt+P'}}); await new Promise(setImmediate);
    const repaired = f.snapshot();
    if (pending.capturing || !pending.disabled || !failed.error || failed.accelerator !== 'Control+Alt+P'
      || restarted.error !== null || !restarted.capturing || repaired.error !== null || repaired.capturing
      || f.writes.length !== 2 || f.writes.some(x => x.hotkey !== 'Control+Alt+P')) throw Error('Mutation ordering mismatch');
    traces.push({kind, pending, failed, restarted, repaired, writes: f.writes});
  }
  const f = fixture(), clear = deferred(); f.requests.push(clear); f.render().props.control.props.onClear();
  clear.resolve({success: false, error: 'Clear failed', state: {hotkey: 'Control+Alt+P'}}); await new Promise(setImmediate);
  const clearFailure = {writes: f.writes, settled: f.snapshot()};
  if (f.writes[0].hotkey !== null || clearFailure.settled.accelerator !== 'Control+Alt+P') throw Error('Clear failure mismatch');
  // Older verified general keyboard settings retain a same-value early return.
  const start = shortcuts.indexOf('onCapture:i=>'), end = shortcuts.indexOf(',onClear:', start);
  const functionStart = shortcuts.indexOf('function Nt('), functionEnd = shortcuts.indexOf('function Pt(', functionStart);
  if ([start, end, functionStart, functionEnd].some(x => x < 0)) throw Error('Missing actual general shortcut callback');
  let capturing = true, mutations = 0;
  const context = {e: {accelerator: 'Control+Alt+P'}, r: 'macOS', M: value => {capturing = value !== null},
    ne: value => value, Mt: () => {throw Error('Same value must return before validation')}, It: () => {mutations++}};
  vm.createContext(context); vm.runInContext(shortcuts.slice(functionStart, functionEnd), context);
  const callback = vm.runInContext('(' + shortcuts.slice(start + 'onCapture:'.length, end) + ')', context);
  callback('Control+Alt+P'); if (capturing || mutations) throw Error('Same-value no-op mismatch');
  fs.writeFileSync(outputPath, JSON.stringify({
    popoutReference: {version: '26.930.51102', build: 13100, sourceSHA256: sha(general)},
    generalShortcutReference: {version: '26.908.70816', build: 9275, sourceSHA256: sha(shortcuts), capturing, mutations},
    boundaries: 'Actual Ps and older general callback; local hooks, identity normalization for an exactly equal string and deferred results; no DOM, OS registration or real persistence',
    traces, clearFailure}, null, 2) + '\n');
  console.log('Extracted three actual Popout failure/retry traces, clear failure and general same-value no-op');
})().catch(error => {console.error(error); process.exitCode = 1});
