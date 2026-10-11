import assert from 'node:assert/strict';
import net from 'node:net';
import {randomBytes,createHash} from 'node:crypto';
import {writeFileSync,appendFileSync} from 'node:fs';
import {relay} from './relay.mjs';

const token=process.env.RELAY_TOKEN;
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const senderPort=Number(process.env.TRANSPORT_SENDER_PORT||53318);
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
try {
 const localUrl=new URL('https://www.browserstack.com/local/v1/list');localUrl.searchParams.set('auth_token',process.env.BROWSERSTACK_ACCESS_KEY);
 const localResponse=await fetch(localUrl,{signal:AbortSignal.timeout(30000)});
 let localText=await localResponse.text();
 for(const secret of [process.env.BROWSERSTACK_ACCESS_KEY,process.env.BROWSERSTACK_USERNAME,token])if(secret)localText=localText.replaceAll(secret,'[redacted]');
 writeFileSync('evidence/local-api-before-session.json',JSON.stringify({httpStatus:localResponse.status,ownIdentifier:process.env.BS_LOCAL_ID,ownIdentifierPresent:localText.includes(process.env.BS_LOCAL_ID),response:localText.slice(0,8000)},null,2));
 const planResponse=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
 if(!planResponse.ok)throw new Error('Could not verify live BrowserStack capacity');
 const plan=await planResponse.json();writeFileSync('evidence/plan-before-session.json',JSON.stringify(plan,null,2));
 const limit=Math.min(5,Number(plan.parallel_sessions_max_allowed),Number(plan.team_parallel_sessions_max_allowed));
 if(Number(plan.parallel_sessions_running)>=limit||Number(plan.queued_sessions)>0)throw new Error('BrowserStack capacity is occupied; no session was created');
 const caps={platformName:'Android','appium:deviceName':process.env.BS_DEVICE||'Vivo Y21','appium:platformVersion':process.env.BS_OS||'11.0','appium:automationName':'UiAutomator2','appium:app':process.env.BASELINE_APP,'appium:otherApps':[process.env.HELPER_APP],'appium:autoGrantPermissions':true,'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,projectName:'LocalSend issue2311',buildName:'issue2311-'+process.env.GITHUB_RUN_ID,sessionName:'issue2311 Windows1.17 Android15 direct-accept control',idleTimeout:300,debug:true,networkLogs:false,video:true,appiumVersion:'2.15.0'}};
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}});
 session=created.sessionId;
 assert(session,'Session ID missing');writeFileSync(process.platform==='win32'?'C:/tmp/helper/session-id':'/tmp/helper/session-id',session);
 await wd('POST',`/session/${session}/appium/settings`,{settings:{waitForIdleTimeout:0}});
 writeFileSync('evidence/appium-settings.json',JSON.stringify(await wd('GET',`/session/${session}/appium/settings`),null,2));
 console.log('BrowserStack control session created for '+caps['appium:deviceName']);
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.cloudtransport'});
 await new Promise(ok=>setTimeout(ok,3000));
 writeFileSync('evidence/helper-before-start.xml',await wd('GET',`/session/${session}/source`));
 await clickText('Start socket control');
 const helperStarted=await wd('GET',`/session/${session}/source`);writeFileSync('evidence/helper-after-start.xml',helperStarted);
 assert(helperStarted.includes('Socket control running'),'Actual helper Start button did not activate the service');
 await new Promise(ok=>setTimeout(ok,2500));
 for(const size of [0,1,65537]){
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
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});
 await new Promise(ok=>setTimeout(ok,4000));
 const source=await wd('GET',`/session/${session}/source`);writeFileSync('localsend-source.xml',source);
 console.log('Original LocalSend activated; relay target switched to localhost53317');
 if(process.env.SCENARIO_MODULE){const {pathToFileURL}=await import('node:url');const scenario=await import(pathToFileURL(process.env.SCENARIO_MODULE));await scenario.default({session,wd,senderHost:'127.0.0.1',senderPort,transportStatus:r.status});}
 const hold=Number(process.env.TRANSPORT_HOLD_SECONDS||0);
 if(hold){console.log('Transport integration window started');for(let i=0;i<hold;i+=20){await new Promise(ok=>setTimeout(ok,Math.min(20,hold-i)*1000));await wd('GET',`/session/${session}/source`);}}
} catch(error) {
 writeFileSync('mobile-control-error.txt',String(error));
 if(session){writeFileSync('helper-failure-source.xml',await wd('GET',`/session/${session}/source`).catch(()=>''));const screenshot=await wd('GET',`/session/${session}/screenshot`).catch(()=>'');if(screenshot)writeFileSync('helper-failure.png',Buffer.from(screenshot,'base64'));}
 throw error;
} finally {
 writeFileSync('mobile-control-final-status.json',JSON.stringify({results,metrics:r.status()},null,2));
 if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});
 if(session){
  try{
   const response=await fetch(`https://api-cloud.browserstack.com/app-automate/sessions/${session}.json`,{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
   if(!response.ok)throw new Error('Session details HTTP '+response.status);
   const detail=(await response.json()).automation_session;
   writeFileSync('evidence/browserstack-session.json',JSON.stringify({session,buildId:detail.build_hashed_id,browserUrl:detail.browser_url,device:detail.device,os:detail.os_version,app:detail.app_details},null,2));
   // Session metadata provides the supported log host; api-cloud returned 404
   // for a completed control whose device_logs_url uses api.browserstack.com.
   const logUrl=new URL(detail.device_logs_url);
   if(logUrl.protocol!=='https:'||!['api.browserstack.com','api-cloud.browserstack.com'].includes(logUrl.hostname)||logUrl.pathname!==`/app-automate/builds/${detail.build_hashed_id}/sessions/${session}/devicelogs`)throw new Error('Unexpected device log URL');
   const logResponse=await fetch(logUrl,{headers:{authorization:auth},signal:AbortSignal.timeout(30000)});
   if(!logResponse.ok)throw new Error('Device logs HTTP '+logResponse.status);
   let log=await logResponse.text();
   for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,token,auth])if(secret)log=log.replaceAll(secret,'[redacted]');
   writeFileSync('evidence/device-logs.txt',log);
   writeFileSync('evidence/cache-boundary-2311.txt',log.split('\n').filter(line=>line.includes('[DEBUG-2311]')).join('\n')+'\n');
  }catch(error){writeFileSync('evidence/device-logs-error.txt',String(error));}
 }
 await r.stop();
 writeFileSync('relay-trace.json',JSON.stringify(r.trace,null,2));
}
