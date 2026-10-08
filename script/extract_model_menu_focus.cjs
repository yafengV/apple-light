// Public menu focus effect only, evaluated against minimal synthetic DOM roots.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2), source = fs.readFileSync(sourcePath,'utf8');
const sha = '234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0';
if (crypto.createHash('sha256').update(source).digest('hex') !== sha) throw Error('Unverified source');
const start = source.indexOf('function X0e('), end = source.indexOf('function ',start+15), menu = source.slice(start,end);
const first = menu.indexOf('se=()=>{'), last = menu.indexOf(',t[16]=n',first);
if (start < 0 || first < 0 || last < 0) throw Error('Missing focus effect');
const cases = [
  {name:'keyboard-return-to-simple',view:'simple',memory:'advanced'},
  {name:'keyboard-open-advanced-selected',view:'advanced',memory:'simple',selected:'sol'},
  {name:'keyboard-open-advanced-default',view:'advanced',memory:'simple',selected:'default'},
  {name:'keyboard-open-advanced-unlisted',view:'advanced',memory:'simple'},
  {name:'same-simple-retains-existing-focus',view:'simple',memory:'simple',hasFocus:true},
  {name:'removed-reset-falls-to-first',view:'simple',memory:'simple'},
  {name:'same-advanced-retains-existing-focus',view:'advanced',memory:'advanced',hasFocus:true,selected:'sol'},
  {name:'pointer-advanced-with-focus',view:'advanced',hasFocus:true,selected:'sol'},
  {name:'pointer-advanced-body',view:'advanced',selected:'sol'},
  {name:'inactive-pointer-body',view:'advanced',selected:'sol',active:false},
  {name:'disabled-selected-falls-to-first',view:'advanced',memory:'simple',selected:'sol',disabledSelected:true},
].map(input => {
  let focusedID = null, preventScroll = null;
  const target = id => ({focus:options => {focusedID=id;preventScroll=options.preventScroll;}});
  const simple = {querySelector:selector => selector.includes('menuitemradio') ? null : target('choose-model')};
  const advanced = {querySelector:selector => selector.includes('menuitemradio')
    ? (input.selected && !input.disabledSelected ? target(input.selected) : null) : target('default'),
    closest:() => target('menu-root')};
  const body = {}, context = {n:input.active ?? true,ee:input.view==='advanced',s:input.view,
    A:{current:input.memory ?? null},O:{current:simple},k:{current:advanced},
    document:{body,activeElement:input.hasFocus ? {} : body}};
  vm.createContext(context); vm.runInContext('('+menu.slice(first+3,last)+')',context)();
  return {...input,expected:{focusedID,preventScroll,memory:context.A.current}};
});
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:sha,cases},null,2)+'\n');
console.log('Extracted',cases.length,'menu focus cases');
