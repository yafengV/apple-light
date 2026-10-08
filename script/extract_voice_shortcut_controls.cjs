// Execute the pinned public capture component with local hooks/JSX only.
// Class strings describe the source; this does not run DOM, CSS or OS capture.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [primaryPath, sharedPath, outputPath] = process.argv.slice(2);
const primary = fs.readFileSync(primaryPath, 'utf8'), shared = fs.readFileSync(sharedPath, 'utf8');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
if (sha(primary) !== '234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0'
  || sha(shared) !== 'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab') throw Error('Unverified reference');
function source(text, name) {
  const i = text.indexOf('function ' + name + '('), j = text.indexOf('function ', i + 10);
  if (i < 0 || j < 0) throw Error('Missing ' + name);
  return text.slice(i, j);
}
function fixture(props) {
  const slots = [], calls = []; let cursor = 0;
  const jsx = (type, props) => type === 'Message' ? props.defaultMessage : {type, props};
  const formatMessage = (message, values = {}) => message.defaultMessage.replace(/\{(\w+)\}/g, (_, name) => values[name]);
  const memo = {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
  const context = {dBe: memo, kli: memo,
    kP: {useId: () => 'capture', useRef: value => {const i = cursor++; return slots[i] ?? (slots[i] = {current: value})},
      useState: value => {const i = cursor++; if (!(i in slots)) slots[i] = value; return [slots[i], value => {slots[i] = value}]}, useEffect: () => {}},
    AP: {jsx, jsxs: jsx}, Ali: {jsx, jsxs: jsx}, Cc: () => ({formatMessage}), Eo: () => ({platform: 'macOS'}),
    Lr: (...values) => values.filter(Boolean).join(' '), q: (...values) => values.filter(Boolean).join(' '),
    IMe: 'Input', sBe: 'NativeCapture', za: 'Button', J: 'Message', Lc: 'Keycap', Xze: 'KeyLabel',
    _a: 'Icon', It: 'edit', ale: 'clear', yc: 'reset', Cd: 'Tooltip', clearTimeout: () => {}};
  vm.createContext(context);
  for (const name of ['lBe', 'uBe']) vm.runInContext(source(primary, name), context);
  vm.runInContext(source(shared, 'Oli'), context);
  cursor = 0;
  const tree = context.lBe({hotkeyName: 'Dictation', emptyLabel: 'Off',
    onStartCapture: mode => calls.push(['start', mode]), onClear: () => calls.push(['clear']),
    onCancelCapture: () => calls.push(['cancel']), ...props});
  function walk(node) {
    if (node == null || typeof node !== 'object') return [];
    return [node, ...[node.props?.children].flat(2).flatMap(walk)];
  }
  const nodes = walk(tree), buttons = nodes.filter(node => node.type === 'Button');
  const result = {className: tree.props.className, buttons: buttons.map(({props}) => ({
    label: props['aria-label'] ?? props.children, color: props.color, size: props.size,
    uniform: props.uniform ?? false, disabled: props.disabled ?? false,
    preventsMouseDown: props.onMouseDown === context.uBe})),
    valueClass: nodes.find(node => node.type === 'span')?.props.className ?? null,
    keycap: nodes.find(node => node.type === 'Keycap')?.props.className ?? null,
    captureWidthClass: nodes.find(node => node.props?.className === 'w-36 max-w-full')?.props.className ?? null};
  for (const button of buttons) {
    const mouse = {prevented: false, preventDefault() {this.prevented = true}};
    button.props.onMouseDown?.(mouse); button.props.onClick?.({shiftKey: false});
    if (button.props.onMouseDown && !mouse.prevented) throw Error('Cancel did not preserve pointer-down focus');
  }
  result.calls = calls;
  result.keycapDeclaredClasses = context.Oli({keysLabel: '⌃⌥J', className: '!px-2 !py-1 !text-sm'}).props.className;
  return result;
}
const empty = fixture({accelerator: null, acceleratorLabel: null});
const bound = fixture({accelerator: 'Control+Alt+J', acceleratorLabel: '⌃⌥J'});
const disabled = fixture({accelerator: 'Control+Alt+J', acceleratorLabel: '⌃⌥J', disabled: true});
const capturing = fixture({accelerator: 'Control+Alt+J', acceleratorLabel: '⌃⌥J', isCapturing: true});
if (empty.buttons.length !== 1 || empty.buttons[0].label !== 'Set shortcut for Dictation'
  || bound.buttons.length !== 2 || bound.buttons[1].label !== 'Clear shortcut for Dictation'
  || capturing.buttons.length !== 1 || capturing.buttons[0].label !== 'Cancel'
  || !capturing.buttons[0].preventsMouseDown || disabled.buttons.some(button => !button.disabled)) throw Error('Unexpected control shape');
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100,
  primarySHA256: sha(primary), sharedSHA256: sha(shared),
  boundaries: 'Actual lBe/uBe/Oli with local hooks/JSX; no DOM focus, CSS cascade, glyph rendering, OS registration or persistence',
  empty, bound, disabled, capturing}, null, 2) + '\n');
console.log('Extracted actual edit/clear/cancel branches, labels, declared classes and callbacks');
