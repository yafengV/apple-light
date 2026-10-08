// Evaluate pinned, publicly shipped VoiceSettings components with inert hooks.
// No account, device, permission, microphone or network operation is performed.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const hash = crypto.createHash('sha256').update(source).digest('hex');
if (hash !== 'dcac6c84dc913e502511a3c408178dad8266acbd53fe463c312c7dcb5757055f') throw Error('Unverified voice reference');
const cache = {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const markers = {};
for (const name of ['q','P','U','xn','un','an','rn','nn','en','Dn','Pn','Fn','kn','mn','yt','wt']) markers[name] = name;
markers.q = Object.assign(function Section() {}, {Header:'SectionHeader',Content:'SectionContent'});
const jsx = (type, props) => type === 'message' ? props.defaultMessage : {type: typeof type === 'function' ? type.name : type, props};
const voices = {voices:[{slug:'test-voice',name:'Test voice'}],effectiveVoiceSlug:'test-voice'};
const context = {...markers, Z:cache,on:cache,$:{jsx,jsxs:jsx,Fragment:'Fragment'},J:{jsx,jsxs:jsx,Fragment:'Fragment'},
  sn:{useState:value=>[value,()=>{}]},M:'message',ge:(key)=>key==='capability'?{isCapable:true}:true,oe:'capability',st:'appshots',
  G:()=>({}),v:'store',ht:()=>true,_t:()=>true,F:()=>({platform:'macOS'}),jt:()=>({hostId:'test-host'}),
  dt:'tools',tt:'voices',Oe:()=> 'voices',K:key=>key==='tools'?{dynamicTools:{appshotsEnabled:true}}:key==='voices'?{data:voices}: {data:{}},
  k:'Button',V:{parse:value=>value},Dt:()=>{},Rt:'hotkeys',Ut:()=>true,ce:()=>true,T:'sounds',et:'EmptyRow',
  H:()=>({formatMessage:props=>props.defaultMessage}),O:'CopyButton',i:'MenuTrigger',He:'DropdownMenu',W:{Item:'MenuItem'},Je:'download',$e:'delete'};
vm.createContext(context);
for (const name of ['bn','tn','En','On','In']) {
  const start = source.indexOf(`function ${name}(`), end=source.indexOf('function ',start+10);
  if(start<0||end<0) throw Error('Missing '+name);
  vm.runInContext(source.slice(start,end),context);
}
// Resolve only the evaluated entry points; other component bodies stay inert.
const page = context.bn(), voice = context.tn(), dictation=context.En({isGlobalDictationEnabled:true}), dictionary=context.On();
const sections=page.props.children[0].props.children;
if(sections[0].props.children[0].props.title!=='General'||sections[1].type!=='tn'||sections[2].type!=='En')throw Error('Unexpected page order');
const generalRows=sections[0].props.children[1].props.children.props.children.map(row=>row.type);
const voiceRows=voice.props.children[1].props.children.props.children.props.children.map(row=>row?.type??null);
if(generalRows.join(',')!=='xn,un'||voiceRows.join(',')!=='P,an,,rn')throw Error('Unexpected voice row order');
const dictationCards= dictation.props.children[1].props.children.map(card=>card.props.children.type);
if(dictationCards.join(',')!=='Dn,Pn,Fn'||dictionary.props.children.props.children.props.children.type!=='kn')throw Error('Unexpected dictation cards');
const recording=context.In({selected:false,actionDisabled:false,isTranscribing:false,
  item:{text:'Fixture transcript',status:'saved',createdAtMs:0,sizeBytes:128},timestamp:'Fixture timestamp'});
if(recording.type!=='P'||recording.props.size!=='compact')throw Error('Unexpected recording row density');
const result={version:'26.930.51102',build:13100,sourceSHA256:hash,
  boundaries:'Actual bn/tn/En/On/In evaluated using inert hooks, eligible macOS fixtures; account access, capability variants and permission callbacks are not executed',
  expected:{pageOrder:['general','voiceChat','dictation','dictionary'],generalRows:['microphone','language'],voiceRows:['voice','hotkey','screenContext'],
    dictationCards:['sounds','shortcuts','recordings'],dictionarySeparateCard:true,recordingRowSize:'compact'},page,voice,dictation,dictionary,recording};
fs.writeFileSync(outputPath,JSON.stringify(result,null,2)+'\n');
console.log('Extracted actual voice page order, shared cards, voice rows and dictation groups');
