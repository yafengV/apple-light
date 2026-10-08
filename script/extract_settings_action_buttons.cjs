// Execute the pinned public button component and read its desktop toolbar tokens.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const {desktopTypography} = require('./reference_desktop_typography.cjs');
const [sourcePath, cssPath, outputPath] = process.argv.slice(2);
const hashes = ['eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab',
  '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720'];
const [source, css] = [sourcePath, cssPath].map((path, i) => {
  const text = fs.readFileSync(path, 'utf8');
  if (crypto.createHash('sha256').update(text).digest('hex') !== hashes[i]) throw Error('Unverified public resource');
  return text;
});
function literal(name) {
  const start = source.indexOf(name + '={') + name.length + 1;
  if (start < name.length + 1) throw Error('Missing ' + name);
  let depth = 0, quote = null, escape = false;
  for (let end = start; end < source.length; end++) {
    const c = source[end];
    if (quote) { if (escape) escape = false; else if (c === '\\') escape = true; else if (c === quote) quote = null; }
    else if ('"\'`'.includes(c)) quote = c;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return vm.runInNewContext('(' + source.slice(start, end + 1) + ')');
  }
  throw Error('Unclosed ' + name);
}
const context = {fli: {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
  q: (...items) => items.flat(Infinity).filter(Boolean).join(' '), ali: 'spinner',
  o5: {jsx: (type, props) => ({type, props}), jsxs: (type, props) => ({type, props}), Fragment: 'fragment'}};
for (const name of ['qci', 'mli', 'hli', 'gli']) context[name] = literal(name);
vm.createContext(context);
const start = source.indexOf('function dli('), end = source.indexOf('function ', start + 10);
if (start < 0 || end < 0) throw Error('Missing actual public button');
vm.runInContext(source.slice(start, end).replace(/var [^;]+;$/, ''), context);
const cases = [];
for (const color of ['secondary', 'ghost']) for (const disabled of [false, true]) {
  const props = {color, size: 'toolbar', disabled, children: 'Action'};
  cases.push({props, tree: context.dli(props)});
}
const spacing = Number(css.match(/--spacing:([\d.]+)rem;/)[1]) * 16;
const toolbar = css.match(/\.button-toolbar\{([^}]+)\}/)[1];
if (!toolbar.includes('height:var(--spacing-token-button-composer)')
  || !toolbar.includes('padding-inline:var(--spacing-button-toolbar-inline)')) throw Error('Unexpected toolbar CSS');
const expected = {
  height: spacing * Number(css.match(/--spacing-token-button-composer:calc\(var\(--spacing\) \* (\d+)\)/)[1]),
  horizontalPadding: spacing * Number(css.match(/--spacing-button-toolbar-inline:calc\(var\(--spacing\) \* (\d+)\)/)[1]),
  borderWidth: 1, fontSize: desktopTypography(css).labelSize, lineHeight: 18,
  radius: Number(css.match(/--radius-lg-base:([\d.]+)rem;/)[1]) * 16,
  focusRing: 2, disabledOpacity: 0.4, backgroundOpacity: 0.05, hoverBackgroundOpacity: 0.1
};
for (const {tree} of cases) if (tree.type !== 'button' || !tree.props.className.includes('button-toolbar')
  || !tree.props.className.includes('rounded-button-toolbar')) throw Error('Unexpected public button tree');
if (!context.mli.secondary.includes('bg-text/5') || !context.mli.secondary.includes('hover:bg-text/10')
  || !context.mli.ghost.includes('text-tertiary') || !cases[0].tree.props.className.includes('disabled:opacity-40'))
  throw Error('Unexpected public colors or disabled state');
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100,
  sourceSHA256: hashes, cases, expected, cornerShapeNote: 'Default round fallback; superellipse support changes radius scale to 1.25.'}, null, 2) + '\n');
console.log('Extracted actual secondary/ghost toolbar buttons and desktop tokens');
