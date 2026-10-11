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
const r=relay({token:process.env.RELAY_TOKEN});
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
async function tap(name){
 const xml=await source();const found=nodes(xml).filter(n=>(n.text===name||n['content-desc']===name)&&n.enabled==='true'&&n.displayed==='true');
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
 const xml=await wait(s=>labels(s).includes('Accept'),90000,'Android incoming approval absent');await snap(name+'-incoming',xml);await tap('Accept');
 await snap(name+'-accepted');
}
async function receivedHash(fixture,name){
 await wait(s=>labels(s).some(x=>/Finished|Done/.test(x)),180000,'Android transfer did not finish');await snap(name+'-received');
 await activate('org.localsend.cloudtransport');await tap('Verify received file');
 const basename=path.win32.basename(fixture.path);await wait(s=>labels(s).includes(basename),30000,'SAF picker did not expose received file '+basename);await snap(name+'-hash-picker');await tap(basename);
 const xml=await wait(s=>labels(s).some(v=>v.startsWith('RECEIVED_FILE_HASH\n')),60000,'Public SAF hash missing');await snap(name+'-hash',xml);
 const value=JSON.parse(labels(xml).find(v=>v.startsWith('RECEIVED_FILE_HASH\n')).slice('RECEIVED_FILE_HASH\n'.length));
 assert.equal(value.status,'passed');assert.equal(value.bytes,fixture.bytes);assert.equal(value.sha256,fixture.sha256);
 report.controlHash=value;await activate('org.localsend.localsend_app');
 await tap('Done');
}
async function normalWifiDisconnect(){
 // Use the actual Android system Wi-Fi switch. Closing diagnostic sockets is not this experiment.
 await wd('POST',base()+'/appium/device/start_activity',{appPackage:'com.android.settings',appActivity:'.Settings$WifiSettingsActivity'});
 const xml=await wait(s=>nodes(s).some(n=>n.class==='android.widget.Switch'&&n.enabled==='true'),30000,'System Wi-Fi switch not exposed');
 await snap('wifi-before-disconnect',xml);
 const switches=nodes(xml).filter(n=>n.class==='android.widget.Switch'&&n.enabled==='true'&&n.displayed==='true');assert.equal(switches.length,1,'Ambiguous system Wi-Fi switch');
 assert.equal(switches[0].checked,'true','Wi-Fi must be on before normal disconnect');
 const elements=await wd('POST',base()+'/elements',{using:'class name',value:'android.widget.Switch'});assert.equal(elements.length,1);
 const element=elements[0]['element-6066-11e4-a52e-4f735466cecf']||elements[0].ELEMENT;
 report.wifiSwitchMayHaveChanged=true;
 await wd('POST',base()+'/element/'+element+'/click',{});report.actions.push({utc:new Date().toISOString(),label:'Normal Android Settings Wi-Fi off',before:switches[0]});
 const off=await wait(s=>nodes(s).some(n=>n.class==='android.widget.Switch'&&n.checked==='false'),30000,'System Wi-Fi did not switch off');await snap('wifi-off',off);
 report.wifiDisconnectObserved=true;
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
 await tap('Stop helper');await wait(s=>labels(s).some(v=>v.includes('HELPER_SERVICE_STATUS')&&v.includes('"servicePresent":false')),45000,'Control helper not stopped');
 const end=Date.now()+10000;while(r.status().peers){assert(Date.now()<end,'Control peers not closed');await sleep(100);}
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
 await command('probe',{fixture:'control',phase:'before-selection'});await command('probe',{fixture:'failed',phase:'before-selection'});
 await command('add-favorite');await command('select',{fixture:'control'});await command('send');await accept('control');await receivedHash(ready.fixtures.control,'control');
 await command('probe',{fixture:'control',phase:'after-success'});
 await command('select',{fixture:'failed'});await command('send');await accept('interrupted');
 const before=r.status().fromSender;const progressEnd=Date.now()+90000;
 while(r.status().fromSender-before<1048576){assert(Date.now()<progressEnd,'No real source data progression before disconnect');await sleep(250);}
 await command('probe',{fixture:'failed',phase:'during-upload'});
 await normalWifiDisconnect();await command('screenshot',{label:'after-disconnect'});
 await command('record-interruption',{kind:'normal-network-interruption',evidence:'../wifi-off.png; actual Android Settings switch verified true→false'});
 await sleep(15000);const after=await command('probe',{fixture:'failed',phase:'after-terminal-error'});report.cases.push({name:'normal-wifi-disconnect',probe:after});
 await command('quit');const quit=await command('probe',{fixture:'failed',phase:'after-quit'});report.cases.push({name:'after-app-quit',probe:quit});
 report.status='observations-complete';report.reproduced=false;
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
 if(session&&report.wifiSwitchMayHaveChanged){try{const xml=await source();const sw=nodes(xml).filter(n=>n.class==='android.widget.Switch'&&n.checked==='false');if(sw.length===1){const e=await wd('POST',base()+'/element',{using:'class name',value:'android.widget.Switch'});await wd('POST',base()+'/element/'+(e['element-6066-11e4-a52e-4f735466cecf']||e.ELEMENT)+'/click',{});await snap('wifi-restored');}}catch(e){report.cleanupErrors.push(redact(e.message));}}
 if(session){try{await wd('DELETE',base());}catch(e){report.cleanupErrors.push(redact(e.message));}}
 try{await r.stop();}catch(e){report.cleanupErrors.push(redact(e.message));}
 save('relay-trace.json',r.trace);save('relay-status.json',r.status());report.finishedUtc=new Date().toISOString();save('results.json',report);
}
