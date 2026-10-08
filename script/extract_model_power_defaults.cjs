// Execute the public client's pure fallback resolver with pinned source identity.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [appPath, outputPath] = process.argv.slice(2), source = fs.readFileSync(appPath,'utf8');
const sha='22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3';
if(crypto.createHash('sha256').update(source).digest('hex')!==sha) throw Error('Unverified app');
const context={}; vm.createContext(context);
for(const name of ['H9r','U9r']) {
 const start=source.indexOf('function '+name+'('),end=source.indexOf('function ',start+15);
 if(start<0||end<0) throw Error('Missing '+name);
 vm.runInContext(source.slice(start,end),context);
}
vm.runInContext('const q9r=/(?:^|[-_.])sol(?:$|[-_.])/iu;',context);
const common=['gpt-5.6-terra:low','gpt-5.6-sol:low','gpt-5.6-sol:medium','gpt-5.6-sol:high'];
const inputs=[
 ['exact-terra-low',common,'gpt-5.6-terra:low'],
 ['exact-sol-high',common,'gpt-5.6-sol:high'],
 ['same-effort-sol',common,'custom:high'],
 ['unavailable-effort',common,'gpt-5.6-terra:ultra'],
 ['missing-preference',common,null],
 ['no-medium-sol',['gpt-5.6-terra:low','gpt-5.6-sol:high'],null],
 ['other-medium',['custom:low','custom:medium','custom:high'],null],
 ['first-option',['custom:high','custom:low'],null],
 ['empty',[],null],
 ['sol-case-and-delimiter',['custom:medium','OAI.SOL.test:high'],null],
 ['sol-word-boundary',['gpt-solar:high','custom:medium'],null],
 ['multiple-colons',['org:model:high','gpt-5.6-sol:medium'],'org:model:high'],
 ['multiple-colons-effort',common,'org:model:high'],
 ['no-colon-effort',common,'high'],
 ['empty-effort',common,'custom:'],
];
const cases=inputs.map(([name,ids,preferredID])=>{
 const selections=ids.map((id,powerSettingIndex)=>({id,model:id.slice(0,id.lastIndexOf(':')),
  reasoningEffort:id.slice(id.lastIndexOf(':')+1),powerSettingIndex}));
 return {name,selections,preferredID,expectedID:context.H9r(selections,preferredID??undefined)?.id??null};
});
const models=[
 {id:'gpt-5.6-terra',display_name:'Terra',supported_reasoning_efforts:['low','medium','high','xhigh'],default_reasoning_effort:'low',isDefault:true},
 {id:'gpt-5.6-sol',display_name:'Sol',supported_reasoning_efforts:['low','medium','high','xhigh'],default_reasoning_effort:'medium',isDefault:false},
];
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:sha,models,cases},null,2)+'\n');
console.log('Extracted',cases.length,'default fallback cases');
