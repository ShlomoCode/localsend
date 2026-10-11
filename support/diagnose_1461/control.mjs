import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {relay} from '../cloud_transport/relay.mjs';

const out=path.resolve('evidence/issue1461');fs.mkdirSync(out,{recursive:true});
const windows=path.join(out,'windows');fs.mkdirSync(windows,{recursive:true});
const secretKeys=['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','RELAY_TOKEN','RELAY_APP','BASELINE_APP'];
for(const key of secretKeys)assert(process.env[key],key+' required');
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const secrets=[auth,...secretKeys.map(k=>process.env[k])];
const redact=v=>secrets.reduce((s,k)=>s.replaceAll(k,'[redacted]'),String(v));
const save=(name,v)=>fs.writeFileSync(path.join(out,name),redact(typeof v==='string'?v:JSON.stringify(v,null,2)));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const report={status:'preparing',startedUtc:new Date().toISOString(),issue:1461,
 release:'1.14.0',device:'Samsung Galaxy S23',android:'13.0',
 boundaries:['Windows Server 2022 differs from Windows 11','Galaxy S23 Android 13 differs from Redmi K40 HyperOS Android 13','Cloud relay differs from shared LAN'],
 actions:[],cases:[],cleanupErrors:[]};
const r=relay({token:process.env.RELAY_TOKEN,downlink:'persistent'});
let session,sessionCreationAttempted=false,child,childExit,commandId=0,deadline=Date.now()+30*60000;
const base=()=>'/session/'+session;
async function wd(method,url,body){
 const started=Date.now();assert(Date.now()<deadline,'Controller absolute deadline expired');
 const response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+url,{method,
  headers:{authorization:auth,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),
  signal:AbortSignal.timeout(Math.min(url==='/session'?240000:60000,deadline-Date.now()))});
 const json=await response.json();
 fs.appendFileSync(path.join(out,'webdriver.jsonl'),redact(JSON.stringify({utc:new Date(started).toISOString(),method,url,
  body:url==='/session'?'[private capabilities omitted]':body,status:response.status,elapsedMs:Date.now()-started}))+'\n');
 assert(response.ok&&!json.value?.error,'WebDriver '+response.status+' '+redact(json.value?.message||json.value?.error||''));
 return json.value;
}
function decode(v){return v.replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(+n)).replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');}
function nodes(xml){return [...xml.matchAll(/<[^/!?][^>]*>/g)].map(m=>Object.fromEntries([...m[0].matchAll(/([\w.:-]+)=(["'])(.*?)\2/g)].map(a=>[a[1],decode(a[3])])));}
const labels=xml=>nodes(xml).flatMap(n=>[n.text||'',n['content-desc']||'']);
const source=()=>wd('GET',base()+'/source');
async function snap(name,xml){const value=xml||await source();save(name+'.xml',value);fs.writeFileSync(path.join(out,name+'.png'),Buffer.from(await wd('GET',base()+'/screenshot'),'base64'));return value;}
async function wait(predicate,ms,message){const end=Math.min(deadline,Date.now()+ms);let last;do{last=await source();if(predicate(last))return last;await sleep(1000);}while(Date.now()<end);await snap('failed-wait-'+Date.now(),last);throw Error(message);}
async function tap(name,{action=false}={}){
 const xml=await source();const found=nodes(xml).filter(n=>(n.text===name||n['content-desc']===name)&&n.enabled==='true'&&n.displayed==='true'&&(!action||n.clickable==='true'||n.class==='android.widget.Button'));
 assert.equal(found.length,1,'Expected one visible enabled control '+name);
 const n=found[0],bounds=n.bounds?.match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);assert(bounds,'Missing actual control bounds');
 const x=Math.round((+bounds[1]+ +bounds[3])/2),y=Math.round((+bounds[2]+ +bounds[4])/2);
 report.actions.push({utc:new Date().toISOString(),label:name,bounds:n.bounds});
 await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'finger1461',parameters:{pointerType:'touch'},actions:[
  {type:'pointerMove',duration:0,origin:'viewport',x,y},{type:'pointerDown',button:0},{type:'pause',duration:100},{type:'pointerUp',button:0}]}]});
}
async function activate(appId){await wd('POST',base()+'/appium/device/activate_app',{appId});}
async function command(action,fields={}){
 const id=String(++commandId);const input=path.join(windows,'commands',id+'.json');fs.writeFileSync(input+'.tmp',JSON.stringify({id,action,...fields}));
 fs.renameSync(input+'.tmp',input);
 const result=path.join(windows,'results',id+'.json');const end=Math.min(deadline,Date.now()+300000);let value;
 do{assert(!childExit,'Windows sender exited '+JSON.stringify(childExit));assert(Date.now()<end,'Windows action timed out '+action);
  if(fs.existsSync(result)){value=JSON.parse(fs.readFileSync(result,'utf8'));if(value.status!=='running')break;}await sleep(250);
 }while(true);
 report.actions.push({utc:new Date().toISOString(),windowsCommand:action,result:value});
 assert(value.status==='passed',action+' failed; inspect Windows evidence');return value;
}
async function accept(name){
 const xml=await wait(s=>labels(s).includes('Accept'),90000,'Android incoming approval absent');await snap(name+'-incoming',xml);await tap('Accept',{action:true});
 await snap(name+'-accepted');
}
async function receivedHash(fixture,name){
 await wait(s=>labels(s).some(x=>/Finished|Done/.test(x)),180000,'Android transfer did not finish');await snap(name+'-received');
 await activate('org.localsend.cloudtransport');await tap('Verify received file',{action:true});
 const basename=path.win32.basename(fixture.path);
 let picker=await wait(s=>nodes(s).some(n=>/documentsui/.test(n.package||'')),30000,'Public document picker absent');
 if(!labels(picker).includes(basename)){
  const drawer=nodes(picker).filter(n=>n.enabled==='true'&&n.displayed==='true'&&/^(Show roots|Show navigation drawer|Open navigation drawer)$/.test(n['content-desc']||''));
  assert.equal(drawer.length,1,'Document picker navigation drawer not uniquely observed');await snap(name+'-picker-navigation',picker);await tap(drawer[0]['content-desc']);
  await wait(s=>labels(s).includes('Downloads'),10000,'Downloads destination absent from observed picker roots');await tap('Downloads');
 }
 await wait(s=>labels(s).includes(basename),30000,'Observed Downloads picker did not expose saved file '+basename);await snap(name+'-hash-picker');await tap(basename);
 const xml=await wait(s=>labels(s).some(v=>v.startsWith('RECEIVED_FILE_HASH\n')),60000,'Public SAF hash missing');await snap(name+'-hash',xml);
 const value=JSON.parse(labels(xml).find(v=>v.startsWith('RECEIVED_FILE_HASH\n')).slice('RECEIVED_FILE_HASH\n'.length));
 assert.equal(value.status,'passed');assert.equal(value.bytes,fixture.bytes);assert.equal(value.sha256,fixture.sha256);
 report.controlHash=value;await activate('org.localsend.localsend_app');
 await tap('Done',{action:true});
}
function wifiSwitches(xml){return nodes(xml).filter(n=>/Switch/.test(n.class||'')&&n.enabled==='true'&&n.displayed==='true'&&['true','false'].includes(n.checked));}
async function toggleWifi(expected,name,{requireActivePeer=false}={}){
 const xml=await source(),switches=wifiSwitches(xml);assert.equal(switches.length,1,'Ambiguous observed system Wi-Fi switch');
 assert(nodes(xml).some(n=>n.package==='com.android.settings')&&labels(xml).some(v=>/Wi-Fi/.test(v)),'Observed switch is not on native Wi-Fi settings');
 assert.equal(switches[0].checked,expected?'false':'true','Unexpected Wi-Fi starting state');
 const n=switches[0],bounds=n.bounds?.match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);assert(bounds,'Missing observed Wi-Fi switch bounds');
 const targets=n.clickable==='true'?[n]:nodes(xml).filter(v=>v.package===n.package&&v.enabled==='true'&&v.displayed==='true'&&v.clickable==='true'&&v['resource-id']?.endsWith('/switch_bar')&&v.bounds);
 assert.equal(targets.length,1,'Nonclickable native Switch requires its uniquely observed clickable switch bar');const target=targets[0];
 const rect=target.bounds.match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);assert(rect&&+rect[1]<=+bounds[1]&&+rect[2]<=+bounds[2]&&+rect[3]>=+bounds[3]&&+rect[4]>=+bounds[4],'Observed clickable switch bar does not contain Wi-Fi switch');
 await snap(name+'-before',xml);
 if(requireActivePeer){const state=r.status();assert(state.activePeerIds.includes(report.interruptedPeer),'Large-upload peer already ended before Wi-Fi input');assert(state.peerChunks[report.interruptedPeer].fromSender.bytes<report.largeFixtureBytes*0.9,'Source may already have finished before Wi-Fi input');save('transport-immediately-before-wifi-input.json',state);}
 report.wifiSwitchMayHaveChanged=true;
 const elements=await wd('POST',base()+'/elements',{using:'id',value:target['resource-id']});assert.equal(elements.length,1,'Observed clickable native switch target not unique');
 const id=elements[0]['element-6066-11e4-a52e-4f735466cecf']||elements[0].ELEMENT;assert(id,'Native switch element reference missing');
 await wd('POST',base()+'/element/'+id+'/click',{});
 report.actions.push({utc:new Date().toISOString(),label:name,before:n,actionTarget:target,method:'Native click on observed clickable system switch-bar ancestor'});
 const changed=await wait(s=>wifiSwitches(s).length===1&&wifiSwitches(s)[0].checked===String(expected),30000,'System Wi-Fi did not change');
 await snap(name,changed);return changed;
}
async function normalWifiDisconnect({requireActivePeer=false}={}){
 // Use the actual Android system Wi-Fi switch. Closing diagnostic sockets is not this experiment.
 await activate('org.localsend.cloudtransport');await tap('Open Wi-Fi settings',{action:true});
 await wait(s=>wifiSwitches(s).length===1&&nodes(s).some(n=>n.package==='com.android.settings'),30000,'Resolved native Settings Wi-Fi switch not exposed');
 await toggleWifi(false,'wifi-off',{requireActivePeer});
 report.wifiDisconnectObserved=true;
}
function successfulFileControl(value,phase){
 const result=value.result;assert.equal(result?.phase,phase,'Wrong file-control phase');
 assert.equal(result.rename?.success,true,'Ordinary control rename failed');assert.equal(result.delete?.success,true,'Ordinary control delete failed');
 assert.equal(result.restored,true,'File-control source restoration failed');
 for(const handle of [result.handlesBefore,result.handlesAfter]){
  assert(handle?.raw&&fs.existsSync(handle.raw),'Handle observation evidence absent');
  assert([0,1].includes(handle.exitCode),'Handle observation invocation failed');
  const raw=fs.readFileSync(handle.raw,'utf8');assert(/No matching handles found\./.test(raw),'Successful file control unexpectedly retains matching handles');
 }
 return result;
}
function partialReceive(xml,basename){
 const text=labels(xml).join('\n');
 const percents=[...text.matchAll(/(?:^|\s)(\d+(?:\.\d+)?)\s*%/g)].map(m=>Number(m[1]));
 return text.includes('Receiving')&&text.includes(basename)&&!text.includes('Finished')&&percents.some(p=>p>0&&p<100);
}
async function helperLossEvidence(streamId,name){
 await activate('org.localsend.cloudtransport');const end=Date.now()+30000;let status,xml,observed;
 do{await tap('Show transport status',{action:true});xml=await wait(s=>labels(s).some(v=>v.startsWith('HELPER_TRANSPORT_STATUS\n')),10000,'Retired helper transport observation absent');
  status=JSON.parse(labels(xml).find(v=>v.startsWith('HELPER_TRANSPORT_STATUS\n')).slice('HELPER_TRANSPORT_STATUS\n'.length));observed=status.lastDownlinkObservation;
  if(observed?.streamId===streamId&&observed.closedMs>0)break;assert(Date.now()<end,'No matching Android native physical closure observed');await sleep(1000);
 }while(true);await snap(name,xml);
 assert(/^physical-read-failure:/.test(observed.outcome),'Helper stream closure was diagnostic or unclassified');
 assert(observed.firstReadMs>0&&observed.closedMs>=observed.firstReadMs,'Helper never established physical read or missing native closure time');
 assert(!observed.retirementReason||observed.retirementReason==='service-cleanup','Diagnostic retirement preceded link closure');
 save(name+'.json',status);return observed;
}
async function forwardControls(){
 await tap('Start socket control');
 await wait(s=>labels(s).some(v=>v.includes('HELPER_SERVICE_STATUS')&&v.includes('"ready":true')&&v.includes('53319')),45000,'Forward control listener not ready');
 const cases=[];
 for(const count of [0,1,65537]){
  const data=Buffer.alloc(count);for(let i=0;i<count;i++)data[i]=(i*31+7)&255;
  const expected=createHash('sha256').update(data).digest('hex');
  const returned=await new Promise((resolve,reject)=>{
   const socket=net.connect({host:'127.0.0.1',port:53318,allowHalfOpen:true});const chunks=[];
   const timer=setTimeout(()=>socket.destroy(new Error('Forward byte control deadline')),30000);
   socket.on('connect',()=>socket.end(data));socket.on('data',d=>chunks.push(d));socket.on('error',reject);
   socket.on('end',()=>{clearTimeout(timer);socket.destroy();try{resolve(JSON.parse(Buffer.concat(chunks).toString()));}catch(e){reject(e);}});
  });
  assert.equal(returned.count,count);assert.equal(returned.sha256,expected);cases.push({count,sha256:expected,returned,halfClosed:true,replyReadThroughEof:true});
 }
 save('forward-physical-control.json',{status:'passed',scope:'Opaque transport checksum and half-close control, not app reproduction',cases});
 // An independent active control socket must terminate from the observed physical link closure.
 // Neither the timer below nor cleanup may manufacture a qualifying TCP failure.
 const stream=r.status().persistent;assert(stream?.established,'Persistent physical downlink not established');
 const opened=r.status().opened;let closed=null;
 const physical=net.connect({host:'127.0.0.1',port:53318,allowHalfOpen:true});
 physical.on('end',()=>{closed={kind:'native-socket-eof',utc:new Date().toISOString()};});
 physical.on('error',error=>{closed={kind:'native-socket-error',code:error.code,utc:new Date().toISOString()};});
 physical.on('close',hadError=>{closed={...closed,kind:closed?.kind||'native-socket-close',hadError,utc:new Date().toISOString()};});
 try{
  await new Promise((resolve,reject)=>{physical.once('connect',resolve);physical.once('error',reject);});physical.write(Buffer.alloc(65537,7));
  const activeEnd=Date.now()+30000;let peer;
  do{peer=r.status().activePeerIds.find(id=>r.status().peerDownlink[id]===stream.id&&r.status().peerChunks[id]?.fromSender.bytes===65537);if(peer)break;assert(Date.now()<activeEnd,'Physical dropout socket did not progress');await sleep(100);}while(true);
  assert.equal(r.status().opened,opened+1,'Unexpected socket opened during transport loss control');
  save('physical-dropout-before.json',r.status());await normalWifiDisconnect();
  const lossEnd=Date.now()+60000;let event;
  do{event=r.status().streamHistory.find(e=>e.id===stream.id&&e.physical&&e.ownedPeers.includes(peer));if(event&&closed&&!r.status().activePeerIds.includes(peer))break;assert(Date.now()<lossEnd,'Normal Wi-Fi off did not produce a native downlink abort and native Windows peer close; no synthetic reset substituted');await sleep(250);}while(true);
  const androidLoss=await helperLossEvidence(stream.id,'physical-dropout-helper');
  save('physical-dropout-control.json',{status:'passed',scope:'Transport loss propagation only, not LocalSend failure',streamId:stream.id,peer,event,androidLoss,closed,status:r.status()});
  await tap('Open Wi-Fi settings',{action:true});await wait(s=>wifiSwitches(s).length===1,30000,'Physical control Wi-Fi restore unavailable');await toggleWifi(true,'physical-control-wifi-restored');
 }finally{physical.destroy();}
 await activate('org.localsend.cloudtransport');
 await tap('Stop helper');await wait(s=>labels(s).some(v=>v.includes('HELPER_SERVICE_STATUS')&&v.includes('"servicePresent":false')),45000,'Control helper not stopped');
 const end=Date.now()+10000;while(r.status().peers){assert(Date.now()<end,'Control peers not closed');await sleep(100);}
}
async function preserveAndroidRecording(){
 const end=Date.now()+90000;let value;const observations=[];
 do{
  const response=await fetch('https://api-cloud.browserstack.com/app-automate/sessions/'+session+'.json',{headers:{authorization:auth},signal:AbortSignal.timeout(15000)});
  assert(response.ok,'Owned BrowserStack recording metadata unavailable');value=(await response.json()).automation_session;
  if(value?.video_url){
   const url=new URL(value.video_url);assert.equal(url.protocol,'https:','Recording URL must use HTTPS');
   const media=await fetch(value.video_url,{headers:url.hostname.endsWith('.browserstack.com')?{authorization:auth}:{},signal:AbortSignal.timeout(30000)});
   const binary=Buffer.from(await media.arrayBuffer());
   const valid=media.ok&&binary.length>24&&binary.length<256*1024*1024&&binary.subarray(4,8).toString()==='ftyp';
   observations.push({utc:new Date().toISOString(),httpStatus:media.status,contentType:media.headers.get('content-type'),bytes:binary.length,sha256:createHash('sha256').update(binary).digest('hex'),validMp4:valid,endpoint:{origin:url.origin,path:url.pathname}});
   save('android-recording-readiness.json',observations);
   if(valid){
    fs.writeFileSync(path.join(out,'android-session.mp4'),binary);
    save('android-recording.json',{session,status:value.status,duration:value.duration,bytes:binary.length,sha256:createHash('sha256').update(binary).digest('hex'),source:'Video URL returned by authenticated owned BrowserStack session API; capability URL omitted'});return;
   }
  }
  await sleep(3000);
 }while(Date.now()<end);
 throw Error('Owned BrowserStack video did not become a valid MP4; no XML/HTML substituted for recording');
}
try{
 const capacityResponse=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
 assert(capacityResponse.ok,'Fresh BrowserStack capacity failed');const capacity=await capacityResponse.json();save('fresh-capacity.json',capacity);
 assert(Number.isFinite(capacity.parallel_sessions_running)&&capacity.parallel_sessions_running<Math.min(5,capacity.parallel_sessions_max_allowed),'No authorized shared BrowserStack capacity');
 await r.start();
 sessionCreationAttempted=true;
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:{platformName:'Android','appium:deviceName':report.device,'appium:platformVersion':'13.0',
  'appium:app':process.env.BASELINE_APP,'appium:autoGrantPermissions':true,'appium:otherApps':[process.env.RELAY_APP],
  'bstack:options':{userName:process.env.BROWSERSTACK_USERNAME,accessKey:process.env.BROWSERSTACK_ACCESS_KEY,
   projectName:'LocalSend bug sprint',buildName:'issue1461-'+process.env.GITHUB_RUN_ID,sessionName:'Original1.14 Windows source handle interruption',
   local:true,localIdentifier:process.env.BS_LOCAL_ID,debug:true,video:true,appiumVersion:'2.0.1'}}}});
 session=created.sessionId;assert(session,'Missing owned session ID');save('session.json',{session,device:report.device,android:report.android});
 await activate('org.localsend.cloudtransport');await snap('helper-start');await forwardControls();await tap('Relay to LocalSend');
 const helper=await wait(s=>labels(s).some(v=>v.includes('HELPER_SERVICE_STATUS')&&v.includes('"ready":true')),45000,'Forward helper did not become ready');await snap('helper-ready',helper);
 await activate('org.localsend.localsend_app');await snap('original-receiver-ready');
 const stdout=fs.createWriteStream(path.join(windows,'stdout.txt')),stderr=fs.createWriteStream(path.join(windows,'stderr.txt'));
 child=spawn('pwsh',['-NoProfile','-ExecutionPolicy','Bypass','-File','support/diagnose_1461/windows_sender.ps1','-OutputDirectory',windows],{stdio:['ignore','pipe','pipe']});
 child.stdout.pipe(stdout);child.stderr.pipe(stderr);child.on('exit',(code,signal)=>{childExit={code,signal};});
 const readyFile=path.join(windows,'ready.json'),end=Date.now()+180000;
 while(!fs.existsSync(readyFile)){assert(!childExit,'Windows sender startup failed');assert(Date.now()<end,'Windows startup deadline');await sleep(500);}
 const ready=JSON.parse(fs.readFileSync(readyFile,'utf8'));save('windows-ready.json',ready);
 successfulFileControl(await command('probe',{fixture:'control',phase:'before-selection'}),'before-selection');
 successfulFileControl(await command('probe',{fixture:'failed',phase:'before-selection'}),'before-selection');
 await command('add-favorite');await command('select',{fixture:'control'});await command('send');await accept('control');await receivedHash(ready.fixtures.control,'control');
 successfulFileControl(await command('probe',{fixture:'control',phase:'after-success'}),'after-success');
 await command('record-start');await command('select',{fixture:'failed'});await command('send');await accept('interrupted');
 const before=r.status().fromSender;const progressEnd=Date.now()+90000;
 while(r.status().fromSender-before<1048576){assert(Date.now()<progressEnd,'No real source data progression before disconnect');await sleep(250);}
 await command('probe',{fixture:'failed',phase:'during-upload'});
 const partial=await wait(s=>partialReceive(s,path.win32.basename(ready.fixtures.failed.path)),30000,'Actual Android partial receive progression absent');await snap('interrupted-partial-receive',partial);
 const active=r.status();save('interrupted-active-transport.json',active);
 const peers=active.activePeerIds?.filter(id=>active.peerChunks[id]?.fromSender.bytes>=1048576)||[];assert.equal(peers.length,1,'Expected one observed active large-upload peer');
 report.interruptedPeer=peers[0];report.interruptedStream=active.peerDownlink[peers[0]];report.largeFixtureBytes=ready.fixtures.failed.bytes;await command('screenshot',{label:'active-immediately-before-network-off'});
 await normalWifiDisconnect({requireActivePeer:true});await command('screenshot',{label:'after-disconnect'});
 const physicalEnd=Date.now()+60000;let physicalLoss;
 do{physicalLoss=r.status().streamHistory.find(e=>e.id===report.interruptedStream&&e.physical&&e.ownedPeers.includes(report.interruptedPeer));if(physicalLoss)break;assert(Date.now()<physicalEnd,'Actual transfer network loss had no native physical downlink abort; synthetic/deadline failures excluded');await sleep(250);}while(true);
 report.physicalLoss=physicalLoss;report.androidPhysicalLoss=await helperLossEvidence(report.interruptedStream,'actual-network-helper-loss');save('actual-network-loss.json',{windows:physicalLoss,android:report.androidPhysicalLoss});
 await command('record-interruption',{kind:'normal-network-interruption',evidence:'../wifi-off.png; actual Android Settings switch verified true→false'});
 await sleep(15000);const after=await command('probe',{fixture:'failed',phase:'after-terminal-error'});report.cases.push({name:'normal-wifi-disconnect',probe:after});
 const details=await command('error-details');report.errorDetails=details;
 const errorText=details.result?.ocr?.text+' '+((details.result?.uia?.tree||[]).map(n=>n.name).join(' '));assert(/DioException|SocketException|connection|network/i.test(errorText),'Actual error details lack a network-failure observation');
 await command('click',{label:'Close'});
 await command('quit');const quit=await command('probe',{fixture:'failed',phase:'after-quit'});report.cases.push({name:'after-app-quit',probe:quit});successfulFileControl(quit,'after-quit');
 report.windowsRecording=await command('record-stop');assert.equal(report.windowsRecording.result.status,'capture-finished');assert.equal(report.windowsRecording.result.exitCode,0);assert(report.windowsRecording.result.bytes>0,'Continuous Windows recording absent');
 report.status='observations-complete';report.reproduced=null;report.verdict='Await independent inspection of terminal error, physical interruption provenance and source-owner handle evidence';
}catch(error){report.status='incomplete';report.error=redact(error.stack||error);process.exitCode=1;if(session){try{await snap('failure');}catch(e){report.snapshotError=redact(e.message);}}}
finally{
 deadline=Date.now()+180000;
 if(!session&&sessionCreationAttempted){try{
  const get=async suffix=>{const response=await fetch('https://api-cloud.browserstack.com/app-automate/'+suffix,{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});assert(response.ok,'Owned startup lookup '+response.status);return response.json();};
  const builds=(await get('builds.json')).map(x=>x.automation_build).filter(x=>x.name==='issue1461-'+process.env.GITHUB_RUN_ID);assert(builds.length<=1,'Ambiguous owned build');
  if(builds.length){const sessions=(await get('builds/'+builds[0].hashed_id+'/sessions.json')).map(x=>x.automation_session);assert(sessions.length<=1,'Ambiguous owned session');if(sessions[0]?.status==='running')session=sessions[0].hashed_id;save('startup-session-lookup.json',sessions.map(x=>({id:x.hashed_id,status:x.status})));}
 }catch(e){report.cleanupErrors.push(redact(e.message));}}
 if(child&&!childExit){try{await command('stop');}catch{child.kill();}}
 // Restore only this owned device's Wi-Fi before session cleanup when the normal switch was changed.
 if(session&&report.wifiSwitchMayHaveChanged){try{await activate('org.localsend.cloudtransport');await tap('Open Wi-Fi settings',{action:true});await wait(s=>wifiSwitches(s).length===1,30000,'Restore Wi-Fi switch unavailable');if(wifiSwitches(await source())[0].checked==='false')await toggleWifi(true,'wifi-restored');}catch(e){report.cleanupErrors.push(redact(e.message));}}
 if(session){try{await wd('DELETE',base());await preserveAndroidRecording();}catch(e){report.cleanupErrors.push(redact(e.message));}}
 try{await r.stop();}catch(e){report.cleanupErrors.push(redact(e.message));}
 save('relay-trace.json',r.trace);save('relay-status.json',r.status());report.finishedUtc=new Date().toISOString();save('results.json',report);
}
