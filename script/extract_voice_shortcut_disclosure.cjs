// Execute Pn from the pinned public voice settings asset. This fixture supplies
// local hooks and a fake mutation service; it does not emulate DOM focus/Qt.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const hash = crypto.createHash('sha256').update(source).digest('hex');
if (hash !== 'dcac6c84dc913e502511a3c408178dad8266acbd53fe463c312c7dcb5757055f') throw Error('Unverified voice reference');
function fixture(mode, state) {
  const slots = []; let cursor = 0, writes = [], invalidated = [];
  const jsx = (type, props) => type === 'Message' ? props.defaultMessage : {type, props};
  const context = {Z:{c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
    Q:{useState:value=>{const index=cursor++; if(!(index in slots)) slots[index]=value;
      return [slots[index],value=>{slots[index]=value}]}, useId:()=> 'optional-shortcut'},
    $:{jsx,jsxs:jsx}, H:()=>({formatMessage:props=>props.defaultMessage}),
    ve:()=>({setQueryData:()=>{}}), Pe:()=>key=>invalidated.push(key), c:key=>key,
    I:(name,options)=>({isPending:false,mutateAsync:async({hotkey})=>{
      writes.push({name,hotkey}); const result={success:true,state}; options.onSuccess(result); return result;
    }}), j:value=>value, Hn:{holdToDictateHotkey:{defaultMessage:'Dictation shortcut'},
      toggleDictationHotkey:{defaultMessage:'Single-tap shortcut'}},
    Bt:'dictation-shortcut', M:'Message', k:'Button', je:'Up', Se:'Down',
    P:'Row', Ft:'Capture', Qt:'Disclosure'};
  vm.createContext(context);
  const start=source.indexOf('function Pn('),end=source.indexOf('function Fn(',start);
  if(start<0||end<0) throw Error('Missing Pn');
  vm.runInContext(source.slice(start,end),context);
  const render=()=>{cursor=0;return context.Pn({mode,hotkeyState:state})};
  return {render,writes,invalidated};
}
(async()=>{
  const hold=fixture('hold',{configuredHotkey:'Control',configuredToggleHotkey:'Alt+Shift'});
  let tree=hold.render();
  const summarize=tree=>({expanded:tree.props.expanded,contentID:tree.props.contentId,
    toggleMode:tree.props.content.props.mode,holdLabel:tree.props.children.props.label,
    description:tree.props.children.props.description.props.children[0],
    advanced:tree.props.children.props.description.props.children[1].props.children.props.children[0],
    ariaExpanded:tree.props.children.props.description.props.children[1].props.children.props['aria-expanded'],
    capture:tree.props.children.props.control.props.accelerator});
  const collapsed=summarize(tree);
  tree.props.children.props.description.props.children[1].props.children.props.onClick();
  tree=hold.render(); const expanded=summarize(tree);
  tree.props.children.props.description.props.children[1].props.children.props.onClick();
  const recollapsed=summarize(hold.render());
  const toggle=fixture('toggle',{configuredHotkey:'Control',configuredToggleHotkey:'Alt+Shift'});
  let row=toggle.render(); const singleTap={label:row.props.label,
    description:row.props.description.props.children[0],
    advanced:row.props.description.props.children[1],capture:row.props.control.props.accelerator};
  row.props.control.props.onStartCapture(); row=toggle.render();
  const capturing=row.props.control.props.isCapturing;
  row.props.control.props.onCancelCapture(); row=toggle.render();
  const cancelled=row.props.control.props.isCapturing;
  row.props.control.props.onCapture('Control+Alt+Shift+K'); await new Promise(setImmediate);
  row=toggle.render(); row.props.control.props.onClear(); await new Promise(setImmediate);
  const result={version:'26.930.51102',build:13100,sourceSHA256:hash,
    boundaries:'Actual Pn callbacks with local hooks/mutation; Qt content lifetime, DOM focus and native registration are not executed',
    collapsed,expanded,recollapsed,singleTap,capturing,cancelled,writes:toggle.writes};
  if(collapsed.expanded||collapsed.ariaExpanded||!expanded.expanded||!expanded.ariaExpanded||recollapsed.expanded) throw Error('Disclosure trace mismatch');
  if(!capturing||cancelled||singleTap.advanced!==null||toggle.writes.length!==2) throw Error('Capture trace mismatch');
  fs.writeFileSync(outputPath,JSON.stringify(result,null,2)+'\n');
  console.log('Extracted actual default-collapse, disclosure toggles, single-tap capture/cancel/save/clear callbacks');
})().catch(error=>{console.error(error);process.exitCode=1});
