import assert from 'node:assert/strict';
import {mkdirSync,readFileSync,writeFileSync,appendFileSync,existsSync,createWriteStream} from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {relay} from '../cloud_transport/relay.mjs';
import {runScenario} from './android-scenario.mjs';

// Temporary diagnostic: unmodified official apps, supported storage APIs, one owned physical session.
const minute=60000,output=path.resolve('evidence/issue2096');mkdirSync(output,{recursive:true});
for(const key of ['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','HELPER_APP','RELAY_APP','BASELINE_APP','BS_LOCAL_ID','RELAY_TOKEN','WINDOWS_EXECUTABLE','JOB_DEADLINE_UTC','ADMISSION_UTC','RESERVATION_ID','EXPECTED_HEAD'])assert(process.env[key],key+' required');
assert.equal(process.env.GITHUB_REPOSITORY,'ShlomoCode/localsend','Fork-only diagnostic');
assert.equal(process.env.GITHUB_SHA,process.env.EXPECTED_HEAD,'Admission must bind the exact reviewed source');
assert.equal(process.env.GITHUB_RUN_ATTEMPT,'1','A rerun cannot reuse a consumed one-session admission');
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const secrets=[auth,...['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','HELPER_APP','RELAY_APP','BASELINE_APP','RELAY_TOKEN'].map(k=>process.env[k])];
function redact(value){let s=String(value);for(const secret of secrets)s=s.replaceAll(secret,'[redacted]');return s;}
const save=(name,value)=>writeFileSync(path.join(output,name),redact(typeof value==='string'?value:JSON.stringify(value,null,2)));
const sleep=ms=>new Promise(ok=>setTimeout(ok,ms));
const jobEnd=Date.parse(process.env.JOB_DEADLINE_UTC);assert(Number.isFinite(jobEnd),'Invalid job deadline');
const activeEnd=jobEnd-10*minute;
let deadline=activeEnd,session,creationAttempted=false,relayStarted=false,receiver,receiverExit,receiverDone,deviceStart;
let wdBusy=false;const actions=[],commands=[],snapshots=[];
const report={issue:2096,status:'preparing',head:process.env.GITHUB_SHA,runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT,
 reservationId:process.env.RESERVATION_ID,requestedDevice:'Samsung Galaxy S20',requestedAndroid:'10.0',release:'1.16.1',startedUtc:new Date().toISOString(),
 limits:{jobEndUtc:new Date(jobEnd).toISOString(),activeEndUtc:new Date(activeEnd).toISOString(),deviceActiveMaxMinutes:35,cleanupReserveMinutes:10,maxProviderSessions:1},
 boundaries:['Reporter model, OS, provider and exact tree grant are unknown.','Windows Server 2022 and reverse HTTP relay differ from an ordinary shared LAN.'],cases:[],cleanupErrors:[]};
const ownedBuild='issue2096-'+process.env.GITHUB_RUN_ID+'-attempt-'+process.env.GITHUB_RUN_ATTEMPT;
const r=relay({token:process.env.RELAY_TOKEN,reverseTargetPort:53317,transport:'legacy'});
const base=()=>'/session/'+session;
async function api(endpoint){const response=await fetch('https://api-cloud.browserstack.com/app-automate/'+endpoint,{headers:{authorization:auth},signal:AbortSignal.timeout(Math.min(30000,deadline-Date.now()))});assert(response.ok,'Provider metadata '+response.status);return response.json();}
async function wd(method,url,body,readEnd=deadline){
 assert(!wdBusy,'WebDriver calls must remain serial');const started=Date.now();
 const limit=url==='/session'?180000:url.endsWith('/source')?15000:30000;
 const timeout=Math.floor(Math.min(limit,deadline-Date.now(),readEnd-Date.now()));assert(timeout>0,'Diagnostic phase deadline expired');wdBusy=true;
 const event={utc:new Date(started).toISOString(),method,path:url,body:url==='/session'?'[private capability references omitted]':body};
 try{const response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+url,{method,headers:{authorization:auth,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(timeout)});
  const json=await response.json();event.status=response.status;
  assert(response.ok&&!json.value?.error,'WebDriver '+response.status+' '+redact(json.value?.message||json.value?.error||'failed'));return json.value;
 }catch(error){event.error=redact(error.message);throw error;}
 finally{event.elapsedMs=Date.now()-started;commands.push(event);appendFileSync(path.join(output,'wd-commands.jsonl'),redact(JSON.stringify(event))+'\n');wdBusy=false;}
}
const source=async readEnd=>{assert(Date.now()<Math.min(readEnd??deadline,deadline),'Observation deadline expired');return wd('GET',base()+'/source',undefined,readEnd??deadline);};
async function snap(name,xml){xml??=await source();save(name+'.xml',xml);const png=Buffer.from(await wd('GET',base()+'/screenshot'),'base64');
 assert(png.length>24&&png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])),'Invalid provider PNG');writeFileSync(path.join(output,name+'.png'),png);
 snapshots.push({name,utc:new Date().toISOString(),width:png.readUInt32BE(16),height:png.readUInt32BE(20)});return xml;}
async function touch(rect,label){assert(rect.width>0&&rect.height>0,'Observed input bounds missing');actions.push({utc:new Date().toISOString(),label,rect});save('input-events.json',actions);
 await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'finger2096',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,origin:'viewport',x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},{type:'pointerDown',button:0},{type:'pause',duration:120},{type:'pointerUp',button:0}]}]});}
async function activate(appId){await wd('POST',base()+'/appium/device/activate_app',{appId});}
function decode(s){return s.replace(/&#x([0-9a-f]+);/gi,(_,n)=>String.fromCodePoint(parseInt(n,16))).replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');}
function labels(xml){return [...xml.matchAll(/(?:text|content-desc)="([^"]*)"/g)].map(m=>decode(m[1]));}
async function stopReceiver(){
 if(receiver&&!receiverExit){writeFileSync(path.join(receiver.output,'stop'),'stop');await Promise.race([receiverDone,sleep(5000)]);
  if(!receiverExit){const killer=spawn('taskkill.exe',['/PID',String(receiver.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});await Promise.race([new Promise(ok=>{killer.once('exit',ok);killer.once('error',ok);}),sleep(5000)]);await Promise.race([receiverDone,sleep(1000)]);}}
 receiver=null;
}
async function transfer(request,sendAction){
 await stopReceiver();assert(Date.now()+150000<deadline,'Insufficient active budget for receiver setup and bounded transfer');
 const caseDir=path.join(output,'windows',request.caseName);mkdirSync(caseDir,{recursive:true});
 assert(Array.isArray(request.manifest.files)&&request.manifest.files.length>0&&request.manifest.files.length<=20,'Whole-root admitted manifest required');
 assert(request.manifest.files.every(f=>f.owned===true&&f.sha256&&Number.isSafeInteger(f.bytes)),'Unrelated or unhashed files may not be sent');
 const manifestPath=path.join(caseDir,'expected.json');writeFileSync(manifestPath,JSON.stringify({...request.manifest,caseName:request.caseName,expectedNames:request.expectedNames},null,2));
 receiverExit=null;const receiverDeadline=Math.min(deadline,Date.now()+150000);
 receiver=spawn('pwsh',['-NoProfile','-File',path.resolve('support/diagnose_2096/windows_receiver.ps1'),'-Executable',process.env.WINDOWS_EXECUTABLE,'-OutputDirectory',caseDir,'-CaseManifest',manifestPath,'-DeadlineUtc',new Date(receiverDeadline).toISOString()],{windowsHide:false,stdio:['ignore','pipe','pipe']});receiver.output=caseDir;
 const out=createWriteStream(path.join(caseDir,'stdout.txt')),err=createWriteStream(path.join(caseDir,'stderr.txt'));receiver.stdout.pipe(out);receiver.stderr.pipe(err);
 receiverDone=new Promise(ok=>{receiver.once('exit',(code,signal)=>{receiverExit={code,signal};out.end();err.end();ok();});receiver.once('error',error=>{receiverExit={error:redact(error.message)};ok();});});
 const prepEnd=Date.now()+30000;while(!existsSync(path.join(caseDir,'ready.json'))){assert(!receiverExit,'Windows receiver preparation failed');assert(Date.now()<prepEnd,'Windows receiver readiness deadline');await sleep(500);}
 const ready=JSON.parse(readFileSync(path.join(caseDir,'ready.json'),'utf8'));assert(ready.ready===true,'Windows readiness receipt rejected');
 await activate('org.localsend.localsend_app');const sendUtc=new Date().toISOString();r.beginMeasurement(request.caseName);await sendAction();
 const end=Math.min(deadline,Date.now()+120000);let androidFinished=false,windows;
 while(Date.now()<end){const xml=await request.observe();const names=labels(xml);
  assert(!names.some(n=>n.includes('Finished with error')),'Android transfer error; retained actual UI');
  if(names.some(n=>n==='Finished'||n==='100, Finished'||n.startsWith('Finished\n'))){androidFinished=true;await snap(request.caseName+'-android-finished',xml);}
  if(existsSync(path.join(caseDir,'results.json'))){windows=JSON.parse(readFileSync(path.join(caseDir,'results.json'),'utf8'));if(windows.status==='saved-files-verified'&&androidFinished)break;}
  assert(!receiverExit||receiverExit.code===0,'Windows receive/verification failed');await sleep(2000);
 }
 assert(androidFinished&&windows?.status==='saved-files-verified','Actual apps did not finish and verify saved bytes in 120 seconds');
 assert(windows.actions?.some(a=>a.name==='Accept'),'Real Windows Accept action required');
 for(const expected of request.manifest.files)assert(windows.savedFiles?.some(f=>f.bytes===expected.bytes&&f.sha256?.toLowerCase()===expected.sha256.toLowerCase()),'Saved hash missing for '+expected.displayRelativePath);
 await Promise.race([receiverDone,sleep(5000)]);assert.equal(receiverExit?.code,0,'Verified receiver process must finish');
 const result={status:'saved-files-verified',androidFinished,receiverResult:windows,sendUtc,finishedUtc:new Date().toISOString(),transport:r.status()};report.cases.push({caseName:request.caseName,...result});save('case-results.json',report.cases);return result;
}
async function recoverStartup(){
 const end=Math.min(deadline-120000,Date.now()+300000),observations=[];
 while(Date.now()<end){
  const builds=(await api('builds.json')).map(v=>v.automation_build).filter(v=>v.name===ownedBuild);assert(builds.length<=1,'Ambiguous owned build identity');
  const sessions=builds.length?(await api('builds/'+builds[0].hashed_id+'/sessions.json')).map(v=>v.automation_session):[];assert(sessions.length<=1,'Ambiguous owned session identity');
  observations.push({utc:new Date().toISOString(),buildMatches:builds.length,sessions:sessions.map(v=>({id:v.hashed_id,status:v.status}))});save('owned-startup.json',observations);
  if(sessions.length){session=sessions[0].hashed_id;report.allocationResolution={status:'exact-owned-session-found',session,providerStatus:sessions[0].status};return;}
  await sleep(5000);
 }
 report.allocationResolution={status:'unconfirmed-no-owned-session-observed',buildName:ownedBuild,probes:observations.length,
  requirement:'Coordinator must preserve this possible allocation until exact owned build/session terminal evidence; absence from metadata is not proof of no late allocation.'};
 throw Error('Owned POST outcome remains unconfirmed after bounded metadata polling; reservation stays occupied');
}
async function retainProvider(){
 let info;const end=Math.min(deadline,Date.now()+90000);
 do{const metadata=await api('sessions/'+session+'.json');info=metadata.automation_session;if(info?.video_url)break;await sleep(3000);}while(Date.now()<end);
 assert(info,'Provider final session metadata missing');save('provider-final.json',{id:session,status:info.status,reason:info.reason,duration:info.duration,device:info.device,os:info.os,os_version:info.os_version,videoAvailable:!!info.video_url});
 for(const [field,file,max] of [['video_url','provider-original.mp4',64*1024*1024],['device_logs_url','provider-device.log',8*1024*1024],['appium_logs_url','provider-appium.log',8*1024*1024]]){
  assert(info[field],field+' missing');const response=await fetch(info[field],{headers:{authorization:auth},signal:AbortSignal.timeout(Math.min(90000,deadline-Date.now()))});assert(response.ok,'Provider retained artifact failed');
  const chunks=[];let bytes=0;for await(const chunk of response.body){bytes+=chunk.length;assert(bytes<=max,'Provider retained artifact byte cap');chunks.push(Buffer.from(chunk));}
  const raw=Buffer.concat(chunks);if(file.endsWith('.log'))save(file,raw.toString());else writeFileSync(path.join(output,file),raw);
  save(file+'.identity.json',{bytes,sha256:createHash('sha256').update(raw).digest('hex'),logsRedacted:file.endsWith('.log')});
 }
}
try{
 const admissionAge=Date.now()-Date.parse(process.env.ADMISSION_UTC);assert(admissionAge>=0&&admissionAge<10*minute,'Coordinator admission is stale');
 assert(activeEnd-Date.now()>15*minute,'Insufficient job time after source preparation; no device allocated');
 const plan=await api('plan.json');save('capacity-before-post.json',{running:plan.parallel_sessions_running,max:plan.parallel_sessions_max_allowed,unknownManualHolds:2});
 assert(Number.isInteger(plan.parallel_sessions_running)&&Number.isInteger(plan.parallel_sessions_max_allowed),'Fresh capacity unavailable');
 assert(plan.parallel_sessions_running<Math.min(3,plan.parallel_sessions_max_allowed),'Preserve two unknown manual holds and five combined slots');
 await r.start();relayStarted=true;deviceStart=Date.now();creationAttempted=true;deadline=Math.min(activeEnd,deviceStart+35*minute);
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:{platformName:'Android','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0','appium:automationName':'UiAutomator2','appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP,process.env.RELAY_APP],'appium:autoGrantPermissions':true,'appium:newCommandTimeout':300,
  'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,idleTimeout:300,projectName:'LocalSend bug sprint',buildName:ownedBuild,sessionName:'issue2096-official1161-Downloads-tree',debug:true,video:true,networkLogs:false}},firstMatch:[{}]}});
 session=created.sessionId;assert(session,'Provider creation response missing owned ID');save('session.json',{session,build:ownedBuild,head:process.env.GITHUB_SHA,runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT,creationUtc:new Date(deviceStart).toISOString()});
 await wd('POST',base()+'/orientation',{orientation:'PORTRAIT'});await wd('POST',base()+'/timeouts',{implicit:1000});await wd('POST',base()+'/appium/settings',{settings:{waitForIdleTimeout:1000,waitForSelectorTimeout:1000}});
 await activate('org.localsend.cloudtransport');const element=await wd('POST',base()+'/element',{using:'accessibility id',value:'Relay from LocalSend'});const id=element['element-6066-11e4-a52e-4f735466cecf']||element.ELEMENT;await touch(await wd('GET',base()+'/element/'+id+'/rect'),'Start own reverse relay');
 const readyEnd=Date.now()+45000;let ready=false;while(Date.now()<readyEnd){const xml=await source();save('relay-ready.xml',xml);const label=labels(xml).find(v=>v.startsWith('HELPER_SERVICE_STATUS\n'));if(label){const state=JSON.parse(label.slice('HELPER_SERVICE_STATUS\n'.length));save('relay-ready.json',state);ready=state.ready&&state.firstPullSucceeded&&state.listenerPort===53318;if(ready)break;}await sleep(1000);}assert(ready,'Owned relay did not establish supported reverse readiness');
 report.scenario=await runScenario({session,wd,base,source,snap,touch,activate,deadline,save,transfer,output,expectedSignerSha256:[process.env.EXPECTED_ANDROID_SIGNER_SHA256]});report.status='scenario-completed-awaiting-original-evidence-review';
}catch(error){report.status='incomplete';report.error=redact(error.stack||error);process.exitCode=1;}
finally{
 deadline=Math.min(jobEnd-30000,Date.now()+10*minute);
 await stopReceiver().catch(error=>report.cleanupErrors.push(redact(error.message)));
 if(!session&&creationAttempted)await recoverStartup().catch(error=>report.cleanupErrors.push('Owned allocation recovery: '+redact(error.message)));
 if(session){
  try{await activate('org.localsend.diagnose2096');const e=await wd('POST',base()+'/element',{using:'accessibility id',value:'CLEANUP_FIXTURES'});const id=e['element-6066-11e4-a52e-4f735466cecf']||e.ELEMENT;await touch(await wd('GET',base()+'/element/'+id+'/rect'),'Delete helper-owned fixture URIs only');
   const end=Math.min(deadline,Date.now()+30000);let cleaned=false;
   while(Date.now()<end){const xml=await source(end);const text=labels(xml).find(v=>v.startsWith('DIAG2096_JSON:'));if(text){const result=JSON.parse(text.slice('DIAG2096_JSON:'.length));if(result.status==='CLEANED'){assert(result.remaining?.length===0&&result.deleted?.every(v=>v.deletedRows===1||(v.deletedRows===0&&v.verifiedAbsent===true)),'Owned deletion receipt incomplete');report.fixtureCleanup=result;await snap('fixture-cleanup',xml);cleaned=true;break;}}await sleep(500);}
   assert(cleaned,'Owned fixture CLEANED receipt deadline');
  }catch(error){report.cleanupErrors.push('Fixture cleanup: '+redact(error.message));}
  for(const appId of ['org.localsend.localsend_app','org.localsend.diagnose2096','org.localsend.cloudtransport'])try{await wd('POST',base()+'/appium/device/terminate_app',{appId});}catch(error){report.cleanupErrors.push('Owned app terminate: '+redact(error.message));}
  try{await wd('DELETE',base());report.sessionDeleteReturnedUtc=new Date().toISOString();}catch(error){report.cleanupErrors.push('Owned delete unconfirmed: '+redact(error.message));}
  await retainProvider().catch(error=>{report.cleanupErrors.push('Retained original recording/logs: '+redact(error.message));process.exitCode=1;});
 }
 if(relayStarted)await r.stop().catch(error=>report.cleanupErrors.push('Relay cleanup: '+redact(error.message)));
 if(report.cleanupErrors.length)process.exitCode=1;
 report.finishedUtc=new Date().toISOString();save('relay-trace.json',r.trace);save('relay-final.json',r.status());save('snapshots.json',snapshots);save('results.json',report);
}
