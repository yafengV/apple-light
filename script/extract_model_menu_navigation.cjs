// Run only the public model menu's keyboard capture closure, in an isolated VM.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sha = '234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0';
if (crypto.createHash('sha256').update(source).digest('hex') !== sha) throw Error('Unverified source');
const start = source.indexOf('function X0e('), end = source.indexOf('function ', start + 15);
const menu = source.slice(start, end);
const arrowStart = menu.indexOf('de=e=>{'), arrowEnd = menu.indexOf(',t[28]=s', arrowStart);
if (start < 0 || end < 0 || arrowStart < 0 || arrowEnd < 0) throw Error('Missing keyboard closure');
const closure = menu.slice(arrowStart + 3, arrowEnd);
const items = ['default', 'sol', 'terra'];
const inputs = [
  ['down', 'sol', 'ArrowDown'], ['up', 'sol', 'ArrowUp'], ['tab', 'default', 'Tab'],
  ['reverse-tab', 'default', 'Tab', {shift: true}], ['down-wrap', 'terra', 'ArrowDown'],
  ['up-wrap', 'default', 'ArrowUp'], ['child-target', 'sol', 'ArrowDown', {child: true}],
  ['outside-item', null, 'ArrowDown'], ['unrecognized-key', 'sol', 'ArrowRight'],
  ['slider-excluded', 'sol', 'ArrowDown', {slider: true}],
  ['composer-slider-excluded', 'sol', 'ArrowDown', {reasoning: true, code: 'ComposerNavigation'}],
  ['ordinary-reasoning-descendant', 'sol', 'ArrowDown', {reasoning: true}],
  ['enter-memory', 'sol', 'Enter'], ['space-memory', 'sol', ' '],
  ['disabled-row-skipped', 'default', 'ArrowDown', {disabled: ['sol']}],
  ['noninteractive-row-skipped', 'default', 'Tab', {noninteractive: ['sol']}],
  ['hidden-row-skipped', 'default', 'ArrowDown', {hidden: ['sol']}],
  ['empty', null, 'Tab', {empty: true}], ['single-wrap', 'sol', 'Tab', {single: true}],
];
const cases = inputs.map(([name, currentID, key, options = {}]) => {
  let focusedID = null, prevented = false, stopped = false;
  class Element {
    constructor(id) { this.id = id; }
    contains(target) { return target.parent === this; }
    closest(selector) {
      if (selector === '[role="slider"]') return options.slider ? this : null;
      if (selector === '[data-reasoning-slider]') return options.reasoning ? this : null;
      return null;
    }
    matches() { return this.id != null; }
    focus() { focusedID = this.id; }
  }
  const rows = (options.empty ? [] : options.single ? ['sol'] : items).map(id => new Element(id));
  let target = rows.find(row => row.id === currentID) ?? new Element(null);
  if (options.child) { const parent = target; target = new Element(null); target.parent = parent; }
  const context = {HTMLElement: Element, A: {current: null}, s: 'advanced',
    Z0e: row => !options.hidden?.includes(row.id)};
  vm.createContext(context);
  const handler = vm.runInContext('(' + closure + ')', context);
  handler({target, key, code: options.code ?? key, shiftKey: options.shift ?? false,
    currentTarget: {querySelectorAll: () => rows.filter(row => !options.disabled?.includes(row.id) && !options.noninteractive?.includes(row.id))},
    preventDefault: () => { prevented = true; }, stopPropagation: () => { stopped = true; }});
  return {name, items: rows.map(row => row.id), currentID, key, ...options,
    expected: {focusedID, prevented, stopped, memory: context.A.current}};
});
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100,
  sourceSHA256: sha, cases}, null, 2) + '\n');
console.log('Extracted', cases.length, 'menu keyboard cases');
