// Execute the pinned public closed color input and accent composition.
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

const general=fs.readFileSync(generalPath,'utf8'),generalHash='91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535';
if(crypto.createHash('sha256').update(general).digest('hex')!==generalHash)throw Error('Unverified general settings');
context.lo=p=>({...chevron,props:{...chevron.props,...p}});
Object.assign(context,{va:cache,ya:{useState:v=>[v,()=>{}]},ba:{jsx,jsxs:jsx},Tt:p=>p.children,dn:p=>p.children[0],on:()=>null,yi:'picker',ha:()=>{},ma:()=>{},pa:()=>{},
 b9:cache,JOi:{useId:()=> 'reference-color-row'},x9:{jsx,jsxs:jsx}});
function component(source,name){const a=source.indexOf('function '+name+'('),b=source.indexOf('function ',a+10);if(a<0||b<0)throw Error('Missing '+name);vm.runInContext(source.slice(a,b).replace(/var [^;]+;$/,''),context)}
component(general,'fa');component(shared,'qOi');component(shared,'HOi');
Object.assign(context,{Ca:cache,wa:{jsx,jsxs:jsx},z:()=>({get:()=>null}),k:'store',P:()=>({formatMessage:p=>p.defaultMessage}),Xt:()=>({state:{}}),Vr:'account',Pt:'pending',
 B:t=>t==='account'?context.referenceAccount:{isPending:false},Bn:()=> '#0088ff',
 Di:{custom:{defaultMessage:'Custom'},default:{defaultMessage:'Default'},blue:{defaultMessage:'Blue'},lightCustom:{defaultMessage:'Custom accent'},darkCustom:{defaultMessage:'Custom accent'}},
 Ue:{options:['default','blue']},M:p=>p.defaultMessage,Hn:context.wvs,Zt:p=>p.triggerButton,I:{RadioItem:'menu-item',Section:'section',RadioGroup:'group'}});
component(general,'Sa');
const colors=['#181818','#FFFFFF'].map(value=>({value,tree:context.fa({ariaLabel:'Color',value,onChange:()=>{}})}));
const accents=['custom','account'].map(source=>{
 context.referenceAccount=source==='account'?{chatTheme:'blue',effectiveTheme:'blue'}:null;
 const control=context.Sa({ariaLabel:'Accent',theme:{accent:'#181818',accentSource:source==='account'?'chatgpt':'custom'},variant:'light',onSelect:()=>Promise.resolve(),onCustomColorChange:()=>{}});
 return {source,tree:context.HOi({size:'compact',label:'Accent',control})};
});
const spacing=Number(css.match(/--spacing:([\d.]+)rem;/)[1])*16;
if(!colors.every(c=>c.tree.props.className.includes('h-7 w-24 shrink-0')&&c.tree.props.className.includes('focus-within:ring-2')))throw Error('Unexpected color trigger');
const metrics={width:spacing*24,height:spacing*7,padding:spacing*2,swatch:spacing*3.5,gap:spacing*2,border:1,font:12,lineHeight:spacing*4,radius:9999,fieldX:1+spacing*2+spacing*3.5+spacing*2};
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,generalSettingsSHA256:generalHash,
 boundaries:'Closed popover composition; controlled account/color/translation data, callbacks not invoked',colors,accents,metrics},null,2)+'\n');
console.log('Extracted actual color input and two accent row compositions');
