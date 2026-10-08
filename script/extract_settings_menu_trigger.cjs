// Execute the pinned public form trigger, shared button and chevron components.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const {desktopTypography} = require('./reference_desktop_typography.cjs');
const [initialPath, sharedPath, cssPath, outputPath] = process.argv.slice(2);
const hashes = ['22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3',
  'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab',
  '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720'];
const [initial, shared, css] = [initialPath, sharedPath, cssPath].map((path, index) => {
  const text = fs.readFileSync(path, 'utf8');
  if (crypto.createHash('sha256').update(text).digest('hex') !== hashes[index]) throw Error('Unverified public resource');
  return text;
});
function literal(name) {
  const start = shared.indexOf(name + '={') + name.length + 1;
  if (start < name.length + 1) throw Error('Missing ' + name);
  let depth = 0, quote = null, escape = false;
  for (let end = start; end < shared.length; end++) {
    const c = shared[end];
    if (quote) { if (escape) escape = false; else if (c === '\\') escape = true; else if (c === quote) quote = null; }
    else if ('"\'`'.includes(c)) quote = c;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return vm.runInNewContext('(' + shared.slice(start, end + 1) + ')');
  }
  throw Error('Unclosed ' + name);
}
const cache = {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const join = (...items) => items.flat(Infinity).filter(Boolean).join(' ');
const jsx = (type, props) => typeof type === 'function' ? type(props) : {type, props};
const context = {fli: cache, Dvs: cache, q: join, ca: join, ali: 'spinner',
  o5: {jsx, jsxs: jsx, Fragment: 'fragment'}, $6: {jsx, jsxs: jsx}, Wxi: {jsx}, lo: 'reference-chevron'};
for (const name of ['qci', 'mli', 'hli', 'gli']) context[name] = literal(name);
vm.createContext(context);
for (const [text, name] of [[shared, 'dli'], [initial, 'wvs']]) {
  const start = text.indexOf('function ' + name + '('), end = text.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error('Missing component ' + name);
  vm.runInContext(text.slice(start, end).replace(/var [^;]+;$/, ''), context);
  if (name === 'dli') context.ao = context.dli;
}
const iconStart = shared.indexOf('Gxi=e=>') + 4, iconEnd = shared.indexOf('})))()}', iconStart);
if (iconStart < 4 || iconEnd < 0) throw Error('Missing public chevron');
const chevron = vm.runInContext('(' + shared.slice(iconStart, iconEnd) + ')({})', context);
const cases = [];
for (const leading of [false, true]) for (const disabled of [false, true]) {
  const props = {children: 'Selected option', disabled, ...(leading ? {leadingVisual: 'swatch'} : {})};
  cases.push({leading, disabled, tree: context.wvs(props)});
}
const spacing = Number(css.match(/--spacing:([\d.]+)rem;/)[1]) * 16;
const expected = {height: spacing * Number(css.match(/--spacing-token-button-composer:calc\(var\(--spacing\) \* (\d+)\)/)[1]),
  fontSize: desktopTypography(css).labelSize, lineHeight: 18,
  radius: Number(css.match(/--radius-lg-base:([\d.]+)rem;/)[1]) * 16,
  borderWidth: 1, padding: spacing * 3, swatchSize: spacing * 5,
  outerGap: spacing, innerGap: spacing * 1.5,
  chevronSize: Number(css.match(/\.icon-2xs\{height:var\(--icon-secondary-size,(\d+)px\)/)[1]),
  focusRing: 2, disabledOpacity: 0.4};
expected.swatchPadding = (expected.height - expected.swatchSize) / 2 - expected.borderWidth;
for (const item of cases) {
  const classes = item.tree.props.className;
  if (item.tree.type !== 'button' || !classes.includes('button-toolbar') || !classes.includes('gap-1')
    || !classes.includes('justify-between') || !classes.includes('data-[state=open]:bg-primary-ghost-hover')
    || !(item.leading ? classes.includes('ps-[calc(') : classes.includes('px-3'))) throw Error('Unexpected trigger');
}
if (chevron.type !== 'svg' || chevron.props.children.type !== 'path') throw Error('Unexpected icon');
const desktopBody = css.match(/:is\(\[data-codex-window-type=browser\],\[data-codex-window-type=chrome-extension\],\[data-codex-window-type=electron\]\) body\{([^{}]+)\}/)?.[1];
const commonRoots = [...css.matchAll(/:where\(:root,\[data-theme\]\)\{([^{}]+)\}/g)].map(match => match[1]);
if (!desktopBody || !commonRoots.length) throw Error('Missing desktop color cascade');
const colorVariables = Object.fromEntries(['background-primary-soft-alpha', 'background-primary-ghost-hover', 'border', 'text-tertiary']
  .map(role => { const pattern = new RegExp('--color-' + role + ':var\\((--app-[^,)]+)');
    const match = desktopBody.match(pattern) ?? commonRoots.flatMap(rule => [...rule.matchAll(new RegExp(pattern, 'g'))]).at(-1);
    if (!match) throw Error('Missing desktop color ' + role); return [role, match[1]]; }));
fs.writeFileSync(outputPath, JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,
  cases,chevron,expected,colorVariables},null,2)+'\n');
console.log('Extracted actual form trigger branches, shared toolbar geometry, desktop colors and chevron');
