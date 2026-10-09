// Pinned public browser menu execution. Native capabilities/focus are not mocked as passed.
const fs=require('fs'),vm=require('vm'),crypto=require('crypto');
const args=process.argv.slice(2);
if(args.length!==3)throw Error('Usage: initial.js shared.js output.json');
const [initialPath,sharedPath,output]=args,path=require('path');
const resolvedOutput=fs.existsSync(output)?fs.realpathSync(output):path.resolve(output);
if([initialPath,sharedPath].map(p=>fs.realpathSync(p)).includes(resolvedOutput))throw Error('Output must differ from reference inputs');
const hashes=['22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3','eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab'];
const [source,shared]=[initialPath,sharedPath].map((p,i)=>{const text=fs.readFileSync(p,'utf8');if(crypto.createHash('sha256').update(text).digest('hex')!==hashes[i])throw Error('Unverified resource');return text;});
function fn(name){let start=source.indexOf('function '+name+'('),end=source.indexOf('function ',start+10);if(start<0||end<0)throw Error(name);return source.slice(start,end).replace(/var [^;]+;$/,'');}
const externalPattern=shared.match(/mxr=(\/\^\(\?:[^;]+?\/i)/)[1];
const samples=[
 {name:'no-snapshot',snapshot:null},
 {name:'invalid-web',snapshot:{tabType:'WEB',url:'not-a-url'}},
 {name:'blank-web',snapshot:{tabType:'WEB',url:'about:blank',isSuspended:false,isAudioMuted:false}},
 {name:'loaded-web',snapshot:{tabType:'WEB',url:'https://source.example/page',isSuspended:false,isAudioMuted:false}},
 {name:'default-browser',snapshot:{tabType:'WEB',url:'https://source.example/page',isSuspended:false},defaultBrowser:true},
 {name:'suspended-web',snapshot:{tabType:'WEB',url:'https://source.example/page',isSuspended:true}},
 {name:'muted-web',snapshot:{tabType:'WEB',url:'https://source.example/page',isAudioMuted:true}},
 {name:'media-tab',snapshot:{tabType:'MEDIA',url:'https://source.example/media'}},
 {name:'forkable-web',snapshot:{tabType:'WEB',url:'https://source.example/page'},fork:true}
];
const cases=[];
for(const sample of samples){
 const state={snapshot:sample.snapshot,current:true,phase:'ready',tab:null};const calls=[];
 const controller={presentedTabById$:'presented',tabById$:'raw',tabs$:'tabs',panelId:'right',isCurrentTabInstance:(_,tab)=>state.tab===tab,closeTab:(_,id)=>calls.push({kind:'close',id})};
 const get=key=>({presented:state.tab,raw:state.tab,tabs:[state.tab],owner:'a',cwd:'/a',phase:{phase:state.phase},closed:false,fork:!!sample.fork,root:'/a',permanent:true,
 forkMessages:{intoLocal:{defaultMessage:'Fork local'},intoSameWorktree:{},intoWorktree:{defaultMessage:'Fork worktree'},actions:{defaultMessage:'Fork'}},toasts:{success:()=>{},danger:()=>{}}})[key];
 const scope={get,value:{kind:'local'}};
 const context={UH:{getSnapshot:()=>state.snapshot,getPagePersistence:()=>null},Yp:{WEB:'WEB'},URL,crypto:{randomUUID:()=> 'child-uuid'},Cpe:x=>x,
 hi:x=>x,Af:()=>sample.fork?'a':null,yya:'fork',RO:'root',Uhn:'missing',DLn:'permanent',dCa:'forkMessages',Yu:()=>false,
 HGe:{},yRe:{},Gm:()=>({}),Axa:{},I:()=>{},wOe:{},fCa:()=>Promise.resolve(null),pCa:()=>Promise.resolve(null),ec:x=>x,
 im:()=>!!sample.defaultBrowser,JGe:vm.runInNewContext(externalPattern),_l:'toasts',En:'intl',q:'message',awa:{jsx:(t,p)=>({t,p})},$Re:{urlCopied:{}},On:()=>{},
 ve:{clipboard:{writeText:value=>{calls.push({kind:'copy',value});return Promise.resolve();}}},
 Mp:{dispatchMessage:(type,args)=>calls.push({kind:args.command.type,type,args}),dispatchHostMessage:()=>{}},
 QCa:x=>x,Tg:()=> 'a',c4r:()=>{},y4r:()=>{},ZJ:{open:(_,args)=>{calls.push({kind:'new',args});return true;}},dO:args=>calls.push({kind:'external',args}),
 Uva:({isAudioMuted})=>({id:isAudioMuted?'unmute-browser-tab':'mute-browser-tab',message:{defaultMessage:'Audio'},onSelect:()=>{}}),
 zO:'host',rN:'owner',pf:'cwd',hM:'phase',dM:'closePolicy',aS:'workspace',QJr:{default:(a,b)=>JSON.stringify(a)===JSON.stringify(b)},nBn:()=>false,CBn:()=>false,
 OM:()=>true};
 for(const icon of ['fm','VPe','Um','KZe','DNe','eIe','gr','l','ANe','Wd'])context[icon]=icon;
 const page={tabId:'browser',dndId:'instance',renderPanel:{},isLabel:false,props:{browserConversationId:'a',browserTabId:'browser',cwd:'/a'},tabType:{kind:'browser',getContextMenuItems:(e,p,args)=>context.ewa(e,p,args)}};
 state.tab=page;vm.createContext(context);context.JGe=x=>context.JGePattern.test(x);context.JGePattern=vm.runInNewContext(externalPattern);
 for(const name of ['XJ','nwa','twa','rwa','ewa','ZJr','tYr','eYr'])vm.runInContext(fn(name),context);
 const items=context.eYr({scope,controller,tab:page,placement:'sidebar-pin',isSourceCurrent:()=>state.current,onBeginRename:()=>calls.push({kind:'rename'})});
 const flatten=items=>items.map(x=>({id:x.id,type:x.type??'action',title:x.message?.defaultMessage,submenu:x.submenu?flatten(x.submenu):undefined}));
 // Execute duplicate's actual fallback route; no browser host or network is present.
 items.find(x=>x.id==='duplicate-browser-tab')?.onSelect();const duplicate=calls.splice(0);
 state.current=false;for(const item of items)item.onSelect?.();
 cases.push({...sample,items:flatten(items),duplicate,staleCallbacks:calls.splice(0)});
}
fs.writeFileSync(output,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,
 boundary:'Actual ewa/eYr/tYr/ZJr and duplicate fallback twa/rwa/XJ (including default revealAndFocus). Scope selectors, closeability, browser snapshots, fork availability, audio item provider, icon/intl/JSX, page initialization, ZJ.open controller and host effects are explicit mocks. No native audio, full-history clone, fork runtime, menu/focus or network acceptance.',cases},null,2)+'\n');
console.log('Extracted',cases.length,'actual sidebar browser menus, fallback insertion and stale action guards');
