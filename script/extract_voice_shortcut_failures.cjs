// Actual Pn/an callback ordering, with manually resolved local RPC promises.
// No DOM focus, global hotkeys, user configuration or network access is used.
const fs = require('fs');
const vm = require('vm'), crypto = require('crypto');
const {fixture,hash} = require('./extract_voice_shortcut_disclosure.cjs');
const outputPath=process.argv[3];
const primary=fs.readFileSync(process.argv[4],'utf8');
const primaryHash=crypto.createHash('sha256').update(primary).digest('hex');
if(primaryHash!=='234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0')throw Error('Unverified shortcut capture reference');
const state={configuredHotkey:'Control',configuredToggleHotkey:'Alt+Shift',configuredVoiceHotkey:'Control+Alt+V'};
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject}};
const row=(tree,mode)=>mode==='hold'?tree.props.children:tree;
function snapshot(f,mode) {
  const r=row(f.render(),mode), control=r.props.control.props;
  const error=r.props.description.props.children.find(value=>value?.type==='span'&&value.props.className==='text-danger');
  return {capturing:control.isCapturing,disabled:control.disabled,accelerator:control.accelerator,error:error?.props.children??null};
}
async function failure(name,mode,settle,component='Pn') {
  const request=deferred(),f=fixture(mode,state,{component,mutate:()=>request.promise});
  row(f.render(),mode).props.control.props.onStartCapture();
  const before=snapshot(f,mode);
  row(f.render(),mode).props.control.props.onCapture('Control+Alt+Shift+K');
  const pending=snapshot(f,mode);
  settle(request);await new Promise(setImmediate);
  const settled=snapshot(f,mode);
  row(f.render(),mode).props.control.props.onStartCapture();
  const restarted=snapshot(f,mode);
  row(f.render(),mode).props.control.props.onCancelCapture();
  const cancelled=snapshot(f,mode);
  if(!before.capturing||pending.capturing||!pending.disabled||pending.error!==null||settled.disabled||!settled.error||!restarted.capturing||restarted.error!==null||cancelled.capturing) throw Error('Unexpected failure ordering: '+name);
  return {name,mode,before,pending,settled,restarted,cancelled,writes:f.writes};
}
function captureEvents() {
  const slots=[];let cursor=0,captured=[],cancelled=0,decoded=0;
  const jsx=(type,props)=>type==='Message'?props.defaultMessage:{type,props};
  const context={dBe:{c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
    kP:{useId:()=> 'capture',useRef:value=>{const i=cursor++;return slots[i]??(slots[i]={current:value})},
      useState:value=>{const i=cursor++;if(!(i in slots))slots[i]=value;return[slots[i],value=>{slots[i]=value}]},useEffect:()=>{}},
    AP:{jsx,jsxs:jsx},Cc:()=>({formatMessage:props=>props.defaultMessage}),Eo:()=>({platform:'macOS'}),
    Lr:(...values)=>values.filter(Boolean).join(' '),IMe:'Input',sBe:'NativeCapture',za:'Button',J:'Message',
    eBe:event=>['Control','Alt','Meta','Shift'].includes(event.key)?event.key:null,
    $ze:event=>{decoded++;return event.accelerator??null},clearTimeout:()=>{}};
  vm.createContext(context);
  for(const name of ['lBe','uBe']) {
    const i=primary.indexOf('function '+name+'('),j=primary.indexOf('function ',i+10);
    if(i<0||j<0)throw Error('Missing '+name);vm.runInContext(primary.slice(i,j),context);
  }
  const render=()=>{cursor=0;const tree=context.lBe({isCapturing:true,allowsBareModifiers:true,
    captureAriaLabel:'Dictation shortcut capture',onCapture:value=>captured.push(value),onCancelCapture:()=>{cancelled++}});
    const line=tree.props.children[0].props.children;
    return {input:line[0].props.children.props.children(false).props,cancel:line[1].props};};
  const event=(key,extra={})=>({key,repeat:false,ctrlKey:false,altKey:false,metaKey:false,shiftKey:false,
    prevented:false,stopped:false,preventDefault(){this.prevented=true},stopPropagation(){this.stopped=true},
    nativeEvent:{key,accelerator:'Control+K'},...extra});
  let tree=render();const repeated=event('k',{repeat:true,ctrlKey:true});tree.input.onKeyDown(repeated);
  const repeat={captured:[...captured],cancelled,decoded,prevented:repeated.prevented,stopped:repeated.stopped};
  const ordinary=event('k',{ctrlKey:true});tree.input.onKeyDown(ordinary);
  const key={captured:[...captured],decoded,prevented:ordinary.prevented,stopped:ordinary.stopped};
  const modifierDown=event('Control',{ctrlKey:true});tree.input.onKeyDown(modifierDown);
  const modifierUp=event('Control');tree.input.onKeyUp(modifierUp);
  const bare={captured:[...captured],decoded};
  tree.input.onKeyDown(event('Escape'));const escape=cancelled;
  tree.input.onBlur();const blur=cancelled;
  const mouse=event('');tree.cancel.onMouseDown(mouse);tree.cancel.onClick();
  if(repeat.captured.length||repeat.decoded||repeat.cancelled||!key.prevented||!key.stopped||bare.captured.at(-1)!=='Control'||escape!==1||blur!==2||cancelled!==3||!mouse.prevented)throw Error('Capture event trace mismatch');
  return {repeat,key,bare,escape,blur,cancelButton:{label:tree.cancel.children,preventedOnMouseDown:mouse.prevented,cancelled}};
}
(async()=>{
  const cases=[];
  cases.push(await failure('toggle-conflict','toggle',r=>r.resolve({success:false,errorCode:'shortcut-conflict',state})));
  cases.push(await failure('hold-registration-error','hold',r=>r.resolve({success:false,errorCode:'unavailable',error:'Local registration failed',state})));
  cases.push(await failure('toggle-transport-error','toggle',r=>r.reject(new Error('Transport unavailable'))));
  cases.push(await failure('hold-unknown-error','hold',r=>r.reject(7)));
  cases.push(await failure('voice-chat-error','voiceChat',r=>r.reject(new Error('Voice hotkey unavailable')),'an'));
  cases.push(await failure('voice-chat-unknown-error','voiceChat',r=>r.reject(7),'an'));
  const a=deferred(),b=deferred();
  const hold=fixture('hold',state,{mutate:()=>a.promise});
  const toggle=fixture('toggle',state,{mutate:()=>b.promise});
  row(hold.render(),'hold').props.control.props.onCapture('Control+Alt+K');
  a.resolve({success:false,errorCode:'unavailable',error:'Hold error',state});await new Promise(setImmediate);
  row(toggle.render(),'toggle').props.control.props.onStartCapture();
  const isolation={hold:snapshot(hold,'hold'),toggle:snapshot(toggle,'toggle')};
  if(isolation.hold.error!=='Hold error'||isolation.toggle.error!==null)throw Error('Error scope mismatch');
  // Clear invokes the same asynchronous save callback and removes the prior error.
  const c=deferred(),clear=fixture('toggle',state,{mutate:()=>c.promise});
  row(clear.render(),'toggle').props.control.props.onClear();const clearPending=snapshot(clear,'toggle');
  c.resolve({success:false,errorCode:'unavailable',error:'Could not clear shortcut',state});await new Promise(setImmediate);
  const clearFailure={pending:clearPending,settled:snapshot(clear,'toggle'),writes:clear.writes};
  if(clearFailure.writes[0].hotkey!==null||!clearPending.disabled||clearFailure.settled.error!=='Could not clear shortcut')throw Error('Clear failure mismatch');
  const result={version:'26.930.51102',build:13100,sourceSHA256:hash,primarySHA256:primaryHash,
    boundaries:'Actual Pn/an/lBe/uBe callbacks; local hooks/deferred RPC and shortcut decoder fixture, no DOM focus, OS registration or real persistence',
    cases,isolation,clearFailure,captureEvents:captureEvents()};
  fs.writeFileSync(outputPath,JSON.stringify(result,null,2)+'\n');
  console.log('Extracted six actual deferred failure traces, independent error scopes and clear failure');
})().catch(error=>{console.error(error);process.exitCode=1});
