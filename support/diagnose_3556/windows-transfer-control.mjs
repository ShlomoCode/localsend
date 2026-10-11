import assert from 'node:assert/strict';
import {mkdirSync,readFileSync,writeFileSync,appendFileSync,existsSync,createWriteStream} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {relay} from '../cloud_transport/relay.mjs';
import shareScenario from './share-scenario.mjs';

// Drive the unmodified apps. The moderate control measures throughput; neither size proves 16GB behavior.
const controlBytes=process.env.MODERATE_TRANSFER_CONTROL==='1'?64*1024*1024:1048576;
const controlName=controlBytes===1048576?'1 MiB':'64 MiB';
const controlSizeLabel=controlBytes===1048576?'1.0 MB':'67.1 MB';
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
 release:process.env.ALIAS_BASELINE_APK?'current-c1ce322':'1.17.0',scenario:'Actual Android confirmed alias, Receive, Windows registration, server Stop/Start and relaunch',
 boundaries:['Issue 2426 does not specify peer OS; this experiment uses a real Windows Server 2022 x64 peer','Reverse cloud relay differs from reported shared LAN','Alias discovery observations only; no file transfer is performed'],
 fixture:null,observations:[],actions:[],receiverExit:null,sendUtc:null,verifiedUtc:null,elapsedSendToVerifiedMs:null};
let session,receiver,receiverExit,receiverDone,receiverLogs=[],startedRelay=false,physicalServer;
let sessionCreationAttempted=false;
const physicalSockets=new Set(),physicalCases=[],physicalTrace=[];
const r=relay({token:process.env.RELAY_TOKEN,reverseTargetPort:53317});
async function wd(method,url,body,attempt=0){
 const started=Date.now();
 let response;
 try{
 response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+url,{
  method,headers:{authorization:auth,'content-type':'application/json'},
  body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(url==='/session'?300000:120000)});
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
   await sleep(1000);return wd(method,url,body,attempt+1);
  }
  throw error;
 }
}
const base=()=>'/session/'+session;
async function source(){return wd('GET',base()+'/source');}
async function recoverOwnedStartupSession(){
 // A timed-out POST can still allocate a device. Resolve only this unique Actions build.
 const get=async url=>{
  const response=await fetch('https://api-cloud.browserstack.com/app-automate/'+url,{
   headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
  assert(response.ok,'Owned startup lookup failed: '+response.status);return response.json();
 };
 const builds=await get('builds.json');
 const owned=builds.map(b=>b.automation_build).filter(b=>b.name==='issue2426-'+process.env.GITHUB_RUN_ID);
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
async function peerObserve(id,tap=''){
 save('peer-command-'+id+'.json',{id,tap});
 writeFileSync(path.join(windowsOutput,'command.json'),JSON.stringify({id,tap}));
 const end=Date.now()+60000;
 while(Date.now()<end){if(existsSync(path.join(windowsOutput,'response-'+id+'.json')))return;await sleep(500);}
 throw Error('Real Windows peer observation timed out: '+id);
}
async function renameAlias(value){
 await click('Settings\nTab 3 of 3');
 for(let i=0;i<2;i++)await wd('POST',base()+'/execute/sync',{script:'mobile: scrollGesture',args:[{left:60,top:350,width:900,height:1500,direction:'down',percent:0.7}]});
 const settings=await snap('settings-before-confirm');
 const button=nodes(settings).find(n=>n.class==='android.widget.Button'&&n['content-desc']&&!/^(Open|Donate|\(Downloads\)|Receive\n|Send\n|Settings\n)/.test(n['content-desc']));
 assert(button,'Observed alias button is missing');report.aliasBefore=button['content-desc'];
 await click(button['content-desc']);
 const field=elementId(await wd('POST',base()+'/element',{using:'class name',value:'android.widget.EditText'}));
 await touch(await wd('GET',base()+'/element/'+field+'/rect'),'Focus alias editor');
 await wd('POST',base()+'/element/'+field+'/clear',{});await wd('POST',base()+'/element/'+field+'/value',{text:value,value:[...value]});
 assert.equal(await wd('GET',base()+'/element/'+field+'/text'),value);
 await snap('alias-typed');await click('Confirm');await snap('alias-confirmed');await click('Receive\nTab 1 of 3');await snap('receive-after-confirm');
 report.aliasConfirmed=value;
}
async function refreshRegistration(label){
 await click('Send\nTab 2 of 3');await click('Favorites');
 const xml=await snap(label+'-favorites');

 const before=r.status();
 await tap('-android uiautomator','new UiSelector().descriptionContains("issue3556-cloud-receiver")');
 await waitFor(s=>!labels(s).includes('Add')&&r.status().opened>before.opened,60000,'Actual favorite connection refresh failed');
 await snap(label+'-registered');save(label+'-transport.json',{utc:new Date().toISOString(),before,after:r.status()});await peerObserve(label);
 await wd('POST',base()+'/appium/device/press_keycode',{keycode:4});await snap(label+'-picker-dismissed');

}
async function restartServer(){
 await click('Settings\nTab 3 of 3');for(let i=0;i<2;i++)await wd('POST',base()+'/execute/sync',{script:'mobile: scrollGesture',args:[{left:60,top:350,width:900,height:1500,direction:'down',percent:0.7}]});
 await snap('server-before-stop');
 await tap('xpath','(//android.widget.Button[not(@content-desc)])[2]');
 await waitFor(s=>labels(s).some(v=>v.includes('Server (Offline)')),30000,'Server Stop did not reach Offline');await snap('server-offline');
 await tap('xpath','(//android.widget.Button[not(@content-desc)])[1]');
 await waitFor(s=>!labels(s).some(v=>v.includes('Server (Offline)')),30000,'Server Start did not leave Offline');await snap('server-started');
 await click('Receive\nTab 1 of 3');await snap('receive-after-server-start');
}
try{
 const response=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});assert(response.ok);
 const plan=await response.json();save('plan.json',plan);assert(plan.parallel_sessions_running<5,'No cloud slot');
 await r.start();startedRelay=true;sessionCreationAttempted=true;
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:{platformName:'Android','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0','appium:automationName':'UiAutomator2','appium:app':process.env.RELAY_APP,'appium:otherApps':[process.env.BASELINE_APP,process.env.HELPER_APP],'appium:autoGrantPermissions':true,'appium:newCommandTimeout':1200,'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,idleTimeout:600,projectName:'LocalSend bug sprint',buildName:'issue2426-'+process.env.GITHUB_RUN_ID,sessionName:'issue2426-real-Windows-alias',debug:true,video:true,networkLogs:false}},firstMatch:[{}]}});
 session=created.sessionId;save('session.json',{session,device:report.device,android:report.android});
 await wd('POST',base()+'/timeouts',{implicit:5000});await activate('org.localsend.cloudtransport');await click('Relay from LocalSend');await runPhysicalReverseControl();
 await startReceiver({bytes:1048576,sha256:'0'.repeat(64)});await peerObserve('peer-send-tab','Send');
 await activate('org.localsend.localsend_app');await snap('localsend-receive-control');
 await click('Send\nTab 2 of 3');await addFavorite();await peerObserve('peer-initial-registration');await click('Cancel');
 await renameAlias('Alias2426Cloud');await refreshRegistration('peer-after-confirm');
 await restartServer();await refreshRegistration('peer-after-server-start');
 await wd('POST',base()+'/appium/device/terminate_app',{appId:'org.localsend.localsend_app',options:{timeout:5000}});await activate('org.localsend.localsend_app');await snap('receive-after-relaunch');await refreshRegistration('peer-after-relaunch');
 report.status='alias-observations-complete';save('alias-observations.json',report);
}catch(error){
 report.status='incomplete';report.error=redact(error.stack||error);
 if(session)await snap('failure').catch(()=>{});
 process.exitCode=1;
}finally{
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

