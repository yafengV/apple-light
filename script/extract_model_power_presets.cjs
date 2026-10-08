// Run the pinned public bundle's pure default Power-preset resolver.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [appPath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(appPath, 'utf8');
const sha = '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3';
if (crypto.createHash('sha256').update(source).digest('hex') !== sha) throw Error('Unverified app');
function read(name) {
  const start = source.indexOf('function '+name+'('), end = source.indexOf('function ', start + 15);
  if (start < 0 || end < 0) throw Error('Missing '+name);
  return source.slice(start, end).split('var K9r,')[0];
}
const context = {}; vm.createContext(context);
for (const name of ['I9r', 'R9r', 'G9r']) vm.runInContext(read(name), context);
const start = source.indexOf('J9r=[', source.indexOf('function G9r('));
const end = source.indexOf(']})))()}', start);
if (start < 0 || end < 0) throw Error('Missing preset constants');
vm.runInContext('const '+source.slice(start,end+1)+';', context);
const terra = (efforts) => ({model:'gpt-5.6-terra', displayName:'GPT-5.6-terra', efforts});
const sol = (efforts) => ({model:'gpt-5.6-sol', displayName:'GPT-5.6-sol', efforts});
const inputs = [
  {name:'both-complete', models:[terra(['low','medium','high','xhigh']),sol(['low','medium','high','xhigh','ultra'])]},
  {name:'sol-only', models:[sol(['low','medium','high','xhigh','ultra'])]},
  {name:'terra-only', models:[terra(['low','medium','high','xhigh'])]},
  {name:'partial-primary', models:[terra(['low','medium','high']),sol(['medium','high'])]},
  {name:'primary-too-short-use-terra', models:[terra(['low','medium','high']),sol(['high'])]},
  {name:'two-options-unavailable', models:[terra(['low']),sol(['high'])]},
  {name:'unknown-service-model', models:[{model:'custom',displayName:'Custom',efforts:['low','medium','high']}]},
  {name:'missing-capabilities', models:[terra([]),sol([])]},
  {name:'provider-order-does-not-reorder-preset', models:[sol(['high','medium','low']),terra(['low'])]},
  {name:'remove-xhigh', removeXHigh:true, models:[terra(['low']),sol(['low','medium','high','xhigh','ultra'])]},
];
const cases=inputs.map(input=>({...input, expected:context.R9r(input.models.map(model=>({...model,
  supportedReasoningEfforts:model.efforts.map(reasoningEffort=>({reasoningEffort}))})),
  {removeXHigh:input.removeXHigh??false})}));
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:sha,cases},null,2)+'\n');
console.log('Extracted',cases.length,'default preset cases');
