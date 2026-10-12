// Independent always-step fallback after the transfer supervisor exits.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,existsSync,readdirSync,lstatSync,rmSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';

assert(process.env.GITHUB_ACTIONS==='true'&&process.env.GITHUB_REPOSITORY==='ShlomoCode/localsend','Fork Actions cleanup only');
const runId=process.env.GITHUB_RUN_ID,attempt=process.env.GITHUB_RUN_ATTEMPT;
assert(/^\d+$/.test(runId)&&/^\d+$/.test(attempt),'Exact numeric run/attempt required');
assert(process.env.RUNNER_TEMP&&process.env.TRANSFER_EVIDENCE_DIRECTORY,'Owned runner/evidence locations required');
const buildName='issue3441-'+runId+'-attempt-'+attempt,prefix=buildName+'-';
const output=path.resolve(process.env.TRANSFER_EVIDENCE_DIRECTORY);mkdirSync(output,{recursive:true});
const username=process.env.BROWSERSTACK_USERNAME||process.env.BS_SPRINT_USERNAME,key=process.env.BROWSERSTACK_ACCESS_KEY||process.env.BS_SPRINT_ACCESS_KEY;
const auth='Basic '+Buffer.from(username+':'+key).toString('base64');
const secrets=[username,key,auth,process.env.RELAY_TOKEN,process.env.BASELINE_APP,process.env.HELPER_APP,process.env.RELAY_APP].filter(Boolean);
const redact=value=>{let text=String(value);for(const secret of secrets)text=text.replaceAll(secret,'[redacted]');return text.replace(/bs:\/\/[a-f0-9]+/gi,'[redacted app reference]');};
const report={runId,runAttempt:attempt,buildName,startedUtc:new Date().toISOString(),session:null,tunnel:null,privateDirectories:[],errors:[]};
const hardDeadline=Date.parse(process.env.ISSUE3441_JOB_DEADLINE_UTC);
const deadline=Math.min(Date.now()+110000,Number.isFinite(hardDeadline)?hardDeadline-6*60000:Infinity);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const save=()=>writeFileSync(path.join(output,'android-independent-cleanup.json'),redact(JSON.stringify(report,null,2)));
let ownership;
async function request(base,route,method='GET') {
 assert(username&&key,'BrowserStack credentials required for owned session cleanup');
 const remaining=deadline-Date.now();assert(remaining>0,'Independent cleanup deadline expired');
 const response=await fetch(base+route,{method,headers:{authorization:auth},signal:AbortSignal.timeout(Math.min(10000,remaining))});
 const text=await response.text();assert(text.length<=1024*1024,'Provider cleanup response exceeds bound');
 let data;try{data=JSON.parse(text);}catch{throw Error('Provider cleanup returned invalid JSON HTTP '+response.status);}
 return {status:response.status,ok:response.ok,data};
}
async function provider(route) {const response=await request('https://api-cloud.browserstack.com/app-automate/',route);assert(response.ok,'Provider cleanup HTTP '+response.status);return response.data;}
try {
 const file=path.join(output,'android-ownership.json');
 if(existsSync(file)) {
  const candidate=JSON.parse(readFileSync(file,'utf8'));
  assert(candidate.runId===runId&&candidate.runAttempt===attempt&&candidate.buildName===buildName,'Ownership receipt does not match this exact job');
  ownership=candidate;
 }
}catch(error){ownership=undefined;report.errors.push('Ownership: '+redact(error.message));}
try {
 let knownId=ownership?.session;
 const sessionFile=path.join(output,'session.json');
 if(existsSync(sessionFile)) {
  const saved=JSON.parse(readFileSync(sessionFile,'utf8'));
  assert(saved.buildName===buildName&&typeof saved.session==='string','Session receipt does not identify this exact build');
  if(knownId)assert(knownId===saved.session,'Owned session receipts disagree');knownId=saved.session;
 }
 let verifiedId,providerBuildHash;
 if(knownId) {
  assert(/^[a-zA-Z0-9_-]+$/.test(knownId),'Invalid saved provider session ID');
  const metadata=(await provider('sessions/'+encodeURIComponent(knownId)+'.json')).automation_session;
  assert(metadata?.hashed_id===knownId,'Provider metadata differs from saved session');
  // Use returned identity fields only when observed; missing fields require the authoritative build/session lookup.
  if(typeof metadata.build_name==='string'){assert(metadata.build_name===buildName,'Provider session belongs to a different build');verifiedId=knownId;}
  if(typeof metadata.build_hashed_id==='string')providerBuildHash=metadata.build_hashed_id;
 }
 if(!verifiedId&&(knownId||ownership?.creationAttempted!==false)) {
  // Bounded pagination and a second fresh pass resolve a creation race without treating a missing first page as success.
  let foundBuild;
  for(let pass=0;pass<2&&!foundBuild;pass++) {
   for(let page=0;page<6&&!foundBuild;page++) {
    assert(deadline-Date.now()>15000,'Insufficient cleanup budget for build recovery and deletion');
    const data=await provider('builds.json?limit=100&offset='+page*100);assert(Array.isArray(data),'Provider build page unavailable');
    const matches=data.map(row=>row.automation_build).filter(row=>row.name===buildName);
    assert(matches.length<=1,'Exact owned BrowserStack build is ambiguous');
    if(matches.length)foundBuild=matches[0];if(data.length<100)break;
   }
   if(!foundBuild&&pass===0)await sleep(Math.min(1500,Math.max(0,deadline-Date.now()-15000)));
  }
  if(foundBuild) {
   if(providerBuildHash)assert(foundBuild.hashed_id===providerBuildHash,'Session metadata build hash differs from exact owned build');
   const sessions=(await provider('builds/'+encodeURIComponent(foundBuild.hashed_id)+'/sessions.json')).map(row=>row.automation_session);
   assert(sessions.length<=1,'Exact owned build has ambiguous sessions');
   if(sessions.length){verifiedId=sessions[0].hashed_id;if(knownId)assert(verifiedId===knownId,'Owned receipt session differs from exact provider build');}
   else {assert(!knownId,'Saved session is absent from its provider build');report.session={status:'owned-build-has-no-session'};}
  }else {
   assert(!knownId,'Known owned session could not be verified within bounded build pages');
   assert(ownership?.creationAttempted!==true,'Creation was attempted but the exact owned build is still unresolved');
   report.session={status:'no-exact-owned-build-after-bounded-recovery'};
  }
 }else if(!verifiedId)report.session={status:'owned-receipt-confirms-no-creation-attempt'};
 if(verifiedId) {
  assert(typeof verifiedId==='string'&&/^[a-zA-Z0-9_-]+$/.test(verifiedId),'Invalid verified session ID');
  const response=await request('https://hub-cloud.browserstack.com/wd/hub','/session/'+encodeURIComponent(verifiedId),'DELETE');
  const absent=response.status===404&&/invalid session id|not started or terminated/i.test(JSON.stringify(response.data));
  assert(absent||response.ok&&!response.data.value?.error,'Owned session delete failed HTTP '+response.status);
  report.session={id:verifiedId,deleteStatus:response.status,status:absent?'already-absent':'deleted'};
 }
}catch(error){report.errors.push('Session: '+redact(error.message));}finally{save();}
try {
 const tunnel=ownership?.tunnel;
 if(tunnel) {
  assert(Number.isSafeInteger(tunnel.pid)&&tunnel.pid>1&&tunnel.identity&&tunnel.binary&&tunnel.localIdentifier===ownership.localIdentifier,'Incomplete owned tunnel identity');
  const inspect=()=>{
   try {
    const identity=execFileSync('/bin/ps',['-p',String(tunnel.pid),'-o','lstart=','-o','comm='],{encoding:'utf8',timeout:2000}).trim();
    const args=execFileSync('/bin/ps',['-p',String(tunnel.pid),'-o','args='],{encoding:'utf8',timeout:2000}).trim();
    return {identity,owns:identity===tunnel.identity&&args.startsWith(tunnel.binary+' ')&&args.includes('--local-identifier '+tunnel.localIdentifier)};
   }catch(error){if(error.status===1)return null;throw Error('Owned tunnel identity read failed');}
  };
  const current=inspect();
  if(!current)report.tunnel={pid:tunnel.pid,status:'already-absent'};
  else if(!current.owns)throw Error('PID identity changed; preserve the unrelated process');
  else {
   process.kill(tunnel.pid,'SIGTERM');const end=Math.min(deadline,Date.now()+5000);
   while(Date.now()<end&&inspect()?.owns)await sleep(250);
   const remaining=inspect();
   if(remaining?.owns){process.kill(tunnel.pid,'SIGKILL');const killEnd=Math.min(deadline,Date.now()+3000);while(Date.now()<killEnd&&inspect()?.owns)await sleep(250);}
   assert(!inspect()?.owns,'Owned tunnel did not exit after SIGKILL');report.tunnel={pid:tunnel.pid,status:'stopped'};
  }
 }else report.tunnel={status:'no-owned-tunnel-receipt'};
}catch(error){report.errors.push('Tunnel: '+redact(error.message));}finally{save();}
try {
 // Prefix includes this exact run/attempt and catches directories created just before termination.
 for(const name of readdirSync(process.env.RUNNER_TEMP)) {
  if(!name.startsWith(prefix+'helpers.')&&!name.startsWith(prefix+'private-logs-'))continue;
  const directory=path.join(process.env.RUNNER_TEMP,name),stat=lstatSync(directory);
  assert(stat.isDirectory()&&!stat.isSymbolicLink(),'Unexpected owned private-directory type');
  rmSync(directory,{recursive:true,force:true});report.privateDirectories.push({name,status:'erased'});
 }
}catch(error){report.errors.push('Private material: '+redact(error.message));}
report.finishedUtc=new Date().toISOString();report.status=report.errors.length?'cleanup-needs-attention':'owned-cleanup-complete';save();
if(report.errors.length)process.exitCode=1;
