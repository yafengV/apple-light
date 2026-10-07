// Execute only public, pure model-selection functions from the pinned app bundle.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [appPath, sharedPath, outputPath] = process.argv.slice(2);
if (!outputPath) throw Error('Expected app, shared and output paths');
const app = fs.readFileSync(appPath, 'utf8'), shared = fs.readFileSync(sharedPath, 'utf8');
const hashes = {app:'22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3',
  shared:'eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab'};
for (const [name, source] of Object.entries({app, shared})) {
  if (crypto.createHash('sha256').update(source).digest('hex') !== hashes[name]) throw Error('Unverified '+name);
}
function read(source, name) {
  const start = source.indexOf('function '+name+'(');
  const end = source.indexOf('function ', start + 15);
  if (start < 0 || end < 0) throw Error('Missing '+name);
  // Eqr is followed by module declarations; evaluate only its function.
  return source.slice(start, end).split('var Dqr,')[0];
}
const context = {};
vm.createContext(context);
vm.runInContext(read(shared, 'Eqr')+';const kve=Eqr;', context);
for (const name of ['I9r', 'V9r', 'Oii', 'kii', 'z9r', 'B9r', 'H9r', 'U9r']) {
  vm.runInContext(read(app, name), context);
}
vm.runInContext('const q9r=/(?:^|[-_.])sol(?:$|[-_.])/iu;', context);
const inputs = [
  {name:'ordered', efforts:['high','low'], defaultEffort:'low', current:''},
  {name:'implicit-medium', efforts:['low','medium','high'], defaultEffort:null, current:''},
  {name:'explicit-high', efforts:['low','medium','high'], defaultEffort:'low', current:'high'},
  {name:'single', efforts:['low'], defaultEffort:'low', current:''},
  {name:'empty', efforts:[], defaultEffort:null, current:''},
  {name:'non-slider-values', efforts:['persistent','unknown','low','high'], defaultEffort:'high', current:''},
  {name:'none-and-minimal', efforts:['none','minimal'], defaultEffort:'none', current:''},
  {name:'hidden-default', efforts:['low','high','max','ultra'], defaultEffort:'ultra', current:''},
  {name:'missing-default', efforts:['low','high'], defaultEffort:null, current:''},
];
const cases = inputs.map(input => {
  const model = {model:input.name, displayName:input.name,
    supportedReasoningEfforts:input.efforts.map(reasoningEffort=>({reasoningEffort})),
    defaultReasoningEffort:input.defaultEffort};
  const options = context.V9r([model]);
  const resolved = context.kii({userSavedModelString:input.name,
    userSavedReasoningEffort:input.current || null, listModelsData:{models:[model]}}).reasoningEffort;
  return {...input, referenceEfforts:options.map(option=>option.reasoningEffort), resolved,
    steps: options.map(option=>({current:option.reasoningEffort,
      decrease:context.B9r(options,option,'decrease').reasoningEffort,
      increase:context.B9r(options,option,'increase').reasoningEffort}))};
});
fs.writeFileSync(outputPath, JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,cases},null,2)+'\n');
console.log('Extracted', cases.length, 'model power cases');
