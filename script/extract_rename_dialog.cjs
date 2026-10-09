// Execute pinned public rename form/components with explicit inert React/JSX mocks.
// This is source/CSS evidence, not a foreground or Radix focus acceptance test.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const {desktopTypography} = require('./reference_desktop_typography.cjs');
const [sourcePath, cssPath, initialPath, outputPath] = process.argv.slice(2);
const hashes = ['eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab',
  '4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720'];
const [source, css] = [sourcePath, cssPath].map((path, i) => {
  const text = fs.readFileSync(path, 'utf8');
  if (crypto.createHash('sha256').update(text).digest('hex') !== hashes[i]) throw Error('Unverified public resource');
  return text;
});
function literal(name) {
  const start = source.indexOf(name + '={') + name.length + 1;
  if (start < name.length + 1) throw Error('Missing ' + name);
  let depth = 0, quote = null, escape = false;
  for (let end = start; end < source.length; end++) {
    const c = source[end];
    if (quote) { if (escape) escape = false; else if (c === '\\') escape = true; else if (c === quote) quote = null; }
    else if ('"\'`'.includes(c)) quote = c;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return vm.runInNewContext('(' + source.slice(start, end + 1) + ')');
  }
  throw Error('Unclosed ' + name);
}
const context = {fli: {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
  q: (...items) => items.flat(Infinity).filter(Boolean).join(' '), ali: 'spinner',
  o5: {jsx: (type, props) => ({type, props}), jsxs: (type, props) => ({type, props}), Fragment: 'fragment'}};
for (const name of ['qci', 'mli', 'hli', 'gli']) context[name] = literal(name);
vm.createContext(context);
const start = source.indexOf('function dli('), end = source.indexOf('function ', start + 10);
if (start < 0 || end < 0) throw Error('Missing actual public button');
vm.runInContext(source.slice(start, end).replace(/var [^;]+;$/, ''), context);

const initial = fs.readFileSync(initialPath, 'utf8');
const initialHash = '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3';
if (crypto.createHash('sha256').update(initial).digest('hex') !== initialHash) throw Error('Unverified initial resource');
function fn(src, name) {
  const start = src.indexOf('function ' + name + '('), end = src.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error('Missing ' + name);
  return src.slice(start, end).replace(/var [^;]+;$/, '');
}
const jsx = {jsx: (type, props) => ({type, props}), jsxs: (type, props) => ({type, props}), Fragment: 'fragment'};
const memo = {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const shared = {M7: memo, P7: jsx, A7: () => false, q: context.q,
  k7: {body:'_body_1k5bv_2',section:'_section_1k5bv_2',footer:'_footer_1k5bv_2'},
  N7: {Children:{toArray: x => x}, isValidElement:x=>!!x?.props, cloneElement:(x,p)=>({...x,props:{...x.props,...p}})}, a5:'button'};
vm.createContext(shared);
for (const name of ['qbi','lxi','uxi','dxi','mxi','pxi','fxi']) vm.runInContext(fn(source,name),shared);
const rename = {wvo:memo, D1:{useRef:()=>({current:null}),useState:x=>[x,()=>{}]}, O1:jsx,
  pp:()=>({}),W:{},vs:()=>({formatMessage:x=>x.defaultMessage}),Wl:()=>null,WV:{},$:()=>false,AJr:{},
  id:'heading',L:'description',q:'message',Ia:'section',Vi:'header',QA:'input',ao:'button',Yc:'footer',sc:'body',Il:'dialog'};
vm.createContext(rename);vm.runInContext(fn(initial,'Cvo'),rename);
const messages={title:{defaultMessage:'Rename'},subtitle:{defaultMessage:'Short name'},placeholder:{defaultMessage:'Name'},ariaLabel:{defaultMessage:'Name'}};
const cases=[];
function find(node,type){if(!node)return; if(Array.isArray(node))return node.map(x=>find(x,type)).find(Boolean); if(node.type===type)return node;return find(node.props?.children,type);}
for (const requireNonEmpty of [false,true]) for(const initialValue of ['','Original']) {
  const tree=rename.Cvo({initialValue,requireNonEmpty,messages,onSave:()=>{},onClose:()=>{}});
  const footer=find(tree,'footer'), input=find(tree,'input');
  const buttons=shared.fxi({children:footer.props.children}).props.children[1].props.children;
  const rendered=buttons.map(x=>context.dli(x.props));
  cases.push({requireNonEmpty,initialValue,tree,buttons:rendered});
  if(tree.props.size!=='compact'||input.props.value!==initialValue||buttons.some(x=>x.props.size!=='medium'))throw Error('Unexpected rename form');
}
const spacing=Number(css.match(/--spacing:([\d.]+)rem;/)[1])*16;
const root=css.match(/@layer theme\{:root,:host\{([^{}]+)\}/)[1];
function rootRem(name){const value=root.match(new RegExp('--'+name+':([\\d.]+)(rem|px);')); if(!value)throw Error('Missing token '+name); return Number(value[1])*(value[2]==='rem'?16:1);}
function sectionMultiplier(name,property){const rule=css.match(new RegExp('\\.'+name+'\\{([^}]+)\\}'))[1];return spacing*Number(rule.match(new RegExp(property+':calc\\(var\\(--spacing,.25rem\\) \\* (\\d+)\\)'))[1]);}
const compact=shared.qbi('compact');
const medium=context.hli.medium;
if(compact!=='w-105'||!medium.includes('px-4 py-1.5 text-base leading-[18px]'))throw Error('Unexpected geometry');
if(!source.includes('children:[he?(0,O7.jsx)(`div`,{ref:pe,children:n}):n,ye]'))throw Error('Close button order changed');
if(!css.includes('--color-dialog-overlay:#0002;')||!css.includes('line-height:28px}.codex-dialog .heading-dialog'))throw Error('Unexpected modal CSS');
const inputVariant=initial.match(/default:`(h-9 rounded-md bg-primary-soft px-2\.5 text-sm)`/)[1];
const expected={width:spacing*Number(compact.slice(2)),maxViewportFraction:.92,
  padding:sectionMultiplier('_body_1k5bv_2','padding-inline'),sectionGap:sectionMultiplier('_section_1k5bv_2','padding-top'),headerGap:spacing,
  headingFont:rootRem('text-heading-md'),headingLineHeight:28,descriptionFont:rootRem('text-base'),descriptionLineHeight:rootRem('text-base')*1.5,
  inputHeight:spacing*9,inputPadding:spacing*2.5,inputFont:desktopTypography(css).labelSize,
  buttonHeight:18+spacing*1.5*2+2,buttonPadding:spacing*4,buttonFont:rootRem('text-base'),buttonLineHeight:18,
  borderWidth:1,buttonGap:spacing*3,closeSize:spacing*2+16,closeInset:spacing*4,
  overlayOpacity:2/15,disabledOpacity:.4,surfaceRadius:rootRem('radius-3xl-base'),buttonRadius:rootRem('radius-lg-base'),inputRadius:rootRem('radius-md-base')};
function focusOrder(sample) {
  const input=find(sample.tree,'input');
  return [...(input.props.disabled?[]:['name']),...sample.buttons.flatMap((x,i)=>x.props.disabled?[]:[i===0?'cancel':'save']),...(sample.tree.props.showDialogClose?['close']:[])];
}
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:[...hashes,initialHash],
  mocks:['React memo/state/ref; JSX inert tree; metadata disabled; no persistence, Radix or DOM execution'],cases,
  header:shared.uxi({title:'Rename',subtitle:'Short name'}),body:shared.dxi({as:'form',children:[]}),inputVariant,
  focusOrder:focusOrder(cases[0]),invalidFocusOrder:focusOrder(cases.find(x=>x.requireNonEmpty&&x.initialValue==='')),expected,
  cornerShapeNote:'CSS fallback radii; supported superellipse(1.5) scales radii by 1.25. Native curve/material still require paired acceptance.'},null,2)+'\n');
console.log('Extracted actual compact rename tree, medium buttons and CSS metrics');
