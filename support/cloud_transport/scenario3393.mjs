import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {writeFileSync} from 'node:fs';
const exec=promisify(execFile);
export default async function({session,wd,senderPort,transportStatus}) {
 const results=[];
 async function ui(action,x,y,label) { await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-ui.ps1','-Action',action,'-X',String(x),'-Y',String(y),'-Label',label]); }
 async function source(label) { const xml=await wd('GET',`/session/${session}/source`);writeFileSync(`evidence/${label}.xml`,xml);return xml; }
 async function lifecycle(label) {
  const failures=[];
  for(const command of ['dumpsys activity -p org.localsend.localsend_app processes','dumpsys activity processes','dumpsys activity']){
   try{
    const state=await wd('POST',`/session/${session}/execute/sync`,{script:'browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),args:[]});
    writeFileSync(`evidence/${label}-processes.txt`,state);writeFileSync(`evidence/${label}-lifecycle-capability.json`,JSON.stringify({command,failures},null,2));return;
   }catch(error){failures.push({command,error:String(error)});}
  }
  const appState=await wd('POST',`/session/${session}/appium/device/app_state`,{appId:'org.localsend.localsend_app'}).catch(error=>({error:String(error)}));
  writeFileSync(`evidence/${label}-lifecycle-capability.json`,JSON.stringify({failures,appState,processFlagsUnavailable:true},null,2));
 }
 async function click(label) { const e=await wd('POST',`/session/${session}/element`,{using:'accessibility id',value:label});await wd('POST',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{}); }
 try {
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows_release_ui_probe.ps1','-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-11-arm','-FixtureTimestampUtc','2026-10-11T00:00:00Z','-FixtureFileName','issue3393-payload.txt','-DiagnosticPeerPort',String(senderPort)]);
  await source('control-before');await lifecycle('control-before');
  await ui('click',246,266,'windows-favorites');
  await ui('click',145,205,'windows-send');
  let receiver='';
  for(let attempt=0;attempt<12;attempt++){receiver=await source('control-pending-'+attempt);if(receiver.includes('Accept'))break;await new Promise(resolve=>setTimeout(resolve,1000));}
  if(!receiver.includes('Accept'))throw new Error('Direct-accept control never reached the real Android acceptance prompt');
  await click('Accept');
  await new Promise(resolve=>setTimeout(resolve,3000));
  const accepted=await source('control-after-accept');
  if(accepted.includes('permission_allow_button')){
   const allow=await wd('POST',`/session/${session}/element`,{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'});
   await wd('POST',`/session/${session}/element/${allow['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
   await new Promise(resolve=>setTimeout(resolve,3000));await source('control-after-storage-permission');
  }
  await lifecycle('control-after-accept');await ui('snapshot',0,0,'windows-after-accept');
  const saved=await wd('POST',`/session/${session}/appium/device/pull_file`,{path:'/sdcard/Download/issue3393-payload.txt'});
  const data=Buffer.from(saved,'base64');writeFileSync('evidence/control-saved-payload.txt',data);
  const expected='LocalSend 2026-10-11T00:00:00Z timestamp diagnostic';
  if(data.toString()!==expected)throw new Error('Saved receiver content differs from sender payload');
  results.push({case:'direct-accept',actualWindowsSender:true,actualAndroidReceiver:true,savedContentVerified:true});
  const completed=await source('control-completed');
  if(completed.includes('permission_allow_button')){
   const allow=await wd('POST',`/session/${session}/element`,{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'});
   await wd('POST',`/session/${session}/element/${allow['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
  }
  await source('control-notification-handled');await click('Done');
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-repeat.ps1','-Case','picker-calibration']);
  let pending='';for(let i=0;i<15;i++){pending=await source('calibration-pending-'+i);if(pending.includes('Accept'))break;await new Promise(resolve=>setTimeout(resolve,1000));}
  if(!pending.includes('Accept'))throw new Error('Repeat sender did not reach receiver approval');
  await click('Options');await source('calibration-options');
  const edit=await wd('POST',`/session/${session}/element`,{using:'xpath',value:'(//android.widget.Button[@content-desc="" and @clickable="true"])[1]'});
  await wd('POST',`/session/${session}/element/${edit['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
  await source('calibration-native-picker');await lifecycle('calibration-native-picker');
  const shot=await wd('GET',`/session/${session}/screenshot`);writeFileSync('evidence/calibration-native-picker.png',Buffer.from(shot,'base64'));
  results.push({case:'picker-calibration',dwellTest:false,nativeUiObserved:true});
 } finally { writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2)); }
}
