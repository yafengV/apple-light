// Execute the pinned public desktop label/row components and resolve their CSS tokens.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sharedPath, cssPath, generalPath, outputPath] = process.argv.slice(2);
const hashes = ['eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab',
  '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720',
  '91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535'];
const [shared, css, general] = [sharedPath, cssPath, generalPath].map((path, index) => {
  const text = fs.readFileSync(path, 'utf8');
  if (crypto.createHash('sha256').update(text).digest('hex') !== hashes[index]) throw Error('Unverified public resource');
  return text;
});
const cache = {c: count => Array(count).fill(Symbol.for('react.memo_cache_sentinel'))};
const join = (...items) => items.flat(Infinity).filter(Boolean).join(' ');
const jsx = (type, props) => typeof type === 'function' ? type(props) : {type, props};
const context = {b9: cache, q: join, JOi: {useId: () => 'reference-row'}, x9: {jsx, jsxs: jsx}};
vm.createContext(context);
for (const name of ['qOi', 'HOi']) {
  const start = shared.indexOf(`function ${name}(`), end = shared.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  vm.runInContext(shared.slice(start, end).replace(/var [^;]+;$/, ''), context);
}
const cases = [{}, {size: 'compact'}, {controlSizing: 'intrinsic'}, {controlSizing: 'grow'},
  {variant: 'nested'}, {variant: 'stacked'}, {labelWeight: 'regular'}].map(props => ({props,
    tree: context.HOi({...props, label: 'Setting', description: 'Description', control: 'Control'})}));
Object.assign(context, {as: cache, ss: {jsx, jsxs: jsx}, os: {useState: () => [false, () => {}]},
  z: () => ({}), k: {}, P: () => ({}), R: () => context.customRoot,
  F: {projectlessWorkspaceRoot: 'folder'}, B: () => ({data: '/default/folder'}), rt: 'default-folder',
  M: 'message', xn: 'middle-truncated-text', me: 'button', N: context.HOi});
const folderStart = general.indexOf('function is(e)'), folderEnd = general.indexOf('function ', folderStart + 12);
if (folderStart < 0 || folderEnd < 0) throw Error('Missing actual folder component');
vm.runInContext(general.slice(folderStart, folderEnd).replace(/var [^;]+;$/, ''), context);
const folders = [null, '/custom/folder'].map(root => {
  context.customRoot = root;
  return {root, tree: context.is({service: {}})};
});
const folderControl = folders[0].tree.props.children[1].props.children;
const pathClasses = folderControl.props.children[0].props.className;
if (!pathClasses.includes('w-48 max-w-full font-mono text-xs')) throw Error('Unexpected actual folder path');
const normal = cases[0].tree, label = normal.props.children[0], control = normal.props.children[1];
const title = label.props.children[1].props.children[0];
const description = label.props.children[1].props.children[1];
if (!title.props.className.includes('text-sm') || !description.props.className.includes('text-xs leading-4')
  || !control.props.className.includes('min-w-[min(--spacing(40),40cqw)]')) throw Error('Unexpected public row structure');
const spacing = Number(css.match(/--spacing:([.\d]+)rem;/)[1]) * 16;
const labelFontSize = Number(css.match(/--text-sm:([\d.]+)px;/)[1]);
const descriptionFontSize = Number(css.match(/--text-xs:([\d.]+)px;/)[1]);
const lineRatio = css.match(/--text-sm--line-height:calc\(([\d.]+) \/ ([\d.]+)\);/);
if (!lineRatio) throw Error('Missing desktop label line height');
const minimum = css.match(/min-width:min\(calc\(var\(--spacing\) \* (\d+)\), (\d+)cqw\)/);
if (!minimum) throw Error('Missing actual CSS minimum width rule');
const expected = {labelFontSize, descriptionFontSize, labelDescriptionGap: spacing * .5,
  labelLineHeight: labelFontSize * Number(lineRatio[1]) / Number(lineRatio[2]),
  controlMinimum: spacing * Number(minimum[1]), controlWidthFraction: Number(minimum[2]) / 100,
  rowGap: spacing * 6, descriptionLineHeight: spacing * 4, folderPathWidth: spacing * 48};
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256: hashes,
  cases, folders, expected, widths: [628, 328, 168].map(width => ({width,
    minimumControlWidth: Math.min(expected.controlMinimum, width * expected.controlWidthFraction)}))}, null, 2) + '\n');
console.log(`Extracted ${cases.length} actual row branches, desktop typography and CSS width rule`);
