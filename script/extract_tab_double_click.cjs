const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [initialPath, chromePath, output] = process.argv.slice(2);
const source = fs.readFileSync(initialPath,'utf8'), chrome = fs.readFileSync(chromePath,'utf8');
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
if (sha(source) !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3'
  || sha(chrome) !== 'db5f01832c7d9c730407f6f4e4cdd699dd584393c206439fe12890d265dd3c4b') throw Error('Unverified source');
const start = chrome.indexOf('F=e=>{if(i.get(cr))'), end = chrome.indexOf(',t[2]=x',start);
if (start < 0 || end < 0) throw Error('Missing double-click handler');
const handler = chrome.slice(start+2,end);
const functions = ['fwa','pwa','mwa','QJ','$J','cwa','dwa','kM','SHn','mHn','KM','GM','pHn','fHn','aHn','iVn','aC'];
const code = functions.map(name => {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ',start+10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start,end).replace(/var [^;]+;$/,'');
}).join('\n');
const traces = [];
for (const mode of ['full','split']) for (const visible of [false,true])
for (const focus of ['chat','content']) for (const count of [0,1,3]) for (const target of ['chat','content']) {
  if (!visible && focus === 'content' || visible && count === 0
    || mode === 'full' && visible && focus === 'chat' || target === 'content' && count === 0) continue;
  const tabs = Array.from({length:count},(_,i)=>({tabId:`content-${i+1}`,dndId:`content-${i+1}`,tabType:{}}));
  const initial = {mode,visible,focus,ids:tabs.map(t=>t.tabId),selected:tabs.at(-1)?.tabId??null,target};
  const values = {qS:true,KS:false,Xx:false,aS:{},bi:false,tS:mode,nS:false,yC:visible,
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
  vm.runInContext(`(${handler})`,context)(target==='chat'?{kind:'chat'}:{kind:'content',tab:tabs[0]});
  traces.push({initial,result:{mode:values.tS,visible:values.yC,focus:scope.get('eN'),focusArea:values.cS,selected:values.active?.tabId??null,ids:tabs.map(t=>t.tabId)}});
}
fs.writeFileSync(output,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:sha(source),chromeSHA256:sha(chrome),
  boundary:'Actual Du double-click handler plus pinned layout functions. Ordinary workspace, retained nonempty content; explicit atoms and inert native effects. State is at handler invocation, not a simulated OS click sequence. Empty-browser selection disposal is covered separately in phase 715. No primary workspace or foreground acceptance.',traces},null,2)+'\n');
console.log(`Extracted ${traces.length} double-click layout traces`);
