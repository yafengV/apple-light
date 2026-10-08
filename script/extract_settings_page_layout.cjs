// Evaluate the public settings page components without starting the application.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, cssPath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8'), css = fs.readFileSync(cssPath, 'utf8');
const sourceSHA256 = '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3';
const cssSHA256 = '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720';
const hash = text => crypto.createHash('sha256').update(text).digest('hex');
if (hash(source) !== sourceSHA256 || hash(css) !== cssSHA256) throw Error('Unverified public resources');
function component(name) {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end).replace(/var [^;]+;$/, '');
}
const cache = {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const jsx = (type, props) => typeof type === 'function' ? type(props) : {type, props};
const flatten = tree => tree == null ? [] : Array.isArray(tree) ? tree.flatMap(flatten)
  : typeof tree === 'object' ? [tree, ...flatten(tree.props?.children), ...flatten(tree.props?.title)] : [];
const cases = [];
for (const slate of [false, true]) for (const density of ['default', 'compact']) for (const embedded of [false, true]) {
  const context = {avs: cache, Q_s: cache, ca: (...items) => items.flat(Infinity).filter(Boolean).join(' '),
    ovs: {useRef: () => ({current: null}), useState: () => [false, () => {}],
      useContext: () => ({slateLayout: slate}), useLayoutEffect: () => {}},
    X6: {jsx, jsxs: jsx, Fragment: 'fragment'}, Y6: {jsx, jsxs: jsx},
    vm: () => {}, tC: {}, tvs: {}, gNa: 'sticky-controls', sNa: 'page-header', lNa: 'page-actions',
    EU: {Header: 'shell-header', HeaderToolbar: 'shell-toolbar'}};
  vm.createContext(context);
  vm.runInContext(component('Z_s') + component('rvs'), context);
  const tree = context.rvs({title: 'Reference settings', subtitle: 'Reference subtitle',
    density, embedded, children: 'settings-content'}), nodes = flatten(tree);
  const heading = nodes.find(node => node.type === 'h1');
  const page = nodes.find(node => node.props?.['data-density']);
  const sections = nodes.find(node => node.props?.children === 'settings-content');
  const headingClass = heading.props.className;
  const size = /heading-xl/.test(headingClass) ? 'xl' : 'lg';
  const rem = name => Number(css.match(new RegExp(`--${name}:([.\\d]+)rem;`))[1]) * 16;
  const spacing = rem('spacing');
  cases.push({slate, density, embedded, headingClass, pageClass: page.props.className,
    sectionClass: sections.props.className, expected: !slate && !embedded && density === 'default' ? {
      headingSize: rem(`font-heading-${size}-size`),
      headingWeight: headingClass.includes('font-normal') ? 'regular' : 'semibold',
      panelInset: spacing * 5, contentWidth: rem('container-3xl'),
      sectionSpacing: spacing * 10,
      headingContentSpacing: spacing * 8,
    } : undefined});
}
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100,
  sourceSHA256, cssSHA256, cases}, null, 2) + '\n');
console.log('Extracted', cases.length, 'settings page layout branches');
