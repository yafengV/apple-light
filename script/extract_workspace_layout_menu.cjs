// Extract inert component/event traces from the pinned reference, never load its application.
const fs=require('fs'),vm=require('vm'),crypto=require('crypto');
const [path,out]=process.argv.slice(2),source=fs.readFileSync(path,'utf8');
const sha=crypto.createHash('sha256').update(source).digest('hex');
if(sha!=='db5f01832c7d9c730407f6f4e4cdd699dd584393c206439fe12890d265dd3c4b')throw Error('Unverified reference');
function code(name){const a=source.indexOf(`function ${name}(`),b=source.indexOf('function ',a+10);if(a<0||b<0)throw Error(name);return source.slice(a,b).replace(/var [^;]+;$/,'');}
const jsx=(type,props)=>({type,props}),cache={c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const policies=[];
for(const home of [false,true])for(const count of [0,1,3])for(const display of ['chat','split','full']){
 const context={tu:cache,nu:{jsx},Ht:()=>({value:{routeKind:home?'home':'thread'}}),_:0,
  Me:()=>({formatMessage:()=>''}),K:key=>({ps:'toggle',cr:true,ru:count,gi:display,ms:false})[key],ut:()=>'',
  zl:'newTab',Wl:'retained',ie:'icon',Ro:'count',ce:'button',rt:'tooltip',wo:'dropdown',ti:0,Ce:0,
  ps:'ps',cr:'cr',ru:'ru',gi:'gi',ms:'ms'};
 vm.createContext(context);vm.runInContext(code('eu'),context);let tree=context.eu({});
 policies.push({home,count,display,kind:['newTab','retained'].includes(tree.type)?tree.type:'toggle'});
}
function handlers(name){
 let open=false,refIndex=0,stateIndex=0;const refs=[],events=[],tabs=name==='Wl'?[{tabId:'one',title:'One'}]:[];
 const hooks={useState:()=>stateIndex++===0?[open,v=>{open=v;events.push({event:'open',value:v});}]:[false,()=>{}],useRef:v=>refs[refIndex++]??(refs[refIndex-1]={current:v})};
 const scope={get:key=>key==='tabs'?tabs:key==='cr'?true:key==='active'?tabs[0]:key==='byID'?tabs[0]:'right'};
 const context={Jl:cache,Bl:cache,Xl:{jsx,jsxs:jsx},Hl:{jsx,jsxs:jsx},
  Yl:hooks,Vl:hooks,
  Ht:()=>scope,_:0,Me:()=>({formatMessage:()=>''}),K:key=>key==='tabs'?tabs:key==='cr'?true:'toggle',ut:()=>'',
  ps:'ps',cr:'cr',J:{tabs$:'tabs',activeTab$:'active',tabById$:'byID'},La:'La',Jr:'Jr',i:0,ti:0,
  pt:'trigger',ce:'button',Ro:'count',on:'content',B:'label',fn:'popover',Gl:'row',rn:'plus',ie:'icon',Pt:0,
  gt:{Item:'item'},Yt:'dropdownContent',wo:'dropdown',Node:class{},
  document:{activeElement:null},window:{setTimeout:(f,ms)=>{events.push({event:'timer',ms});return 1;},clearTimeout:()=>{}},
  wt:()=>()=>{},Wi:(_scope,_reason,f)=>f(),_o:()=>events.push({event:'toggle'}),Da:()=>{},
  ma:(_scope,mode)=>events.push({event:'create',mode})};
 vm.createContext(context);vm.runInContext(code(name),context);
 function render(){refIndex=0;stateIndex=0;return context[name]({});}
 function find(tree,key){if(tree?.props?.[key])return tree.props;if(!tree?.props)return null;
   for(const child of [tree.props.children,tree.props.triggerButton].flat(Infinity)){const found=find(child,key);if(found)return found;}return null;}
 let tree=render();find(tree,'onPointerEnter').onPointerEnter({pointerType:'touch'});
 const afterTouch=open;find(tree,'onPointerEnter').onPointerEnter({pointerType:'mouse'});const afterMouse=open;
 tree=render();const focusEvents=[];
 refs[0].current={};
 refs[1].current={querySelectorAll:()=>[{focus:()=>focusEvents.push('first')},{focus:()=>focusEvents.push('last')}],contains:()=>false,getBoundingClientRect:()=>({top:20,bottom:40})};
 refs[0].current.getBoundingClientRect=()=>({top:0,bottom:10});
 find(tree,'onPointerEnter').onPointerLeave({pointerType:'mouse',currentTarget:refs[0].current,relatedTarget:null,clientX:0,clientY:10});
 find(tree,'onPointerEnter').onKeyDown({key:'ArrowUp',preventDefault:()=>{}});
 const keyboardFocus=focusEvents[0];
 const trigger=find(tree,'onPointerEnter');
 if(name==='zl')trigger.onPointerDown({pointerType:'mouse',preventDefault:()=>{}});
 trigger.onClick({currentTarget:refs[0].current,preventDefault:()=>{}});
 return {afterTouch,afterMouse,keyboardFocus,events};
}
const retained=handlers('Wl'),empty=handlers('zl');
// The shared leave closures contain this exact grace interval in both pinned components.
for(const name of ['Wl','zl'])if(!code(name).includes('window.setTimeout(e,100)')&&!code(name).includes('window.setTimeout(t,100)'))throw Error('Missing hover grace');
fs.writeFileSync(out,JSON.stringify({version:'26.930.51102',build:13100,chromeSHA256:sha,
 boundary:'Actual eu route/display policy and Wl/zl mouse versus touch and keyboard-edge handlers; explicit JSX/hooks, inert native effects. Not DOM rendering, OS focus acceptance, primary workspace or backend proof.',policies,retained,empty},null,2)+'\n');
console.log('Extracted '+policies.length+' policy states and both actual hover/keyboard handlers');
