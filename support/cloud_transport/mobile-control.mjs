import assert from 'node:assert/strict';
import net from 'node:net';
import {randomBytes,createHash} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
import {relay} from './relay.mjs';

const token=process.env.RELAY_TOKEN;
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const senderPort=Number(process.env.TRANSPORT_SENDER_PORT||53318);
const r=relay({token,tcpPort:senderPort});await r.start();let session;
const sourceAudit={helperScannerInvocations:0,scannerGuardViolations:0,events:[]};
const sourceElements=new Map();let sourceActivePackage='org.localsend.cloudtransport';
function redactSourceAudit(value){
 if(typeof value==='string'){
  for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,token])if(secret)value=value.replaceAll(secret,'[redacted]');
  return value;
 }
 if(Array.isArray(value))return value.map(redactSourceAudit);
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,redactSourceAudit(item)]));
 return value;
}
async function wd(method,path,body) {
 if(process.env.ISSUE_2007_SOURCE_COMPARISON==='1'){
  const clickId=method==='POST'?path.match(/\/element\/([^/]+)\/click$/)?.[1]:null;
  const locator=clickId?sourceElements.get(clickId):null;
  const scannerRequest=/Finalize owned received file|Owned scan filename|Scan completed/.test(locator?.value||body?.value||'');
  const helperPointer=method==='POST'&&path.endsWith('/actions')&&sourceActivePackage==='org.localsend.cloudtransport';
  const unknownHelperClick=Boolean(clickId&&!locator&&sourceActivePackage==='org.localsend.cloudtransport');
  sourceAudit.events.push(redactSourceAudit({utc:new Date().toISOString(),method,path,body,locator,activePackage:sourceActivePackage,scannerRequest,helperPointer,unknownHelperClick}));
  if(scannerRequest||helperPointer||unknownHelperClick){sourceAudit.scannerGuardViolations++;throw new Error('Source comparison blocked helper scanner control or unverified helper input');}
 }
 const res=await fetch('https://hub-cloud.browserstack.com/wd/hub'+path,{method,headers:{authorization:auth,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(path==='/session'?240000:120000)});
 const json=await res.json();if(!res.ok||json.value?.error){let message=String(json.value?.message||'');for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,token])if(secret)message=message.replaceAll(secret,'[redacted]');const missingPath=message.includes('No such file or directory');throw new Error('WebDriver '+res.status+' '+(json.value?.error||'')+' '+message.slice(0,2000)+(missingPath?' [No such file or directory]':''));}
 if(process.env.ISSUE_2007_SOURCE_COMPARISON==='1'){
  if(method==='POST'&&/\/elements?$/.test(path))for(const element of Array.isArray(json.value)?json.value:[json.value]){
   if(element?.['element-6066-11e4-a52e-4f735466cecf'])sourceElements.set(element['element-6066-11e4-a52e-4f735466cecf'],redactSourceAudit(body));
  }
  if(method==='POST'&&path.endsWith('/activate_app'))sourceActivePackage=body.appId;
  if(method==='GET'&&path.endsWith('/current_package'))sourceActivePackage=json.value;
 }
 return json.value;
}
async function clickText(text){
 const e=await wd('POST',`/session/${session}/element`,{using:'accessibility id',value:text});
 await wd('POST',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
}
const results=[];
try {
 const sourceComparison=process.env.ISSUE_2007_SOURCE_COMPARISON==='1';
 const pair=sourceComparison?JSON.parse(readFileSync(process.env.ISSUE_2007_BUILD_PAIR_JSON,'utf8')):null;
 const caps={platformName:'Android','appium:deviceName':process.env.BS_DEVICE||'Vivo Y21','appium:platformVersion':process.env.BS_OS||'11.0','appium:automationName':'UiAutomator2','appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP],'appium:autoGrantPermissions':true,'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,projectName:'LocalSend issue 2007',buildName:'issue-2007-'+process.env.GITHUB_RUN_ID,sessionName:'issue-2007-original-app-control',debug:true,networkLogs:false,video:true,appiumVersion:'2.15.0'}};
 if(sourceComparison){
  assert.equal(caps['appium:deviceName'],'Samsung Galaxy S21');
  assert.equal(caps['appium:platformVersion'],'11.0');
  for(const label of ['baseline','candidate'])assert(/^bs:\/\/[0-9a-f]+$/.test(pair[label].browserstack_app_url));
  caps['appium:otherApps']=[pair.candidate.browserstack_app_url];
  // Official W3C location and command documented at:
  // https://www.browserstack.com/docs/app-automate/appium/advanced-features/test-app-upgrades
  caps['bstack:options'].midSessionInstallApps=[pair.candidate.browserstack_app_url,pair.baseline.browserstack_app_url];
  caps['bstack:options'].resignApp=false;
  const sourceArms=Number(process.env.ISSUE_2007_SOURCE_ARMS||'4');
  assert(sourceArms===2||sourceArms===4,'Source arm count must be 2 or 4 before allocation');
  assert(/^[0-9a-f]{40}$/.test(process.env.ISSUE_2007_EXPECTED_CANDIDATE_SHA),'Expected immutable candidate SHA is required before allocation');
  assert.equal(pair.candidate.source_sha,process.env.ISSUE_2007_EXPECTED_CANDIDATE_SHA,'Candidate identity must match before allocation');
  caps['bstack:options'].sessionName=sourceArms===2?'issue-2007-source-candidate-baseline':'issue-2007-source-candidate-baseline-candidate-baseline';
  writeFileSync('evidence/source-session-capabilities.json',JSON.stringify(redactSourceAudit(caps),null,2));
  const planResponse=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
  assert(planResponse.ok,'Fresh BrowserStack capacity probe failed before allocation');
  const plan=await planResponse.json();
  const availableLimit=Math.min(5,Number(plan.parallel_sessions_max_allowed));
  writeFileSync('evidence/source-allocation-capacity.json',JSON.stringify({checkedUtc:new Date().toISOString(),running:plan.parallel_sessions_running,limit:availableLimit,queued:plan.queued_sessions},null,2));
  assert(availableLimit>0&&Number(plan.parallel_sessions_running)<availableLimit,'No fresh shared BrowserStack capacity; do not queue or disturb other sessions');
 }
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}});
 session=created.sessionId;
 assert(session,'Session ID missing');writeFileSync(process.platform==='win32'?'C:/tmp/helper/session-id':'/tmp/helper/session-id',session);
 if(sourceComparison)writeFileSync('evidence/browserstack-session.json',JSON.stringify({session},null,2));
 console.log('BrowserStack control session created for '+caps['appium:deviceName']);
 await new Promise(ok=>setTimeout(ok,3000));await clickText('Start socket control');
 await new Promise(ok=>setTimeout(ok,2500));
 for(const size of [0,1,65537,8*1024*1024]){
  const data=randomBytes(size),expected=createHash('sha256').update(data).digest('hex');
  const s=net.connect({host:'127.0.0.1',port:senderPort,allowHalfOpen:true});s.setTimeout(180000,()=>s.destroy(new Error('Physical relay timeout')));s.end(data);
  const chunks=[];for await(const d of s)chunks.push(d);const reply=JSON.parse(Buffer.concat(chunks));
  assert.equal(reply.count,size);assert.equal(reply.sha256,expected);results.push({bytes:size,byteExact:true,replyAfterHalfClose:true});console.log('Physical control passed '+size+' bytes');
 }
 writeFileSync('mobile-control-results.json',JSON.stringify({device:caps['appium:deviceName'],os:caps['appium:platformVersion'],results,metrics:r.status()},null,2));
 await clickText('Stop helper');
 // The prior service can still hold one 15-second long pull. Let that
 // request finish before the replacement service starts another pull.
 console.log('Waiting for prior helper long-pull lifecycle to finish');
 await new Promise(ok=>setTimeout(ok,16000));
 const drainDeadline=Date.now()+15000;
 while(r.status().pollPending&&Date.now()<drainDeadline)await new Promise(ok=>setTimeout(ok,100));
 assert(!r.status().pollPending,'Prior helper poll did not drain after Stop');
 r.record('helper-old-poll-drained');
 await clickText('Relay to LocalSend');
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});
 await new Promise(ok=>setTimeout(ok,4000));
 const source=await wd('GET',`/session/${session}/source`);writeFileSync('localsend-source.xml',source);
 console.log('Original LocalSend activated; relay target switched to localhost53317');
 if(process.env.SCENARIO_MODULE){const {pathToFileURL}=await import('node:url');const scenario=await import(pathToFileURL(process.env.SCENARIO_MODULE));await scenario.default({session,wd,senderHost:'127.0.0.1',senderPort,transportStatus:r.status,sourceAudit});}
 const hold=Number(process.env.TRANSPORT_HOLD_SECONDS||0);
 if(hold){console.log('Transport integration window started');for(let i=0;i<hold;i+=20){await new Promise(ok=>setTimeout(ok,Math.min(20,hold-i)*1000));await wd('GET',`/session/${session}/source`);}}
} catch(error) {
 writeFileSync('mobile-control-error.txt',String(error));
 if(session){writeFileSync('helper-failure-source.xml',await wd('GET',`/session/${session}/source`).catch(()=>''));const screenshot=await wd('GET',`/session/${session}/screenshot`).catch(()=>'');if(screenshot)writeFileSync('helper-failure.png',Buffer.from(screenshot,'base64'));}
 throw error;
} finally {
 if(session){
  const logcat=await wd('POST',`/session/${session}/log`,{type:'logcat'}).catch(error=>({unavailable:String(error)}));
  writeFileSync('evidence/android-logcat.json',JSON.stringify(logcat,null,2));
 }
 writeFileSync('mobile-control-final-status.json',JSON.stringify({results,metrics:r.status()},null,2));
 writeFileSync('evidence/relay-trace.json',JSON.stringify(r.trace,null,2));
 if(process.env.ISSUE_2007_SOURCE_COMPARISON==='1')writeFileSync('evidence/source-webdriver-audit.json',JSON.stringify(sourceAudit,null,2));
 if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});
 await r.stop();
}
