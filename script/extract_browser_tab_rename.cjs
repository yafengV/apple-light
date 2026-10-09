// Executes the pinned inline editor, sidebar dialog save and browser state functions.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [input, localization, output] = process.argv.slice(2);
const bytes = fs.readFileSync(input), source = bytes.toString();
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const sourceSHA256 = sha(bytes);
if (sourceSHA256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified source');
const locale = fs.readFileSync(localization), localeSHA256 = sha(locale);
if (localeSHA256 !== 'c6ac10a9fb407a393ea002d9aa818a4c7ed0e215e9c8bf0cfe2b798a98e3756f') throw Error('Unverified localization');
function extracted(name) {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end).replace(/var [^;]+;$/, '');
}
const callback = source.match(/onSave:(e=>\{if\(h\.isCurrent\(\).*?return h\.tab\.onRename\?\.\(e\.length===0\?null:e\)\})/);
if (!callback) throw Error('Missing guarded rename callback');
const cases = [];
const inlineCases = [], inlineKeys = [];
const inlineContext = {}; vm.createContext(inlineContext);
vm.runInContext(extracted('IJr'),inlineContext);
for (const oldTitle of [null,'工作页','  old  ']) {
  for (const input of ['', '  ', ' 工作页\n', '  新名称  ']) {
    const writes = [];
    const props = inlineContext.IJr({renameValue:oldTitle, renamePlaceholder:'Page',
      onFinishRenaming:()=>{},onRename:value=>writes.push(value)}, {formatMessage:()=> '标签页标题'});
    props.onBlur({currentTarget:{value:input,dataset:{}}});
    inlineCases.push({oldTitle,input,writes});
  }
}
for (const key of ['Enter','Escape','Tab']) for (const composing of [false,true]) {
  const writes = []; let finished=0, prevented=false, blurred=false;
  const target={value:' Changed ',dataset:{},blur(){blurred=true;props.onBlur({currentTarget:this})}};
  const props = inlineContext.IJr({renameValue:'Original',onFinishRenaming:()=>finished++,
    onRename:value=>writes.push(value)}, {formatMessage:()=> '标签页标题'});
  props.onKeyDown({key,nativeEvent:{isComposing:composing},currentTarget:target,preventDefault(){prevented=true}});
  inlineKeys.push({key,composing,writes,finished,prevented,blurred,cancelled:target.dataset.cancelRename==='true'});
}
for (const oldTitle of [null, '工作页', '  old  ']) {
  for (const input of ['', '  ', ' 工作页\n', '  新名称  ']) {
    for (const current of [true, false]) {
      const writes = [], h = {isCurrent: () => current, tab: {renameValue:oldTitle, onRename:value=>writes.push(value)}};
      // Cvo computes z=C.trim(), and trimOnSave selects z before invoking this callback.
      const save = vm.runInNewContext(`(${callback[1]})`, {h});
      save(input.trim());
      cases.push({oldTitle,input,current,writes});
    }
  }
}
const discard = [], routes = [];
for (const customTitle of [null, '工作页']) {
  for (const empty of [true, false]) {
    const UH = {getCustomTitle:()=>customTitle, isDisposableEmptyNewTab:()=>empty,
      getSnapshot:()=>({url:empty?'':'https://example.invalid/page'}), getDeviceToolbarTabState:()=>null};
    const context = {UH,NH:()=>null,ah:value=>value.trim()}; vm.createContext(context);
    vm.runInContext(extracted('kCa')+'\n'+extracted('LCa'),context);
    discard.push({customTitle,empty,disposable:context.kCa('conversation','browser')});
    routes.push(context.LCa('conversation','browser','storage',null));
  }
}
const messages = {};
for (const key of ['Title','Subtitle','Placeholder','AriaLabel']) {
  const id = 'sidebar.contentTab.renameDialog'+key;
  const match = locale.toString().match(new RegExp('"'+id+'":`([^`]+)`'));
  if (!match) throw Error('Missing '+id);
  messages[key] = match[1];
}
for (const required of ['initialValue:h.tab.renameValue??``','trimOnSave:!0',
  'onUndoClose:(e,t)=>{UH.setCustomTitle(s,c,y)', 'renamePlaceholder:h,renameValue:m']) {
  if (!source.includes(required)) throw Error('Missing reference behavior: '+required);
}
fs.writeFileSync(output,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256,localeSHA256,
  boundary:'Actual IJr inline editor callbacks; Lis pinned-sidebar guarded dialog save; kCa discard and LCa route with mocked host/address helper. Sidebar modal is distinct from tab-strip inline editing. No foreground, geometry or complete browser-menu evidence.',
  messages,inlineCases,inlineKeys,cases,discard,routes},null,2)+'\n');
console.log(`Extracted ${cases.length} rename saves, ${discard.length} discard/route cases`);
