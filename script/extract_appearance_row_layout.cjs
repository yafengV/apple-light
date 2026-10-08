// Execute the pinned public font wrapper, compact row and trigger components.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
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

const general=fs.readFileSync(generalPath,'utf8');
if(crypto.createHash('sha256').update(general).digest('hex')!=='91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535')throw Error('Unverified general settings');
context.lo=p=>({...chevron,props:{...chevron.props,...p}});
Object.assign(context,{b9:cache,JOi:{useId:()=> 'reference-row'},x9:{jsx,jsxs:jsx}});
for(const name of ['qOi','HOi']){
 const a=shared.indexOf('function '+name+'('),b=shared.indexOf('function ',a+10);
 vm.runInContext(shared.slice(a,b).replace(/var [^;]+;$/,''),context);
}
Object.assign(context,{Na:cache,Pa:{useState:v=>[v,()=>{}]},ka:'fonts',B:()=>({data:[{family:'Menlo',faces:[{postscriptName:'Menlo-Regular',styleName:'Regular'}]}],isPending:false}),
 Ea:value=>value?{family:{family:value,faces:[{postscriptName:'Menlo-Regular',styleName:'Regular'}]},face:{styleName:'Regular'}}:null,
 Da:v=>v,Ma:()=>true,hi:v=>v,gi:()=>{},Y:{jsx,jsxs:jsx,Fragment:'fragment'},
 M:p=>p.defaultMessage,J:{chromeThemeSystemFont:{defaultMessage:'System default'},chromeThemeRegularFontStyle:{defaultMessage:'Regular'}},
 Zt:p=>p.triggerButton,Hn:context.wvs,T:'spinner',I:{Input:'input',Item:'menu-item',Section:'section',Separator:'hr'},ye:'check'});
const a=general.indexOf('function ja('),b=general.indexOf('function ',a+10);
vm.runInContext(general.slice(a,b).replace(/var [^;]+;$/,''),context);
const cases=[];
for(const [name,controls,value,defaultFont] of [
 ['family','family','Menlo','system'],['style','style','Menlo','system'],['both','both','Menlo','system'],
 ['inherit','both',null,'ui'],['long','both','A very long installed family name','system']]){
 const control=context.ja({ariaLabel:name,styleAriaLabel:name+' style',controls,value,defaultFont,onChange:()=>{}});
 cases.push({name,tree:context.HOi({size:'compact',label:'Font',control})});
}
const widths=[628,328,168];
const spacing=Number(css.match(/--spacing:([\d.]+)rem;/)[1])*16;
const minimum=css.match(/min-width:min\(calc\(var\(--spacing\) \* (\d+)\), (\d+)cqw\)/);
const arrow=Number(css.match(/\.icon-2xs\{height:var\(--icon-secondary-size,(\d+)px\)/)[1]);
const border=Number(css.match(/\.border\{border-style:[^;]+;border-width:(\d+)px/)[1]);
const metrics={horizontalPadding:spacing*4,rowGap:spacing*4,controlMinimum:spacing*Number(minimum[1]),controlFraction:Number(minimum[2])/100,
 buttonChrome:spacing*4+spacing+2*border+arrow,controlsGap:spacing*2};

for(const item of cases){
 const row=item.tree,control=row.props.children[1];
 if(!row.props.className.includes('gap-4 py-2')||!control.props.className.includes('min-w-[min(--spacing(40),40cqw)]'))throw Error('Unexpected compact font row');
}
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,generalSettingsSHA256:crypto.createHash('sha256').update(general).digest('hex'),cases,widths,metrics},null,2)+'\n');
console.log('Extracted five actual ja font controls in compact HOi rows');
