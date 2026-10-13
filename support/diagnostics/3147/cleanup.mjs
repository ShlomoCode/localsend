import assert from "node:assert/strict";
import {existsSync,readFileSync,writeFileSync,mkdirSync} from "node:fs";
const out="evidence/issue3147",user=process.env.BROWSERSTACK_USERNAME,key=process.env.BROWSERSTACK_ACCESS_KEY;
mkdirSync(out,{recursive:true});
const report={status:"not-started",errors:[]};
const save=()=>writeFileSync(out+"/independent-cleanup.json",JSON.stringify(report,null,2));
const deadline=Math.min(Date.now()+100000,Date.parse(process.env.ISSUE3147_JOB_DEADLINE_UTC)-180000);
async function api(route,method="GET",hub=false) {
 assert(deadline>Date.now(),"Cleanup reserve expired");
 const r=await fetch((hub?"https://hub-cloud.browserstack.com/wd/hub":"https://api-cloud.browserstack.com/app-automate")+route,{method,headers:{authorization:"Basic "+Buffer.from(user+":"+key).toString("base64")},signal:AbortSignal.timeout(Math.min(10000,deadline-Date.now()))});
 const data=await r.json();assert(Date.now()<deadline,"Late cleanup response: terminal ownership remains unconfirmed");assert(r.ok||(method==="DELETE"&&r.status===404&&/invalid session|terminated/i.test(JSON.stringify(data))),"Cleanup HTTP "+r.status);return data;
}
try {
 assert(process.env.GITHUB_ACTIONS==="true"&&process.env.GITHUB_REPOSITORY==="ShlomoCode/localsend"&&process.env.GITHUB_RUN_ATTEMPT==="1"&&user&&key,"Exact fork cleanup only");
 if(!existsSync(out+"/ownership.json")){report.status="no-creation-receipt";save();process.exit(0);}
 const owned=JSON.parse(readFileSync(out+"/ownership.json","utf8")),buildName=`issue3147-${process.env.GITHUB_RUN_ID}-attempt-1`;
 assert(owned.issue===3147&&owned.runId===process.env.GITHUB_RUN_ID&&owned.runAttempt==="1"&&owned.head===process.env.GITHUB_SHA&&owned.buildName===buildName,"Wrong ownership");
 let build;
 for(let page=0;page<4&&!build;page++) {
  const data=await api("/builds.json?limit=100&offset="+page*100);assert(Array.isArray(data),"Invalid inventory");
  const matches=data.map(x=>x.automation_build).filter(x=>x?.name===buildName);assert(matches.length<=1,"Ambiguous exact build");build=matches[0];if(data.length<100)break;
 }
 assert(build,"Uncertain create: preserve hold, exact build unresolved");
 const sessions=await api("/builds/"+encodeURIComponent(build.hashed_id)+"/sessions.json");assert(Array.isArray(sessions)&&sessions.length<=1,"Ambiguous owned sessions");
 if(!sessions.length){assert(!owned.session,"Known session absent from exact build");report.status="exact-build-empty";save();process.exit(0);}
 const id=sessions[0].automation_session?.hashed_id;assert(typeof id==="string"&&/^[\w-]+$/.test(id)&&(!owned.session||owned.session===id),"Exact session mismatch");
 owned.session=id;writeFileSync(out+"/ownership.json",JSON.stringify(owned,null,2));report.session=id;
 const before=(await api("/sessions/"+id+".json")).automation_session;assert(before?.hashed_id===id,"Native provider identity mismatch");
 const terminal=["done","failed","error","timeout"];
 if(!terminal.includes(before.status)) {
  report.deviceBudgetOverrun=Date.parse(owned.deviceDeadlineUtc)<=Date.now();
  await api("/session/"+id,"DELETE",true);
 }
 const after=(await api("/sessions/"+id+".json")).automation_session;
 assert(after?.hashed_id===id&&terminal.includes(after.status),"Owned session nonterminal: preserve hold");assert(Date.now()<deadline,"Late terminal receipt: preserve hold");report.status="exact-owned-session-terminal";report.providerStatus=after.status;
}catch(e){report.status="cleanup-needs-attention";report.errors.push(String(e.message).replaceAll(user||"UNSET_USER","[redacted]").replaceAll(key||"UNSET_KEY","[redacted]"));process.exitCode=1;}
report.finishedUtc=new Date().toISOString();save();
