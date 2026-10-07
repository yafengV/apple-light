// Extract only the public theme-card JSX expressions, not the application runtime.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import path from 'node:path';

const [sourcePath, resourceDirectory, fixturePath] = process.argv.slice(2);
if (!sourcePath || !resourceDirectory || !fixturePath) throw new Error('Expected source, resource directory and fixture path');
const source = fs.readFileSync(sourcePath, 'utf8');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const jsx = (type, props) => ({ type: typeof type === 'function' ? type.name : type, props });
const context = vm.createContext({ W: { jsx, jsxs: jsx }, G: { jsx, jsxs: jsx }, q: { jsx, jsxs: jsx }, K: { jsx, jsxs: jsx },
  Q: { c: count => Array(count).fill(Symbol.for('react.memo_cache_sentinel')) }, $: { jsx, jsxs: jsx },
  ie: (...values) => values.filter(Boolean).join(' '), bc: { light: 'light', dark: 'dark' }, aa: 'system-light', ra: 'system-dark', oc: 'preview', ut: 'tooltip' });
const component = name => {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`Missing ${name}`);
  return source.slice(start, source.indexOf('function ', start + 15));
};
vm.runInContext(component('ac') + component('oc'), context);
const attributeNames = { clipPath: 'clip-path', strokeWidth: 'stroke-width', strokeOpacity: 'stroke-opacity',
  fillOpacity: 'fill-opacity', shapeRendering: 'shape-rendering', colorInterpolationFilters: 'color-interpolation-filters', floodOpacity: 'flood-opacity' };
const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
const svg = tree => {
  const { children, ...props } = tree.props ?? {};
  const attributes = Object.entries(props).map(([key, value]) => `${attributeNames[key] ?? key}="${escape(value)}"`).join(' ');
  return `<${tree.type}${attributes ? ' ' + attributes : ''}>${[children].flat(Infinity).filter(Boolean).map(svg).join('')}</${tree.type}>`;
};
fs.mkdirSync(resourceDirectory, { recursive: true });
const artwork = [];
for (const [name, symbol] of [['dark', '$i'], ['light', 'ta'], ['system-light', 'aa'], ['system-dark', 'ra']]) {
  const start = source.indexOf(`${symbol}=e=>`), end = source.indexOf('})))()}', start);
  if (start < 0 || end < 0) throw new Error(`Missing ${symbol} artwork`);
  vm.runInContext('var ' + source.slice(start, end), context);
  const tree = context[symbol]({});
  const data = svg(tree) + '\n';
  fs.writeFileSync(path.join(resourceDirectory, name + '.svg'), data);
  artwork.push({ name, symbol, sha256: sha(data), tree });
}
// Evaluate the actual group to retain its classes, option order and checked state.
Object.assign(context, { z: () => ({}), k: {}, P: () => ({ formatMessage: value => value }), R: () => context.mode,
  V: { theme: 'theme' }, S: () => {}, J: { theme: '主题' }, yc: [{ id: 'system', label: '系统' }, { id: 'light', label: '浅色' }, { id: 'dark', label: '深色' }] });
vm.runInContext(component('Ys'), context);
const cases = ['system', 'light', 'dark'].map(mode => {
  context.mode = mode;
  return { mode, group: context.Ys(), option: context.ac({ ariaLabel: mode, mode, selected: true, onSelect: () => {} }), preview: context.oc({ mode, selected: true }) };
});
fs.writeFileSync(fixturePath, JSON.stringify({ version: '26.930.51102', build: '13100', sourceAsset: 'general-settings-4f1402fc1fbd.js', sourceSHA256: sha(source), cases, artwork }, null, 2) + '\n');
fs.writeFileSync(path.join(resourceDirectory, 'PROVENANCE.md'), `# Theme preview artwork\n\nExtracted from the publicly distributed Codex desktop application 26.930.51102 (build 13100), asset general-settings-4f1402fc1fbd.js, SHA-256 ${sha(source)}. Original artwork belongs to OpenAI; the Codex Core Apache license is not asserted to cover these desktop assets.\n\nThe extraction procedure is script/extract_theme_card_reference.mjs. SVG currentColor is resolved using the active theme when rendered.\n\nscript/render_theme_previews.swift renders the original SVGs offline using WebKit into separate neutral base and accent-mask PNGs at 1×, 2× and 3×. Native AppKit SVG decoding omits some filter effects; the packaged raster representations preserve them without a live WebKit view in the picker. Regenerate SVGs first, then raster resources.\n\n${artwork.map(item => `- ${item.name}.svg (${item.symbol}): ${item.sha256}`).join('\n')}\n`);
console.log(JSON.stringify({ sourceSHA256: sha(source), artwork: artwork.map(({ name, sha256 }) => ({ name, sha256 })) }));
