// Execute the pinned DropdownMenuContent close/outside callbacks. React lifecycle,
// FocusScope timers, browser event scheduling and native timing are not simulated.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sourceSHA256 = 'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab';
if (crypto.createHash('sha256').update(source).digest('hex') !== sourceSHA256) throw Error('Unverified public resource');
const declaration = source.indexOf('$Me=ib.forwardRef(ob(');
if (declaration < 0) throw Error('Missing DropdownMenuContent declaration');
const start = source.indexOf('function(e,t)', declaration);
const end = source.indexOf(',`DropdownMenuContent`', start);
if (start < 0 || end < 0) throw Error('Missing DropdownMenuContent');
const component = source.slice(start, end);
const composeStart = source.indexOf('function Ig('), composeEnd = source.indexOf('function ', composeStart + 10);
if (composeStart < 0 || composeEnd < 0) throw Error('Missing actual handler composition');
const context = {Lg: fn => fn, ib: {useRef: value => ({current: value})}, QMe: 'scope',
  cb: () => ({}), ab: {jsx: (type, props) => ({type, props})}, Uy: 'MenuContent'};
vm.createContext(context); vm.runInContext(source.slice(composeStart, composeEnd), context);
const render = vm.runInContext('(' + component + ')', context);
const cases = [
  {id: 'modal-close', modal: true}, {id: 'nonmodal-close', modal: false},
  {id: 'nonmodal-outside-left', modal: false, button: 0},
  {id: 'modal-outside-right', modal: true, button: 2},
  {id: 'modal-outside-control-left', modal: true, button: 0, ctrlKey: true},
  {id: 'prevented-close', modal: true, preventClose: true}
].map(input => {
  let focusCalls = 0;
  context.qMe = () => ({modal: input.modal, contentId: 'content', triggerId: 'trigger', triggerRef: {current: {focus() { focusCalls++; }}}});
  const event = () => ({defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }});
  const props = input.preventClose ? {onCloseAutoFocus: e => e.preventDefault()} : {};
  const tree = render(props, null);
  if (input.button !== undefined) tree.props.onInteractOutside({...event(), detail: {originalEvent: {button: input.button, ctrlKey: !!input.ctrlKey}}});
  const close = event(); tree.props.onCloseAutoFocus(close);
  return {...input, focusCalls, defaultPrevented: close.defaultPrevented};
});
if (cases.some(item => item.focusCalls !== (item.id.endsWith('-close') && !item.preventClose ? 1 : 0) || !item.defaultPrevented)) throw Error('Unexpected close callback behavior');
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256,
  boundaries: 'Actual DropdownMenuContent and handler composition with controlled context; React unmount timing and browser focus scheduling are not executed',
  deferredUnmountPresent: source.includes('setTimeout(()=>{let t=new CustomEvent(uEe,dEe)'), cases}, null, 2) + '\n');
console.log('Extracted six actual close/outside focus callback cases');
