import {writeFileSync} from 'node:fs';
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
let session;
async function wd(method,path,body){
 const response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+path,{method,headers:{authorization:auth,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(120000)});
 const j=await response.json();if(!response.ok||j.value?.error)throw Error('WebDriver '+response.status+' '+String(j.value?.error||''));return j.value;
}
async function snap(name){writeFileSync('evidence/'+name+'.xml',await wd('GET',`/session/${session}/source`));writeFileSync('evidence/'+name+'.png',Buffer.from(await wd('GET',`/session/${session}/screenshot`),'base64'));}
async function click(name){const e=await wd('POST',`/session/${session}/element`,{using:'accessibility id',value:name});await wd('POST',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{});}
try{
 const plan=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth}}).then(r=>r.json());writeFileSync('evidence/live-plan.json',JSON.stringify(plan));if(plan.parallel_sessions_running>=plan.parallel_sessions_max_allowed)throw Error('No live BrowserStack slot');
 const c=await wd('POST','/session',{capabilities:{alwaysMatch:{platformName:'Android','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0','appium:automationName':'UiAutomator2','appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP],'appium:autoGrantPermissions':true,'bstack:options':{projectName:'LocalSend bug sprint',buildName:'issue3556-'+process.env.GITHUB_RUN_ID,sessionName:'issue3556-S20-storage-control',debug:true,video:true,networkLogs:false}},firstMatch:[{}]}});
 session=c.sessionId;if(!session)throw Error('No session ID');writeFileSync('evidence/session.json',JSON.stringify({session,device:'Samsung Galaxy S20',android:'10.0',baselineSha256:'82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3'}));
 await snap('capacity-before');await click('Stage small data');
 for(let i=0;i<30;i++){const s=await wd('GET',`/session/${session}/source`);if(s.includes('READY'))break;if(s.includes('FAILED')||s.includes('INSUFFICIENT'))throw Error('Staging failed');await new Promise(r=>setTimeout(r,1000));}
 await snap('small-data-ready');await click('Stage small video');
 for(let i=0;i<30;i++){const s=await wd('GET',`/session/${session}/source`);if(s.includes('READY')&&s.includes('.mp4'))break;await new Promise(r=>setTimeout(r,1000));}
 await snap('small-video-ready');await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});await new Promise(r=>setTimeout(r,4000));await snap('baseline-initial');
 console.log('S20 storage and small fixture snapshots captured. No large file staged or transferred.');
 if(process.env.HOLD_SECONDS){console.log('Owned issue3556 session='+session);const end=Date.now()+Number(process.env.HOLD_SECONDS)*1000;while(Date.now()<end){await new Promise(r=>setTimeout(r,20000));try{await wd('GET',`/session/${session}/source`);}catch(e){console.log('Owned session was ended externally; closing runner.');break;}}await snap('selection-final').catch(()=>{});}
}catch(e){writeFileSync('evidence/storage-error.txt',String(e));if(session)await snap('failure').catch(()=>{});throw e;}
finally{if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});}
