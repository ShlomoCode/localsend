import assert from 'node:assert/strict';
import {mkdirSync,readFileSync,writeFileSync,appendFileSync,existsSync,createWriteStream} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {relay} from '../cloud_transport/relay.mjs';

// Drive the unmodified apps. This 1 MiB control cannot establish 16GB throughput.
const here=path.dirname(fileURLToPath(import.meta.url));
const output=path.resolve(process.env.TRANSFER_EVIDENCE_DIRECTORY||'evidence/windows-transfer');
const windowsOutput=path.join(output,'windows');
mkdirSync(windowsOutput,{recursive:true});
const required=['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','BS_LOCAL_ID','RELAY_TOKEN','RELAY_APP','HELPER_APP','BASELINE_APP'];
for(const key of required) assert(process.env[key],key+' is required');
const secrets=required.filter(k=>k!=='BS_LOCAL_ID').map(k=>process.env[k]);
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
function redact(value){let s=String(value);for(const secret of [...secrets,auth])s=s.replaceAll(secret,'[redacted]');return s;}
const save=(name,value)=>writeFileSync(path.join(output,name),typeof value==='string'?redact(value):redact(JSON.stringify(value,null,2)));
const sleep=ms=>new Promise(ok=>setTimeout(ok,ms));
const report={status:'preparing',startedUtc:new Date().toISOString(),device:'Samsung Galaxy S20',android:'10.0',
 requestedOrientation:'PORTRAIT',initialObservedOrientation:null,cleanupErrors:[],snapshots:[],
 release:'1.18.2',scenario:'Actual 1 MiB MP4 Android File/Recent selection, favorite registration/send, Windows UI Accept and saved hash',
 boundaries:['Windows Server differs from reported Windows 10 Pro','Reverse cloud relay differs from reported shared LAN','1 MiB control cannot extrapolate stable throughput or 16GB behavior'],
 fixture:null,observations:[],actions:[],receiverExit:null,sendUtc:null,verifiedUtc:null,elapsedSendToVerifiedMs:null};
let session,receiver,receiverExit,receiverDone,receiverLogs=[],startedRelay=false,physicalServer;
const physicalSockets=new Set(),physicalCases=[],physicalTrace=[];
const r=relay({token:process.env.RELAY_TOKEN,reverseTargetPort:53317});
async function wd(method,url,body){
 const started=Date.now();
 const response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+url,{
  method,headers:{authorization:auth,'content-type':'application/json'},
  body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(120000)});
 const json=await response.json();
 // Never retain capabilities containing private uploaded-app references.
 appendFileSync(path.join(output,'wd-commands.jsonl'),redact(JSON.stringify({
  utc:new Date(started).toISOString(),method,path:url,body:url==='/session'?'[private capability references omitted]':body,
  status:response.status,elapsedMs:Date.now()-started}))+'\n');
 if(!response.ok||json.value?.error)throw Error('WebDriver '+response.status+' '+redact(json.value?.error||'invalid response')+' '+redact(String(json.value?.message||'').slice(0,600)));
 return json.value;
}
const base=()=>'/session/'+session;
async function source(){return wd('GET',base()+'/source');}
async function snap(name,xml){
 const text=xml||await source();save(name+'.xml',text);
 const png=Buffer.from(await wd('GET',base()+'/screenshot'),'base64');
 writeFileSync(path.join(output,name+'.png'),png);
 const pngValid=png.length>=24&&png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
 const hierarchy=nodes(text).find(n=>n.class==='hierarchy');
 report.snapshots.push({name,utc:new Date().toISOString(),width:pngValid?png.readUInt32BE(16):null,
  height:pngValid?png.readUInt32BE(20):null,sourceWidth:Number(hierarchy?.width)||null,sourceHeight:Number(hierarchy?.height)||null,
  primarypackage:nodes(text).find(n=>n.package)?.package||null});
 return text;
}
function decode(text){return text.replace(/&#x([0-9a-f]+);/gi,(_,n)=>String.fromCodePoint(parseInt(n,16)))
 .replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/&quot;/g,'"').replace(/&apos;/g,"'")
 .replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');}
function nodes(xml){return [...xml.matchAll(/<[^/!?][^>]*>/g)].map(m=>Object.fromEntries(
 [...m[0].matchAll(/([\w.:-]+)=(["'])(.*?)\2/g)].map(a=>[a[1],decode(a[3])])));}
function labels(xml){return nodes(xml).flatMap(n=>[n.text||'',n['content-desc']||'']);}
async function waitFor(predicate,timeout,message){
 const end=Date.now()+timeout;
 do {const xml=await source();if(predicate(xml))return xml;await sleep(1000);}while(Date.now()<end);
 throw Error(message);
}
function elementId(element){const id=element['element-6066-11e4-a52e-4f735466cecf']||element.ELEMENT;assert(id,'Missing WebDriver element ID');return id;}
async function touch(rect,label){
 assert(rect.width>0&&rect.height>0,'Control has no observable bounds: '+label);
 report.actions.push({utc:new Date().toISOString(),label,rect});
 await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'finger3556',parameters:{pointerType:'touch'},actions:[
  {type:'pointerMove',duration:0,origin:'viewport',x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},
  {type:'pointerDown',button:0},{type:'pause',duration:120},{type:'pointerUp',button:0}]}]});
}
async function tap(using,value){
 const element=await wd('POST',base()+'/element',{using,value});
 await touch(await wd('GET',base()+'/element/'+elementId(element)+'/rect'),value);
}
const click=name=>tap('accessibility id',name);
const ui=expression=>tap('-android uiautomator','new UiSelector().'+expression);
async function activate(appId){
 await wd('POST',base()+'/appium/device/activate_app',{appId});
 await wd('POST',base()+'/orientation',{orientation:'PORTRAIT'});
 report.actions.push({utc:new Date().toISOString(),label:'Request PORTRAIT after activation',appId,
  observedOrientation:await wd('GET',base()+'/orientation')});
}
function receiverResult(){
 const file=path.join(windowsOutput,'results.json');
 if(!existsSync(file))return null;
 try{return JSON.parse(readFileSync(file,'utf8'));}catch{return null;}
}
async function startReceiver(fixture){
 const stdout=createWriteStream(path.join(windowsOutput,'receiver.stdout.txt'));
 const stderr=createWriteStream(path.join(windowsOutput,'receiver.stderr.txt'));receiverLogs=[stdout,stderr];
 receiver=spawn('pwsh',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(here,'windows_receiver.ps1'),
  '-OutputDirectory',windowsOutput,'-TimeoutSeconds','900','-ExpectedBytes',String(fixture.bytes),'-ExpectedSha256',fixture.sha256],
  {windowsHide:true,stdio:['ignore','pipe','pipe']});
 receiver.stdout.pipe(stdout);receiver.stderr.pipe(stderr);
 receiverDone=new Promise(ok=>{
  receiver.once('error',error=>{receiverExit={spawnError:redact(error.message)};ok();});
  receiver.once('exit',(code,signal)=>{receiverExit={code,signal};ok();});
 });
 const end=Date.now()+180000;
 while(Date.now()<end){
  if(receiverExit)throw Error('Windows receiver exited before readiness; inspect its stdout/stderr/results');
  const ready=path.join(windowsOutput,'ready.json');
  if(existsSync(ready)){
   const state=JSON.parse(readFileSync(ready,'utf8'));
   if(state.ready===true){save('receiver-ready.json',state);return;}
  }
  await sleep(500);
 }
 throw Error('Windows receiver readiness exceeded 180 seconds');
}
function expectedControl(count){
 const bytes=Buffer.alloc(count);
 for(let i=0;i<count;i++)bytes[i]=(i*31+7)&255;
 return {count,sha256:createHash('sha256').update(bytes).digest('hex')};
}
async function stopPhysicalServer(){
 if(!physicalServer)return;
 const server=physicalServer;physicalServer=null;
 const closed=new Promise((ok,no)=>server.close(error=>error?no(error):ok()));
 const end=Date.now()+2000;
 while(physicalSockets.size&&Date.now()<end)await sleep(100);
 for(const socket of physicalSockets)socket.destroy();
 await closed;
 physicalTrace.push({utc:new Date().toISOString(),event:'temporary-control-server-closed'});
}
async function runPhysicalReverseControl(){
 const expected=[0,1,65537].map(expectedControl),metricsBefore=r.status();
 physicalServer=net.createServer({allowHalfOpen:true},socket=>{
  physicalSockets.add(socket);const index=physicalCases.length;
  const entry={index,openedUtc:new Date().toISOString(),expected:expected[index]||null,count:0,sha256:null,readHalfClosed:false,replyFlushed:false};
  physicalCases.push(entry);const hash=createHash('sha256');
  physicalTrace.push({utc:entry.openedUtc,event:'control-socket-open',index});
  socket.setTimeout(180000,()=>socket.destroy(new Error('Physical reverse control idle timeout')));
  socket.on('data',data=>{
   entry.count+=data.length;hash.update(data);
   physicalTrace.push({utc:new Date().toISOString(),event:'control-data',index,bytes:data.length,total:entry.count});
  });
  socket.once('end',()=>{
   entry.readHalfClosed=true;entry.readHalfClosedUtc=new Date().toISOString();entry.sha256=hash.digest('hex');
   entry.byteExact=entry.expected?.count===entry.count&&entry.expected?.sha256===entry.sha256;
   physicalTrace.push({utc:entry.readHalfClosedUtc,event:'control-readable-eof-before-reply',index,count:entry.count,sha256:entry.sha256});
   socket.end(JSON.stringify({count:entry.count,sha256:entry.sha256}),()=>{
    entry.replyFlushed=true;entry.replyFlushedUtc=new Date().toISOString();
    physicalTrace.push({utc:entry.replyFlushedUtc,event:'control-reply-flushed-after-half-close',index});
   });
  });
  socket.on('error',error=>{entry.error=redact(error.message);physicalTrace.push({utc:new Date().toISOString(),event:'control-socket-error',index,error:entry.error});});
  socket.once('close',()=>{physicalSockets.delete(socket);entry.closedUtc=new Date().toISOString();physicalTrace.push({utc:entry.closedUtc,event:'control-socket-close',index});});
 });
 await new Promise((ok,no)=>{physicalServer.once('error',no);physicalServer.listen(53317,'127.0.0.1',ok);});
 physicalTrace.push({utc:new Date().toISOString(),event:'temporary-control-server-listening',port:53317});
 await snap('reverse-control-before');await click('Run reverse byte control');
 const passed=await waitFor(s=>{
  const text=labels(s).join('\n');
  if(text.includes('REVERSE_CONTROL_FAILED'))throw Error('Physical reverse control failed; no actual transfer is attempted');
  return text.includes('REVERSE_CONTROL_PASSED counts=0,1,65537');
 },600000,'Physical reverse byte/half-close control timed out; no actual transfer is attempted');
 await snap('reverse-control-passed',passed);
 const details=labels(passed).find(v=>v.includes('REVERSE_CONTROL_PASSED counts=0,1,65537'));
 const native=JSON.parse(details.split('\n').find(line=>line.startsWith('['))||'null');
 assert(Array.isArray(native),'Android control result JSON missing');
 assert.deepEqual(native.map(c=>c.count),[0,1,65537],'Android control case counts differ');
 for(let i=0;i<expected.length;i++){
  assert.equal(native[i].sha256,expected[i].sha256,'Android control deterministic hash mismatch');
  assert.equal(native[i].replyAfterShutdownOutput,true);assert.equal(native[i].replyReadThroughEof,true);
 }
 await stopPhysicalServer();
 assert.equal(physicalCases.length,3,'Windows control case count differs');
 for(let i=0;i<expected.length;i++){
  assert.equal(physicalCases[i].count,expected[i].count);assert.equal(physicalCases[i].sha256,expected[i].sha256);
  assert(physicalCases[i].readHalfClosed&&physicalCases[i].replyFlushed&&!physicalCases[i].error,'Windows half-close response was not verified');
 }
 report.physicalReverseControl={status:'passed',scope:'Transport proof only; temporary TCP server and native helper, not LocalSend app reproduction',
  expected,android:native,windows:physicalCases,metricsBefore,metricsAfter:r.status()};
 save('reverse-physical-controls.json',report.physicalReverseControl);save('reverse-physical-trace.json',physicalTrace);
}
function visibleFavoriteFields(xml){
 return nodes(xml).filter(n=>{
  const bounds=(n.bounds||'').match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);
  return n.class==='android.widget.EditText'&&n.displayed==='true'&&n.enabled==='true'&&bounds&&
   Number(bounds[3])>Number(bounds[1])&&Number(bounds[4])>Number(bounds[2]);
 });
}
async function hideFavoriteKeyboard(stage){
 try{await wd('POST',base()+'/appium/device/hide_keyboard',{});}catch(error){
  const observed=await source();
  await snap('favorite-hide-keyboard-error-'+stage,observed);
  const keyboardAbsent=/keyboard.*(?:not.*(?:shown|open|present|visible)|already.*hidden)|no .*keyboard/i.test(error.message);
  if(!keyboardAbsent||visibleFavoriteFields(observed).length!==3)throw Error('Keyboard hide failed without an absent-keyboard message and three visible favorite fields: '+redact(error.message));
  report.actions.push({utc:new Date().toISOString(),label:'Keyboard hide error tolerated after observing three visible fields',stage,error:redact(error.message)});
 }
}
async function addFavorite(){
 await click('Favorites');await snap('favorites-before-add');await click('Add');
 // v1.18.2 auto-focuses IP. The keyboard can collapse all dialog fields in landscape.
 // Hide it before waiting for fields, including when the preceding app rotated the device.
 await hideFavoriteKeyboard('initial');
 await snap('favorite-edit-keyboard-hidden-initial');
 const xml=await waitFor(s=>visibleFavoriteFields(s).length===3,30000,'Favorite dialog must expose exactly three visible EditTexts');
 await snap('favorite-edit-before',xml);
 // v1.18.2 FavoriteEditDialog orders name, IP, and port; verify observed field bounds.
 const elements=await wd('POST',base()+'/elements',{using:'class name',value:'android.widget.EditText'});
 assert.equal(elements.length,3,'Unexpected favorite EditText count');
 const fields=[];
 for(const element of elements){const id=elementId(element);fields.push({id,rect:await wd('GET',base()+'/element/'+id+'/rect')});}
 fields.sort((a,b)=>a.rect.y-b.rect.y);
 assert(fields.every(f=>f.rect.width>0&&f.rect.height>0),'Favorite fields must be visible');
 const values=['issue3556-cloud-receiver','127.0.0.1','53318'];
 for(let i=0;i<fields.length;i++){
  await wd('POST',base()+'/element/'+fields[i].id+'/clear',{});
  await wd('POST',base()+'/element/'+fields[i].id+'/value',{text:values[i],value:[...values[i]]});
 }
 save('favorite-fields.json',fields.map((f,i)=>({rect:f.rect,value:values[i]})));
 await snap('favorite-edit-filled');
 await hideFavoriteKeyboard('before-confirm');
 const confirmSource=await waitFor(s=>nodes(s).some(n=>(n['content-desc']==='Confirm'||n.text==='Confirm')&&
  n.enabled==='true'&&n.displayed==='true'&&/\[\d+,\d+\]\[\d+,\d+\]/.test(n.bounds||'')),30000,'Confirm did not remain visible after hiding the native keyboard');
 const confirm=await wd('POST',base()+'/element',{using:'accessibility id',value:'Confirm'});
 assert.equal(await wd('GET',base()+'/element/'+elementId(confirm)+'/displayed'),true,'Confirm is not displayed');
 await snap('favorite-confirm-keyboard-hidden',confirmSource);
 await click('Confirm');
 const registered=await waitFor(s=>labels(s).some(v=>v.includes('issue3556-cloud-receiver')&&v.includes('127.0.0.1'))&&
  nodes(s).filter(n=>n.class==='android.widget.EditText').length===0,60000,'Favorite registration did not complete through the genuine relay');
 await snap('favorite-registered',registered);
}
try{
 const planResponse=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
 assert(planResponse.ok,'BrowserStack plan request failed');const plan=await planResponse.json();
 save('plan.json',{parallel_sessions_running:plan.parallel_sessions_running,parallel_sessions_max_allowed:plan.parallel_sessions_max_allowed});
 assert(Number.isFinite(plan.parallel_sessions_running)&&Number.isFinite(plan.parallel_sessions_max_allowed),'BrowserStack live capacity is unavailable');
 assert(plan.parallel_sessions_running<plan.parallel_sessions_max_allowed,'No live BrowserStack slot');
 await r.start();startedRelay=true;
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:{
  platformName:'Android','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0','appium:automationName':'UiAutomator2',
  'appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP,process.env.RELAY_APP],
  'appium:autoGrantPermissions':true,'appium:newCommandTimeout':1200,
  'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,idleTimeout:600,projectName:'LocalSend bug sprint',
   buildName:'issue3556-'+process.env.GITHUB_RUN_ID,sessionName:'issue3556-S20-to-Windows-1MiB-control',debug:true,video:true,networkLogs:false}},
  firstMatch:[{}]}});
 session=created.sessionId;assert(session,'No BrowserStack session ID');save('session.json',{session,device:report.device,android:report.android});
 await wd('POST',base()+'/orientation',{orientation:'PORTRAIT'});
 report.initialObservedOrientation=await wd('GET',base()+'/orientation');
 assert.equal(report.initialObservedOrientation,'PORTRAIT','The small transfer control requires initial portrait orientation');
 await wd('POST',base()+'/timeouts',{implicit:5000});
 await wd('POST',base()+'/appium/settings',{settings:{waitForIdleTimeout:1000,waitForSelectorTimeout:1000}});
 await snap('fixture-before');await click('Stage small video');
 const staged=await waitFor(s=>{const t=labels(s).join('\n');if(/FAILED|INSUFFICIENT_STORAGE/.test(t))throw Error('Fixture staging failed');return /READY name=.*\.mp4/.test(t);},60000,'Small video staging timed out');
 await snap('fixture-ready',staged);
 const details=labels(staged).find(v=>v.includes('READY name='));
 const name=details.match(/READY name=([^\n]+)/)?.[1],bytes=Number(details.match(/\nbytes=(\d+)/)?.[1]);
 const sha256=details.match(/\nsha256=([a-f0-9]{64})/)?.[1];
 assert(name&&name.endsWith('.mp4')&&sha256,'Fixture identity missing');assert.equal(bytes,1048576,'Control must be exactly 1 MiB');
 const mediaDurationMs=Number(details.match(/mediaDurationMs=(\d+)/)?.[1]);
 const decodedFrame=details.match(/decodedFrame=(\d+)x(\d+)/);
 assert(mediaDurationMs>0,'Fixture helper did not report positive video duration');
 assert(decodedFrame&&Number(decodedFrame[1])>0&&Number(decodedFrame[2])>0,'Fixture helper did not decode a video frame');
 report.fixture={name,bytes,sha256,mediaDurationMs,decodedFrame:{width:Number(decodedFrame[1]),height:Number(decodedFrame[2])},details};save('fixture.json',report.fixture);
 await activate('org.localsend.cloudtransport');await snap('relay-before');await click('Relay from LocalSend');
 await waitFor(s=>labels(s).some(v=>v.includes('Receiving LocalSend connections at localhost:53318')),30000,'Relay UI did not confirm reverse mode');
 await snap('relay-running');
 await runPhysicalReverseControl();
 // The temporary control server is fully closed before the real release binds TCP 53317.
 await startReceiver(report.fixture);
 await activate('org.localsend.localsend_app');
 await waitFor(s=>s.includes('org.localsend.localsend_app'),30000,'LocalSend did not activate');await snap('localsend-initial');
 await click('Send\nTab 2 of 3');await click('File');
 await waitFor(s=>s.includes('com.google.android.documentsui'),30000,'Android File picker did not appear');
 await snap('file-picker');await click('Show roots');
 const roots=await snap('file-picker-roots');
 const recent=nodes(roots).filter(n=>n.text==='Recent');assert(recent.length,'Recent root not observed');
 await ui('text("Recent").instance('+(recent.length-1)+')');
 await snap('file-picker-recent');await ui('textContains('+JSON.stringify(name)+')');
 const selected=await waitFor(s=>labels(s).some(v=>/Selection\nFiles: 1\nSize: 1\.0 MB/.test(v)),60000,'LocalSend did not show Selection, one file, and 1.0 MB');
 await snap('selected-one-file',selected);await addFavorite();
 const metricsBefore=r.status();report.sendUtc=new Date().toISOString();const sendStart=Date.now();
 // Favorite selection registers again and then startSession sends the already selected file.
 await ui('descriptionContains("issue3556-cloud-receiver")');
 await snap('send-first-frame');
 const end=sendStart+600000;let androidFinished=false,verifiedAt=null,waits=0;
 do{
  const xml=await source(),now=Date.now(),names=labels(xml);
  const anr=/isn.t responding|not responding/i.test(names.join('\n'));
  const finished=names.some(v=>v==='Finished'||v.startsWith('Finished\n'))&&!names.some(v=>v.includes('Finished with error'));
  await snap('transfer-'+String(report.observations.length).padStart(3,'0'),xml);
  if(finished)androidFinished=true;
  const result=receiverResult();
  if(result?.status==='saved-file-verified'&&!verifiedAt){
   verifiedAt=Number.isFinite(Date.parse(result.finishedUtc))?Date.parse(result.finishedUtc):now;
   report.verifiedUtc=new Date(verifiedAt).toISOString();report.elapsedSendToVerifiedMs=verifiedAt-sendStart;
   report.verificationObservationLagMs=now-verifiedAt;
  }
  report.observations.push({utc:new Date(now).toISOString(),elapsedMs:now-sendStart,anr,androidFinished:finished,receiverStatus:result?.status,transport:r.status()});
  save('transfer-progress.json',report);
  if(anr){waits++;await ui('textMatches("(?i)wait")');}
  if(receiverExit&&receiverExit.code!==0)throw Error('Windows receiver failed; inspect results and both UI states');
  if(androidFinished&&verifiedAt){
   const saved=result.savedFiles.find(f=>f.bytes===bytes&&f.sha256.toLowerCase()===sha256);
   assert(saved,'Windows result does not contain the actual fixture bytes/hash');assert(result.actions.some(a=>a.name==='Accept'),'Windows real Accept action missing');
   await Promise.race([receiverDone,sleep(5000)]);
   assert.equal(receiverExit?.code,0,'Verified Windows receiver did not exit successfully');
   report.status='passed';report.anrWaitActions=waits;
   const metricsAfter=r.status();
   report.transport={before:metricsBefore,after:metricsAfter,
    windowsToAndroidBytes:metricsAfter.fromSender-metricsBefore.fromSender,
    androidToWindowsBytes:metricsAfter.fromDevice-metricsBefore.fromDevice,
    scope:'Transport counts include TLS and protocol traffic. Elapsed time includes registration, approval, network, saving, and up to 5s polling delay; 1 MiB only.'};
   await snap('android-finished',xml);break;
  }
  await sleep(5000);
 }while(Date.now()<end);
 assert.equal(report.status,'passed','Ten-minute app-to-app control did not reach Android Finished and verified Windows save');
 console.log('1 MiB Android-to-Windows app control passed; no 16GB or stable-throughput claim.');
}catch(error){
 report.status='incomplete';report.error=redact(error.stack||error);
 if(session)await snap('failure').catch(()=>{});
 process.exitCode=1;
}finally{
 try{await stopPhysicalServer();}catch(error){report.cleanupErrors.push('Temporary control server stop: '+redact(error.message));process.exitCode=1;}
 if(receiver&&!receiverExit){
  writeFileSync(path.join(windowsOutput,'stop'),'stop');
  await Promise.race([receiverDone,sleep(15000)]);
  if(!receiverExit){
   // A blocked UI Automation call must not leave this receiver's application child behind.
   const killer=spawn('taskkill.exe',['/PID',String(receiver.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});
   await Promise.race([new Promise(ok=>{killer.once('exit',ok);killer.once('error',ok);}),sleep(10000)]);
   await Promise.race([receiverDone,sleep(5000)]);
  }
 }
 report.receiverExit=receiverExit;report.finishedUtc=new Date().toISOString();
 for(const log of receiverLogs)log.end();
 if(session){
  try{await wd('DELETE',base());}catch(error){
   report.cleanupErrors.push('Owned session delete: '+redact(error.message));
   // Retry only this owned session; a relay shutdown failure must not skip its release.
   try{await wd('DELETE',base());}catch(retryError){report.cleanupErrors.push('Owned session delete retry: '+redact(retryError.message));process.exitCode=1;}
  }
 }
 if(startedRelay){try{await r.stop();}catch(error){report.cleanupErrors.push('Relay stop: '+redact(error.message));process.exitCode=1;}}
 save('reverse-physical-controls.json',report.physicalReverseControl||{status:'incomplete',scope:'Transport proof only; actual LocalSend transfer gate not passed',windows:physicalCases});
 save('reverse-physical-trace.json',physicalTrace);
 save('relay-trace.json',r.trace);save('relay-final-status.json',r.status());save('results.json',report);
}

