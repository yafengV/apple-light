// Execute pinned public request preparation; host/config/placement effects are explicit mocks.
const fs=require('fs'),vm=require('vm'),crypto=require('crypto'),path=require('path');
const args=process.argv.slice(2);
if(args.length!==3)throw Error('Usage: initial.js shared.js output.json');
const [initialPath,sharedPath,output]=args;
const outputPath=fs.existsSync(output)?fs.realpathSync(output):path.resolve(output);
const paths=[initialPath,sharedPath];
if(paths.map(p=>fs.realpathSync(p)).includes(outputPath))throw Error('Output must differ from inputs');
const expected=['22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3','eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab'];
const sources=paths.map((p,i)=>{
  const source=fs.readFileSync(p,'utf8');
  if(crypto.createHash('sha256').update(source).digest('hex')!==expected[i])throw Error('Unverified reference input');
  return source;
});
function fn(source,name){
  const start=source.indexOf('function '+name+'('),end=source.indexOf('function ',start+10);
  if(start<0||end<0)throw Error('Missing function '+name);
  return source.slice(start,end).replace(/var [^;]+;$/,'');
}
(async()=>{
  const cases=[];
  for(const turns of [[],[{turnId:'first',status:'inProgress'}],[{turnId:'first',status:'completed'}]]){
    const conversation={cwd:'/fixture',title:'Source',turns};
    const manager={getHostId:()=> 'local',getConversation:()=>conversation,
      requestClient:{getAppServerVersion:()=> '0.146.0-alpha.8'}};
    const capabilities={readTokenBudgetThread:()=>false,readPlacement:()=>({status:'ready',placement:null}),
      readConfig:async()=>({model:'fixture'})};
    const context={el:()=>false};vm.createContext(context);
    vm.runInContext(fn(sources[0],'vya'),context);
    vm.runInContext(fn(sources[1],'S5t'),context);
    const eligible=context.vya(false,'local',null);
    const prepared=await context.S5t(manager,{sourceConversationId:'source'},capabilities,{}).prepareRequest();
    if(!eligible||prepared.status!=='ready'||prepared.request.threadId!=='source'||'lastTurnId' in prepared.request)
      throw Error('Unexpected initial/latest request preparation');
    cases.push({turns,eligible,prepared});
  }
  fs.writeFileSync(output,JSON.stringify({version:'26.930.51102',build:13100,
    inputs:Object.fromEntries(paths.map((p,i)=>[p,expected[i]])),
    boundary:'Actual vya eligibility and S5t.prepareRequest. Host classification, conversation state, config and placement are explicit mocks. No desktop, app-server or Core execution; request preparation alone does not prove server acceptance.',cases},null,2)+'\n');
  console.log('Pinned public empty, first-active and completed request preparation: 3 cases PASS');
})().catch(e=>{console.error(e);process.exitCode=1;});
