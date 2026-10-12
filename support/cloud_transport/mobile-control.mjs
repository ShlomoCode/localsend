import assert from 'node:assert/strict';
import net from 'node:net';
import {randomBytes,createHash} from 'node:crypto';
import {readFileSync,writeFileSync,appendFileSync} from 'node:fs';
import {relay} from './relay.mjs';

const token=process.env.RELAY_TOKEN;
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const senderPort=Number(process.env.TRANSPORT_SENDER_PORT||53318);
const natural90=Number(process.env.PICKER_LONG_DWELL_MS)===90000;
const r=relay({token,tcpPort:senderPort});await r.start();let session;
async function wd(method,path,body,{timeoutMs=120000}={}) {
 const start=Date.now();
 let res,error;
 try {
  res=await fetch('https://hub-cloud.browserstack.com/wd/hub'+path,{method,headers:{authorization:auth,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(timeoutMs)});
  const json=await res.json();if(!res.ok||json.value?.error){let message=String(json.value?.message||'').slice(0,600);for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,token])if(secret)message=message.replaceAll(secret,'[redacted]');throw new Error('WebDriver '+res.status+' '+(json.value?.error||'')+' '+message);}return json.value;
 }catch(failure){error=String(failure);throw failure;}
 finally{appendFileSync('evidence/webdriver-boundaries.jsonl',JSON.stringify({utc:new Date(start).toISOString(),elapsedMs:Date.now()-start,timeoutMs,method,path:path.replace(/\/session\/[^/]+/,'/session/owned'),status:res?.status,error})+'\n');}
}
async function clickText(text){
 const e=await wd('POST',`/session/${session}/element`,{using:'accessibility id',value:text});
 await wd('POST',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
}
const results=[];
const helperMode=process.env.HELPER_SERVICE_MODE||'foreground';
const helperObservationMode=process.env.HELPER_OBSERVATION_MODE||'native';
if(!natural90){
 assert(['foreground','ordinary'].includes(helperMode),'Unknown helper service mode');
 assert(['native','public-supplementary'].includes(helperObservationMode),'Unknown helper observation mode');
 assert(helperObservationMode!=='public-supplementary'||helperMode==='ordinary','Supplementary trial requires ordinary helper');
}
const transportSnapshot=()=>({utc:new Date().toISOString(),status:r.status(),trace:r.trace.map(event=>({...event}))});
function assertJobBudget({caseName,holdMs,cleanupReserveMs}){
 const receipt={checkedAt:new Date().toISOString(),holdMs,cleanupReserveMs,requiredRemainingMs:holdMs+cleanupReserveMs,admitted:false};
 try{
  const job=JSON.parse(readFileSync('evidence/physical-job-budget.json','utf8').replace(/^\uFEFF/,''));
  receipt.job=job;
  assert(job.schema===1&&job.repository===process.env.GITHUB_REPOSITORY&&String(job.runId)===process.env.GITHUB_RUN_ID&&String(job.runAttempt)===process.env.GITHUB_RUN_ATTEMPT&&job.jobName==='physical-control'&&job.status==='in_progress'&&job.runnerName===process.env.RUNNER_NAME&&job.configuredTimeoutMs===1500000&&/^\d+$/.test(String(job.jobId)),'Current physical job budget identity unavailable');
  const startedAt=Date.parse(job.startedAt),retrievedAt=Date.parse(job.retrievedAt),checkedAt=Date.now();
  assert(Number.isFinite(startedAt)&&Number.isFinite(retrievedAt)&&startedAt<=retrievedAt&&retrievedAt<=checkedAt,'Job start clock or receipt unavailable');
  receipt.elapsedJobMs=checkedAt-startedAt;receipt.remainingJobMs=1500000-receipt.elapsedJobMs;receipt.deadlineUtc=new Date(startedAt+1500000).toISOString();
  assert(receipt.remainingJobMs>=receipt.requiredRemainingMs,'Insufficient remaining job time for 90-second hold plus 600-second cleanup reserve');
  receipt.admitted=true;
 }catch(error){receipt.error=String(error);throw error;}
 finally{writeFileSync(`evidence/${caseName}-job-budget-admission.json`,JSON.stringify(receipt,null,2));}
}
function allowlistedCapabilities(caps={}){
 if(!caps||typeof caps!=='object'||Array.isArray(caps))return {};
 const allowed=['platformName','deviceName','platformVersion','automationName','newCommandTimeout','idleTimeout','appium:deviceName','appium:platformVersion','appium:automationName','appium:newCommandTimeout'];
 const result={};
 for(const name of allowed)if(['string','number','boolean'].includes(typeof caps[name]))result[name]=caps[name];
 const options=caps['bstack:options'];
 if(options&&typeof options==='object')result['bstack:options']=Object.fromEntries(['idleTimeout','appiumVersion','video','debug','networkLogs','local'].filter(name=>['string','number','boolean'].includes(typeof options[name])).map(name=>[name,options[name]]));
 return result;
}
try {
 if(natural90){
  assert(process.env.DIAGNOSTIC_SCENARIO==='physical-control'&&process.env.BS_DEVICE==='Samsung Galaxy S25'&&process.env.BS_OS==='15.0'&&process.env.BACKGROUND_POLICY_EXPERIMENT==='samsung-enable-and-restore'&&helperMode==='foreground'&&helperObservationMode==='native','90-second condition configuration is not admitted');
  assert(Number(process.env.TRANSPORT_HOLD_SECONDS||0)===0,'90-second condition excludes transport keepalive holds');
 }
 const localUrl=new URL('https://www.browserstack.com/local/v1/list');localUrl.searchParams.set('auth_token',process.env.BROWSERSTACK_ACCESS_KEY);
 const localResponse=await fetch(localUrl,{signal:AbortSignal.timeout(30000)});
 let localText=await localResponse.text();
 for(const secret of [process.env.BROWSERSTACK_ACCESS_KEY,process.env.BROWSERSTACK_USERNAME,token])if(secret)localText=localText.replaceAll(secret,'[redacted]');
 writeFileSync('evidence/local-api-before-session.json',JSON.stringify({httpStatus:localResponse.status,ownIdentifier:process.env.BS_LOCAL_ID,ownIdentifierPresent:localText.includes(process.env.BS_LOCAL_ID),response:localText.slice(0,8000)},null,2));
 const caps={platformName:'Android','appium:deviceName':process.env.BS_DEVICE||'Vivo Y21','appium:platformVersion':process.env.BS_OS||'11.0','appium:automationName':'UiAutomator2','appium:app':process.env.BASELINE_APP,'appium:otherApps':[process.env.HELPER_APP],'appium:autoGrantPermissions':true,'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,projectName:'LocalSend issue3393',buildName:'issue3393-'+process.env.GITHUB_RUN_ID,sessionName:'issue3393 Windows1.17 Android15 direct-accept control',idleTimeout:300,debug:true,networkLogs:false,video:true,appiumVersion:'2.15.0'}};
 if(natural90)caps['appium:newCommandTimeout']=300;
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}});
 session=created.sessionId;
 assert(session,'Session ID missing');writeFileSync('/tmp/helper/session-id',session);
 if(natural90){
  const returned=allowlistedCapabilities(created.capabilities),requested=allowlistedCapabilities(caps);
  const newCommandValues=[returned['appium:newCommandTimeout'],returned.newCommandTimeout].filter(value=>value!==undefined);
  const idleValues=[returned['bstack:options']?.idleTimeout,returned.idleTimeout].filter(value=>value!==undefined);
  const receipt={sessionId:session,requested,returned,acceptedTimeoutEvidence:'returned session capabilities only; absent or conflicting values stop admission',newCommandValues,idleValues,admitted:newCommandValues.length>0&&newCommandValues.every(value=>value===300)&&idleValues.length>0&&idleValues.every(value=>value===300)};
  writeFileSync('evidence/natural90-capability-admission.json',JSON.stringify(receipt,null,2));
  assert(receipt.admitted,'Accepted 300-second newCommandTimeout and idleTimeout evidence unavailable or ambiguous');
 }
 await wd('POST',`/session/${session}/appium/settings`,{settings:{waitForIdleTimeout:0}});
 writeFileSync('evidence/appium-settings.json',JSON.stringify(await wd('GET',`/session/${session}/appium/settings`),null,2));
 console.log('BrowserStack control session created for '+caps['appium:deviceName']);
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.cloudtransport'});
 await new Promise(ok=>setTimeout(ok,3000));
 writeFileSync('evidence/helper-before-start.xml',await wd('GET',`/session/${session}/source`));
 await clickText('Start socket control');
 const helperStarted=await wd('GET',`/session/${session}/source`);writeFileSync('evidence/helper-after-start.xml',helperStarted);
 assert(helperStarted.includes('Socket control running'),'Actual helper Start button did not activate the service');
 assert(helperStarted.includes(`Service mode: ${helperMode}`),'Helper UI did not identify the built service mode');
 await new Promise(ok=>setTimeout(ok,2500));
 for(const size of [0,1,65537,8*1024*1024]){
  const data=randomBytes(size),expected=createHash('sha256').update(data).digest('hex');
  const s=net.connect({host:'127.0.0.1',port:senderPort,allowHalfOpen:true});s.setTimeout(180000,()=>s.destroy(new Error('Physical relay timeout')));s.end(data);
  const chunks=[];for await(const d of s)chunks.push(d);const reply=JSON.parse(Buffer.concat(chunks));
  assert.equal(reply.count,size);assert.equal(reply.sha256,expected);results.push({bytes:size,byteExact:true,replyAfterHalfClose:true});console.log('Physical control passed '+size+' bytes');
 }
 writeFileSync('mobile-control-results.json',JSON.stringify({device:caps['appium:deviceName'],os:caps['appium:platformVersion'],results,metrics:r.status()},null,2));
 await clickText('Stop helper');
 const drainStart=Date.now();while(r.status().pollPending && Date.now()-drainStart<25000)await new Promise(ok=>setTimeout(ok,250));
 writeFileSync('evidence/helper-poll-drain.json',JSON.stringify({elapsedMs:Date.now()-drainStart,status:r.status()},null,2));
 assert(!r.status().pollPending,'Old helper poll did not drain');await clickText('Relay to LocalSend');
 if(helperMode==='ordinary'){
  const {observeHelper}=await import(helperObservationMode==='public-supplementary'?'./helper-public-observation3393.mjs':'./helper-lifecycle3393.mjs');
  await observeHelper({session,wd,label:'relay-before-localsend',transportSnapshot,expectBackground:false});
 }
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});
 await new Promise(ok=>setTimeout(ok,4000));
 const source=await wd('GET',`/session/${session}/source`);writeFileSync('localsend-source.xml',source);
 console.log('Original LocalSend activated; relay target switched to localhost53317');
 if(process.env.SCENARIO_MODULE){const {pathToFileURL}=await import('node:url');const scenario=await import(pathToFileURL(process.env.SCENARIO_MODULE));await scenario.default({session,wd,senderHost:'127.0.0.1',senderPort,transportStatus:r.status,transportSnapshot,assertJobBudget});}
 const hold=Number(process.env.TRANSPORT_HOLD_SECONDS||0);
 if(hold){console.log('Transport integration window started');for(let i=0;i<hold;i+=20){await new Promise(ok=>setTimeout(ok,Math.min(20,hold-i)*1000));await wd('GET',`/session/${session}/source`);}}
} catch(error) {
 writeFileSync('mobile-control-error.txt',String(error));
 if(session){writeFileSync('helper-failure-source.xml',await wd('GET',`/session/${session}/source`).catch(()=>''));const screenshot=await wd('GET',`/session/${session}/screenshot`).catch(()=>'');if(screenshot)writeFileSync('helper-failure.png',Buffer.from(screenshot,'base64'));}
 throw error;
} finally {
 writeFileSync('mobile-control-final-status.json',JSON.stringify({results,metrics:r.status()},null,2));
 if(!natural90){
  if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});
  await r.stop();
  writeFileSync('relay-trace.json',JSON.stringify(r.trace,null,2));
 }else{
  const cleanupErrors=[];
  const deletion={attempted:!!session,sessionId:session||null,started:new Date().toISOString(),timeoutMs:30000,verified:false};
  const deletionStart=process.hrtime.bigint();
  try{
   if(session){
    const response=await fetch('https://hub-cloud.browserstack.com/wd/hub/session/'+session,{method:'DELETE',headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
    deletion.httpStatus=response.status;deletion.httpOk=response.ok;
    let raw=await response.text();
    for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,token])if(secret)raw=raw.replaceAll(secret,'[redacted]');
    deletion.rawResponse=raw;
    let body;try{body=JSON.parse(raw);}catch{throw new Error('Session deletion response was not JSON');}
    deletion.verified=response.ok&&body.value===null&&!body.error&&(body.status===undefined||body.status===0);
    if(!deletion.verified)throw new Error('Session deletion was not acknowledged by the provider');
   }
  }catch(error){deletion.error=String(error);cleanupErrors.push(deletion.error);}
  finally{deletion.ended=new Date().toISOString();deletion.elapsedMs=Number(process.hrtime.bigint()-deletionStart)/1e6;writeFileSync('evidence/natural90-session-delete.json',JSON.stringify(deletion,null,2));}
  const relayStop={started:new Date().toISOString(),before:r.status(),verified:false},relayStopStart=process.hrtime.bigint();
  try{await r.stop();relayStop.completed=true;relayStop.after=r.status();relayStop.verified=relayStop.after.peers===0&&!relayStop.after.pollPending;if(!relayStop.verified)throw new Error('Relay stop did not drain its peers/poll');}
  catch(error){relayStop.error=String(error);cleanupErrors.push(relayStop.error);}
  finally{relayStop.ended=new Date().toISOString();relayStop.elapsedMs=Number(process.hrtime.bigint()-relayStopStart)/1e6;writeFileSync('evidence/natural90-relay-stop.json',JSON.stringify(relayStop,null,2));writeFileSync('relay-trace.json',JSON.stringify(r.trace,null,2));}
  if(cleanupErrors.length)throw new Error('90-second cleanup incomplete: '+cleanupErrors.join('; '));
 }
}
