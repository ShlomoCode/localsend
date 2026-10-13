import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync, appendFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { retainProviderArtifacts } from "./provider-artifacts.mjs";
const APP="org.localsend.localsend_app", out="evidence/issue3147";
const user=process.env.BROWSERSTACK_USERNAME,key=process.env.BROWSERSTACK_ACCESS_KEY,app=process.env.BASELINE_APP;
const auth="Basic "+Buffer.from(`${user}:${key}`).toString("base64"), hash=x=>createHash("sha256").update(x).digest("hex");
const redact=x=>String(x).replace(/https?:\/\/[^\s"<>]+/g,"[URL redacted]").replace(/bs:\/\/[\w-]+/g,"[app reference redacted]");
const safe=x=>{let s=redact(x);for(const v of [user,key,app,auth].filter(Boolean))s=s.replaceAll(v,"[redacted]");return s;};
mkdirSync(out,{recursive:true});
const save=(name,value)=>writeFileSync(path.join(out,name),safe(typeof value==="string"?value:JSON.stringify(value,null,2)));
const json=f=>JSON.parse(readFileSync(f,"utf8"));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let session,owned,actionDeadline,deviceDeadline,conditionDeadline,uncertain=false,stage="preflight",n=0;
const report={status:"not-started",productVerdict:null,handlerQualification:"unknown",nativeBuild:"unknown",oneUI:"unknown",installedVersion:"unknown",observations:[],boundaries:["Galaxy S22 differs from reported A21s", "Android12 does not establish OneUI4.1", "Original numerical release and installation source unknown", "Passing current release cannot resolve historical report"]};
function acceptWithin(limit=Math.min(actionDeadline,conditionDeadline??Infinity)) {
 assert(Number.isFinite(limit)&&Date.now()<limit,"Late response or capture: condition remains ambiguous");
}
async function request(method,p,body,{provider=false,cleanup=false,fileTrigger=false}={}) {
 const serialized=body===undefined?undefined:JSON.stringify(body),at=Date.now();
 if(fileTrigger){conditionDeadline=Math.min(actionDeadline,at+10000);report.fileTriggerStartUtc=new Date(at).toISOString();}
 const limit=cleanup?Math.min(deviceDeadline,Date.parse(process.env.ISSUE3147_JOB_DEADLINE_UTC)-180000):Math.min(actionDeadline,conditionDeadline??Infinity);
 assert(Date.now()<limit,"Absolute request deadline reached");
 const url=(provider?"https://api-cloud.browserstack.com":"https://hub-cloud.browserstack.com/wd/hub")+p;
 try {
  const r=await fetch(url,{method,headers:{authorization:auth,"content-type":"application/json"},body:serialized,signal:AbortSignal.timeout(Math.max(1,Math.min(p==="/session"?90000:10000,limit-at)))});
  const text=await r.text();assert(Buffer.byteLength(text)<16*1024*1024,"Response retention bound");
  const j=JSON.parse(text);
  if(p==="/session"&&method==="POST") {
   const id=j.value?.sessionId??j.sessionId;
   if(typeof id==="string"&&/^[\w-]+$/.test(id)){session=id;owned.session=id;save("ownership.json",owned);}
  }
  appendFileSync(path.join(out,"commands.jsonl"),safe(JSON.stringify({at:new Date(at).toISOString(),stage,method,path:p,status:r.status,elapsedMs:Date.now()-at,late:Date.now()>=limit,error:j.value?.error}))+"\n");
  assert(r.ok&&!j.value?.error,"Remote response failed: "+r.status+" "+(j.value?.error??""));acceptWithin(limit);return j;
 }catch(e){if(method==="POST"&&p!=="/session")uncertain=true;throw e;}
}
const wd=async(m,p,b,options)=>{assert(session,"Owned handle required");assert(m!=="POST"||!uncertain,"Uncertain input prohibits further input");return (await request(m,"/session/"+session+p,b,options)).value;};
const decode=s=>s.replace(/&quot;/g,"\"").replace(/&apos;/g,"\u0027").replace(/&amp;/g,"&").replace(/&lt;/g,"<").replace(/&gt;/g,">");
const nodes=xml=>[...xml.matchAll(/<[^/!?][^>]*>/g)].map(m=>Object.fromEntries([...m[0].matchAll(/([\w.:-]+)=(["\u0027])([\s\S]*?)\2/g)].map(a=>[a[1],decode(a[3])])));
const label=x=>x["content-desc"]||x.text||"";
async function snapshot(name) {
 const xml=await wd("GET","/source"),png=Buffer.from(await wd("GET","/screenshot"),"base64");
 assert(png.length>=24&&png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])),"Original PNG required");
 const pkg=await wd("GET","/appium/device/current_package"),appState=await wd("POST","/appium/device/app_state",{appId:APP});
 save(name+".xml",xml);writeFileSync(path.join(out,name+".png"),png);
 const state={xml,pkg,appState,width:png.readUInt32BE(16),height:png.readUInt32BE(20)};
 save(name+".json",{utc:new Date().toISOString(),pkg,appState,width:state.width,height:state.height,pngSha256:hash(png),xmlSha256:hash(xml)});acceptWithin();return state;
}
async function tap(text,expected=APP,fileTrigger=false) {
 const name="input-"+(++n),a=await snapshot(name+"-before"),b=await wd("GET","/source");
 assert(a.pkg===expected,"Unexpected foreground before "+text);
 const find=x=>nodes(x).filter(v=>label(v)===text&&v.package===expected&&v.enabled==="true"&&v.bounds);
 const first=find(a.xml),last=find(b);assert(first.length===1&&last.length===1&&first[0].bounds===last[0].bounds,"Exact visible control did not settle: "+text);
 const bounds=last[0].bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);assert(bounds,"Bounds missing");
 const [x1,y1,x2,y2]=bounds.slice(1).map(Number);assert(x2>x1&&y2>y1&&x1>=0&&y1>=0&&x2<=a.width&&y2<=a.height,"Control outside PNG");
 assert(await wd("GET","/appium/device/current_package")===expected,"Foreground changed before input");
 save(name+"-binding.json",{text,pkg:expected,bounds:last[0].bounds,utc:new Date().toISOString()});
 acceptWithin();
 await wd("POST","/actions",{actions:[{type:"pointer",id:"finger3147",parameters:{pointerType:"touch"},actions:[{type:"pointerMove",duration:0,origin:"viewport",x:Math.floor((x1+x2)/2),y:Math.floor((y1+y2)/2)},{type:"pointerDown",button:0},{type:"pause",duration:100},{type:"pointerUp",button:0}]}]},{fileTrigger});
}
async function nativePackage(name) {
 const body={script:"browserstack_executor: "+JSON.stringify({action:"adbShell",arguments:{command:"dumpsys package "+name}}),args:[]};
 const reply=await wd("POST","/execute/sync",body);
 save("native-package-"+name+".json",{command:body,reply,utc:new Date().toISOString()});
 acceptWithin();return typeof reply==="string"&&reply.trim()?reply:"";
}
function registeredDocumentHandler(text,packageName) {
 // Missing default activity state stays unknown. Accept only an explicit User0 component-enable override.
 const lines=text.split(/\r?\n/),users=lines.map((line,index)=>({line,index,match:line.match(/^(\s*)User 0:/)})).filter(x=>x.match);
 if(users.length!==1)return false;
 const user=users[0],indent=user.match[1].length;
 if(!/\binstalled=true\b/.test(user.line)||!/\bhidden=false\b/.test(user.line)||!/\bsuspended=false\b/.test(user.line)||!/\benabled=[01](?:\s|$)/.test(user.line))return false;
 const section=[];
 for(let i=user.index+1;i<lines.length;i++){if(lines[i].trim()&&lines[i].match(/^\s*/)[0].length<=indent)break;section.push(lines[i]);}
 const component=token=>{const parts=token.split("/");if(parts.length>2||parts.length===2&&parts[0]!==packageName)return null;const value=parts.at(-1);return /^[\w.$]+$/.test(value)?value.startsWith(".")?packageName+value:value:null;};
 const membership=kind=>{const headings=section.map((line,index)=>({line,index,match:line.match(/^(\s*)(enabledComponents|disabledComponents):\s*$/) })).filter(x=>x.match&&x.match[2]===kind);if(headings.length>1)return null;if(!headings.length)return new Set();const h=headings[0],values=new Set();for(let i=h.index+1;i<section.length;i++){if(section[i].trim()&&section[i].match(/^\s*/)[0].length<=h.match[1].length)break;const token=section[i].trim();if(!token)continue;const value=component(token);if(!value)return null;values.add(value);}return values;};
 const enabled=membership("enabledComponents"),disabled=membership("disabledComponents");if(!enabled?.size||!disabled)return false;
 const filters=text.split(/(?=^\s*[a-f0-9]+\s+[\w.]+\/[\w.$]+\s+filter\s)/m);
 const candidates=filters.slice(1).map(block=>{
  const owner=block.match(/^\s*[a-f0-9]+\s+([\w.]+\/[\w.$]+)\s+filter\s/m)?.[1],activity=owner?component(owner):null;
  return activity&&enabled.has(activity)&&!disabled.has(activity)&&/^\s*Action: "android.intent.action.OPEN_DOCUMENT"\s*$/m.test(block)&&/^\s*Category: "android.intent.category.OPENABLE"\s*$/m.test(block)&&/^\s*(?:StaticType|Type): (?:"\*\/\*"|\*\/\*)\s*$/m.test(block)?activity:null;
 });
 const qualified=[...new Set(candidates.filter(Boolean))];return qualified.length===1?qualified[0]:null;
}
async function ready(name,timeout=10000) {
 const end=Math.min(actionDeadline,Date.now()+timeout);let s;
 do{s=await snapshot(name+"-"+Date.now());if(s.pkg===APP&&s.appState===4&&nodes(s.xml).some(x=>label(x)==="Send")&&nodes(s.xml).some(x=>label(x)==="Receive")){acceptWithin();return s;}await sleep(250);}while(Date.now()<end);
 throw Error("Responsive ordinary app home not qualified");
}
async function fileObservation(name) {
 await tap("Receive");await tap("Send");await tap("File",APP,true);const end=conditionDeadline;let result;const finish=value=>{conditionDeadline=null;return value;};
 do {
  const s=await snapshot(name+"-"+Date.now());
  const picker=["com.google.android.documentsui","com.android.documentsui"].includes(s.pkg)&&nodes(s.xml).some(x=>x.package===s.pkg&&x.bounds);
  const crashDialog=nodes(s.xml).some(x=>/LocalSend closed|LocalSend keeps stopping|LocalSend has stopped/i.test(label(x)));
  const launcher=/launcher|nexuslauncher|touchwiz/i.test(s.pkg);
  acceptWithin();result={utc:new Date().toISOString(),pkg:s.pkg,appState:s.appState,pickerCandidate:picker,crashDialog,launcher};report.observations.push(result);save("result.json",report);acceptWithin();
  if(picker){report.handlerQualification="observed real document picker, original PNG inspection pending";return finish("picker-observed");}
  if(crashDialog||launcher&&s.appState<=2)return finish("crash-symptom-observed");
  await sleep(Math.min(250,Math.max(0,end-Date.now())));
 }while(Date.now()<end);
 return finish("ambiguous-timeout");
}
try {
 assert(process.env.GITHUB_ACTIONS==="true"&&process.env.GITHUB_REPOSITORY==="ShlomoCode/localsend"&&process.env.GITHUB_REF==="refs/heads/codex/diagnose-3147-file-picker"&&process.env.GITHUB_RUN_ATTEMPT==="1","Exact admitted fork attempt only");
 assert(user&&key&&/^bs:\/\/[\w-]+$/.test(app),"Private credentials and bound upload required");
 const receipt=json("support/diagnostics/3147/original-apk-binding.json");assert(receipt.sha256==="82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3"&&receipt.bytes===46558706&&receipt.uploadReferenceSha256===hash(app),"Unchanged official APK provenance mismatch");save("apk-binding.json",receipt);
 const lease=JSON.parse(process.env.ISSUE3147_LEASE_JSON),now=Date.now(),jobEnd=Date.parse(process.env.ISSUE3147_JOB_DEADLINE_UTC);
 assert(lease.issue===3147&&lease.head===process.env.GITHUB_SHA&&lease.branch==="codex/diagnose-3147-file-picker"&&lease.owner&&lease.id&&lease.rootExactSourceAcceptance===true&&lease.maximumConcurrentJobs===1&&lease.maximumJobMinutes===20&&lease.browserStackSlots===1&&lease.device==="Samsung Galaxy S22"&&lease.os==="Android12"&&lease.maximumDeviceMinutes===8&&lease.status==="admitted"&&Date.parse(lease.issuedAt)<=now&&now-Date.parse(lease.issuedAt)<300000&&Date.parse(lease.expiresAt)>now,"Fresh exact-head coordinator lease missing");save("lease.json",lease);
 assert(Number.isFinite(jobEnd)&&jobEnd-now>=12*60000,"Insufficient actual job reserve");
 deviceDeadline=Math.min(now+480000,jobEnd-360000);actionDeadline=deviceDeadline-60000;
 save("deadlines.json",{jobDeadlineUtc:new Date(jobEnd).toISOString(),deviceDeadlineUtc:new Date(deviceDeadline).toISOString(),observationDeadlineUtc:new Date(actionDeadline).toISOString(),cleanupStartUtc:new Date(actionDeadline).toISOString(),fallbackAndRetentionDeadlineUtc:new Date(jobEnd-180000).toISOString(),uploadDeadlineUtc:new Date(jobEnd).toISOString(),deviceClockIncludesCreate:true});
 const plan=(await request("GET","/app-automate/plan.json",undefined,{provider:true}));save("provider-plan.json",plan);
 const running=plan.parallel_sessions_running,queued=plan.queued_sessions,cap=plan.parallel_sessions_max_allowed;
 assert([running,queued,cap].every(Number.isInteger)&&running>=0&&queued>=0&&running+queued+2+1<=5&&running+queued+1<=cap,"Capacity gate including two unknown App Live holds failed");
 assert(Date.parse(lease.expiresAt)>Date.now(),"Lease expired before create");
 owned={issue:3147,runId:process.env.GITHUB_RUN_ID,runAttempt:"1",head:process.env.GITHUB_SHA,buildName:`issue3147-${process.env.GITHUB_RUN_ID}-attempt-1`,session:null,creationAttempted:true,deviceDeadlineUtc:new Date(deviceDeadline).toISOString()};
 writeFileSync(path.join(out,"ownership.json"),JSON.stringify(owned,null,2),{flag:"wx"});stage="one-session-create";
 await request("POST","/session",{capabilities:{alwaysMatch:{platformName:"Android","appium:automationName":"UiAutomator2","appium:deviceName":"Samsung Galaxy S22","appium:platformVersion":"12.0","appium:app":app,"appium:orientation":"PORTRAIT","bstack:options":{projectName:"LocalSend3147 short observation",buildName:owned.buildName,sessionName:"official1182-native-file-launch",video:true,debug:true,networkLogs:false,idleTimeout:60,resignApp:false}}}});
 assert(session,"Uncertain creation; reconcile unique build, never POST again");
 const metadata=(await request("GET",`/app-automate/sessions/${session}.json`,undefined,{provider:true})).automation_session;
 assert(metadata?.hashed_id===session&&metadata.device==="Samsung Galaxy S22"&&metadata.os?.toLowerCase()==="android"&&["12","12.0"].includes(String(metadata.os_version)),"Actual device identity mismatch");
 save("native-qualification.json",{device:metadata.device,android:metadata.os_version,oneUI:"unknown",nativeBuild:"unknown",installedVersion:"provenance-bound 1.18.2; native package readback unavailable",handlerBeforeFile:"unknown",providerDeviceIdentity:true});
 assert(await wd("POST","/appium/device/app_installed",{appId:APP})===true,"Normal installation unavailable");
 stage="read-only-native-package-qualification";
 const packageDump=await nativePackage(APP);
 const version=packageDump.match(/versionName=([^\s]+)/)?.[1];assert(version==="1.18.2","Native installed APK version unavailable or differs");report.installedVersion=version;
 const propsBody={script:"browserstack_executor: "+JSON.stringify({action:"adbShell",arguments:{command:"getprop ro.bootimage.build.fingerprint"}}),args:[]};
 const props=await wd("POST","/execute/sync",propsBody);save("native-build-properties.json",{command:propsBody,reply:props});
 const fingerprint=typeof props==="string"?props.trim():"";acceptWithin();
 report.nativeBuild=/^[^\s:/]+\/[^\s:/]+\/[^\s:]+:\d+(?:\.\d+)*\/[^\s:/]+\/[^\s:]+:(?:user|userdebug|eng)\/[^\s:/]+$/.test(fingerprint)?fingerprint:"unknown";
 const handlerCandidates=[];
 for(const handler of ["com.android.documentsui","com.google.android.documentsui"]) {
  const installed=await wd("POST","/appium/device/app_installed",{appId:handler});
  save("handler-installed-"+handler+".json",{handler,installed});
  if(installed===true){const dump=await nativePackage(handler);const component=registeredDocumentHandler(dump,handler);if(component)handlerCandidates.push({package:handler,component});}
 }
 acceptWithin();const handlerQualified=handlerCandidates.length===1;report.documentHandler=handlerQualified?handlerCandidates[0]:null;report.handlerQualification=handlerQualified?"Enabled installed User0 package registers exact OPEN_DOCUMENT/OPENABLE/* filter; native reply and PNG audit pending":"unknown: exact native handler filter not qualified";
 save("native-qualification.json",{device:metadata.device,android:metadata.os_version,oneUI:"unknown until native reply inspected",installedVersion:version,handlerQualified,documentHandler:report.documentHandler,normalPackageAndProviderIdentity:true});
 stage="ordinary-home-control";await ready("home");await tap("Send");await tap("Media");
 // Handle only an observed Android permission dialog through its native Allow resource.
 let media=await snapshot("media-open");
 if(["com.android.permissioncontroller","com.google.android.permissioncontroller"].includes(media.pkg)) {
  const allowed=nodes(media.xml).filter(x=>/permission_allow(?:_foreground_only)?_button$/.test(x["resource-id"]??"")&&x.package===media.pkg);
  assert(allowed.length===1&&label(allowed[0]),"Ambiguous permission prompt");await tap(label(allowed[0]),media.pkg);media=await snapshot("media-after-permission");
 }
 assert(media.pkg===APP&&nodes(media.xml).some(x=>label(x)==="Cancel")&&nodes(media.xml).some(x=>/Recent|Album|Albums/i.test(label(x))),"Media picker control not qualified");
 await tap("Cancel");await ready("media-cancel-return");report.mediaControl="picker-rendered-cancel-return, pixels pending";
 stage="exact-file-trigger";const first=await fileObservation("file-first");report.first=first;
 if(first==="picker-observed") {
  // A system Back action is permitted only after this live document-picker qualification.
  const s=await snapshot("picker-before-cancel");assert(["com.google.android.documentsui","com.android.documentsui"].includes(s.pkg),"Picker changed before normal cancellation");
  await wd("POST","/back");await ready("file-cancel-return");report.productVerdict="CURRENT_RELEASE_NON_REPRODUCTION_PENDING_PIXEL_AUDIT";
 }else if(first==="crash-symptom-observed") {
  report.productVerdict=handlerQualified?"CURRENT_RELEASE_CRASH_CANDIDATE_PENDING_PIXEL_LOG_AUDIT":"CRASH_SYMPTOM_HANDLER_UNQUALIFIED";
  const current=await snapshot("failure-repeat-readiness");
  if(handlerQualified&&!uncertain&&/launcher|nexuslauncher|touchwiz/i.test(current.pkg)&&current.appState<=2&&actionDeadline-Date.now()>90000) {
   await wd("POST","/appium/device/activate_app",{appId:APP});await ready("repeat-normal-launch");
   stage="identical-file-trigger-once";report.repeat=await fileObservation("file-identical-repeat");report.determinismRepetitions=1;
  }else report.repeatSkipped="Exact handler or clean native recovery state or absolute budget unavailable";

 }else report.productVerdict="AMBIGUOUS_OBSERVATION_STOP";
 report.status="observation-complete-independent-pixel-log-audit-required";save("result.json",report);
}catch(e){report.status="gate-or-observation-blocked";report.failureStage=stage;report.error=safe(e.message);save("result.json",report);process.exitCode=1;}
finally {
 if(session) {
  try{const r=await request("DELETE","/session/"+session,undefined,{cleanup:true});save("exact-delete.json",{session,completedUtc:new Date().toISOString(),acknowledged:!r.value?.error});}catch(e){save("delete-failed.json",{session,error:safe(e.message)});process.exitCode=1;}
  try{await retainProviderArtifacts({session,auth,output:out,privatePrefix:owned.buildName+"-",deadline:Date.parse(process.env.ISSUE3147_JOB_DEADLINE_UTC)-180000,redact:safe,save});}catch(e){save("retention-failure.json",{error:safe(e.message)});process.exitCode=1;}
 }
}
