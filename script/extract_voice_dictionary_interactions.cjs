// Execute the public, pinned dictionary component's actual event callbacks.
// Hooks, storage and animation frames are local deterministic fixtures. This
// proves callback semantics, not browser focus scheduling or native UI parity.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const hash = crypto.createHash('sha256').update(source).digest('hex');
if (hash !== 'dcac6c84dc913e502511a3c408178dad8266acbd53fe463c312c7dcb5757055f') throw Error('Unverified voice reference');
function fixture(initial) {
  let saved = initial, slots = [], cursor = 0, frames = [], writes = [], focused = null;
  const jsx = (type, props) => type === 'Message' ? props.defaultMessage : {type, props};
  const context = {Z:{c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))},
    Q:{useState:value=>{const index=cursor++; if(!(index in slots)) slots[index]=value;
      return [slots[index],value=>{slots[index]=value}]},
      useRef:value=>{const index=cursor++; return slots[index]??(slots[index]={current:value})}},
    $:{jsx,jsxs:jsx,Fragment:'Fragment'},G:()=>({}),v:'store',me:{dictationDictionary:'dictionary'},
    H:()=>({formatMessage:(props,values)=>props.defaultMessage.replace('{index}',values.index)}),
    Ne:()=>saved,p:async(_store,_key,value)=>{saved=value; writes.push(value)},
    M:'Message',Be:'Icon',St:'Plus',Qe:'Plus16',P:'Row',k:'Button',At:'Input',Kt:'Minus',
    Ln:'',Rn:[''],zn:['Jane Doe','Acme Widget','checkout-form.tsx','useCartState'],
    requestAnimationFrame:callback=>frames.push(callback),
    document:{querySelector:selector=>({focus:()=>{focused=Number(selector.match(/="(\d+)"/)[1])}})}};
  vm.createContext(context);
  for(const name of ['kn','An','jn','Mn','Nn']) {
    const start=source.indexOf(`function ${name}(`),end=source.indexOf('function ',start+10);
    if(start<0||end<0) throw Error('Missing '+name);
    vm.runInContext(source.slice(start,end),context);
  }
  function render() {
    cursor=0;
    const children=context.kn().props.children;
    return {add:children[0].props.control.props,
      rows:children[1].map(row=>({input:row.props.control.props.children[0].props,
        remove:row.props.control.props.children[1].props}))};
  }
  return {render,normalize:value=>context.Nn(value),flushFrames:()=>{frames.splice(0).forEach(callback=>callback())},
    snapshot:()=>({saved:JSON.parse(JSON.stringify(saved)),writes:JSON.parse(JSON.stringify(writes)),focused})};
}
const event=()=>({prevented:false,preventDefault(){this.prevented=true}});
(async()=>{
  const f=fixture(['First','Last']);let tree=f.render();
  tree.rows[0].input.onChange({currentTarget:{value:'  中文草稿  '}});tree=f.render();
  const enter=event();enter.key='Enter';tree.rows[0].input.onKeyDown(enter);tree=f.render();
  tree.rows[0].input.onBlur();await new Promise(setImmediate);f.flushFrames();tree=f.render();
  const afterEnter={...f.snapshot(),values:tree.rows.map(row=>row.input.value),prevented:enter.prevented};
  tree.rows[1].input.onBlur();await new Promise(setImmediate);tree=f.render();
  const afterRealBlur={...f.snapshot(),values:tree.rows.map(row=>row.input.value)};
  const a=fixture(['One']);let added=a.render();const addDown=event();added.add.onMouseDown(addDown);
  added.add.onClick();a.flushFrames();added=a.render();
  const afterAdd={...a.snapshot(),values:added.rows.map(row=>row.input.value),prevented:addDown.prevented};
  const d=fixture(['First','Middle','Last']);let deleted=d.render();
  deleted.rows[0].input.onChange({currentTarget:{value:'  First edited  '}});deleted=d.render();
  const removeDown=event();deleted.rows[1].remove.onMouseDown(removeDown);
  deleted.rows[1].remove.onClick();await new Promise(setImmediate);deleted=d.render();
  const afterRemove={...d.snapshot(),values:deleted.rows.map(row=>row.input.value),prevented:removeDown.prevented};
  const empty=fixture([]).render();
  const duplicates=fixture([' A ','','A']);let dup=duplicates.render();dup.rows[0].input.onBlur();await new Promise(setImmediate);
  const result={version:'26.930.51102',build:13100,sourceSHA256:hash,
    boundaries:'Actual kn/An/jn/Mn/Nn callbacks; local hooks/storage/RAF, no browser focus or account operation',
    afterEnter,afterRealBlur,afterAdd,afterRemove,duplicates:duplicates.snapshot(),
    normalization:["\ufeff Word \ufeff", "\u0085Word\u0085", "\u180eWord\u180e", "\u200bWord\u200b", "\u2028Word\u2029", "\u3000中文\u00a0", "   ", "A  B"].map(input=>({input,output:f.normalize(input)})),
    empty:{values:empty.rows.map(row=>row.input.value),disabled:empty.rows[0].remove.disabled,
      label:empty.rows[0].input['aria-label'],placeholder:empty.rows[0].input.placeholder}};
  if(afterEnter.writes.length||!afterEnter.prevented||afterEnter.focused!==1||afterEnter.values.join('|')!=='  中文草稿  ||Last')throw Error('Unexpected Enter');
  if(afterRealBlur.saved.join('|')!=='中文草稿|Last'||afterRealBlur.values.length!==2)throw Error('Unexpected blur');
  if(!afterAdd.prevented||afterAdd.focused!==1||afterAdd.writes.length)throw Error('Unexpected add');
  if(!afterRemove.prevented||afterRemove.saved.join('|')!=='First edited|Last')throw Error('Unexpected remove');
  if(!empty.rows[0].remove.disabled||duplicates.snapshot().saved.join('|')!=='A|A')throw Error('Unexpected normalization');
  fs.writeFileSync(outputPath,JSON.stringify(result,null,2)+'\n');
  console.log('Extracted actual dictionary draft, Enter, blur, add/remove, fallback and normalization callbacks');
})().catch(error=>{console.error(error);process.exitCode=1});
