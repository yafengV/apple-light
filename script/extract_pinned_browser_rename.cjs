const fs=require('fs'),crypto=require('crypto'),vm=require('vm');
const [input,output]=process.argv.slice(2),source=fs.readFileSync(input,'utf8');
const sourceSHA256=crypto.createHash('sha256').update(source).digest('hex');
if(sourceSHA256!=='22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3')throw Error('Unverified source');
function extract(name){const start=source.indexOf(`function ${name}(`),end=source.indexOf('function ',start+10);
 if(start<0||end<0)throw Error(name);return source.slice(start,end).replace(/var [^;]+;$/,'');}
const cases=[];
for(const name of ['live','missing-reference','cold-scope','unpinned','missing-tab','kind-mismatch',
 'unpin-after-menu','replace-pin-after-menu','replace-scope-after-menu','closed-scope-after-menu',
 'replace-render-panel-after-menu','rename-unavailable','owner-change-after-capture',
 'cwd-change-after-capture','phase-change-after-capture','drag-after-capture',
 'closing-after-capture','instance-change-after-capture']){
 const pin={tabId:'browser',tabKind:'browser'},panel={},tab={tabId:'browser',tabType:{kind:'browser'},renderPanel:panel,dndId:'instance',onRename:()=>{}};
 const state={pin,scope:null,pinned:true,presented:tab,raw:tab,owner:'source',cwd:'/source',phase:'ready',closed:false,drag:false,closing:false};
 const scope={get(key){return({presented:state.presented,raw:state.raw,owner:state.owner,cwd:state.cwd,phase:{phase:state.phase},closed:state.closed})[key]}};
 state.scope=scope;let captured=null,request=null;
 const controller={tabById$:'raw',presentedTabById$:'presented',isCurrentTabInstance:(_,entry)=>state.raw===entry};
 const main={get(key){return key==='pin'?state.pin:key==='scope'?state.scope:key==='pins'?(state.pinned?['pin']:[]):null}};
 const context={Mxe:'pin',iN:'scope',oN:'pins',aM:'closed',rN:'owner',pf:'cwd',hM:'phase',jM:controller,MM:{tabById$:'absent'},
 QJr:{default:(a,b)=>JSON.stringify(a)===JSON.stringify(b)},nBn:()=>state.drag,CBn:()=>state.closing,
 eYr:args=>{captured=args;return[{id:'rename',run:args.onBeginRename}]}};
 vm.createContext(context);vm.runInContext(extract('Rrs')+'\n'+extract('ZJr'),context);
 if(name==='missing-reference')state.pin=null;
 if(name==='cold-scope')state.scope=null;
 if(name==='unpinned')state.pinned=false;
 if(name==='missing-tab'){state.presented=null;state.raw=null}
 if(name==='kind-mismatch')state.presented={...tab,tabType:{kind:'file'}};
 const menu=context.Rrs(main,'pin',value=>request=value);
 if(name==='unpin-after-menu')state.pinned=false;
 if(name==='replace-pin-after-menu')state.pin={...pin};
 if(name==='replace-scope-after-menu')state.scope={get:scope.get};
 if(name==='closed-scope-after-menu')state.closed=true;
 if(name==='replace-render-panel-after-menu')state.presented={...tab,renderPanel:{}};
 if(name==='rename-unavailable')state.presented={...tab,onRename:null};
 menu[0]?.run();
 if(name==='owner-change-after-capture')state.owner='other';
 if(name==='cwd-change-after-capture')state.cwd='/other';
 if(name==='phase-change-after-capture')state.phase='new';
 if(name==='drag-after-capture')state.drag=true;
 if(name==='closing-after-capture')state.closing=true;
 if(name==='instance-change-after-capture')state.raw={...tab};
 cases.push({name,menuAvailable:menu.length>0,captured:request!=null,current:request?.isCurrent()??false});
}
fs.writeFileSync(output,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256,
 boundary:'Actual Rrs source resolution and ZJr identity guards. eYr menu rendering, controller instance lookup, deep equality, drag and closing registry are explicit mocks. No native menu/focus/foreground evidence.',cases},null,2)+'\n');
console.log(`Extracted ${cases.length} pinned source/identity cases`);
