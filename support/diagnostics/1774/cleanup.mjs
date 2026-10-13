import assert from "node:assert/strict";
import {readFileSync,writeFileSync,mkdirSync,existsSync} from "node:fs";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import path from "node:path";
assert(process.env.GITHUB_ACTIONS==="true"&&process.env.GITHUB_REPOSITORY==="ShlomoCode/localsend","Fork cleanup only");
const output=path.resolve(process.env.EVIDENCE_DIR);mkdirSync(output,{recursive:true});
const buildName="issue1774-"+process.env.GITHUB_RUN_ID+"-attempt-"+process.env.GITHUB_RUN_ATTEMPT;
const report={buildName,errors:[],startedAt:new Date().toISOString(),nativeRestorationVerified:false};
const user=process.env.BROWSERSTACK_USERNAME,key=process.env.BROWSERSTACK_ACCESS_KEY,auth="Basic "+Buffer.from(user+":"+key).toString("base64");
const deadline=Math.min(Date.now()+100000,Date.parse(process.env.ISSUE1774_JOB_DEADLINE_UTC)-6*60000);
const save=()=>writeFileSync(path.join(output,"independent-cleanup.json"),JSON.stringify(report,null,2));
async function api(route,method="GET",hub=false){assert(deadline>Date.now(),"Cleanup reserve expired");const response=await fetch((hub?"https://hub-cloud.browserstack.com/wd/hub":"https://api-cloud.browserstack.com/app-automate")+route,{method,headers:{authorization:auth},signal:AbortSignal.timeout(Math.min(10000,deadline-Date.now()))});const data=await response.json();assert(response.ok||(method==="DELETE"&&response.status===404&&/invalid session|terminated/i.test(JSON.stringify(data))),"Cleanup HTTP "+response.status);return {response,data};}
try{
 const file=path.join(output,"ownership.json");if(!existsSync(file)){report.status="no-creation-receipt";save();process.exit(0);}
 const owned=JSON.parse(readFileSync(file,"utf8"));assert(owned.buildName===buildName&&owned.runId===process.env.GITHUB_RUN_ID&&owned.runAttempt===process.env.GITHUB_RUN_ATTEMPT,"Wrong ownership receipt");
 if(owned.deviceDeadlineUtc){const hard=Date.parse(owned.deviceDeadlineUtc);assert(Number.isFinite(hard),"Invalid owned device lifetime deadline");report.deviceDeadlineUtc=owned.deviceDeadlineUtc;}
 let session=owned.session;
 if(!owned.creationAttempted&&!session){report.status="no-creation-attempt";save();process.exit(0);}
 let found;
 for(let page=0;page<4&&!found;page++){
  const {data}=await api("/builds.json?limit=100&offset="+page*100);assert(Array.isArray(data),"Invalid build inventory");const matches=data.map(row=>row.automation_build).filter(row=>row?.name===buildName);assert(matches.length<=1,"Ambiguous exact build");found=matches[0];if(data.length<100)break;
 }
 assert(found,"Creation attempted but exact build unresolved; coordinator must retain hold");
 const {data}=await api("/builds/"+encodeURIComponent(found.hashed_id)+"/sessions.json");assert(Array.isArray(data)&&data.length<=1,"Ambiguous exact session inventory");
 if(!data.length){assert(!session,"Known session absent from exact build");report.status="exact-build-empty";save();process.exit(0);}
 const verified=data[0].automation_session?.hashed_id;assert(typeof verified==="string"&&(!session||session===verified),"Owned session mismatch");session=verified;report.session=session;owned.session=session;writeFileSync(file,JSON.stringify(owned,null,2));
 // The restoration mode cannot create a session or repeat an uncertain mutation.
 const restoredFile=path.join(output,"finally-native-restoration.json");const restored=existsSync(restoredFile)?JSON.parse(readFileSync(restoredFile,"utf8")):null;
 const orientationFile=path.join(output,"finally-orientation-restoration.json");const orientationRestored=existsSync(orientationFile)?JSON.parse(readFileSync(orientationFile,"utf8")):null;
 if((restored?.restored===true||restored?.mutationRecorded===false)&&(orientationRestored?.restored===true||orientationRestored?.mutationRecorded===false)){report.nativeRestorationVerified=true;report.orientationRestorationVerified=true;report.restoration="controller retained native and orientation restoration receipts";}else if(owned.nativeDeadlineUtc&&Date.parse(owned.nativeDeadlineUtc)-Date.now()>15000){
  try{await promisify(execFile)(process.execPath,["support/diagnostics/1774/controller.mjs","--restore"],{timeout:Math.min(45000,Date.parse(owned.nativeDeadlineUtc)-Date.now()-10000),maxBuffer:1024*1024});report.nativeRestorationVerified=true;report.orientationRestorationVerified=true;}catch(error){report.errors.push("Native restoration unresolved: "+String(error.code??"restore failure"));}
 }else report.restoration="Native restoration deadline unavailable/expired; original state requires retained receipt";
 const {data:beforeDelete}=await api("/sessions/"+encodeURIComponent(session)+".json");assert(beforeDelete.automation_session?.hashed_id===session,"Pre-delete provider identity mismatch");
 const priorStatus=beforeDelete.automation_session.status;
 if(["done","failed","error","timeout"].includes(priorStatus)){report.status="exact-owned-session-already-terminal";report.providerStatus=priorStatus;}else{
  report.activeLifetimeBudgetOverrun=Date.parse(owned.deviceDeadlineUtc)<=Date.now();
  if(report.activeLifetimeBudgetOverrun)report.errors.push("Owned device exceeded 12-minute lifetime; immediate exact cleanup required");
  const {response}=await api("/session/"+encodeURIComponent(session),"DELETE",true);report.deleteStatus=response.status;report.status="exact-session-deleted-or-absent";
 }
 const {data:terminal}=await api("/sessions/"+encodeURIComponent(session)+".json");assert(terminal.automation_session?.hashed_id===session,"Terminal receipt mismatch");assert(["done","failed","error","timeout"].includes(terminal.automation_session.status),"Exact owned session remains nonterminal; preserve coordinator hold");report.providerStatus=terminal.automation_session.status;report.providerReason=terminal.automation_session.reason;
}catch(error){report.errors.push(error.message.replaceAll(user??"UNSET_USER","[redacted]").replaceAll(key??"UNSET_KEY","[redacted]"));report.status="cleanup-needs-attention";}
report.finishedAt=new Date().toISOString();save();if(report.errors.length)process.exitCode=1;
