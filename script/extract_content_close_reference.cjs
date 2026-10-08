// Pinned pure close-selection functions only; no application initialization.
const fs=require('fs'),vm=require('vm'),crypto=require('crypto');
const [sourcePath,outputPath]=process.argv.slice(2),source=fs.readFileSync(sourcePath,'utf8');
const sourceSHA256=crypto.createHash('sha256').update(source).digest('hex');
if(sourceSHA256!=='22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3')throw Error('Unverified source');
const names=['IBn','UBn','LBn','RBn','zBn','VBn','HBn','BBn','WBn','GBn','KBn','qBn'];
const code=names.map(name=>{const i=source.indexOf('function '+name+'('),j=source.indexOf('function ',i+10);if(i<0||j<0)throw Error(name);return source.slice(i,j).replace(/var [^;]+;$/,'')}).join('\n');
const context={};vm.createContext(context);vm.runInContext(code,context);
const open=(id,opener,background=false)=>({action:'open',id,...opener?{opener}:{},background});
const select=id=>({action:'select',id}),close=id=>({action:'close',id});
const move=(id,target,after=false)=>({action:'reorder',id,target,after});
const base=[open('a'),open('u'),open('z')];
const scenarios=[
 ['middle-right', [...base,select('u'),close('u')]],
 ['last-left', [...base,close('z')]],
 ['first-right', [...base,select('a'),close('a')]],
 ['inactive-no-selection', [...base,close('a')]],
 ['single-empty', [open('a'),close('a')]],
 ['missing-close', [...base,close('missing')]],
 ['explicit-opener', [...base,open('b','a'),close('b')]],
 ['nested-opener', [...base,open('b','a'),open('c','b'),close('c'),close('b')]],
 ['select-opener-preserves-family', [...base,open('b','a'),select('a'),select('b'),close('b')]],
 ['manual-unrelated-invalidates', [...base,open('b','a'),select('z'),select('b'),close('b')]],
 ['independent-new-tab-invalidates', [...base,open('b','a'),open('new'),select('b'),close('b')]],
 ['sibling-selection', [...base,open('b','a'),open('c','a'),select('b'),select('c'),close('c'),select('b'),close('b')]],
 ['background-from-selected-opener', [...base,select('a'),open('b','a',true),select('b'),close('b')]],
 ['background-from-unrelated-selection', [...base,open('b','a',true),select('b'),close('b')]],
 ['background-close-does-not-select', [...base,open('b','a',true),close('b')]],
 ['move-child-invalidates', [...base,open('b','a'),move('b','z',true),close('b')]],
 ['move-opener-invalidates', [...base,open('b','a'),move('a','z',true),close('b')]],
 ['move-unrelated-retains', [...base,open('b','a'),move('z','u'),close('b')]],
 ['remove-inactive-opener-prunes-descendants', [...base,open('b','a'),open('c','b'),close('a'),close('c')]],
 ['remove-inactive-child-prunes-grandchildren', [...base,open('b','a'),open('c','b'),close('b'),close('c')]],
 ['remove-unrelated-retains', [...base,open('b','a'),close('z'),close('b')]],
 ['new-generation', [...base,open('b','a'),select(null),select('z'),open('c','a'),close('c'),select('b'),close('b')]],
 ['explicit-clear', [...base,open('b','a'),select(null),select('b'),close('b')]],
 ['repeated-selection', [...base,open('b','a'),select('b'),select('b'),close('b')]],
];
const traces=scenarios.map(([name,actions])=>{
 let ids=[],selected=null,state={active:false,generation:0,lastSelectedTabId:null,tabs:{}};
 const setSelected=id=>{if(selected!==id){selected=id;state=context.zBn(state,id,ids)}};
 const steps=actions.map(step=>{
  if(step.action==='open'){
   const fresh=!ids.includes(step.id);if(fresh){const i=ids.indexOf(step.opener);ids.splice(i<0?ids.length:i+1,0,step.id)}
   if(fresh&&step.opener&&ids.includes(step.opener))state=context.RBn(state,step.id,step.opener,step.background);
   if(!step.background)setSelected(step.id);
  }else if(step.action==='select')setSelected(step.id);
  else if(step.action==='reorder'){
   const from=ids.indexOf(step.id);ids.splice(from,1);ids.splice(ids.indexOf(step.target)+(step.after?1:0),0,step.id);state=context.HBn(state,step.id);
  }else if(step.action==='close'&&ids.includes(step.id)){
   const next=selected===step.id?context.IBn(state,ids,ids.indexOf(step.id),step.id):selected;
   ids=ids.filter(id=>id!==step.id);setSelected(next);state=context.VBn(state,step.id);
  }
  return {...step,ids:[...ids],selected,history:JSON.parse(JSON.stringify(state))};
 });return{name,steps};
});
const siblingCases=[];
for(const ids of [['b','u','c'],['c','u','b'],['b','u'],['u','b']]){
 let state={active:true,generation:2,lastSelectedTabId:'b',tabs:{b:{generation:2,openerTabId:'missing'},c:{generation:2,openerTabId:'missing'}}};
 siblingCases.push({ids,state,closing:'b',next:context.IBn(state,ids,ids.indexOf('b'),'b')});
}
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256,
 boundary:'Actual IBn/RBn/zBn/VBn/HBn helpers with explicit controller state and caller order. Excludes paired content, unsaved approval, native focus and primary workspace; those require separate integration evidence.',traces,siblingCases},null,2)+'\n');
console.log(`Extracted ${traces.length} controller traces and ${siblingCases.length} explicit missing-opener cases`);
