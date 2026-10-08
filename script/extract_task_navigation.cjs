// Verified current public command literals and pure navigation functions only.
// The adjacent-chat hook uses inert registration/store stubs; no app or bridge.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sha256 = crypto.createHash('sha256').update(source).digest('hex');
if (sha256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified public registry');
function component(name) {
  const i = source.indexOf(`function ${name}(`), j = source.indexOf('function ', i + 10);
  if (i < 0 || j < 0) throw Error('Missing ' + name);
  return source.slice(i, j).replace(/var [^;]+;$/, '');
}
const mapping = {previousThread:'previous-task', nextThread:'next-task', previousTab:'previous-tab',
  nextTab:'next-tab', previousRecentThread:'previous-recent-task', nextRecentThread:'next-recent-task'};
const commands = Object.entries(mapping).map(([id, shipiosID]) => {
  const start = source.indexOf('{id:`' + id + '`', source.indexOf('function vqr('));
  const end = source.indexOf('},{id:', start) + 1;
  const command = vm.runInNewContext('(' + source.slice(start, end) + ')', {}, {timeout:1000});
  return {id, shipiosID, defaults:(command.electron.platformDefaultKeybindings?.macOS ?? command.electron.defaultKeybindings).map(value=>value.key),
    commandMenu:command.commandMenu===true, allowsRepeat:command.allowsKeyRepeat===true};
});
const pure={gSs:20};vm.createContext(pure);
vm.runInContext(['hSs','fSs','dcc'].map(component).join('\n'),pure);
const recentCases=[];
for(const current of [null,'a']) for(const direction of ['next','previous']) {
  const recent=['a','b','c']; const result=pure.hSs({currentThreadKey:current,direction,recentThreadKeys:recent});
  recentCases.push({current,direction,recent,session:null,unavailable:[],result});
}
let session=null;
for(const direction of ['next','next','next','previous']) {
  const before=session;session=pure.hSs({currentThreadKey:'a',direction,recentThreadKeys:['c','b','a'],session});
  recentCases.push({current:'a',direction,recent:['c','b','a'],session:before,unavailable:[],result:session});
}
for(const recent of [[],['a'],['a','b','c']]) {
  const unavailable=['b'];const result=pure.hSs({currentThreadKey:'a',direction:'next',recentThreadKeys:recent,isThreadAvailable:id=>!unavailable.includes(id)});
  recentCases.push({current:'a',direction:'next',recent,session:null,unavailable,result});
}
const releases=[{ctrlKey:true,key:'Tab'},{metaKey:true,altKey:true,key:'x'},
  {shiftKey:true,key:'Tab'},{ctrlKey:true,shiftKey:true,key:'Tab'}].map(event=>({event,keys:pure.dcc(event)}));
const adjacentCases=[];
for(const current of [null,'a','b','c','missing']) for(const direction of ['next','previous']) {
  const registrations={},selected=[];
  const context={gLa:{c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},W:0,FV:0,
    pp:()=>({get:()=>[]}),Wl:()=>[],ww:(id,action,options)=>{registrations[id]=action},
    fLa:()=>false,Sw:()=>false,GH:()=>false,fJr:()=>{}};
  vm.createContext(context);vm.runInContext(component('hLa') + component('mLa'),context);
  context.mLa({targets:['a','b','c'],getCurrentTarget:()=>current,onSelect:id=>selected.push(id)});
  registrations[direction==='next'?'nextThread':'previousThread']();
  adjacentCases.push({current,direction,targets:['a','b','c'],selected});
}
const actualPairs=source.match(/Kqr=(\[\[.*?\]\]),qqr=new Map/)?.[1];
if (!actualPairs) throw Error('Missing compatible command pairs');
const compatiblePairs = vm.runInNewContext(actualPairs, {}, {timeout:1000})
  .filter(pair => pair.every(id=>mapping[id])).map(pair=>pair.map(id=>mapping[id]));
if (compatiblePairs.length !== 4) throw Error('Unexpected navigation compatibility');
// Actual unified tab selector; supplied atoms/layout and inert selection only.
const contentTabCases=[];
for (const mode of ['full','split']) for (const current of mode==='full'?['left','right1','right2']:['right1','right2']) for (const direction of ['next','previous']) {
  const chat={kind:'chat'}, content=['left','right1','right2'].map(id=>({kind:'content',tab:{tabId:id,dndId:id}})), selected=[];
  const values={layout:{chat,content,auxiliary:content.slice(1)},primarySplit:mode==='split',mode:{mode},
    active:{tabId:current},includeChat:true,primaryMode:mode,kind:'content',locale:{locale:'en'},ordered:[chat,...content]};
  const context={HV:'layout',Xx:'primarySplit',ZM:'mode',XM:'active',cM:'includeChat',$M:'primaryMode',eN:'kind',En:'locale',_Jr:'ordered',Zx:'kind',jM:{activeTab$:'active'},
    qe:()=> 'ltr', cwa:(scope,tab)=>selected.push(tab.kind==='chat'?'chat':tab.tab.tabId), DM:id=>id,
    document:{getElementById:()=>null},requestAnimationFrame:()=>{}};
  vm.createContext(context);vm.runInContext(component('swa'),context);
  const handled=context.swa({get:key=>values[key]},direction,'chat-panel');
  contentTabCases.push({mode,current,direction,handled,selected});
}
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:sha256,
  boundary:'Literal commands, actual hSs/fSs/dcc, mLa and swa with inert command/store/explicit layout hooks; native modifier release, panel priority and rendered acceptance require separate validation',
  commands,compatiblePairs,recentCases,releases,adjacentCases,contentTabCases,
  cappedVisit:pure.fSs(Array.from({length:25},(_,i)=>String(i)),'current')},null,2)+'\n');
console.log('Extracted six commands, recent selection, release keys, adjacent boundaries and compatible pairs');
