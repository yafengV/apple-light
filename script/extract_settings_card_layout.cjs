// Evaluate the pinned public settings section, card and row components.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [initialPath, sharedPath, cssPath, outputPath] = process.argv.slice(2);
const paths = [initialPath, sharedPath, cssPath];
const hashes = [
  '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3',
  'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab',
  '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720',
];
const [initial, shared, css] = paths.map((path, index) => {
  const text = fs.readFileSync(path, 'utf8');
  if (crypto.createHash('sha256').update(text).digest('hex') !== hashes[index]) throw Error('Unverified public resource');
  return text;
});
function component(source, name) {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end).replace(/var [^;]+;$/, '');
}
const cache = {c: count => Array(count).fill(Symbol.for('react.memo_cache_sentinel'))};
const join = (...items) => items.flat(Infinity).filter(Boolean).join(' ');
const jsx = (type, props) => typeof type === 'function' ? type(props) : {type, props};
const context = {iUs: cache, QHs: cache, rki: cache, b9: cache, ca: join, q: join,
  n5: {jsx, jsxs: jsx, Fragment: 'fragment'}, $Hs: {jsx, jsxs: jsx},
  iki: {jsx, jsxs: jsx}, x9: {jsx, jsxs: jsx}, JOi: {useId: () => 'reference-row'},
  qOi: 'setting-label', eki: {daybreak: 'reference-decoration'}};
for (const name of ['XOi', 'ZOi']) {
  const match = shared.match(new RegExp(`${name}=\x60([^\x60]+)\x60`));
  if (!match) throw Error(`Missing ${name}`);
  context[name] = match[1];
}
vm.createContext(context);
vm.runInContext(['tUs', 'nUs', 'rUs', 'ZHs'].map(name => component(initial, name)).join('\n')
  + ['nki', 'HOi'].map(name => component(shared, name)).join('\n'), context);
const headers = [{title: 'Section'}, {title: 'Section', subtitle: 'Description'},
  {title: 'Section', size: 'compact', spacing: 'compact'}, {}]
  .map(props => ({props, tree: context.nUs(props)}));
const cards = ['default', 'secondary', 'form', 'flat', 'outlined']
  .map(variant => ({variant, tree: context.nki({variant, children: ['first-row', 'second-row']})}));
const rows = [{}, {size: 'compact'}, {variant: 'nested'}, {variant: 'stacked'},
  {layout: 'split'}, {inset: false}].map(props => ({props,
    tree: context.HOi({...props, label: 'Setting', control: 'Control'})}));
const spacing = Number(css.match(/--spacing:([.\d]+)rem;/)[1]) * 16;
const headingSize = Number(css.match(/--text-base:([\d.]+)px;/)[1]);
const toolbarHeight = Number(css.match(/--height-toolbar:([\d.]+)px;/)[1]);
const radius = css.match(/--radius-2xl-base:([^;]+);/)[1];
if (radius !== '1rem') throw Error(`Unexpected corner radius ${radius}`);
const header = headers[0].tree.props.className, card = cards[0].tree.props.className,
  row = rows[0].tree.props.className;
for (const [value, required] of [[header, ['min-h-toolbar', 'pb-1.5']],
  [card, ['rounded-2xl', 'border border-default', 'after:inset-x-4', 'after:h-px']],
  [row, ['px-4', 'gap-6 py-3']]]) {
  for (const token of required) if (!value.includes(token)) throw Error(`Missing reference class ${token}`);
}
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100,
  sourceSHA256: hashes, headers, cards, rows,
  content: context.rUs({children: 'section-content'}),
  footers: ['description', 'action'].map(variant => context.ZHs({variant, children: 'Footer'})),
  expected: {sectionHeadingSize: headingSize, sectionHeaderMinHeight: toolbarHeight, sectionHeaderBottomInset: spacing * 1.5,
    cardRadius: 16, cardBorderWidth: 1, dividerInset: spacing * 4, dividerHeight: 1,
    rowHorizontalInset: spacing * 4, rowVerticalInset: spacing * 3, rowGap: spacing * 6},
}, null, 2) + '\n');
console.log(`Extracted ${headers.length} section headers, ${cards.length} cards and ${rows.length} row branches`);
