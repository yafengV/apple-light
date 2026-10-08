// Execute the pinned public form trigger, shared button and chevron components.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const {desktopTypography} = require('./reference_desktop_typography.cjs');
const [initialPath, sharedPath, cssPath, generalPath, outputPath] = process.argv.slice(2);
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
const cases=[];
for (const [kind, variant] of [
  ['fontFamily',{size:'menuRow',radius:'full',className:'w-full max-w-36 max-sm:max-w-none'}],
  ['fontStyle',{size:'menuRow',radius:'full',className:'w-full max-w-36 max-sm:max-w-none'}],
  ['accent',{size:'menuRow',radius:'full',color:'outlineSurface',className:'w-full max-w-36 max-sm:max-w-none'}],
  ['codeTheme',{radius:'full',color:'outlineSurface',className:'w-44',leadingVisual:'swatch'}]
]) for(const disabled of [false,true]) cases.push({kind,disabled,props:variant,tree:context.wvs({...variant,disabled,children:'Selected option'})});
const general=fs.readFileSync(generalPath,'utf8');
const generalHash='91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535';
if(crypto.createHash('sha256').update(general).digest('hex')!==generalHash)throw Error('Unverified appearance calls');
const callSites=[...general.matchAll(/Hn,\{[^}]+/g)].map(x=>x[0]).filter(x=>x.includes('radius:`full`'));
if(callSites.length!==4||!callSites.some(x=>x.includes('leadingVisual:'))||!callSites.some(x=>x.includes('size:`menuRow`')))throw Error('Unexpected appearance trigger calls');
const iconName='YRs';
const iconFunction=initial.slice(initial.indexOf('function '+iconName+'('),initial.indexOf('function ',initial.indexOf('function '+iconName+'(')+10)).replace(/var [^;]+;$/, '');
const swatchContext={XRs:cache,ca:join,ZRs:{jsx},q:'message'};
vm.createContext(swatchContext);vm.runInContext(iconFunction,swatchContext);
const swatches=['trigger','default'].map(size=>({size,tree:swatchContext.YRs({size,theme:{ink:'#000000',surface:'#ffffff',accent:'#0000ff'}})}));
if(!swatches.every(x=>x.tree.props.className.includes('rounded-full')))throw Error('Unexpected swatch shape');
const typography=desktopTypography(css), spacing=Number(css.match(/--spacing:([\d.]+)rem;/)[1])*16;
const metrics={height:spacing*7,fontSize:typography.descriptionSize,lineHeight:spacing*4,padding:spacing*2,
 fontMaxWidthClass:spacing*36,codeWidth:spacing*44,codeFontSize:typography.labelSize,
 codeSwatchSize:spacing*5,swatchSize:spacing*6,accentSize:spacing*3,
 radius:Number(css.match(/--radius-full:([\d.]+)px;/)[1]),disabledOpacity:0.4};
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,
 generalSettingsSHA256:generalHash,widthCascade:'max-w-full follows max-w-36 in the full public CSS; the computed maximum is 100%, not 144px',callSites,cases,swatches,metrics},null,2)+'\n');
for(const item of cases.filter(x=>!x.disabled)) console.log(item.kind,item.tree.props.className);
