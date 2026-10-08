// Execute only the pinned controller's selection and transfer functions against
// explicit in-memory signals. No app initialization, DOM, callbacks or bridges.
const fs=require('fs'),vm=require('vm'),crypto=require('crypto');
const [sourcePath,outputPath]=process.argv.slice(2),source=fs.readFileSync(sourcePath,'utf8');
const sourceSHA256=crypto.createHash('sha256').update(source).digest('hex');
if(sourceSHA256!=='22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3')throw Error('Unverified source');
const controllerStart=source.indexOf('function FBn('),controllerEnd=source.indexOf('function IBn(',controllerStart);
const controller=source.slice(controllerStart,controllerEnd);
function extract(text,name,marker='function '+name+'('){
  const start=text.indexOf(marker),end=text.indexOf('function ',start+marker.length);
  if(start<0||end<0)throw Error(name);return text.slice(start,end).replace(/var [^;]+;$/,'');
}
const globals=['YBn','LBn','HBn','BBn','WBn','GBn','KBn','qBn','RBn','zBn'];
const code=globals.map(n=>extract(source,n)).join('\n')+'\n'+['ee','he','ge','_e'].map(n=>extract(controller,n)).join('\n');
const context={i:'ids',o:'tabs',m:'recent',d:'states',p:'selected',h:'history',g:'pair',e:'bottom',
  tVn:()=>{},se:()=>{},requestAnimationFrame:()=>{}};
vm.createContext(context);vm.runInContext(code,context);
const base=['a','b','c','d'];
const select=id=>({action:'select',id}),transfer=id=>({action:'transfer',id});
const open=(id,opener)=>({action:'open',id,...opener?{opener}:{}});
const scenarios=[
 ['recent-before-neighbor',[select('a'),select('c'),transfer('c')]],
 ['recent-last',[select('d'),select('b'),transfer('b')]],
 ['repeated-selection',[select('a'),select('b'),select('b'),transfer('b')]],
 ['inactive',[select('c'),transfer('a')]],
 ['inactive-recent-pruned',[select('a'),select('b'),select('c'),transfer('b'),transfer('c')]],
 ['recent-chain',[select('a'),select('b'),select('c'),select('d'),transfer('d'),transfer('c'),transfer('b'),transfer('a')]],
 ['select-null',[select('a'),select(null),select('b'),transfer('b')]],
 ['null-active',[select('a'),select(null),transfer('a')]],
 ['missing',[select('c'),transfer('missing')]],
 ['repeat-transfer',[select('a'),select('c'),transfer('c'),transfer('c')]],
 ['fresh-open',[select('a'),open('e'),transfer('e')]],
 ['opener-family-moved',[select('a'),open('e','a'),open('f','e'),transfer('e')]],
 ['opener-moved',[select('a'),open('e','a'),transfer('a')]],
 ['unrelated-family-retained',[select('a'),open('e','a'),transfer('b')]],
 ['empty-recent-right',[transfer('b')],{selected:'b'}],
 ['empty-recent-left',[transfer('d')],{selected:'d'}],
 ['single-empty',[transfer('a')],{ids:['a'],selected:'a'}],
 ['workspace-home-rejected',[transfer('a')],{selected:'a',home:'a'}],
];
const traces=scenarios.map(([name,actions,initial={}])=>{
 const ids=initial.ids??base;
 const values={ids:[...ids],tabs:Object.fromEntries(ids.map(id=>[id,{tabId:id,isWorkspaceHome:id===initial.home}])),
  states:Object.fromEntries(ids.map(id=>[id,{value:id}])),selected:initial.selected??null,recent:[],pair:null,
  history:{active:false,generation:0,lastSelectedTabId:null,tabs:{}}};
 const scope={get:(key,id)=>id===undefined?values[key]:values[key][id],set(key,id,value){
  if(arguments.length===3)values[key][id]=value;
  else values[key]=typeof id==='function'?id(values[key]):id;
 }};
 const steps=actions.map(action=>{
  let moved=null;
  if(action.action==='select')context._e(scope,action.id,true);
  else if(action.action==='transfer')moved=context.ee(scope,action.id)?.tab?.tabId??null;
  else {
   const at=action.opener?values.ids.indexOf(action.opener):-1;
   values.ids.splice(at<0?values.ids.length:at+1,0,action.id);
   values.tabs[action.id]={tabId:action.id,isWorkspaceHome:false};values.states[action.id]={value:action.id};
   if(action.opener)values.history=context.RBn(values.history,action.id,action.opener,false);
   context._e(scope,action.id,true);
  }
  return JSON.parse(JSON.stringify({...action,ids:values.ids,selected:values.selected,recent:values.recent,history:values.history,moved}));
 });return{name,initial:{ids,selected:initial.selected??null,home:initial.home??null},steps};
});
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256,
 boundary:'Actual FBn.ee/_e/he/ge and pure history helpers with explicit signals; inert fullscreen, layout repair and frame callbacks. Does not verify receiver routing, native focus, Pages pairs or primary workspace.',traces},null,2)+'\n');
console.log(`Extracted ${traces.length} actual selection/transfer traces`);
