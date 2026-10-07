// Execute only public Dock JSX and visibility functions; never open the reference app.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [settingsPath, visibilityPath, sharedPath, outputPath] = process.argv.slice(2);
if (!settingsPath || !visibilityPath || !sharedPath || !outputPath) throw Error('Expected settings, visibility, shared, output paths');
const settings = fs.readFileSync(settingsPath, 'utf8'), visibility = fs.readFileSync(visibilityPath, 'utf8');
const shared = fs.readFileSync(sharedPath, 'utf8');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
if (hash(settings) !== '91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535'
  || hash(visibility) !== '44dcb985ac16b5c5e3d52bd8a84cc44b7122fb063159fca97fc6543931fd8de6'
  || hash(shared) !== 'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab') throw Error('Unverified public assets');
const defaultPreference = shared.match(/dockIconPreference:_P\(\{agentAccess:`read-write`,default:`([^`]+)`/)?.[1];
if (!defaultPreference) throw Error('Missing public Dock preference default');
function read(source, name) {
  const start = source.indexOf('function ' + name + '('), end = source.indexOf('function ', start + 15);
  if (start < 0 || end < 0) throw Error('Missing function ' + name);
  return source.slice(start, end);
}
const jsx = (type, props) => ({ type, props });
const flatten = tree => !tree || typeof tree !== 'object' ? [] : [tree,
  ...[tree.props?.children].flat(Infinity).flatMap(flatten), ...flatten(tree.props?.control)];
const cases = [];
for (const platform of ['macOS', 'windows', 'linux']) for (const previews of [false, true])
  for (const spaces of [false, true]) for (const selected of ['app-default', 'codex-system', 'space-system']) {
    const writes = [], data = previews ? {appDefault:'default',codexLight:'light',codexDark:'dark',spaceLight:'space-light',spaceDark:'space-dark'} : null;
    const context = { Q:{c:n=>Array(n).fill(Symbol.for('react.memo_cache_sentinel'))}, $:{jsx,jsxs:jsx},
      z:()=>({}),k:0,P:()=>({formatMessage:m=>m.defaultMessage}),Ee:()=>({platform}),B:()=>({data:{dockIconPreviews:data}}),
      ze:0,R:()=>selected,V:{dockIconPreference:0},it:()=>spaces,S:(_,__,value)=>writes.push(value),
      M:'M',N:'N',Qs:'Qs',ie:(...values)=>values.join(' '),t:{Agent:'agent'} };
    vm.createContext(context); vm.runInContext(read(visibility,'r'),context);
    context.Li=context.r; vm.runInContext(read(settings,'Zs'),context);
    const tree=context.Zs(), nodes=flatten(tree), options=nodes.filter(n=>n.type==='Qs').map(n=>n.props);
    context.Qs='Qs'; vm.runInContext(read(settings,'Qs'),context);
    const cards=options.map(option=>{
      const result=flatten(context.Qs(option)),input=result.find(n=>n.type==='input').props;
      input.onChange();
      return {value:option.value,checked:option.checked,label:input['aria-label'],radioType:input.type,name:input.name,
        cardClass:result.find(n=>n.type==='span').props.className};
    });
    cases.push({platform,previews,spaces,selected,visible:tree!=null,options:cards,writes});
  }
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,defaultPreference,sourceSHA256:{settings:hash(settings),visibility:hash(visibility),shared:hash(shared)},cases},null,2)+'\n');
console.log('Extracted',cases.length,'Dock visibility and radio callback cases');
