// Evaluate only selected public JSX and reset functions in a mocked VM; never start the reference application.
const fs=require('fs'),vm=require('vm'),crypto=require('crypto');
const [settingsPath, appPath, fixturePath] = process.argv.slice(2);
if (!settingsPath || !appPath || !fixturePath) throw Error('Expected settings asset, app asset and output fixture');
const settingsSource = fs.readFileSync(settingsPath, 'utf8'), appSource = fs.readFileSync(appPath, 'utf8');
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
if (digest(settingsSource) !== '91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535'
  || digest(appSource) !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified reference version');
const read = filename => {
  const name = filename.split('-')[0], source = ['kRs', 'BRs'].includes(name) ? appSource : settingsSource;
  const start = source.indexOf('function ' + name + '('), end = source.indexOf('function ', start + 15);
  if (start < 0 || end < 0) throw Error('Missing reference function ' + name);
  return source.slice(start, end);
};
const jsx=(type,props,key)=>({type,props,key});
const memo={c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const runtime={jsx,jsxs:jsx,Fragment:'Fragment'};
const flatten=tree=>!tree||typeof tree!=='object'?[]:[tree,...[tree.props?.children].flat(Infinity).flatMap(flatten),...flatten(tree.props?.control)];
function runPage(advanced,separate){let state=0;const c={Q:memo,$:runtime,pc:{useId:()=> 'advanced-panel',useState:()=>[state++?separate:advanced,()=>{}]},B:()=>true,Ge:0,H:{Header:'Header',Content:'Content'}};

for(const n of ['M','qe','N','Ys','Ia','No','me','Rt','kt','sc','Wi','cc','nc','Yt','Gi','tc','Xs','Zs','lc'])c[n]=n;
vm.createContext(c);vm.runInContext(read('Ms-646.js'),c);return c.Ms({defaultAdvancedExpanded:advanced});}
function runVariants(mode,systemDark,separate,section){const c={Xa:memo,X:runtime,Gr:()=>mode,Mr:m=>m==='system'?(systemDark?'dark':'light'):m,s:()=>({data:{isSystemBackdropSupported:true}}),La:'La'};vm.createContext(c);vm.runInContext(read('Ia-645.js'),c);return flatten(c.Ia({section,separateModes:separate})).filter(n=>n.type==='La').map(n=>n.props);}
function runPalette(section,variant,showVariantTitle){const model={fonts:{},theme:{contrast:45},codeThemes:[],exportThemeString:()=>'',canImportThemeString:()=>true};
const c={Xa:memo,X:runtime,z:()=>({}),k:0,P:()=>({formatMessage:(m,v)=>m.id??m}),J:new Proxy({},{get:(_,k)=>({id:k})}),Nr:()=>model,Ya:(_,v)=>v,Ja:v=>v,Za:{useState:v=>[v,()=>{}]}};
for(const n of ['M','za','Ba','ut','me','Vt','Bt','Va','N','Sa','fa','ja','Yt','qa'])c[n]=n;
vm.createContext(c);vm.runInContext(read('La-645.js'),c);const tree=c.La({section,variant,showVariantTitle,showTranslucentSidebarToggle:true});
return flatten(tree).filter(n=>n.type==='ja').map(n=>({controls:n.props.controls,ariaLabel:n.props.ariaLabel}));}
const cases=[];for(const mode of ['system','light','dark'])for(const systemDark of [false,true])for(const separate of [false,true])for(const advanced of [false,true]){
const page=runPage(advanced,separate), nodes=flatten(page);
const variants=runVariants(mode,systemDark,separate,'visual');
cases.push({mode,systemDark,separate,advanced,variants:variants.map(v=>v.variant),advancedMounted:nodes.some(n=>n.type==='sc'),previewMounted:nodes.some(n=>n.type==='AppearanceCodePreview'),visualFonts:runPalette('visual',variants[0].variant,variants.length>1),advancedFonts:runPalette('advanced',variants[0].variant,variants.length>1)});}
const source=read('kRs-646.js'),start=source.indexOf('ne=async function()'),end=source.indexOf('},t[64]',start)+1;
if(start<0||end<start)throw Error('reset extraction');
const reset=source.slice(start+3,end), resets=[];
for(const variant of ['light','dark'])for(const supported of [false,true]){
const initial={accent:'#123456',accentSource:'custom',surface:'#223344',ink:'#CCDDEE',contrast:70,opaqueWindows:true,fonts:{ui:'Menlo',uiFace:{family:'Menlo'},content:'Georgia',contentFace:{family:'Georgia'},code:'Monaco',codeFace:{family:'Monaco'}},semanticColors:{skill:'#987654'}};
let result;const c={te:true,e:variant,U:{contrast:variant==='dark'?60:45,opaqueWindows:false},U8:0,HJe:1,n:{get:key=>key===0?{editRevision:0,getSnapshot:()=>({theme:initial})}:{data:{isSystemBackdropSupported:supported}}},D:async value=>{result=value}};
vm.createContext(c);vm.runInContext(read('BRs-646.js'),c);
resets.push((async()=>{await vm.runInContext('('+reset+')()',c);return{variant,supported,initial,result};})());}
Promise.all(resets).then(resets=>{const output={version:'26.930.51102',build:13100,sourceSHA256:{settings:digest(settingsSource),app:digest(appSource)},cases,resets};fs.writeFileSync(fixturePath,JSON.stringify(output,null,2)+'\n');});
