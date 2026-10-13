import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {existsSync, readFileSync, writeFileSync, createWriteStream, mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import net from 'node:net';

const APP='org.localsend.localsend_app';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const id=element=>element['element-6066-11e4-a52e-4f735466cecf'];
const stamp=()=>({utc:new Date().toISOString(),monotonicMs:performance.now()});

export default async function({session,wd,senderHost,senderPort,transportStatus,relayRecord,relayTrace,budgetDeadline}) {
 mkdirSync('evidence',{recursive:true});
 const prefix=`/session/${session}`;
 const events=[];
 let sequence=0,originalPid=null,originalProcess=null,desktop=null,proxy=null,currentStage=null,firstError=null;
 const timings=[];
 const sockets=new Set();
 const hardEnd=Math.min(budgetDeadline??Infinity,Date.now()+25*60*1000);
 const record=(event,details={})=>{
  events.push({event,...stamp(),...details});
  writeFileSync('evidence/1982-events.json',JSON.stringify(events,null,2));
 };
 const save=(name,value)=>writeFileSync('evidence/1982-'+name+'.json',JSON.stringify(value,null,2));
 const relayMark=(event,details={})=>{if(typeof relayRecord==='function')relayRecord(event,{...stamp(),...details});};
 function remaining(end=hardEnd){const ms=Math.min(end,hardEnd)-Date.now();assert(ms>0,'Scenario deadline reached; stop without extending timings');return ms;}
 async function call(method,path,body,end=hardEnd){
  const started=stamp();
  const timeoutMs=Math.min(15000,remaining(end));
  try{
   const result=await wd(method,prefix+path,body,{timeoutMs});
   record('webdriver',{method,path,started,completed:stamp(),timeoutMs});
   remaining(end);
   return result;
  }catch(error){record('webdriver-failed',{method,path,started,completed:stamp(),timeoutMs,error:String(error)});throw error;}
 }
 async function shell(command,end=hardEnd){
  const started=stamp();
  try{
   const result=await call('POST','/execute/sync',{script:'browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),args:[]},end);
   record('read-only-native-command',{command,started,result});return result;
  }catch(error){record('read-only-native-unavailable',{command,started,error:String(error)});return {unavailable:String(error)};}
 }
 function processIdentity(value){
  const output=typeof value==='string'?value:value?.stdout??value?.result??value?.output;
  assert.equal(typeof output,'string','Current process dump is unavailable');
  assert(output.startsWith('ACTIVITY MANAGER RUNNING PROCESSES'),'Unexpected process dump format');
  const lines=output.split(/\r?\n/);
  const records=[];
  for(let i=0;i<lines.length;i++){
   const header=lines[i].match(/^  \*APP\* UID (\d+) ProcessRecord\{([a-f0-9]+) ([1-9]\d*):org\.localsend\.localsend_app\/(u\d+a\d+)\}$/);
   if(!header){
    assert(!/^  \*APP\*.*:org\.localsend\.localsend_app\//.test(lines[i]),'Unbound or malformed main-process record does not qualify');
    continue;
   }
   const body=[];
   for(let j=i+1;j<lines.length&&/^    /.test(lines[j]);j++)body.push(lines[j]);
   const details=body.join('\n');
   const pid=details.match(/^    pid=([1-9]\d*) starting=false$/m);
   const thread=details.match(/^    thread=(android\.app\.IApplicationThread\$Stub\$Proxy@[a-f0-9]+)$/m);
   const packages=details.match(/^    packageList=\{([^}]+)\}$/m);
   assert(pid&&pid[1]===header[3]&&thread&&packages?.[1].split(', ').includes(APP),'Process record is not a current bound LocalSend process');
   assert(!/killed=true|killedByAm=true|waitingToKill=(?!null)(\S+)/.test(details),'LocalSend process is terminating');
   records.push({uid:header[1],recordId:header[2],pid:header[3],user:header[4],thread:thread[1]});
  }
  assert.equal(records.length,1,'Exactly one current LocalSend process is required; historical or ambiguous records do not qualify');
  return records[0];
 }
 async function identity(expected,end=hardEnd){
  const packageName=await call('GET','/appium/device/current_package',undefined,end);
  const activity=await call('GET','/appium/device/current_activity',undefined,end);
  const rawProcess=await shell('dumpsys activity -p '+APP+' processes',end);
  record('native-process-dump',{expected,rawProcess});
  const observedProcess=processIdentity(rawProcess);
  const pid=observedProcess.pid;
  record('native-identity',{expected,packageName,activity,pid,observedProcess});
  if(originalPid===null){originalPid=pid;originalProcess=observedProcess;}
  assert.deepEqual(observedProcess,originalProcess,'Original receiver process identity changed; preserve evidence and stop');
  assert.equal(pid,originalPid,'Original receiver process changed; preserve evidence and stop');
  const expectedPackage=expected==='app'?packageName===APP:expected==='permission'?/^com\.(google\.)?android\.permissioncontroller$/.test(packageName):/^com\.(google\.)?android\.documentsui$/.test(packageName);
  assert(expectedPackage,'Native foreground package does not match requested action');
  return {packageName,activity,pid};
 }
 async function snapshot(label,end=hardEnd){
  const name=`1982-android-${label}-${sequence++}`;
  const source=await call('GET','/source',undefined,end);
  writeFileSync('evidence/'+name+'.xml',source);
  const screenshot=await call('GET','/screenshot',undefined,end);
  writeFileSync('evidence/'+name+'.png',Buffer.from(screenshot,'base64'));
  record('raw-ui-capture',{name});return source;
 }
 async function element(using,value,end=hardEnd,optional=false){
  let matches;
  try{matches=await call('POST','/elements',{using,value},end);}catch(error){if(optional&&/no such element/.test(String(error)))return null;throw error;}
  if(optional&&matches.length===0)return null;
  assert.equal(matches.length,1,'Native locator missing or ambiguous: '+value);
  const control=matches[0];
  assert.equal(await call('GET',`/element/${id(control)}/enabled`,undefined,end),true,'Native control disabled: '+value);
  assert.equal(await call('GET',`/element/${id(control)}/displayed`,undefined,end),true,'Native control hidden: '+value);
  return control;
 }
 async function click(using,value,label,expected='app',end=hardEnd){
  await identity(expected,end);
  await snapshot(label+'-before-input',end);
  const control=await element(using,value,end);
  const rect=await call('GET',`/element/${id(control)}/rect`,undefined,end);
  record('native-input-start',{label,using,value,rect,expected});
  await call('POST',`/element/${id(control)}/click`,{},end);
  record('native-input-return',{label});
 }
 async function waitMarker(name,end=hardEnd){
  while(!existsSync('evidence/'+name)){
   remaining(end);
   assert(desktop.exitCode===null,'Desktop native driver exited before '+name);
   await sleep(100);
  }
 }
 async function probes(stage){
  try{save(stage+'-logcat-chunk',await call('POST','/log',{type:'logcat'}));}
  catch(error){record('native-logcat-unavailable',{stage,error:String(error)});}

  for(const command of ['dumpsys activity -p '+APP+' activities','dumpsys activity -p '+APP+' processes']){
   await shell(command);
  }
  const observed=stamp();
  relayMark('1982-boundary',{stage,...observed});
  record('native-observation-boundary',{stage,...observed,transport:transportStatus(),relayTrace});
 }
 async function prepareAccept(stage,start){
  const end=start.wallMs+15000;
  const identityReceipt=await identity('app',end);
  const source=await snapshot(stage+'-accept-qualified',end);
  const input=JSON.parse(readFileSync(`evidence/1982-${stage}-input.json`,'utf8'));
  assert(source.includes(input.name),'Accept qualification lost this pending transfer');
  const control=await element('accessibility id','Accept',end);
  const rect=await call('GET',`/element/${id(control)}/rect`,undefined,end);
  record('accept-prequalified',{stage,controlId:id(control),rect,identityReceipt,elapsedMs:Date.now()-start.wallMs});
  return control;
 }
 async function timedAccept(stage,start,control){
  const targetWallMs=start.wallMs+20000;
  const delay=targetWallMs-Date.now();
  assert(delay>0,'Accept preparation exhausted the five-second reserve');
  await sleep(delay);
  const timeoutMs=Math.min(15000,remaining());
  const requestStart={...stamp(),wallMs:Date.now()};
  // Issue only the click at the target. All native qualification occurred by
  // 15s. A stale control is an explicit error; there is no relocation/retry.
  const request=wd('POST',`${prefix}/element/${id(control)}/click`,{},{timeoutMs});
  const lateMs=requestStart.wallMs-targetWallMs;
  const timing={stage,targetWallMs,requestStart,actualPendingMs:requestStart.wallMs-start.wallMs,actualMonotonicPendingMs:requestStart.monotonicMs-start.monotonicMs,lateMs,timingValid:lateMs>=0&&lateMs<=250,controlId:id(control),providerDeviceInputTimestamp:{unavailable:'WebDriver click response supplies no device input timestamp; request time is runner-side only'}};
  timings.push(timing);
  relayMark('1982-accept-request',timing);
  record('actual-accept-request-start',timing);
  await request;
  record('accept-return',{stage,...stamp(),actualElapsedMs:Date.now()-start.wallMs});
  save('timing',timings);
  if(!timing.timingValid){
   save('timing-inconclusive',{reason:'Actual Accept request was outside the approved 20,000–20,250ms request interval; pair cannot qualify',timings});
   throw new Error('Accept timing inconclusive; stop without changing target or repeating');
  }
 }
 async function observeSender(stage,end){
  if(!stage||!existsSync(`evidence/1982-${stage}-requested`))return null;
  writeFileSync(`evidence/1982-${stage}-observe`,'Read-only sender outcome observation; no retry or further product input.\n');
  const path=`evidence/1982-${stage}-sender-result.json`;
  while(!existsSync(path)&&Date.now()<end&&desktop?.exitCode===null)await sleep(100);
  if(existsSync(path))return JSON.parse(readFileSync(path,'utf8'));
  return {unavailable:'Original sender did not produce its native outcome within observation budget',exitCode:desktop?.exitCode??null};
 }
 async function approval(stage,end=hardEnd){
  while(true){
   await identity('app',end);
   const accept=await element('accessibility id','Accept',end,true);
   if(accept){
    const found={...stamp(),wallMs:Date.now()};
    const source=await snapshot(stage+'-pending',end);
    const input=JSON.parse(readFileSync(`evidence/1982-${stage}-input.json`,'utf8'));
    assert(source.includes(input.name),'Approval does not identify this transfer fixture');
    return {source,...found};
   }
   await sleep(Math.min(200,remaining(end)));
  }
 }
 async function picker(stage,start){
  const end=start.wallMs+15000;
  await click('accessibility id','Options',stage+'-options','app',end);
  // c1ce ReceiveOptionsPage places exactly one destination edit button after
  // the Save to folder heading, before the separate destination path text.
  await click('xpath','//*[@content-desc="Save to folder"]/following-sibling::android.widget.Button[1]',stage+'-destination-edit','app',end);
  await identity('documents',end);
  let source=await snapshot(stage+'-native-picker',end);
  assert(/text="(?:Use this folder|USE THIS FOLDER)"/.test(source),'Actual directory-selection footer absent; do not reopen or substitute a file browser');
  const breadcrumb='//*[(@text="Documents") and contains(@resource-id,"breadcrumb")]';
  if(!await element('xpath',breadcrumb,end,true)){
   // Use only observed native navigation semantics. Never infer a directory
   // from an arbitrary file-browser screen or a guessed hamburger position.
   if(!/text="(?:Internal storage|Internal shared storage|Galaxy S21|S21)"/.test(source)){
    await click('xpath','//*[@content-desc="Show roots" and @clickable="true"]',stage+'-native-storage-navigation','documents',end);
    await click('xpath','//*[@resource-id="android:id/title" and (@text="Internal storage" or @text="Internal shared storage" or @text="Galaxy S21" or @text="S21")]',stage+'-native-internal-storage','documents',end);
    source=await snapshot(stage+'-native-storage-root',end);
    assert(/text="(?:Internal storage|Internal shared storage|Galaxy S21|S21)"/.test(source),'Native internal storage root not qualified');
   }
   await click('xpath','//*[@text="Documents" and @resource-id="android:id/title"]',stage+'-native-documents','documents',end);
  }
  await element('xpath',breadcrumb,end);
  await click('xpath','//*[@text="Use this folder" or @text="USE THIS FOLDER"]',stage+'-use-folder','documents',end);
  source=await snapshot(stage+'-permission-or-return',end);
  if(/text="(?:Allow|ALLOW)"/.test(source)){
   await click('xpath','//*[@text="Allow" or @text="ALLOW"]',stage+'-allow','documents',end);
  }
  await identity('app',end);
  source=await snapshot(stage+'-selected-path',end);
  assert(/primary(?:%3A|:)Documents|\/storage\/emulated\/0\/Documents/.test(source),'Actual selected Documents path is absent');
  await identity('app',end);
  record('native-input-start',{label:stage+'-options-back',action:'native Back'});
  await call('POST','/back',{},end);
  await approval(stage,end);
  record('picker-returned',{elapsedMs:Date.now()-start.wallMs,reserveMs:start.wallMs+20000-Date.now()});
  assert(Date.now()<=end,'Picker return exceeded 15 seconds; do not extend the 20-second arm');
 }
 async function result(stage,directory,expected){
  const end=Math.min(hardEnd,Date.now()+30000);
  let source='',receiverError=false,receiverFinished=false,saved=null;
  const input=JSON.parse(readFileSync(`evidence/1982-${stage}-input.json`,'utf8'));
  let observationError=null;
  try{while(Date.now()<end){
   source=await snapshot(stage+'-result',end);
   receiverError=source.includes('Finished with error')||source.includes('Finished with errors');
   receiverFinished=/content-desc="100%?, Finished"/.test(source)&&[...source.matchAll(/content-desc="([^"]*)"/g)].some(m=>m[1].startsWith(input.name+'&#10;')&&m[1].endsWith('&#10;Done'));
   if(receiverError||receiverFinished)break;
   await sleep(250);
  }}catch(error){observationError=String(error);}
  save(stage+'-partial-outcome',{stage,receiverError,receiverFinished,observationError,source,...stamp()});
  // Signal independently observed sender outcome before any saved-file or
  // receive-Finished assertion can throw, including receive observation expiry.
  writeFileSync(`evidence/1982-${stage}-observe`,'Read actual sender outcome independently of receiver Finished and saved bytes.\n');
  try{saved=Buffer.from(await call('POST','/appium/device/pull_file',{path:directory+'/'+input.name}),'base64');}
  catch(error){record('saved-file-unavailable',{stage,path:directory+'/'+input.name,error:String(error)});}
  if(saved)writeFileSync(`evidence/1982-${stage}-saved.txt`,saved);
  const sender=await observeSender(stage,Math.min(hardEnd,Date.now()+10000));
  const outcome={stage,receiverError,receiverFinished,observationError,sender,path:directory+'/'+input.name,expectedSha256:sha(expected),savedSha256:saved?sha(saved):null,byteExact:saved?.equals(expected)??false,transport:transportStatus(),originalReceiverPid:originalPid,session};
  save(stage+'-result',outcome);record('arm-outcome',outcome);
  assert(outcome.byteExact&&receiverFinished&&sender.senderFinished&&!receiverError&&!sender.senderError,'Actual app outcome failed; stop and report original evidence, without resending');
  await waitMarker('1982-'+stage+'-sender-completed',Math.min(hardEnd,Date.now()+10000));
  await click('accessibility id','Done',stage+'-receiver-done');
  return outcome;
 }
 try{
  assert.equal(process.env.BS_DEVICE,'Samsung Galaxy S21');
  assert.equal(process.env.BS_OS,'11.0');
  await identity('app');
  await probes('before-control');
  desktop=spawn('dbus-run-session',['--','xvfb-run','-a','-s','-screen 0 1200x800x24','bash','support/diagnostics/1982/sender.sh'],{env:process.env});
  const log=createWriteStream('evidence/1982-desktop-process.log');desktop.stdout.pipe(log);desktop.stderr.pipe(log);
  await waitMarker('1982-desktop-stopped',Math.min(hardEnd,Date.now()+90000));
  proxy=net.createServer({allowHalfOpen:true},client=>{
   const remote=net.connect({host:senderHost,port:senderPort,allowHalfOpen:true});
   for(const socket of [client,remote]){sockets.add(socket);socket.once('close',()=>sockets.delete(socket));}
   client.pipe(remote);remote.pipe(client);
   client.on('error',error=>{record('proxy-error',{side:'client',error:String(error)});remote.destroy();});
   remote.on('error',error=>{record('proxy-error',{side:'remote',error:String(error)});client.destroy();});
  });
  await new Promise((resolve,reject)=>{proxy.once('error',reject);proxy.listen(53317,'127.0.0.1',resolve);});
  writeFileSync('evidence/transport-ready','Opaque transparent TCP forward ready\n');
  let expected=null;
  for(const stage of ['qualification','ordinary','picker']){
   currentStage=stage;
   await probes('before-'+stage);
   const plannedName=`issue1982-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT||'1'}-${stage}.txt`;
   for(const directory of ['/sdcard/Download','/sdcard/Documents']){
    let before;
    try{before=await call('POST','/appium/device/pull_file',{path:directory+'/'+plannedName});}
    catch(error){if(!/No such file or directory|does not exist/i.test(String(error)))throw error;before=null;}
    assert.equal(before,null,'Owned transfer destination already exists; saved evidence would be ambiguous');
    record('owned-path-absence',{stage,path:directory+'/'+plannedName});
   }
   writeFileSync(`evidence/1982-${stage}-go`,'Select and send this unique real file through the unchanged desktop app.\n');
   await waitMarker('1982-'+stage+'-requested',Math.min(hardEnd,Date.now()+90000));
   const input=JSON.parse(readFileSync(`evidence/1982-${stage}-input.json`,'utf8'));
   assert.equal(input.name,plannedName,'Sender selected an unexpected fixture');
   const bytes=readFileSync(input.path);
   if(expected===null)expected=bytes;else assert(bytes.equals(expected),'Fixture content changed between arms');
   const start=await approval(stage,Math.min(hardEnd,Date.now()+30000));
   record('pending-start',{stage,...start});
   relayMark('1982-pending-start',{stage,...start});
   if(stage==='picker')await picker(stage,start);
   if(stage==='qualification')await click('accessibility id','Accept',stage+'-accept');
   else await timedAccept(stage,start,await prepareAccept(stage,start));
   // A legitimate initial Android storage permission may occur only here.
   const source=await snapshot(stage+'-after-accept');
   if(stage==='qualification'&&source.includes('permission_allow_button')){
    const packageName=await call('GET','/appium/device/current_package');
    assert(/^com\.(google\.)?android\.permissioncontroller$/.test(packageName),'Unknown initial permission-controller package');
    await click('id',packageName+':id/permission_allow_button',stage+'-normal-storage-permission','permission');
   }
   await result(stage,stage==='picker'?'/sdcard/Documents':'/sdcard/Download',expected);
   await probes('after-'+stage);
  }
  const interarmRequestDeltaMs=timings.length===2?Math.abs(timings[0].actualPendingMs-timings[1].actualPendingMs):null;
  const matchedPairValid=timings.length===2&&timings.every(t=>t.timingValid)&&interarmRequestDeltaMs<=250;
  assert(matchedPairValid,'Observed Accept intervals do not qualify the selected matched pair');
  save('summary',{completedStages:['qualification','ordinary','picker'],matchedPairValid,interarmRequestDeltaMs,timings,targetPendingMs:20000,approvedRequestRangeMs:[20000,20250],approvedInterarmDeltaMs:250,pickerReturnDeadlineMs:15000,repeatedPair:false,immediateRetry:false,originalReceiverPid:originalPid,session,transport:transportStatus()});
 }catch(error){
  firstError=String(error);
  // Preserve the sender's actual endpoint/native state even when picker setup,
  // cloud latency, or the receive observation prevents a Finished assertion.
  let sender=null,senderObservationError=null;
  try{sender=await observeSender(currentStage,Math.min(hardEnd,Date.now()+10000));}
  catch(observationError){senderObservationError=String(observationError);}
  save('abort-observation',{stage:currentStage,error:firstError,sender,senderObservationError,...stamp()});
  writeFileSync('evidence/1982-abort',String(error));record('stop',{error:String(error)});throw error;
 }finally{
  writeFileSync('evidence/1982-final-cleanup','All product arms ended; identity-checked owned cleanup permitted.\n');
  for(const socket of sockets)socket.destroy();
  if(proxy?.listening)await new Promise(resolve=>proxy.close(resolve));
  if(desktop){
   // Cleanup uses the caller's reserved final ten minutes, independently of
   // the expired product budget, with its own strict 25-second wait bound.
   const cleanupEnd=Date.now()+25000;
   while(desktop.exitCode===null&&Date.now()<cleanupEnd)await sleep(100);
   let receipt=null,receiptError=null;
   try{receipt=JSON.parse(readFileSync('evidence/1982-desktop-cleanup.json','utf8'));}catch(error){receiptError=String(error);}
   const cleaned=desktop.exitCode!==null&&receipt?.ownedCleanupCompleted===true;
   const cleanupIssue=cleaned?null:'Original desktop driver did not complete verified bounded owned cleanup';
   save('desktop-driver-exit',{exitCode:desktop.exitCode,cleaned,receipt,receiptError,firstError,cleanupIssue,...stamp()});
   if(cleanupIssue&&!firstError)throw new Error(cleanupIssue);
  }
 }
}
