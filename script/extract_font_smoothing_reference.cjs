// Only execute public preference/component/effect code from the installed bundle.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [settingsPath, appPath, sharedPath, cssPath, outputPath] = process.argv.slice(2);
if (!outputPath) throw Error('Expected settings, app, shared, CSS and output paths');
const sources = Object.fromEntries(Object.entries({settings:settingsPath, app:appPath, shared:sharedPath, css:cssPath})
  .map(([key,path]) => [key,fs.readFileSync(path,'utf8')]));
const expected = {settings:'91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535',
  app:'22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3',
  shared:'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab',
  css:'4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720'};
for (const [key,source] of Object.entries(sources)) {
  if (crypto.createHash('sha256').update(source).digest('hex') !== expected[key]) throw Error('Unverified '+key);
}
function read(source,name) {
  const start=source.indexOf('function '+name+'('),end=source.indexOf('function ',start+15);
  if(start<0||end<0)throw Error('Missing function '+name);
  return source.slice(start,end);
}
const jsx=(type,props)=>({type,props}), memo={c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const flatten=tree=>!tree||typeof tree!=='object'?[]:[tree,...[tree.props?.children].flat(Infinity).flatMap(flatten),...flatten(tree.props?.control)];
const controls=[];
for(const platform of ['macOS','windows','linux'])for(const checked of [false,true]) {
  const writes=[],context={Q:memo,z:()=>({}),k:0,P:()=>({formatMessage:m=>m.defaultMessage}),Ee:()=>({platform}),
    R:()=>checked,mc:'smoothing',S:(_,key,value)=>writes.push({key,value}),$: {jsx},M:'message',N:'row',Yt:'toggle',
    J:{fontSmoothing:{id:'fontSmoothing'}}};
  vm.createContext(context);vm.runInContext(read(sources.settings,'lc'),context);
  const tree=context.lc(),toggle=flatten(tree).find(node=>node.type==='toggle');
  if(toggle){toggle.props.onChange(!checked);toggle.props.onChange(checked)}
  controls.push({platform,checked,visible:tree!=null,label:toggle?.props.ariaLabel??null,
    description:tree?.props.description.props.defaultMessage??null,writes});
}
const effects=[];
for(const os of ['darwin','linux'])for(const enabled of [false,true])for(const ready of [false,true]) {
  function node(){const values={'-webkit-font-smoothing':'old-override'};return {values,dataset:{codexOs:os},
    style:{setProperty:(key,value)=>{values[key]=value},removeProperty:key=>{delete values[key]}}}}
  const root=node(),body=node(),Pg={lightChromeTheme:'light',darkChromeTheme:'dark',sansFontSize:{default:14},codeFontSize:'code'};
  const context={QTs:memo,h8:{useState:()=>[false,()=>{}],useLayoutEffect:callback=>callback()},
    g8:{jsx,jsxs:jsx,Fragment:'fragment'},pp:()=>({set:()=>{}}),W:0,bl:()=>ready,kue:()=>1,
    $:key=>key==='zoom'?1:null,_It:'zoom',eK:'effective',Ma:'colored',YL:()=> 'light',JL:()=>null,
    _f:key=>key==='smoothing'?enabled:key==='pointer'?false:key===Pg.sansFontSize?14:key==='code'?12:{},
    Pg,$Ts:'smoothing',eEs:'pointer',v6i:()=>({fonts:{}}),Vm:()=>{},Mp:{subscribe:()=>{},dispatchMessage:()=>{}},
    document:{documentElement:root,body,querySelector:()=>null},aEs:'--zoom',oEs:'-webkit-font-smoothing',tEs:{},
    fu:(target,values)=>{for(const [key,value]of Object.entries(values))value===undefined?target.style.removeProperty(key):target.style.setProperty(key,value)},
    WTs:()=>false,Z6r:0,Y6r:()=>{},kTs:'font',qqe:{Provider:'provider'},LTs:'zoomControl'};
  vm.createContext(context);vm.runInContext(read(sources.app,'GTs'),context);context.GTs({children:null});
  effects.push({os,enabled,ready,root:root.values['-webkit-font-smoothing']??null,body:body.values['-webkit-font-smoothing']??null});
}
const defaultEnabled=/useFontSmoothing:\w+\(\{agentAccess:`read-write`,default:!0,/.test(sources.shared);
const baseAntialiased=/html,:host\{[^}]*-webkit-font-smoothing:antialiased/.test(sources.css);
if(!defaultEnabled||!baseAntialiased)throw Error('Missing default or base CSS');
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:expected,
  defaultEnabled,baseAntialiased,controls,effects},null,2)+'\n');
console.log('Extracted',controls.length,'native setting cases and',effects.length,'runtime effect cases');
