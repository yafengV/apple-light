// Execute only public keyboard and pure stepping functions, never the app module.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [primaryPath, initialPath, outputPath] = process.argv.slice(2);
const primary = fs.readFileSync(primaryPath, 'utf8'), initial = fs.readFileSync(initialPath, 'utf8');
for (const [source, sha] of [[primary, '234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0'],
  [initial, '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3']]) {
  if (crypto.createHash('sha256').update(source).digest('hex') !== sha) throw Error('Unverified source');
}
function read(source, name) {
  const start = source.indexOf('function '+name+'('), end = source.indexOf('function ', start + 15);
  if (start < 0 || end < 0) throw Error('Missing '+name);
  return source.slice(start, end);
}
const slider = read(primary, 'w0e'), start = slider.indexOf('z=e=>{'), end = slider.indexOf(',t[33]=g', start);
if (start < 0 || end < 0) throw Error('Missing keyboard closure');
const cases = [
  ['left', 'medium', 'ArrowLeft'], ['right', 'medium', 'ArrowRight'],
  ['minimum', 'low', 'ArrowLeft'], ['maximum', 'high', 'ArrowRight'],
  ['up-is-menu-navigation', 'medium', 'ArrowUp'], ['down-is-menu-navigation', 'medium', 'ArrowDown'],
  ['composer-up', 'medium', 'ArrowUp', 'ComposerNavigation'],
  ['composer-down', 'medium', 'ArrowDown', 'ComposerNavigation'],
  ['tab-is-menu-navigation', 'medium', 'Tab'], ['space-not-complete', 'medium', ' '],
  ['enter-complete', 'medium', 'Enter'], ['disabled', 'medium', 'ArrowRight', '', true],
  ['disabled-enter', 'medium', 'Enter', '', true], ['locked-enter', 'medium', 'Enter', '', false, true],
].map(([name, current, key, code = key, disabled = false, locked = false]) => {
  const rows = ['low','medium','high'].map(id => ({id, isLocked: locked}));
  const selected = rows.find(row => row.id === current), effects = [];
  const context = {g:disabled, lz:'ComposerNavigation', p:selected, C:rows,
    x:value => effects.push(['focusVisible',value]),
    u:value => effects.push(['select',value.id]),
    a:(value,previous) => effects.push(['commit',value.id,previous.id]),
    l:() => effects.push(['complete'])};
  vm.createContext(context);
  vm.runInContext(read(initial, 'B9r')+';const UAe=B9r;', context);
  const handler = vm.runInContext('('+slider.slice(start+2,end)+')',context);
  let prevented = false, stopped = false;
  handler({key,code,preventDefault:() => {prevented=true;},stopPropagation:() => {stopped=true;}});
  return {name,current,key,code,disabled,locked,expected:{effects,prevented,stopped}};
});
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,cases},null,2)+'\n');
console.log('Extracted',cases.length,'power keyboard cases');
