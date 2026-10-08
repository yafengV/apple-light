// Evaluate only the current public dictation-group component and pure filters.
// Local React hooks/JSX are inert; no app, native bridge, user state or network.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [sourcePath, primaryPath, outputPath] = process.argv.slice(2);
const expected = ['f31de7f3b3c6b2449870be9f0fbc8259cd5f494d06105b619a26560976892328',
  '234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0'];
const [source, primary] = [sourcePath, primaryPath].map((path, i) => {
  const value = fs.readFileSync(path, 'utf8');
  if (crypto.createHash('sha256').update(value).digest('hex') !== expected[i]) throw Error('Unverified public asset');
  return value;
});
function component(text, name) {
  const i = text.indexOf(`function ${name}(`), j = text.indexOf('function ', i + 10);
  if (i < 0 || j < 0) throw Error('Missing ' + name);
  return text.slice(i, j).replace(/var [^;]+;$/, '');
}
const jsx = (type, props) => type === 'Message' ? props.defaultMessage : {type, props};
function fixture() {
  let expanded = false;
  const context = {Zt: {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
    Qt: {useState: () => [expanded, value => {expanded = value}], useId: () => 'advanced'},
    X: {jsx, jsxs: jsx}, zt: 'Disclosure', C: 'Row', ee: 'Button', V: 'Up', L: 'Down',
    S: 'Message', ie: 'Rows', He: {Footer: 'Footer'}};
  vm.createContext(context);
  vm.runInContext(['Xt', 'hn', 'gn', '_n', 'Cn'].map(name => component(source, name)).join('\n'), context);
  const grouping = source.match(/ne=j\?\.find\(_n\),re=j\?\.find\(gn\),M=j\?\.filter\(hn\)/)?.[0];
  const searching = source.match(/searching:(c\.length>0&&\(ne==null\|\|B\))/)?.[1];
  if (!grouping || !searching) throw Error('Missing actual grouping/search expression');
  function render(ids, query = '', byKeys = false) {
    context.j = ids.map(commandId => ({commandId, content: commandId}));
    context.c = query.trim(); context.B = byKeys;
    vm.runInContext(grouping, context);
    const hold = context.ne?.content ?? null, toggle = context.re?.content ?? null;
    const searchingValue = vm.runInContext(searching, context);
    const tree = hold || toggle ? context.Xt({shortcut: hold, singleTapShortcut: toggle, searching: searchingValue}) : null;
    const children = tree?.props.children[0].props.children ?? [];
    const disclosure = children[2];
    return {ordinary: context.M.map(value => value.commandId), searching: searchingValue,
      card: tree != null, hold: children[0] ?? null, directToggle: children[1] ?? null,
      advanced: disclosure == null ? null : {expanded: disclosure.props.expanded,
        ariaExpanded: disclosure.props.children.props.label.props['aria-expanded'],
        label: disclosure.props.children.props.label.props.children[1], content: disclosure.props.content},
      footer: tree?.props.children[1].props.children ?? null,
      toggle: () => disclosure?.props.children.props.label.props.onClick()};
  }
  return {render};
}
const all = ['palette', 'globalDictationHold', 'globalDictationSingleTap', 'realtimeVoice'];
const f = fixture(), collapsed = f.render(all); collapsed.toggle(); const expanded = f.render(all);
expanded.toggle(); const recollapsed = f.render(all);
const cases = [
  ['all', all, '', false], ['textBoth', all.slice(1, 3), 'dictation', false],
  ['textToggle', ['globalDictationSingleTap'], 'single', false],
  ['textHold', ['globalDictationHold'], 'hold', false],
  ['keysToggle', ['globalDictationSingleTap'], '⌃D', true],
  ['keysBoth', all.slice(1, 3), '⌃D', true], ['ordinaryOnly', ['palette'], 'palette', false],
].map(([name, ids, query, byKeys]) => ({name, ids, query, byKeys, ...fixture().render(ids, query, byKeys)}));
const modifiers = primary.match(/rBe=new Set\(\[[^\]]+\]\)/)?.[0];
if (!modifiers) throw Error('Missing modifier exclusion set');
const decoder = {yje: event => event.key}; vm.createContext(decoder);
vm.runInContext(modifiers + ';' + component(primary, 'tBe') + component(primary, '$ze'), decoder);
const ignoredModifiers = ['Meta', 'Control', 'Alt', 'Shift'].map(key => ({key, result: decoder.$ze({key})}));
if (collapsed.advanced?.expanded !== false || expanded.advanced?.expanded !== true ||
  recollapsed.advanced?.expanded !== false || ignoredModifiers.some(value => value.result !== null)) throw Error('Unexpected reference trace');
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256: expected,
  boundaries: 'Actual Xt/pure filters and grouping/search expressions with inert JSX/hooks; modifier exclusion uses actual decoder and key-identity stub; no DOM lifetime, native keyboard or persistence is inferred',
  collapsed, expanded, recollapsed, cases, ignoredModifiers}, null, 2) + '\n');
console.log('Extracted current dictation grouping, advanced toggles, seven searches and four modifier exclusions');
