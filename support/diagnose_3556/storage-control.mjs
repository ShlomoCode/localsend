import {writeFileSync,appendFileSync} from 'node:fs';
const auth='Basic '+Buffer.from(process.env.BROWSERSTACK_USERNAME+':'+process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
let session;
async function wd(method,path,body){
 const started=Date.now();
 const response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+path,{method,headers:{authorization:auth,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(120000)});
 const j=await response.json();appendFileSync('evidence/wd-commands.jsonl',JSON.stringify({at:new Date(started).toISOString(),method,path,body,status:response.status,elapsedMs:Date.now()-started})+'\n');if(!response.ok||j.value?.error)throw Error('WebDriver '+response.status+' '+String(j.value?.error||''));return j.value;
}
async function snap(name){writeFileSync('evidence/'+name+'.xml',await wd('GET',`/session/${session}/source`));writeFileSync('evidence/'+name+'.png',Buffer.from(await wd('GET',`/session/${session}/screenshot`),'base64'));}
async function touch(rect){await wd('POST',`/session/${session}/actions`,{actions:[{type:'pointer',id:'finger3556',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,origin:'viewport',x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},{type:'pointerDown',button:0},{type:'pause',duration:120},{type:'pointerUp',button:0}]}]});}
async function locate(using,value){const e=await wd('POST',`/session/${session}/element`,{using,value});return wd('GET',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/rect`);}
async function click(name){await touch(await locate('accessibility id',name));}
async function ui(expression){await touch(await locate('-android uiautomator','new UiSelector().'+expression));}
async function helperClick(name){await wd('POST',`/session/${session}/element`,{using:'-android uiautomator',value:'new UiScrollable(new UiSelector().scrollable(true)).scrollIntoView(new UiSelector().description('+JSON.stringify(name)+'))'});await click(name);}
async function reset(){await wd('POST',`/session/${session}/appium/device/terminate_app`,{appId:'org.localsend.localsend_app'});await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});await click('Send\nTab 2 of 3');}
async function ready(suffix,deadlineMs){const end=Date.now()+deadlineMs;while(Date.now()<end){const s=await wd('GET',`/session/${session}/source`);if(s.includes('FAILED')||s.includes('INSUFFICIENT_STORAGE'))throw Error('Fixture generation failed');if(s.includes('READY')&&s.includes(suffix))return s;await new Promise(r=>setTimeout(r,3000));}throw Error('Fixture staging deadline');}
function fixtureName(source){const m=source.match(/READY name=([^&<"]+)/);if(!m)throw Error('Fixture name absent');return m[1];}
async function observe(name,seconds){const start=Date.now();let waits=0;const observations=[];for(let i=0;i<=seconds;i+=5){const s=await wd('GET',`/session/${session}/source`);writeFileSync('evidence/'+name+'-'+i+'.xml',s);const anr=/isn.t responding|not responding/i.test(s);observations.push({elapsedMs:Date.now()-start,anr,selectedFiles:s.match(/content-desc="[^"]*files?[^"]*"/gi)});if(anr){await snap(name+'-anr-'+waits);await ui('textMatches("(?i)wait")');waits++;}if(i===0||i===seconds)await snap(name+'-'+i);await new Promise(r=>setTimeout(r,5000));}writeFileSync('evidence/'+name+'-observations.json',JSON.stringify({waits,observations},null,2));}
async function filePick(file,name){
 await reset();await click('File');
 const end=Date.now()+30000;while(Date.now()<end){if((await wd('GET',`/session/${session}/source`)).includes('com.google.android.documentsui'))break;await new Promise(r=>setTimeout(r,1000));}
 await snap(name+'-picker');
 if(file.endsWith('.bin')){await click('Show roots');await snap(name+'-roots');await ui('text("Downloads")');await ui('text("Issue3556")');await snap(name+'-owned-directory');}
 else {await click('Show roots');const roots=await wd('GET',`/session/${session}/source`);const count=[...roots.matchAll(/text="Recent"/g)].length;await ui('text("Recent").instance('+(count-1)+')');}
 await ui('textContains('+JSON.stringify(file)+')');await observe(name,30);
}
async function mediaPick(file,name){await reset();await click('Media');let source=await wd('GET',`/session/${session}/source`);if(source.includes('permissioncontroller'))await ui('textMatches("(?i)allow")');await snap(name+'-picker');await ui('descriptionContains('+JSON.stringify(file)+')');await snap(name+'-selected');await ui('descriptionStartsWith("Confirm")');await observe(name,name.startsWith('large')?300:30);}
async function warmShare(name,seconds){
 await reset();await snap(name+'-before');const sendBounds=await locate('accessibility id','Manual sending');
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.fixture3556'});await helperClick('Share owned fixture');await snap(name+'-chooser');await ui('text("LocalSend")');await snap(name+'-first-frame');
 // A normal next send action, using bounds observed on this app before sharing.
 await touch(sendBounds);await observe(name,seconds);
}
try{
 const plan=await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth}}).then(r=>r.json());writeFileSync('evidence/live-plan.json',JSON.stringify(plan));if(plan.parallel_sessions_running>=plan.parallel_sessions_max_allowed)throw Error('No live BrowserStack slot');
 const c=await wd('POST','/session',{capabilities:{alwaysMatch:{platformName:'Android','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0','appium:automationName':'UiAutomator2','appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP],'appium:autoGrantPermissions':true,'appium:newCommandTimeout':2400,'bstack:options':{idleTimeout:600,projectName:'LocalSend bug sprint',buildName:'issue3556-'+process.env.GITHUB_RUN_ID,sessionName:'issue3556-S20-selection-control',debug:true,video:true,networkLogs:false}},firstMatch:[{}]}});
 session=c.sessionId;if(!session)throw Error('No session ID');writeFileSync('evidence/session.json',JSON.stringify({session,device:'Samsung Galaxy S20',android:'10.0',baselineSha256:'82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3'}));
 await snap('capacity-before');await click('Stage small data');
 for(let i=0;i<30;i++){const s=await wd('GET',`/session/${session}/source`);if(s.includes('READY'))break;if(s.includes('FAILED')||s.includes('INSUFFICIENT'))throw Error('Staging failed');await new Promise(r=>setTimeout(r,1000));}
 await snap('small-data-ready');const smallData=fixtureName(await ready('.bin',30000));await click('Stage small video');
 for(let i=0;i<30;i++){const s=await wd('GET',`/session/${session}/source`);if(s.includes('READY')&&s.includes('.mp4'))break;await new Promise(r=>setTimeout(r,1000));}
 await snap('small-video-ready');const smallVideo=fixtureName(await ready('.mp4',30000));await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});await new Promise(r=>setTimeout(r,4000));await snap('baseline-initial');
 await wd('POST',`/session/${session}/timeouts`,{implicit:5000});
 await wd('POST',`/session/${session}/appium/settings`,{settings:{waitForIdleTimeout:1000,waitForSelectorTimeout:1000}});
 if(process.env.SELECTION_MATRIX==='true'){
   await filePick(smallVideo,'small-file-control');
   await mediaPick(smallVideo,'small-media-control');
   await warmShare('small-share-control',30);
   await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.fixture3556'});await helperClick('Stage 16GB video');const largeVideo=fixtureName(await ready('16000000000.mp4',1800000));await snap('large-video-ready');await filePick(largeVideo,'large-video-file');await mediaPick(largeVideo,'large-video-media');
   await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.fixture3556'});await helperClick('Refresh capacity');await snap('capacity-after-media');
   await warmShare('large-video-share-warm',300);
 }
 console.log('Selection diagnostics captured; no file transfer performed.');
 if(process.env.HOLD_SECONDS){console.log('Owned issue3556 session='+session);const end=Date.now()+Number(process.env.HOLD_SECONDS)*1000;while(Date.now()<end){await new Promise(r=>setTimeout(r,20000));try{await wd('GET',`/session/${session}/source`);}catch(e){console.log('Owned session was ended externally; closing runner.');break;}}await snap('selection-final').catch(()=>{});}
}catch(e){writeFileSync('evidence/storage-error.txt',String(e));if(session)await snap('failure').catch(()=>{});throw e;}
finally{if(session)await wd('DELETE',`/session/${session}`).catch(()=>{});}
