// Execute the pinned actual Pn/an callbacks with the already configured value.
// Only local hooks and deferred mutation results run; no UI or native backend.
const fs = require('fs');
const {fixture, hash} = require('./extract_voice_shortcut_disclosure.cjs');
const state = {configuredHotkey: 'Control', configuredToggleHotkey: 'Alt+Shift',
  configuredVoiceHotkey: 'Control+Alt+V'};
const row = (f, mode) => mode === 'hold' ? f.render().props.children : f.render();
function snapshot(f, mode) {
  const r = row(f, mode), control = r.props.control.props;
  const error = r.props.description.props.children.find(value => value?.type === 'span' && value.props.className === 'text-danger');
  return {accelerator: control.accelerator, capturing: control.isCapturing,
    disabled: control.disabled, error: error?.props.children ?? null};
}
const deferred = () => {let resolve, reject; const promise = new Promise((a, b) => {resolve = a; reject = b}); return {promise, resolve, reject}};
(async () => {
  const cases = [];
  for (const [mode, accelerator] of [['hold', state.configuredHotkey],
    ['toggle', state.configuredToggleHotkey], ['voiceChat', state.configuredVoiceHotkey]]) {
    const requests = [deferred(), deferred()]; let index = 0;
    const f = fixture(mode, state, {component: mode === 'voiceChat' ? 'an' : 'Pn',
      mutate: () => requests[index++].promise});
    row(f, mode).props.control.props.onStartCapture();
    row(f, mode).props.control.props.onCapture(accelerator);
    const pending = snapshot(f, mode);
    requests[0].reject(new Error('Hotkey temporarily unavailable')); await new Promise(setImmediate);
    const failed = snapshot(f, mode);
    row(f, mode).props.control.props.onStartCapture();
    const restarted = snapshot(f, mode);
    row(f, mode).props.control.props.onCapture(accelerator);
    requests[1].resolve({success: true, state}); await new Promise(setImmediate);
    const repaired = snapshot(f, mode);
    if (f.writes.length !== 2 || f.writes.some(write => (mode === 'voiceChat' ? write.update?.accelerator : write.hotkey) !== accelerator)
      || pending.capturing || !pending.disabled || !failed.error || failed.accelerator !== accelerator
      || !restarted.capturing || restarted.error !== null || repaired.capturing || repaired.disabled
      || repaired.error !== null || repaired.accelerator !== accelerator) throw Error('Same-value retry mismatch: ' + mode);
    cases.push({mode, accelerator, pending, failed, restarted, repaired, writes: f.writes});
  }
  fs.writeFileSync(process.argv[3], JSON.stringify({version: '26.930.51102', build: 13100,
    sourceSHA256: hash, boundaries: 'Actual Pn/an callbacks with local hooks and deferred results; no DOM focus, native registration or persistence', cases}, null, 2) + '\n');
  console.log('Extracted three actual same-value failure and retry traces');
})().catch(error => {console.error(error); process.exitCode = 1});
