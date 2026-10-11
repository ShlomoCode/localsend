import assert from 'node:assert/strict';
import net from 'node:net';
import {randomBytes,createHash} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {relay} from './relay.mjs';

const token=process.env.RELAY_TOKEN;
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const r=relay({token});await r.start();let session;
async function wd(method,path,body) {
 const res=await fetch('https://hub-cloud.browserstack.com/wd/hub'+path,{method,headers:{authorization:auth,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(120000)});
 const json=await res.json();if(!res.ok||json.value?.error)throw new Error('WebDriver '+res.status+' '+(json.value?.error||''));return json.value;
}
async function clickText(text){
 const e=await wd('POST',`/session/${session}/element`,{using:'xpath',value:`//*[@text="${text}"]`});
 await wd('POST',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
}
const results=[];
try {
 const caps={platformName:'Android','appium:deviceName':process.env.BS_DEVICE||'Vivo Y21','appium:platformVersion':process.env.BS_OS||'11.0','appium:automationName':'UiAutomator2','appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP],'appium:autoGrantPermissions':true,'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,projectName:'LocalSend cloud transport',buildName:'cloud-transport-'+process.env.GITHUB_RUN_ID,sessionName:'physical socket control',debug:true,networkLogs:false,video:true,appiumVersion:'2.15.0'}};
 const created=await wd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}});
 session=created.sessionId;
 assert(session,'Session ID missing');writeFileSync('/tmp/helper/session-id',session);
 console.log('BrowserStack control session created for '+caps['appium:deviceName']);
 await new Promise(ok=>setTimeout(ok,3000));await clickText('Start socket control');
 await new Promise(ok=>setTimeout(ok,2500));
 for(const size of [0,1,65537,8*1024*1024]){
  const data=randomBytes(size),expected=createHash('sha256').update(data).digest('hex');
  const s=net.connect({host:'127.0.0.1',port:53318,allowHalfOpen:true});s.setTimeout(180000,()=>s.destroy(new Error('Physical relay timeout')));s.end(data);
  const chunks=[];for await(const d of s)chunks.push(d);const reply=JSON.parse(Buffer.concat(chunks));
  assert.equal(reply.count,size);assert.equal(reply.sha256,expected);results.push({bytes:size,byteExact:true,replyAfterHalfClose:true});console.log('Physical control passed '+size+' bytes');
 }
 writeFileSync('mobile-control-results.json',JSON.stringify({device:caps['appium:deviceName'],os:caps['appium:platformVersion'],results,metrics:r.status()},null,2));
 await clickText('Stop helper');await clickText('Relay to LocalSend');
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});
 await new Promise(ok=>setTimeout(ok,4000));
 const source=await wd('GET',`/session/${session}/source`);writeFileSync('localsend-source.xml',source);
 console.log('Original LocalSend activated; relay target switched to localhost53317');
 const hold=Number(process.env.TRANSPORT_HOLD_SECONDS||0);
 if(hold){console.log('Transport integration window started');for(let i=0;i<hold;i+=20){await new Promise(ok=>setTimeout(ok,Math.min(20,hold-i)*1000));await wd('GET',`/session/${session}/source`);}}
} finally {
 writeFileSync('mobile-control-final-status.json',JSON.stringify({results,metrics:r.status()},null,2));
 if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});
 await r.stop();
}
