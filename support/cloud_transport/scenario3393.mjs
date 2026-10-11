import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const exec=promisify(execFile);
export default async function({session,wd,senderPort,transportStatus}) {
 const results=[];
 const controlFile=`issue3393-${process.env.GITHUB_RUN_ID}-control.txt`;
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
 async function nativeText(text) { const e=await wd('POST',`/session/${session}/element`,{using:'xpath',value:`//*[@text="${text}"]`});await wd('POST',`/session/${session}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{}); }
 async function approvalReady(label) {
  const deadline=Date.now()+10000;let attempt=0;
  do {
   const element=await wd('POST',`/session/${session}/element`,{using:'accessibility id',value:'Accept'}).catch(error=>{
    if(!String(error).includes('no such element'))throw error;
    return null;
   });
   if(element){await source(`${label}-ready`);return element;}
   await source(`${label}-transition-${attempt++}`);
   await new Promise(resolve=>setTimeout(resolve,200));
  }while(Date.now()<deadline);
  throw new Error('Actual Accept control did not appear after returning from Options');
 }
 try {
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows_release_ui_probe.ps1','-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-11-arm','-FixtureTimestampUtc','2026-10-11T00:00:00Z','-FixtureFileName',controlFile,'-DiagnosticPeerPort',String(senderPort)]);
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
  const saved=await wd('POST',`/session/${session}/appium/device/pull_file`,{path:`/sdcard/Download/${controlFile}`});
  const data=Buffer.from(saved,'base64');writeFileSync('evidence/control-saved-payload.txt',data);
  const expected='LocalSend 2026-10-11T00:00:00Z timestamp diagnostic';
  if(data.toString()!==expected)throw new Error('Saved receiver content differs from sender payload');
  results.push({case:'direct-accept',fileName:controlFile,actualWindowsSender:true,actualAndroidReceiver:true,savedContentVerified:true});
  const completed=await source('control-completed');
  if(completed.includes('permission_allow_button')){
   const allow=await wd('POST',`/session/${session}/element`,{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'});
   await wd('POST',`/session/${session}/element/${allow['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
  }
  await source('control-notification-handled');await click('Done');
  const {default:observeSettings}=await import('./settings3393.mjs');await observeSettings({session,wd});
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-repeat.ps1','-Case','picker-calibration']);
  let pending='';for(let i=0;i<15;i++){pending=await source('calibration-pending-'+i);if(pending.includes('Accept'))break;await new Promise(resolve=>setTimeout(resolve,1000));}
  if(!pending.includes('Accept'))throw new Error('Repeat sender did not reach receiver approval');
  await click('Options');await source('calibration-options');
  const edit=await wd('POST',`/session/${session}/element`,{using:'xpath',value:'(//android.widget.Button[not(@content-desc) and @clickable="true"])[1]'});
  await wd('POST',`/session/${session}/element/${edit['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
  const entered=Date.now();await source('calibration-native-picker');await lifecycle('calibration-native-picker');await ui('snapshot',0,0,'windows-calibration-native-picker');
  const shot=await wd('GET',`/session/${session}/screenshot`);writeFileSync('evidence/calibration-native-picker.png',Buffer.from(shot,'base64'));
  await new Promise(resolve=>setTimeout(resolve,10000));
  await source('calibration-native-picker-after-hold');await lifecycle('calibration-native-picker-after-hold');await ui('snapshot',0,0,'windows-calibration-native-picker-after-hold');
  writeFileSync('evidence/calibration-picker-time.json',JSON.stringify({entered:new Date(entered).toISOString(),observedDwellMs:Date.now()-entered,exactTimingTrial:false},null,2));
  await nativeText('Documents');
  const documents=await source('calibration-documents-folder');
  if(!documents.includes('package="com.google.android.documentsui"')||!documents.includes('text="Documents"'))throw new Error('Native Documents folder was not observed');
  const folderButton=await wd('POST',`/session/${session}/element`,{using:'xpath',value:'//*[@text="Use this folder"]'});
  const folderButtonRect=await wd('GET',`/session/${session}/element/${folderButton['element-6066-11e4-a52e-4f735466cecf']}/rect`);
  writeFileSync('evidence/calibration-folder-button-rect.json',JSON.stringify(folderButtonRect,null,2));
  await nativeText('Use this folder');
  const permission=await source('calibration-folder-permission');
  if(permission.includes('text="Allow"')){await nativeText('Allow');}
  const destination=await source('calibration-selected-destination');
  if(!destination.includes('content://com.android.externalstorage.documents/tree/primary%3ADocuments'))throw new Error('Options did not show the selected Documents SAF destination');
  const selectedShot=await wd('GET',`/session/${session}/screenshot`);writeFileSync('evidence/calibration-selected-destination.png',Buffer.from(selectedShot,'base64'));
  await lifecycle('calibration-after-folder-selection');
  await wd('POST',`/session/${session}/back`,{});
  const approval=await approvalReady('calibration-before-accept');
  await wd('POST',`/session/${session}/element/${approval['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
  await new Promise(resolve=>setTimeout(resolve,3000));
  await source('calibration-after-accept');await lifecycle('calibration-after-accept');
  await ui('snapshot',0,0,'windows-calibration-after-accept');
  const savedShot=await wd('GET',`/session/${session}/screenshot`);writeFileSync('evidence/calibration-after-accept.png',Buffer.from(savedShot,'base64'));
  const repeatFile=`issue3393-${process.env.GITHUB_RUN_ID}-picker-calibration.txt`;
  const repeatSaved=await wd('POST',`/session/${session}/appium/device/pull_file`,{path:`/sdcard/Documents/${repeatFile}`});
  const repeatData=Buffer.from(repeatSaved,'base64');writeFileSync('evidence/calibration-saved-payload.txt',repeatData);
  if(repeatData.toString()!=='LocalSend issue3393 picker-calibration unique payload')throw new Error('Native-picker saved content differs from sender payload');
  const expectedHash=createHash('sha256').update('LocalSend issue3393 picker-calibration unique payload').digest('hex');
  const savedHash=createHash('sha256').update(repeatData).digest('hex');
  writeFileSync('evidence/calibration-saved-hash.json',JSON.stringify({fileName:repeatFile,size:repeatData.length,expectedSha256:expectedHash,savedSha256:savedHash,verified:savedHash===expectedHash},null,2));
  results.push({case:'picker-calibration',dwellTest:false,nativeUiObserved:true,fileName:repeatFile,destination:'/sdcard/Documents',savedContentVerified:true,savedSha256:savedHash});
 } finally { writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2)); }
}
