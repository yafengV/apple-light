// Evaluate only public number-input callbacks; never launch the reference app.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, fixturePath] = process.argv.slice(2);
if (!sourcePath || !fixturePath) throw Error('Expected settings asset and output fixture');
const source = fs.readFileSync(sourcePath, 'utf8');
const sourceSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (sourceSHA256 !== '91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535') throw Error('Unverified reference version');
const jsx = (type, props) => ({ type, props });
function read(name) {
  const start = source.indexOf('function ' + name + '('), end = source.indexOf('function ', start + 15);
  if (start < 0 || end < 0) throw Error('Missing reference function ' + name);
  return source.slice(start, end);
}
function flatten(tree) {
  return !tree || typeof tree !== 'object' ? [] : [tree,
    ...[tree.props?.children].flat(Infinity).flatMap(flatten), ...flatten(tree.props?.control)];
}
const cases = [];
for (const [kind, name, current, min, max] of [['ui', 'sc', 14, 11, 16], ['code', 'cc', 12, 8, 24]]) {
  for (const [before, after] of [[String(current), String(current + 1)], [String(current), String(current - 1)],
    [String(current), String(max)], [String(current), String(min)], ['0014', '0014'],
    ['', String(min)], ['15.5', '16'], ['bad', 'bad'], ['99', '99']]) {
    const writes = [], schema = { safeParse: n => ({ success: Number.isFinite(n) && n >= min && n <= max }) };
    const context = { Q: { c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel')) },
      $: { jsx, jsxs: jsx }, pc: { useRef: () => ({ current: null }) },
      z: () => ({}), k: 0, P: () => ({ formatMessage: m => m.defaultMessage ?? m.id }),
      R: () => current, V: { sansFontSize: { schema }, codeFontSize: { schema } },
      hn: { sans: { min: 11, max: 16 }, code: { min: 8, max: 24 } },
      S: (_, __, n) => writes.push(n), M: 'M', J: { uiFontSize: {}, codeFontSize: {} }, N: 'N', zr: 'zr' };
    vm.createContext(context); vm.runInContext(read(name), context);
    const input = flatten(context[name]()).find(node => node.type === 'zr').props;
    const target = { value: before };
    input.onPointerDown({ currentTarget: target });
    target.value = after;
    input.onPointerUp({ currentTarget: target });
    const afterRelease = { text: target.value, writes: [...writes] };
    input.onPointerUp({ currentTarget: target });
    cases.push({ kind, current, before, after, afterRelease, afterDuplicateRelease: { text: target.value, writes: [...writes] } });
  }
}
fs.writeFileSync(fixturePath, JSON.stringify({ version: '26.930.51102', build: 13100, sourceSHA256, cases }, null, 2) + '\n');
console.log('Extracted', cases.length, 'actual pointer-release callback cases');
