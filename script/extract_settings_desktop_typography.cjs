const fs = require('fs'), crypto = require('crypto');
const {desktopTypography} = require('./reference_desktop_typography.cjs');
const [cssPath, rowPath, buttonPath, outputPath] = process.argv.slice(2);
const css = fs.readFileSync(cssPath, 'utf8');
const hash = '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720';
if (crypto.createHash('sha256').update(css).digest('hex') !== hash) throw Error('Unverified public CSS');
const row = JSON.parse(fs.readFileSync(rowPath)), button = JSON.parse(fs.readFileSync(buttonPath));
if (row.sourceSHA256[1] !== hash || button.sourceSHA256[1] !== hash
  || row.sourceSHA256[0] !== button.sourceSHA256[0]) throw Error('Inconsistent public components');
const desktop = desktopTypography(css);
if (row.expected.labelFontSize !== desktop.labelSize || button.expected.fontSize !== desktop.labelSize
  || row.expected.descriptionFontSize !== desktop.descriptionSize) throw Error('Unresolved desktop override');
const rule = selector => {
  const start = css.indexOf(selector + '{'), end = css.indexOf('}', start);
  if (start < 0 || end < 0) throw Error('Missing ' + selector);
  return css.slice(start, end + 1);
};
const utilities = ['.text-sm', '.text-xs', '.leading-4', '.leading-\\[18px\\]'].map(rule);
const referenceCSS = [desktop.rootCSS, ...utilities, desktop.desktopCSS].join('\n');
const expected = {...row.expected, ...button.expected};
const normal = row.cases[0].tree.props.children[0].props.children[1].props.children;
const componentClasses = {label: normal[0].props.className, description: normal[1].props.className,
  button: button.cases[0].tree.props.className};
fs.writeFileSync(outputPath, JSON.stringify({version: row.version, build: row.build,
  sourceSHA256: row.sourceSHA256, defaults: desktop.defaults, desktopOverrides: desktop.desktop,
  referenceCSS, componentClasses, expected, widths: row.widths}, null, 2) + '\n');
console.log('Extracted desktop cascade: labels/buttons ' + desktop.labelSize + ', descriptions ' + desktop.descriptionSize);
