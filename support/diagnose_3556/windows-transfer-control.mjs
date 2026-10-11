import assert from 'node:assert/strict';
import {mkdirSync,readFileSync,writeFileSync,appendFileSync,existsSync,createWriteStream,unlinkSync,renameSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {relay} from '../cloud_transport/relay.mjs';
import shareScenario from './share-scenario.mjs';
import {runTransportControls} from './stream-controls.mjs';

// Drive the unmodified apps. The moderate control measures throughput; neither size proves 16GB behavior.
const largeDiagnostic=process.env.LARGE_TRANSFER_DIAGNOSTIC==='1';
const minute=60000,reserveBytes=2*1024*1024*1024;
let controlBytes=(largeDiagnostic||process.env.MODERATE_TRANSFER_CONTROL==='1')?64*1024*1024:1048576;
let controlName=controlBytes===1048576?'1 MiB':'64 MiB';
let controlSizeLabel=controlBytes===1048576?'1.0 MB':'67.1 MB';
const transportMode=process.env.RELAY_TRANSPORT||'legacy';
assert(['legacy','stream','coalesced'].includes(transportMode),'Unknown diagnostic transport mode');
if(transportMode!=='legacy')assert.equal(controlBytes,67108864,'Improved transport must run the exact 64 MiB original-app gate');
const here=path.dirname(fileURLToPath(import.meta.url));
const output=path.resolve(process.env.TRANSFER_EVIDENCE_DIRECTORY||'evidence/windows-transfer');
const windowsRoot=path.join(output,'windows');
let windowsOutput=largeDiagnostic?path.join(windowsRoot,'moderate'):windowsRoot;
mkdirSync(windowsOutput,{recursive:true});
const required=['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','BS_LOCAL_ID','RELAY_TOKEN','RELAY_APP','HELPER_APP','BASELINE_APP'];
for(const key of required) assert(process.env[key],key+' is required');
const secrets=required.filter(k=>k!=='BS_LOCAL_ID').map(k=>process.env[k]);
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
function redact(value){let s=String(value);for(const secret of [...secrets,auth])s=s.replaceAll(secret,'[redacted]');return s;}
let artifactPrefix='';
const artifactName=name=>artifactPrefix&&!['results.json','relay-trace.json','relay-final-status.json','reverse-physical-controls.json','reverse-physical-trace.json'].includes(name)?artifactPrefix+name:name;
const save=(name,value)=>writeFileSync(path.join(output,artifactName(name)),typeof value==='string'?redact(value):redact(JSON.stringify(value,null,2)));
function publishCoordination(name,value){
 const destination=path.join(windowsOutput,name),temporary=destination+'.tmp';
 // Same-directory rename exposes a complete receipt to the independent receiver.
 writeFileSync(temporary,JSON.stringify(value));renameSync(temporary,destination);
}
const sleep=ms=>new Promise(ok=>setTimeout(ok,ms));
const report={status:'preparing',startedUtc:new Date().toISOString(),device:'Samsung Galaxy S20',android:'10.0',
 requestedOrientation:'PORTRAIT',initialObservedOrientation:null,cleanupErrors:[],snapshots:[],
 release:'1.18.2',requestedTransport:transportMode,scenario:'Actual '+controlName+' MP4 Android File/Recent selection, favorite registration/send, Windows UI Accept and saved hash',
 boundaries:['Windows Server differs from reported Windows 10 Pro','Reverse cloud relay differs from reported shared LAN','One control cannot establish sustained 16GB throughput or behavior'],
 fixture:null,observations:[],actions:[],receiverExit:null,sendUtc:null,verifiedUtc:null,elapsedSendToVerifiedMs:null};
let session,receiver,receiverExit,receiverDone,receiverLogs=[],startedRelay=false,physicalServer;
let sessionCreationAttempted=false,sessionStart=null,phaseDeadline=Infinity,wdBusy=false,imageCount=0,observationCount=0,sourceCount=0;
const androidSourceLimit=200,windowsObservationLimit=100;
let windowsImagesRemaining=60,windowsObservationsRemaining=windowsObservationLimit,windowsLargeReceiverStarted=false;
const sessionAge=()=>sessionStart===null?0:Date.now()-sessionStart;
function remaining(){return largeDiagnostic?Math.max(0,Math.min(phaseDeadline,sessionStart===null?Infinity:sessionStart+110*minute)-Date.now()):Infinity;}
function admit(){assert(!largeDiagnostic||sessionAge()<20*minute,'Large stage/controls/selection/Send admission exceeded session age 20 minutes');}
function commandLimit(url){if(url.endsWith('/source'))return 5*minute;if(/screenshot|current_package/.test(url))return minute;if(/context|orientation|attribute|rect|displayed|text|keyboard/.test(url))return 30000;return url==='/session'?5*minute:minute;}
const physicalSockets=new Set(),physicalCases=[],physicalTrace=[];
const r=relay({token:process.env.RELAY_TOKEN,reverseTargetPort:53317,transport:transportMode});
async function wd(method,url,body,attempt=0,readDeadline=Infinity,terminalRead=false){
 const started=Date.now();
 assert(!wdBusy,'WebDriver commands must remain serial');
 const timeout=Math.floor(Math.min(commandLimit(url),remaining(),readDeadline-Date.now()));assert(timeout>0,'WebDriver phase deadline expired');
 if(method==='GET'&&url.endsWith('/source')){
  assert(!largeDiagnostic||sourceCount<(terminalRead?androidSourceLimit:androidSourceLimit-4),'Android hierarchy read allocation exhausted');sourceCount++;
 }
 wdBusy=true;let response;
 try{
 response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+url,{
  method,headers:{authorization:auth,'content-type':'application/json'},
  body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(largeDiagnostic?timeout:(url==='/session'?300000:120000))});
 const json=await response.json();
 // Never retain capabilities containing private uploaded-app references.
 appendFileSync(path.join(output,'wd-commands.jsonl'),redact(JSON.stringify({
  utc:new Date(started).toISOString(),method,path:url,body:url==='/session'?'[private capability references omitted]':body,
  status:response.status,elapsedMs:Date.now()-started}))+'\n');
 if(!response.ok||json.value?.error)throw Error('WebDriver '+response.status+' '+redact(json.value?.error||'invalid response')+' '+redact(String(json.value?.message||'').slice(0,600)));
 return json.value;
 }catch(error){
  appendFileSync(path.join(output,'wd-commands.jsonl'),redact(JSON.stringify({
   utc:new Date(started).toISOString(),method,path:url,body:url==='/session'?'[private capability references omitted]':body,
   status:response?.status||null,elapsedMs:Date.now()-started,attempt,error:String(error.message||error)}))+'\n');
  // Provider gateway returned session-absent while its Appium log showed this GET succeeding.
  // Retry only reads; never replay a touch, input, session creation or deletion.
  if(method==='GET'&&response?.status===404&&/Session not started or terminated/i.test(error.message)&&attempt<2){
   wdBusy=false;await sleep(Math.min(1000,remaining()));return wd(method,url,body,attempt+1,readDeadline,terminalRead);
  }
  throw error;
 }finally{wdBusy=false;}
}
const base=()=>'/session/'+session;
async function source(readDeadline=Infinity,terminalRead=false){return wd('GET',base()+'/source',undefined,0,readDeadline,terminalRead);}
async function waitHelperState({ready,mode,previousInstance,name}){
 const marker='HELPER_SERVICE_STATUS\n';let observed;
 const xml=await waitFor(value=>{
  const text=labels(value).find(label=>label.includes(marker));if(!text)return false;
  observed=JSON.parse(text.slice(text.indexOf(marker)+marker.length));
  report.helperLifecycle??=[];
  if(report.helperLifecycle.length<120)report.helperLifecycle.push({utc:new Date().toISOString(),stage:name,
   servicePresent:observed.servicePresent,running:observed.running,ready:observed.ready,instance:observed.instance,
   transport:observed.transport,lifecycle:observed.lifecycle,listenerHost:observed.listenerHost,listenerPort:observed.listenerPort,
   firstPullSucceeded:observed.firstPullSucceeded,lastFailure:observed.lastFailure});
  if(!ready)return observed.servicePresent===false&&observed.running===false&&observed.ready===false;
  if(observed.lastFailure&&!observed.running)throw Error('Owned helper readiness failed: '+observed.lastFailure);
  return observed.servicePresent===true&&observed.running===true&&observed.ready===true&&observed.firstPullSucceeded===true
   &&observed.transport===mode&&observed.listenerHost==='127.0.0.1'&&observed.listenerPort===53318
   &&typeof observed.instance==='string'&&(!previousInstance||observed.instance!==previousInstance);
 },45000,'Owned helper did not reach observed '+name+' state before deadline');
 save('helper-lifecycle-'+name+'.json',observed);await snap('helper-lifecycle-'+name,xml);return observed;
}
async function recoverOwnedStartupSession(){
 // A timed-out POST can still allocate a device. Resolve only this unique Actions build.
 const get=async url=>{
  const timeout=Math.floor(Math.min(30000,remaining()));assert(timeout>0,'Owned startup recovery cleanup deadline expired');
  const response=await fetch('https://api-cloud.browserstack.com/app-automate/'+url,{
   headers:{authorization:auth},signal:AbortSignal.timeout(timeout)});
  assert(response.ok,'Owned startup lookup failed: '+response.status);return response.json();
 };
 const builds=await get('builds.json');
 const owned=builds.map(b=>b.automation_build).filter(b=>b.name==='issue3556-'+process.env.GITHUB_RUN_ID);
 assert(owned.length<=1,'Owned startup build identity is ambiguous');
 if(!owned.length)return;
 const sessions=(await get('builds/'+owned[0].hashed_id+'/sessions.json')).map(s=>s.automation_session);
 assert(sessions.length<=1,'Owned startup session identity is ambiguous');
 save('startup-session-status.json',sessions.map(s=>({id:s.hashed_id,status:s.status,reason:s.reason,duration:s.duration})));
 if(sessions[0]?.status==='running'){
  session=sessions[0].hashed_id;
  save('session.json',{session,recoveredAfterStartupFailure:true,device:report.device,android:report.android});
 }
}
async function snap(name,xml){
 const terminal=/android-finished|failure|transfer-error|hash-ready/.test(name);
 const text=xml||await source(Infinity,terminal);save(name+'.xml',text);
 if(largeDiagnostic&&imageCount>=(terminal?60:56)){report.snapshots.push({name:artifactName(name),utc:new Date().toISOString(),sourceOnly:true,reason:'Android image budget reserved or exhausted'});return text;}
 imageCount++;const png=Buffer.from(await wd('GET',base()+'/screenshot'),'base64');
 writeFileSync(path.join(output,artifactName(name+'.png')),png);
 const pngValid=png.length>=24&&png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
 const hierarchy=nodes(text).find(n=>n.class==='hierarchy');
 report.snapshots.push({name:artifactName(name),utc:new Date().toISOString(),width:pngValid?png.readUInt32BE(16):null,
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
async function waitFor(predicate,timeout,message,terminalRead=false){
 const end=Math.min(Date.now()+timeout,largeDiagnostic?phaseDeadline:Infinity);
 const poll=largeDiagnostic&&timeout>=3*minute?15000:1000;
 do {const xml=await source(end,terminalRead);if(predicate(xml))return xml;await sleep(Math.min(poll,Math.max(0,end-Date.now())));}while(Date.now()<end);
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
 if(largeDiagnostic&&fixture.bytes===16000000000)windowsLargeReceiverStarted=true;
 const timeoutSeconds=largeDiagnostic&&fixture.bytes===16000000000?Math.max(1,Math.floor((sessionStart+105*minute-Date.now())/1000)):900;
 const stdout=createWriteStream(path.join(windowsOutput,'receiver.stdout.txt'));
 const stderr=createWriteStream(path.join(windowsOutput,'receiver.stderr.txt'));receiverLogs=[stdout,stderr];
 receiver=spawn('pwsh',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(here,'windows_receiver.ps1'),
  '-OutputDirectory',windowsOutput,'-TimeoutSeconds',String(timeoutSeconds),'-ExpectedBytes',String(fixture.bytes),'-ExpectedName',fixture.name,'-ExpectedSha256',fixture.sha256||'',
  ...(largeDiagnostic?['-ImageLimit',String(windowsImagesRemaining),'-UiObservationLimit',String(windowsObservationsRemaining)]:[]),
  ...(largeDiagnostic&&fixture.bytes===16000000000?['-VerificationDeadlineUtc',new Date(sessionStart+105*minute).toISOString()]:[])],
  {windowsHide:true,stdio:['ignore','pipe','pipe']});
 receiver.stdout.pipe(stdout);receiver.stderr.pipe(stderr);
 receiverDone=new Promise(ok=>{
  receiver.once('error',error=>{receiverExit={spawnError:redact(error.message)};ok();});
  receiver.once('exit',(code,signal)=>{receiverExit={code,signal};ok();});
 });
 const end=Math.min(Date.now()+180000,largeDiagnostic?phaseDeadline:Infinity);
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
async function checkLargeStorage(button,requiredBytes,stage){
 const previous=Number(labels(await source()).find(t=>t.includes('storageCheckedUtcMs='))?.match(/storageCheckedUtcMs=(\d+)/)?.[1])||0;
 const requested=Date.now();await click(button);
 const xml=await waitFor(s=>labels(s).some(t=>Number(t.match(/storageCheckedUtcMs=(\d+)/)?.[1])>previous),30000,'Fresh Android capacity evidence missing at '+stage);
 const detail=labels(xml).find(t=>t.includes('storageCheckedUtcMs='));
 const availableBytes=Number(detail.match(/availableBytes=(\d+)/)?.[1]),checked=Number(detail.match(/storageCheckedUtcMs=(\d+)/)?.[1]);
 assert(Number.isSafeInteger(availableBytes)&&checked>previous&&Date.now()-requested<30000,'Stale Android capacity evidence at '+stage);
 report.largeStorageChecks??=[];report.largeStorageChecks.push({stage,availableBytes,requiredBytes,checkedUtc:new Date(checked).toISOString()});save('large-storage-checks.json',report.largeStorageChecks);
 assert(availableBytes>=requiredBytes,'Insufficient fresh Android capacity at '+stage);admit();
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
 physicalCases.length=0;
 const expected=[0,1,65537].map(expectedControl),metricsBefore=r.status();
 const attemptedTransport=r.status().transport;
 try{
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
 report.physicalReverseControl={status:'passed',transport:attemptedTransport,scope:'Transport proof only; temporary TCP server and native helper, not LocalSend app reproduction',
  expected,android:native,windows:structuredClone(physicalCases),metricsBefore,metricsAfter:r.status()};
 save('reverse-physical-controls.json',report.physicalReverseControl);save('reverse-physical-controls-'+r.status().transport+'.json',report.physicalReverseControl);save('reverse-physical-trace.json',physicalTrace);
 }finally{
  save('reverse-physical-attempt-'+attemptedTransport+'.json',{transport:attemptedTransport,
   status:report.physicalReverseControl?.transport===attemptedTransport?'passed':'incomplete',windows:structuredClone(physicalCases),metricsAfter:r.status()});
 }
}
async function gateImprovedTransport(){
 if(transportMode==='legacy')return;
 report.transportControls=[];
 try{
  report.transportControls.push(await runTransportControls({r,snap,click,waitFor,labels,save,sleep,output}));
 }catch(error){
  // Fallback is authorized only for the discriminating prefix/challenge streaming-route failure.
  const partial=error.nativeResult?.cases?.find(c=>c.case==='duplex'&&c.status==='failed');
  const prefix=Buffer.alloc(32768);for(let i=0;i<prefix.length;i++)prefix[i]=(i*31+11)&255;
  const prefixHash=createHash('sha256').update('TC1 duplex\n').update(prefix).digest('hex');
  if(r.status().transport!=='stream'||error.failedPhase!=='duplex-challenge-before-eof'||error.nativeErrorType!=='SocketTimeoutException'
    ||partial?.count!==32779||partial?.sha256!==prefixHash||partial?.receivedCount!==0)throw error;
  report.streamRouteFailure={phase:error.failedPhase,errorType:error.nativeErrorType,prefixCount:partial.count,prefixSha256:partial.sha256,
   reason:'Exact native prefix sent, then bounded challenge read timed out while source output remained open'};
  save('stream-route-fallback.json',report.streamRouteFailure);
  const previousInstance=report.initialHelperState.instance;
  await click('Stop helper');await waitHelperState({ready:false,name:'stream-stopped'});
  r.closePeers('Owned streaming route discriminator ended');
  const deadline=Date.now()+10000;
  while(r.status().peers||r.status().activeUploads){assert(Date.now()<deadline,'Owned stream peers failed bounded cleanup');await sleep(100);}
  r.setTransport('coalesced');
  await click('Relay from LocalSend (coalesced)');
  report.fallbackHelperState=await waitHelperState({ready:true,mode:'coalesced',previousInstance,name:'coalesced-ready'});
  await runPhysicalReverseControl();
  report.transportControls.push(await runTransportControls({r,snap,click,waitFor,labels,save,sleep,output}));
 }
 report.selectedTransport=r.status().transport;
 assert(report.transportControls.every(c=>c.status==='passed'),'All selected-mode synthetic gates must pass before original app');
 save('transport-gate-results.json',{selectedTransport:report.selectedTransport,streamRouteFailure:report.streamRouteFailure,
  controls:report.transportControls,physicalReverseControl:report.physicalReverseControl});
}
function visibleFavoriteFields(xml){
 return nodes(xml).filter(n=>{
  const bounds=(n.bounds||'').match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);
  return n.class==='android.widget.EditText'&&n.displayed==='true'&&n.enabled==='true'&&bounds&&
   Number(bounds[3])>Number(bounds[1])&&Number(bounds[4])>Number(bounds[2]);
 });
}
function favoriteEditorPresent(xml){
 const names=labels(xml);return names.includes('Add to favorites')&&names.includes('Confirm');
}
async function manualInputComparison(){
 const before=r.status();await click('Manual sending');
 const opened=await snap('manual-input-open',await waitFor(s=>labels(s).includes('Enter address'),30000,'Manual input dialog did not open'));
 if(nodes(opened).some(n=>(n['content-desc']==='IP Address'||n.text==='IP Address')&&n.clickable==='true'&&n.displayed==='true'))await click('IP Address');
 const xml=await waitFor(s=>nodes(s).filter(n=>n.class==='android.widget.EditText').length===1,30000,'Manual IP input must expose one field');
 await snap('manual-input-ip-mode',xml);
 const element=await wd('POST',base()+'/element',{using:'class name',value:'android.widget.EditText'}),id=elementId(element);
 await touch(await wd('GET',base()+'/element/'+id+'/rect'),'Focus single Manual IP input');
 assert.equal(await wd('GET',base()+'/element/'+id+'/attribute/focused'),'true','Manual input is not focused');
 await wd('POST',base()+'/element/'+id+'/clear',{});
 await wd('POST',base()+'/element/'+id+'/value',{text:'127.0.0.1',value:[...'127.0.0.1']});
 const observed=await snap('manual-input-focused-value');
 save('manual-input-comparison.json',{scope:'Input comparison only, Cancel without registration; Manual uses settings.port and cannot override relay port',
  expected:'127.0.0.1',fields:nodes(observed).filter(n=>n.class==='android.widget.EditText'),before,after:r.status()});
 await click('Cancel');
 await snap('manual-input-canceled',await waitFor(s=>labels(s).some(v=>v.includes('Selection\nFiles: 1\nSize: '+controlSizeLabel)),30000,'Selection did not return with '+controlSizeLabel+' after canceling Manual input'));
}
async function addFavorite(){
 await click('Favorites');await snap('favorites-before-add');await click('Add');
 const editor=await waitFor(favoriteEditorPresent,30000,'Favorite Add did not expose Add to favorites and Confirm');
 await snap('favorite-edit-before-keyboard-action',editor);
 const shown=await wd('GET',base()+'/appium/device/is_keyboard_shown');
 assert.equal(typeof shown,'boolean','Keyboard visibility must be observable');
 report.actions.push({utc:new Date().toISOString(),label:'Observe keyboard without hiding it',shown});
 // Portrait evidence exposes all fields and Confirm above the keyboard. A hide call dismissed the editor.
 const xml=await waitFor(s=>{
  assert(favoriteEditorPresent(s),'Favorite editor disappeared before field input');
  return visibleFavoriteFields(s).length===3;
 },30000,'Favorite dialog must expose exactly three visible EditTexts without hiding the keyboard');
 await snap('favorite-edit-before',xml);
 // v1.18.2 FavoriteEditDialog orders name, IP, and port; verify observed field bounds.
 const elements=await wd('POST',base()+'/elements',{using:'class name',value:'android.widget.EditText'});
 assert.equal(elements.length,3,'Unexpected favorite EditText count');
 const fields=[];
 for(const element of elements){const id=elementId(element);fields.push({id,rect:await wd('GET',base()+'/element/'+id+'/rect')});}
 fields.sort((a,b)=>a.rect.y-b.rect.y);
 assert(fields.every(f=>f.rect.width>0&&f.rect.height>0),'Favorite fields must be visible');
 const values=['issue3556-cloud-receiver','127.0.0.1','53318'];
 // Port first is the discriminator: focused input, then blur to Name and re-observe actual rendering.
 for(const i of [2,0,1]){
  const id=fields[i].id;
  assert.equal(await wd('GET',base()+'/element/'+id+'/displayed'),true,'Favorite field is no longer displayed before input');
  await snap('favorite-field-'+i+'-before-focus');
  await touch(await wd('GET',base()+'/element/'+id+'/rect'),'Focus favorite field '+i);
  assert.equal(await wd('GET',base()+'/element/'+id+'/attribute/focused'),'true','Favorite field did not gain actual focus');
  await snap('favorite-field-'+i+'-focused-before-value');
  await wd('POST',base()+'/element/'+id+'/clear',{});
  await wd('POST',base()+'/element/'+id+'/value',{text:values[i],value:[...values[i]]});
  fields[i].observedText=await wd('GET',base()+'/element/'+id+'/text');
  assert.equal(fields[i].observedText,values[i],'Favorite field did not retain the intended value');
  await snap('favorite-field-'+i+'-filled');
 }
 await touch(await wd('GET',base()+'/element/'+fields[0].id+'/rect'),'Blur Port and IP by focusing Name');
 assert.equal(await wd('GET',base()+'/element/'+fields[0].id+'/attribute/focused'),'true','Name must be focused to establish Port blur');
 const blurred=await snap('favorite-fields-after-blur');
 for(let i=0;i<fields.length;i++){
  fields[i].observedAfterBlur=await wd('GET',base()+'/element/'+fields[i].id+'/text');
  assert.equal(fields[i].observedAfterBlur,values[i],'Favorite value changed after focus left the field');
 }
 save('favorite-fields-after-blur.json',nodes(blurred).filter(n=>n.class==='android.widget.EditText'));
 save('favorite-fields.json',fields.map((f,i)=>({rect:f.rect,value:values[i],observedText:f.observedText,observedAfterBlur:f.observedAfterBlur})));
 await snap('favorite-edit-filled');
 const confirmSource=await waitFor(s=>nodes(s).some(n=>(n['content-desc']==='Confirm'||n.text==='Confirm')&&
  n.enabled==='true'&&n.displayed==='true'&&/\[\d+,\d+\]\[\d+,\d+\]/.test(n.bounds||'')),30000,'Confirm did not remain visible after filling the fields');
 const confirm=await wd('POST',base()+'/element',{using:'accessibility id',value:'Confirm'});
 assert.equal(await wd('GET',base()+'/element/'+elementId(confirm)+'/displayed'),true,'Confirm is not displayed');
 await snap('favorite-confirm-without-keyboard-hide',confirmSource);
 const registerBefore=r.status();await click('Confirm');
 const registered=await waitFor(s=>labels(s).some(v=>v.includes('issue3556-cloud-receiver')&&v.includes('127.0.0.1'))&&
  nodes(s).filter(n=>n.class==='android.widget.EditText').length===0&&r.status().opened>registerBefore.opened,60000,'Favorite registration did not complete through the genuine relay');
 save('favorite-registration-transport.json',{before:registerBefore,after:r.status()});
 await snap('favorite-registered',registered);
}
try{
 const planResponse=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
 assert(planResponse.ok,'BrowserStack plan request failed');const plan=await planResponse.json();
 save('plan.json',{parallel_sessions_running:plan.parallel_sessions_running,parallel_sessions_max_allowed:plan.parallel_sessions_max_allowed});
 assert(Number.isFinite(plan.parallel_sessions_running)&&Number.isFinite(plan.parallel_sessions_max_allowed),'BrowserStack live capacity is unavailable');
 assert(plan.parallel_sessions_running<plan.parallel_sessions_max_allowed,'No live BrowserStack slot');
 await r.start();startedRelay=true;
 sessionCreationAttempted=true;sessionStart=Date.now();if(largeDiagnostic)phaseDeadline=sessionStart+20*minute;
 report.sessionStartBeforePostUtc=new Date(sessionStart).toISOString();
 report.largeDeadlinePolicy=largeDiagnostic?{officialSessionMaxMinutes:120,admissionMinutes:20,transferSessionAgeMinutes:100,verificationAgeMinutes:105,cleanupAgeMinutes:110,observationsMax:300,imagesMax:120,androidImagesMax:60,androidHierarchyReadsMax:androidSourceLimit,windowsUiObservationsMax:windowsObservationLimit}:null;
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:{
  platformName:'Android','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0','appium:automationName':'UiAutomator2',
  'appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP,process.env.RELAY_APP],
  'appium:autoGrantPermissions':true,'appium:newCommandTimeout':1200,
  'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,idleTimeout:300,projectName:'LocalSend bug sprint',
   buildName:'issue3556-'+process.env.GITHUB_RUN_ID,sessionName:'issue3556-S20-to-Windows-'+controlName+'-'+transportMode,debug:true,video:true,networkLogs:false}},
  firstMatch:[{}]}});
 session=created.sessionId;assert(session,'No BrowserStack session ID');save('session.json',{session,device:report.device,android:report.android});
 await wd('POST',base()+'/orientation',{orientation:'PORTRAIT'});
 report.initialObservedOrientation=await wd('GET',base()+'/orientation');
 assert.equal(report.initialObservedOrientation,'PORTRAIT','The small transfer control requires initial portrait orientation');
 await wd('POST',base()+'/timeouts',{implicit:5000});
 await wd('POST',base()+'/appium/settings',{settings:{waitForIdleTimeout:1000,waitForSelectorTimeout:1000}});
 report.scenario=largeDiagnostic?'Actual 64 MiB control followed by valid 16,000,000,000-byte MP4 Android File/Recent selection, real Send, Windows Accept/save and late Android/Windows hash verification':report.scenario;
 if(largeDiagnostic)report.boundaries[2]='One large attempt through reverse cloud relay does not establish shared-LAN behavior';
 for(const passBytes of (largeDiagnostic?[67108864,16000000000]:[controlBytes])){
 controlBytes=passBytes;controlName=passBytes===16000000000?'16GB':passBytes===67108864?'64 MiB':'1 MiB';
 controlSizeLabel=passBytes===16000000000?'16.0 GB':passBytes===67108864?'67.1 MB':'1.0 MB';
 const largePass=passBytes===16000000000;admit();
 if(largePass){
  const moderateWindows=receiverResult();
  assert(moderateWindows?.status==='saved-file-verified'&&Number.isInteger(moderateWindows.imageCount)&&Number.isInteger(moderateWindows.uiObservationCount),'Moderate Windows evidence budget counters missing');
  assert(moderateWindows.imageCount>=0&&moderateWindows.imageCount<=60&&moderateWindows.uiObservationCount>=0&&moderateWindows.uiObservationCount<=windowsObservationLimit,'Moderate Windows evidence exceeded global allocation');
  windowsImagesRemaining=60-moderateWindows.imageCount;windowsObservationsRemaining=windowsObservationLimit-moderateWindows.uiObservationCount;
  report.windowsEvidenceBudget={moderateImages:moderateWindows.imageCount,moderateObservations:moderateWindows.uiObservationCount,largeImagesRemaining:windowsImagesRemaining,largeObservationsRemaining:windowsObservationsRemaining,maxImages:60,maxObservations:windowsObservationLimit};
  assert(windowsImagesRemaining>=6&&windowsObservationsRemaining>=1,'Moderate Windows control left insufficient evidence budget for large transfer');
  save('moderate-control-results.json',report);
  report.moderateControl={status:report.status,bytes:report.fixture.bytes,sha256:report.fixture.sha256,sendUtc:report.sendUtc,verifiedUtc:report.verifiedUtc,elapsedSendToVerifiedMs:report.elapsedSendToVerifiedMs,evidence:'moderate-control-results.json',windowsEvidenceBudget:report.windowsEvidenceBudget};
  artifactPrefix='large-';
  await activate('org.localsend.cloudtransport');await click('Stop helper');await waitHelperState({ready:false,name:'moderate-stopped'});
  r.closePeers('Moderate completion before fresh large instance');
  const resetEnd=Math.min(Date.now()+10000,phaseDeadline);while(r.status().peers||r.status().activeUploads){assert(Date.now()<resetEnd,'Moderate peers failed cleanup');await sleep(100);}
  r.setPeerLimit(90*minute);
  await click(r.status().transport==='coalesced'?'Relay from LocalSend (coalesced large)':'Relay from LocalSend (large)');
  report.largeHelperState=await waitHelperState({ready:true,mode:r.status().transport,previousInstance:(report.fallbackHelperState||report.initialHelperState).instance,name:'fresh-ready'});
  assert.equal(report.largeHelperState.peerAbsoluteMs,90*minute,'Large helper peer limit must be observed at 90 minutes');
  report.status='preparing';report.observations=[];report.sendUtc=null;report.verifiedUtc=null;report.elapsedSendToVerifiedMs=null;report.uploadStateAtAndroidFinished=null;report.verificationStarted=null;report.windowsCompletion=null;report.verificationDeadlineUtc=null;report.lateHash=null;report.uploadStateAtVerifiedSave=null;report.verificationObservationLagMs=null;report.transport=null;report.realTransferHelper=null;report.transferDeadlineUtc=null;
  windowsOutput=windowsRoot;mkdirSync(windowsOutput,{recursive:true});
  receiver=null;receiverExit=null;for(const log of receiverLogs)log.end();receiverLogs=[];
  // Keep moderate evidence; each receiver owns distinct destination and coordination markers.
  for(const file of ['ready.json','results.json','stop','sender-completed.json','expected-sha256.json','send-started.json','receiver-completed.json','verification-started.json'])if(existsSync(path.join(windowsOutput,file)))unlinkSync(path.join(windowsOutput,file));
  await activate('org.localsend.fixture3556');await checkLargeStorage('Refresh capacity',2*passBytes+reserveBytes,'before-stage');
 }
 await snap('fixture-before');await click(largePass?'Stage 16GB video':controlBytes===1048576?'Stage small video':'Stage 64MiB video');
 const staged=await waitFor(s=>{const t=labels(s).join('\n');if(/FAILED|INSUFFICIENT_STORAGE/.test(t))throw Error('Fixture staging failed');return /READY name=.*\.mp4/.test(t);},largePass?15*minute:60000,'Video staging timed out');
 await snap('fixture-ready',staged);
 const details=labels(staged).find(v=>v.includes('READY name='));
 const uri=details.match(/\nuri=([^\n]+)/)?.[1];
 const name=details.match(/READY name=([^\n]+)/)?.[1],bytes=Number(details.match(/\nbytes=(\d+)/)?.[1]);
 let sha256=details.match(/\nsha256=([a-f0-9]{64})/)?.[1];
 const availableBytes=Number(details.match(/availableBytes=(\d+)/)?.[1]);
 const totalBytes=Number(details.match(/totalBytes=(\d+)/)?.[1]);
 assert(name&&name.endsWith('.mp4')&&(largePass||sha256),'Fixture identity missing');assert.equal(bytes,controlBytes,'Control must have the requested exact size');
 assert(Number.isSafeInteger(availableBytes)&&availableBytes>=0&&Number.isSafeInteger(totalBytes)&&totalBytes>0,'Android fixture storage evidence missing');
 const mediaDurationMs=Number(details.match(/mediaDurationMs=(\d+)/)?.[1]);
 const decodedFrame=details.match(/decodedFrame=(\d+)x(\d+)/);
 assert(mediaDurationMs>0,'Fixture helper did not report positive video duration');
 assert(decodedFrame&&Number(decodedFrame[1])>0&&Number(decodedFrame[2])>0,'Fixture helper did not decode a video frame');
 report.fixture={name,uri,bytes,sha256,availableBytes,totalBytes,mediaDurationMs,decodedFrame:{width:Number(decodedFrame[1]),height:Number(decodedFrame[2])},details};save('fixture.json',report.fixture);
 if(!largePass){await activate('org.localsend.cloudtransport');await snap('relay-before');await click('Relay from LocalSend');
 report.initialHelperState=await waitHelperState({ready:true,mode:transportMode,name:transportMode+'-ready'});
 if(largeDiagnostic)assert.equal(report.initialHelperState.peerAbsoluteMs,15*minute,'Moderate helper peer limit must be observed at 15 minutes');
 await snap('relay-running');
 await runPhysicalReverseControl();
 await gateImprovedTransport();}
 // The temporary control server is fully closed before the real release binds TCP 53317.
 await startReceiver(report.fixture);
 await activate('org.localsend.localsend_app');
 await waitFor(s=>s.includes('org.localsend.localsend_app'),30000,'LocalSend did not activate');await snap('localsend-initial');
 if(largePass){
  const prior=await source();assert(labels(prior).includes('Done'),'Moderate completion did not expose actual Done control');await click('Done');
  await waitFor(s=>labels(s).includes('Send\nTab 2 of 3'),30000,'Moderate Done did not return to main app');
 }
 await click('Send\nTab 2 of 3');
 if(largePass){await activate('org.localsend.fixture3556');await checkLargeStorage('Check picker storage',bytes+reserveBytes,'before-file');await activate('org.localsend.localsend_app');}
 admit();await click('File');
 await waitFor(s=>s.includes('com.google.android.documentsui'),30000,'Android File picker did not appear');
 await snap('file-picker');await click('Show roots');
 const roots=await snap('file-picker-roots');
 const recent=nodes(roots).filter(n=>n.text==='Recent');assert(recent.length,'Recent root not observed');
 await ui('text("Recent").instance('+(recent.length-1)+')');
 await snap('file-picker-recent');await ui('textContains('+JSON.stringify(name)+')');
 const selected=await waitFor(s=>labels(s).some(v=>v.includes('Selection\nFiles: 1\nSize: '+controlSizeLabel)),largePass?Math.max(1,remaining()):60000,'LocalSend did not show Selection, one file, and '+controlSizeLabel);
 await snap('selected-one-file',selected);if(!largePass){await manualInputComparison();await addFavorite();}
 if(largePass){await activate('org.localsend.fixture3556');await checkLargeStorage('Refresh capacity',reserveBytes,'before-send');await activate('org.localsend.localsend_app');}
 const metricsBefore=r.status();
 r.beginMeasurement('Original '+controlName+' favorite-touch through Finished and verified save');
 // Favorite selection registers again and then startSession sends the already selected file.
 const favorite=await wd('POST',base()+'/element',{using:'-android uiautomator',value:'new UiSelector().descriptionContains("issue3556-cloud-receiver")'});
 const favoriteRect=await wd('GET',base()+'/element/'+elementId(favorite)+'/rect');
 admit();report.sendUtc=new Date().toISOString();const sendStart=Date.now();
 report.sendAdmissionAgeMs=sessionAge();
 if(largePass)publishCoordination('send-started.json',{started:true,utc:report.sendUtc,evidence:'large-selected-one-file.xml'});
 await touch(favoriteRect,'Select registered issue3556-cloud-receiver favorite');
 if(largePass)phaseDeadline=Math.min(sendStart+90*minute,sessionStart+100*minute);
 await snap('send-first-frame');
 let end=largePass?phaseDeadline:sendStart+600000;let androidFinished=false,transferCompleted=false,verifiedAt=null,waits=0,lastImage=0;
 const preservePeerDeadline=()=>{if(!largePass||transferCompleted)return;const expiry=Date.parse(r.status().earliestPeerExpiryUtc);if(Number.isFinite(expiry)){end=Math.min(end,expiry-5*minute);phaseDeadline=end;}report.transferDeadlineUtc=new Date(end).toISOString();};preservePeerDeadline();
 do{
  preservePeerDeadline();observationCount++;
  const observationStarted=Date.now();const xml=await source(end),now=Date.now(),names=labels(xml);
  const sourceElapsedMs=now-observationStarted;
  const observationGapMs=report.observations.length?now-Date.parse(report.observations.at(-1).utc):null;
  const anr=/isn.t responding|not responding/i.test(names.join('\n'));
  const finished=names.some(v=>v==='Finished'||v==='100, Finished'||v.startsWith('Finished\n'))&&!names.some(v=>v.includes('Finished with error'));
  const frame='transfer-'+String(report.observations.length).padStart(3,'0');
  if(!largeDiagnostic||now-lastImage>=6*minute||anr||finished||names.some(v=>v.includes('Finished with error'))){await snap(frame,xml);lastImage=now;}else save(frame+'.xml',xml);
  if(finished){androidFinished=true;report.uploadStateAtAndroidFinished??={utc:new Date(now).toISOString(),transport:r.status()};}
  if(finished&&!existsSync(path.join(windowsOutput,'sender-completed.json'))){
   assert(now<=end,'Android Finished was first observed after transfer deadline');
   await snap('android-finished',xml);
   publishCoordination('sender-completed.json',{completed:true,utc:new Date(now).toISOString(),evidence:artifactName('android-finished.xml'),bytes,name,uri});
  }
  const completionPath=path.join(windowsOutput,'receiver-completed.json');let windowsCompletion=null;
  if(existsSync(completionPath)){try{windowsCompletion=JSON.parse(readFileSync(completionPath,'utf8'));}catch{throw Error('Malformed Windows completion receipt');}}
  if(largeDiagnostic&&androidFinished&&windowsCompletion&&!report.verificationStarted){
   preservePeerDeadline();const gateNow=Date.now(),completedAt=Date.parse(windowsCompletion.utc);
   assert(windowsCompletion.completed===true&&windowsCompletion.bytes===bytes&&windowsCompletion.name===name,'Windows completion receipt fixture identity mismatch');
   assert(Number.isFinite(completedAt)&&completedAt>=sendStart&&completedAt<=end&&completedAt<=gateNow&&gateNow<=end,'Both actual completion receipts must be observed within transfer deadline');
   report.windowsCompletion=windowsCompletion;report.transferDeadlineUtc=new Date(end).toISOString();transferCompleted=true;
   if(largePass){phaseDeadline=sessionStart+105*minute;end=phaseDeadline;}
   report.verificationDeadlineUtc=new Date(Math.min(end,phaseDeadline)).toISOString();
   report.verificationStarted={started:true,utc:new Date(gateNow).toISOString(),deadlineUtc:report.verificationDeadlineUtc,bytes,name,uri};
   publishCoordination('verification-started.json',report.verificationStarted);
   if(largePass){
    await activate('org.localsend.fixture3556');await click('Hash owned fixture after completion');
    const hashed=await waitFor(s=>{const t=labels(s).join('\n');if(t.includes('HASH_FAILED'))throw Error('Late fixture hash failed');return t.includes('HASH_READY uri=');},15*minute,'Late Android hash did not finish before verification deadline',true);
    const detail=labels(hashed).find(t=>t.includes('HASH_READY uri='));
    const hash=detail.match(/sha256=([a-f0-9]{64})/)?.[1],hashBytes=Number(detail.match(/bytes=(\d+)/)?.[1]);assert(hash&&hashBytes===bytes&&detail.match(/HASH_READY uri=([^\n]+)/)?.[1]===uri,'Late hash fixture identity mismatch');
    sha256=hash;report.fixture.sha256=hash;report.lateHash={utc:new Date().toISOString(),bytes:hashBytes,sha256:hash};
    publishCoordination('expected-sha256.json',{sha256:hash,bytes:hashBytes,name,uri});
    await snap('hash-ready',hashed);await activate('org.localsend.localsend_app');
   }
  }
  const result=receiverResult();
  if(result?.status==='saved-file-verified'&&!verifiedAt){
   verifiedAt=Number.isFinite(Date.parse(result.finishedUtc))?Date.parse(result.finishedUtc):now;
   report.verifiedUtc=new Date(verifiedAt).toISOString();report.elapsedSendToVerifiedMs=verifiedAt-sendStart;
   report.verificationObservationLagMs=Date.now()-verifiedAt;
   report.uploadStateAtVerifiedSave={observedUtc:new Date(now).toISOString(),transport:r.status(),destination:result.destination};
  }
  report.observations.push({utc:new Date(now).toISOString(),elapsedMs:now-sendStart,sourceElapsedMs,observationGapMs,uiObservationScope:'ANR is observed only in this actual app hierarchy; gaps and helper liveness do not imply absence of ANR',anr,androidFinished:finished,receiverStatus:result?.status,transport:r.status()});
  save('transfer-progress.json',report);
  if(names.some(v=>v.includes('Finished with error'))){
   await snap('android-transfer-error',xml);
   if(names.includes('Advanced')){
    await click('Advanced');const details=await snap('android-transfer-error-advanced');
    save('android-transfer-error-labels.json',labels(details));
   }
   throw Error('Original Android reported Finished with error; inspect saved details and transport/device logs');
  }
  if(anr){waits++;await ui('textMatches("(?i)wait")');}
  if(receiverExit&&receiverExit.code!==0)throw Error('Windows receiver failed; inspect results and both UI states');
  if((largeDiagnostic?transferCompleted:androidFinished)&&verifiedAt){
   const saved=result.savedFiles.find(f=>f.bytes===bytes&&f.sha256.toLowerCase()===sha256);
   assert(saved,'Windows result does not contain the actual fixture bytes/hash');assert(result.actions.some(a=>a.name==='Accept'),'Windows real Accept action missing');
   await Promise.race([receiverDone,sleep(5000)]);
   assert.equal(receiverExit?.code,0,'Verified Windows receiver did not exit successfully');
   report.status='passed';report.anrWaitActions=waits;
   const metricsAfter=r.status();
   report.transport={before:metricsBefore,after:metricsAfter,
    windowsToAndroidBytes:metricsAfter.fromSender-metricsBefore.fromSender,
    androidToWindowsBytes:metricsAfter.fromDevice-metricsBefore.fromDevice,
    scope:'Transport counts include TLS and protocol traffic. Elapsed time starts immediately before the favorite touch and includes registration, approval, network and saving; observation lag is recorded separately. '+controlName+' only.'};
   // A registration socket may be reused for upload; the explicit window excludes synthetic traffic even on an existing peer.
   const realPeers=Object.entries(metricsAfter.measurement.peerChunks);
   report.transport.realPeers=realPeers.map(([id,chunks])=>{
    const upload=chunks.fromDevice,span=upload.lastElapsedMs-upload.firstElapsedMs;
    return {id,...chunks,upload:r.status().uploads[id]||null,uploadSpanMs:span,wireBytesPerSecond:span>0?upload.bytes/(span/1000):null};
   });
   report.transport.wireRateScope='Per-peer relay byte rate covers only the explicit favorite-touch measurement window, including reused registration sockets, and excludes all earlier synthetic traffic. It includes TLS/protocol overhead and differs from file payload / send-to-verified-save elapsed time.';
   await snap('android-finished',xml);if(largeDiagnostic&&!largePass)save('moderate-android-finished.xml',xml);break;
  }
  await sleep(Math.min(largeDiagnostic?90000:5000,Math.max(0,end-Date.now())));
 }while(Date.now()<end);
 assert.equal(report.status,'passed',(largePass?'Large transfer/verification bounded deadline':'Ten-minute app-to-app control')+' did not reach Android Finished and verified Windows save');
 report.controlSizeBytes=bytes;
 report.endToEndBytesPerSecond=bytes/(report.elapsedSendToVerifiedMs/1000);
 if(transportMode!=='legacy'){
  await activate('org.localsend.cloudtransport');await click('Show transport status');
  const helperXml=await snap('helper-after-real-transfer');
  const helperStatus=labels(helperXml).find(v=>v.startsWith('HELPER_TRANSPORT_STATUS\n'));
  assert(helperStatus,'Real-transfer helper metrics not observed');
  report.realTransferHelper=JSON.parse(helperStatus.slice('HELPER_TRANSPORT_STATUS\n'.length));
  assert.equal(report.realTransferHelper.transport,report.selectedTransport);
  assert(Object.values(report.realTransferHelper.peers).every(p=>p.peakQueuedBytes<=(report.selectedTransport==='stream'?65536:1048576)),'Helper real-transfer buffer exceeded configured bound');
  save('helper-after-real-transfer.json',report.realTransferHelper);
 }
 save('app-control-results.json',report);
 console.log(controlName+' Android-to-Windows app control passed.');
 if(!largePass&&largeDiagnostic)phaseDeadline=sessionStart+20*minute;
 }
 if(transportMode==='legacy'&&process.env.SHARE_AFTER_CONTROL==='1'&&controlBytes===1048576){
  report.shareScenario=await shareScenario({session,wd,output});
 }
}catch(error){
 report.status='incomplete';report.error=redact(error.stack||error);
 if(session&&(!largeDiagnostic||remaining()>=2*minute))await source(Date.now()+30000,true).then(xml=>snap('failure',xml)).catch(()=>{});
 process.exitCode=1;
}finally{
 if(largeDiagnostic&&sessionStart!==null)phaseDeadline=sessionStart+110*minute;
 if(largeDiagnostic&&session)try{await wd('POST',base()+'/appium/device/terminate_app',{appId:'org.localsend.fixture3556'});}catch(error){report.cleanupErrors.push('Fixture helper terminate: '+redact(error.message));}
 try{await stopPhysicalServer();}catch(error){report.cleanupErrors.push('Temporary control server stop: '+redact(error.message));process.exitCode=1;}
 try{if(receiver&&!receiverExit){
  writeFileSync(path.join(windowsOutput,'stop'),'stop');
  await Promise.race([receiverDone,sleep(15000)]);
  if(!receiverExit){
   // A blocked UI Automation call must not leave this receiver's application child behind.
   const killer=spawn('taskkill.exe',['/PID',String(receiver.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});
   await Promise.race([new Promise(ok=>{killer.once('exit',ok);killer.once('error',ok);}),sleep(10000)]);
   await Promise.race([receiverDone,sleep(5000)]);
  }
 }}catch(error){report.cleanupErrors.push('Owned receiver shutdown: '+redact(error.message));process.exitCode=1;}
 const finalWindows=receiverResult();
 if(largeDiagnostic&&finalWindows&&Number.isInteger(finalWindows.imageCount)&&Number.isInteger(finalWindows.uiObservationCount)){
  report.windowsEvidenceBudget??={moderateImages:0,moderateObservations:0,maxImages:60,maxObservations:windowsObservationLimit};
  const budget=report.windowsEvidenceBudget;
  budget.finalPassImages=finalWindows.imageCount;budget.finalPassObservations=finalWindows.uiObservationCount;
  budget.totalImages=(windowsLargeReceiverStarted?budget.moderateImages:0)+finalWindows.imageCount;budget.totalObservations=(windowsLargeReceiverStarted?budget.moderateObservations:0)+finalWindows.uiObservationCount;
  if(budget.totalImages>60||budget.totalObservations>windowsObservationLimit){report.cleanupErrors.push('Windows evidence exceeded combined session allocation');process.exitCode=1;}
 }
 report.androidEvidenceBudget={hierarchyReads:sourceCount,transferObservations:observationCount,images:imageCount,maxHierarchyReads:largeDiagnostic?androidSourceLimit:null,reservedTerminalReads:largeDiagnostic?4:null,maxImages:largeDiagnostic?60:null};
 report.receiverExit=receiverExit;report.finishedUtc=new Date().toISOString();
 for(const log of receiverLogs)log.end();
 if(!session&&sessionCreationAttempted){
  try{await recoverOwnedStartupSession();}catch(error){
   report.cleanupErrors.push('Owned startup session lookup: '+redact(error.message));process.exitCode=1;
  }
 }
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

