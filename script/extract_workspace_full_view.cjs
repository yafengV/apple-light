const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [initialPath, chromePath, output, sharedPath, cssPath] = process.argv.slice(2);
const source = fs.readFileSync(initialPath,'utf8'), chrome = fs.readFileSync(chromePath,'utf8');
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
if (sha(source) !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3'
  || sha(chrome) !== 'db5f01832c7d9c730407f6f4e4cdd699dd584393c206439fe12890d265dd3c4b') throw Error('Unverified source');
const functions = ['fwa','pwa','mwa','QJ','$J','cwa','dwa','kM','SHn','mHn','KM','GM','pHn','fHn','aHn','iVn','aC'];
const code = functions.map(name => {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ',start+10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start,end).replace(/var [^;]+;$/,'');
}).join('\n');
const traces = [];
for (const mode of ['full','split']) for (const visible of [false,true])
for (const focus of ['chat','content']) for (const count of [0,1,3]) {
  if (!visible && focus === 'content' || visible && count === 0
    || mode === 'full' && visible && focus === 'chat') continue;
  const tabs = Array.from({length:count},(_,i)=>({tabId:`content-${i+1}`,dndId:`content-${i+1}`,tabType:{}}));
  const initial = {mode,visible,focus,ids:tabs.map(t=>t.tabId),selected:tabs.at(-1)?.tabId??null};
  const values = {qS:true,KS:false,Xx:false,aS:{},bi:false,tS:mode,nS:!visible && mode==='full',yC:visible,
    Yx:visible && mode === 'full',$x:focus,oS:'right',cS:focus === 'chat'?'main':'right-panel',lS:'main',
    active:tabs.at(-1)??null,tabs,Tc:{isCapable:true},vC:{get:()=>1},sS:0,YM:null};
  const scope = {get(key,parameter) {
    if (key === '$M') return values.nS?'chat':values.tS==='full'?'full':this.get('QM')?'split':'chat';
    if (key === 'QM') return values.yC && values.active != null;
    if (key === 'eN') return this.get('QM')&&(values.Yx||values.$x==='content')?'content':'chat';
    if (key === 'byID') return tabs.find(t=>t.tabId===parameter);
    if (key === 'HV') return {chat:{kind:'chat'},content:tabs.map(tab=>({kind:'content',tab}))};
    return values[key];
  },set(key,value) { values[key] = typeof value === 'function'?value(values[key]):value; }};
  const jM = {activeTab$:'active',tabs$:'tabs',tabById$:'byID',activateTab(e,id) {
    e.set('active',tabs.find(t=>t.tabId===id)??null);e.set('$x','content');
  }};
  const context = {jM,hwa:{flushSync:f=>f()},document:{activeElement:null},requestAnimationFrame:()=>{},
    I:()=>{},dte:{},I_e:{},Y$r:{},Jx:(e,area)=>e.set('cS',area),xMt:()=>null,aVn:()=>{},iC:()=>{},
    gHn:()=>{},cHn:()=>{},hHn:()=>null,FM:()=>{},UM:()=>jM,pM:()=>false,
    Wi:(_scope,_reason,action)=>action(),cr:'qS',Po:'HV',Jr:'oS',i:scope,x:mode,
    XJ(e) {const tab={tabId:'new-browser',dndId:'new-browser',tabType:{}};tabs.push(tab);e.set('active',tab);return tab;}};
  for (const atom of ['qS','KS','Xx','aS','bi','tS','nS','yC','Yx','$x','oS','cS','lS','HV','Tc','vC','sS','YM','$M','QM','eN','uS','Zx','XM','eS','YMt']) context[atom]=atom;
  vm.createContext(context);vm.runInContext(code,context);
  context.ma=context.pwa;context.Zi=context.QJ;
  context.pwa(scope,'full');
  traces.push({initial,result:{mode:values.tS,visible:values.yC,display:scope.get('$M'),focus:scope.get('eN'),focusArea:values.cS,selected:values.active?.tabId??null,ids:tabs.map(t=>t.tabId)}});
}

function component(name) {
 const a=chrome.indexOf(`function ${name}(`),b=chrome.indexOf('function ',a+10);
 if(a<0||b<0)throw Error(name);return chrome.slice(a,b).replace(/var [^;]+;$/,'');
}
const jsx=(type,props)=>({type,props}), cache={c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
function button(tree){if(tree?.type==='button')return tree.props;
 for(const child of [tree?.props?.children].flat(Infinity)){if(child){const found=button(child);if(found)return found;}}return null;}
const policies=[];
for(const count of [0,1,9,10,25])for(const display of ['chat','split','full']) {
 const context={tu:cache,nu:{jsx},Ht:()=>({value:{routeKind:'thread'}}),_:0,
 Me:()=>({formatMessage:(_key,args)=>args?.count??''}),K:key=>({ps:'toggle',hs:display==='full'?'exit':'enter',cr:true,ru:count,gi:display,ms:false,au:true})[key],ut:()=>'',
 zl:'newTab',Wl:'retained',ie:'icon',Ro:'stack',Ce:'column',ce:'button',rt:'tooltip',wo:'dropdown',ti:0,E:'expand',ae:'collapse',
 ps:'ps',hs:'hs',cr:'cr',ru:'ru',gi:'gi',ms:'ms',au:'au'};
 vm.createContext(context);vm.runInContext(component('eu')+component('Ql'),context);
 const main=button(context.eu({})), full=button(context.Ql());
 policies.push({count,display,main:main?{pressed:main['aria-pressed']??null,icon:main.children.props.asset??main.children.type,color:main.color}:null,
 full:{pressed:full['aria-pressed'],icon:full.children.props.asset,color:full.color}});
}
const shared=fs.readFileSync(sharedPath,'utf8'),css=fs.readFileSync(cssPath,'utf8');
if(sha(shared)!=='eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab'
 ||sha(css)!=='b9602ce3f1d278f45bb058f5004c769a741b43acb08b987aec3ae57781fc709f')throw Error('Unverified artwork/CSS');
for(const [variable,name]of [['ONi','rectangle-landscape-light-16'],['ENi','plus-sm-light-12']])
 if(!shared.includes(`${variable}=J({name:\`${name}\``))throw Error('Missing artwork metadata');
const fontRules=css.match(/\._count_1ib88_2\{[^}]+\}/)?.[0],overflowRule=css.match(/\._count_1ib88_2\[data-multiple-digits=true\]\{[^}]+\}/)?.[0];
if(!fontRules?.includes('font-size:8px')||!overflowRule?.includes('font-size:6px'))throw Error('Missing count typography');
const a=source.indexOf('function jfs('),b=source.indexOf('function ',a+10);
if(a<0||b<0)throw Error('Missing count component');
const counts=[0,1,9,10,25].map(count=>{
 const context={Mfs:cache,F6:{jsx,jsxs:jsx},Ga:'asset',ele:'rectangle',qse:'plus',uSe:'minus',kfs:{count:'count'},q:'overflow',lg:'number'};
 vm.createContext(context);vm.runInContext(source.slice(a,b).replace(/var [^;]+;$/,''),context);
 const badge=context.jfs({count}).props.children[1].props;
 return {count,label:count===0?null:badge.children.type==='overflow'?`${badge.children.props.values.count}+`:String(badge.children.props.value),
  plus:badge.children.props.asset==='plus',fontSize:badge['data-multiple-digits']?6:8};
});
fs.writeFileSync(output,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:sha(source),chromeSHA256:sha(chrome),sharedSHA256:sha(shared),cssSHA256:sha(css),counts,
 boundary:'Actual ordinary-workspace pwa full-view transitions and eu/Ql toolbar properties, explicit atoms/JSX and inert native effects. Hidden full chat explicitly sets nS. No primary workspace, DOM/OS focus or foreground acceptance.',policies,traces},null,2)+'\n');
console.log(`Extracted ${traces.length} full-view traces and ${policies.length} toolbar states`);
