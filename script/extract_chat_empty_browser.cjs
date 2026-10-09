// Execute the pinned full-view chat selection branch; its discard callback is
// composed from the actual predicate/close results extracted in phase 714.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [input, discardFixture, output] = process.argv.slice(2);
const source = fs.readFileSync(input, 'utf8');
const sourceSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (sourceSHA256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') throw Error('Unverified source');
const discardBytes = fs.readFileSync(discardFixture), discard = JSON.parse(discardBytes);
const discardFixtureSHA256 = crypto.createHash('sha256').update(discardBytes).digest('hex');
if (discard.sourceSHA256 !== sourceSHA256 || discard.cases.length !== 17
  || discardFixtureSHA256 !== 'fe1896a3d86eaffcaec5abfd33db1d8e71b9520f4da77839c17121b6a3f630cc') throw Error('Unverified discard fixture');
const functions = ['QJ','SHn','cwa','pHn','fHn','aHn','iVn','aC'];
const code = functions.map(name => {
  const start = source.indexOf(`function ${name}(`), end = source.indexOf('function ', start + 10);
  if (start < 0 || end < 0) throw Error(`Missing ${name}`);
  return source.slice(start, end).replace(/var [^;]+;$/, '');
}).join('\n');
const cases = [];
for (const sample of discard.cases) {
  const tab = {tabId:'browser', tabType:{}, onDiscardIfEmpty() {
    if (!sample.discarded) return false;
    values.tabs = []; values.active = null; return true;
  }};
  const values = {Xx:false, KS:false, qS:true, sM:true, bi:false, tS:'full', nS:false,
    yC:true, Yx:true, $x:'content', cS:'right-panel', sS:0, cM:true,
    active:tab, tabs:sample.name === 'multiple' ? [tab, {tabId:'other'}] : [tab]};
  const scope = {get(key) { return values[key]; }, set(key, value) {
    values[key] = typeof value === 'function' ? value(values[key]) : value;
  }};
  const context = {jM:{tabs$:'tabs',activeTab$:'active'},
    cHn:()=>{}, hHn:()=>null, iC:()=>{}, Jx:(e, area)=>e.set('cS',area)};
  for (const atom of ['Xx','KS','qS','sM','bi','tS','nS','yC','Yx','$x','cS','sS','cM']) context[atom] = atom;
  vm.createContext(context); vm.runInContext(code, context);
  const handled = context.QJ(scope, {kind:'chat'}, {mode:'full'});
  cases.push({name:sample.name, handled, mode:values.tS, visible:values.yC,
    focus:values.cS === 'main' ? 'chat' : 'content', ids:values.tabs.map(t=>t.tabId)});
}
fs.writeFileSync(output, JSON.stringify({version:discard.version, build:discard.build, sourceSHA256,
  discardFixtureSHA256, functions,
  boundary:'Actual QJ full-view chat selection and hide/focus functions; discard callback composed from phase 714 actual predicate/close extraction. Ordinary workspace only. No native focus, primary workspace or paired foreground evidence.', cases}, null, 2)+'\n');
console.log(`Extracted ${cases.length} full-view chat selections`);
