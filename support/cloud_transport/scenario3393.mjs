import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {waitForNativeControl} from './native-readiness.mjs';
import {exactNativeButton} from './native-labels.mjs';
const exec=promisify(execFile);
export default async function({session,wd,senderPort,transportStatus}) {
 const results=[];
 const policyOn=process.env.BACKGROUND_POLICY_EXPERIMENT==='oneplus-enable-and-restore';
 const samsungDiscovery=process.env.BACKGROUND_POLICY_EXPERIMENT==='samsung-policy-discovery';
 if(samsungDiscovery&&process.env.BS_DEVICE!=='Samsung Galaxy S25')throw new Error('Samsung policy discovery requires Samsung Galaxy S25');
 if(policyOn&&(process.env.BS_DEVICE!=='OnePlus 13R'||Number(process.env.PICKER_LONG_DWELL_MS)!==20000))throw new Error('Policy experiment requires OnePlus 13R and scheduled 20 s');
 let policyAttempted=false,policyModule;
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
 const prefix=`/session/${session}`,appPackage='org.localsend.localsend_app',pickerPackage='com.google.android.documentsui';
 const destinationUri='content://com.android.externalstorage.documents/tree/primary%3ADocuments';
 const appTarget=label=>({using:'xpath',value:`//*[@package="${appPackage}" and @content-desc="${label}" and @clickable="true"]`});
 const destinationTarget={using:'xpath',value:`//*[@package="${appPackage}" and contains(@content-desc,"${destinationUri}")]`};
 // The released Android app groups Destination and media options under one parent.
 // Index 0 is the pencil in the observed native tree; reject ambiguous identities.
 const destinationParent='//*[@package="org.localsend.localsend_app" and @class="android.widget.Button" and (starts-with(@content-desc,"Destination") or starts-with(@content-desc,"Save to folder")) and contains(@content-desc,"/storage/emulated/0/Download")]';
 const pencilChild='android.widget.Button[@package="org.localsend.localsend_app" and @index="0" and not(@content-desc) and @clickable="true" and @enabled="true"]';
 const editTarget={using:'xpath',value:`${destinationParent}[count(${destinationParent})=1 and count(${pencilChild})=1]/${pencilChild}`},documentRow={using:'xpath',value:'//*[@package="com.google.android.documentsui" and @resource-id="android:id/title" and @text="Documents"]/ancestor::*[@clickable="true"][1]'},folderTarget=exactNativeButton({packageName:pickerPackage,resourceId:'android:id/button1',text:'Use this folder'});
 async function ready(label,target,options={}) {return await waitForNativeControl({wd,prefix,label,...target,...options});}
 async function clickElement(element,label){
  const record={started:new Date().toISOString(),elementId:element['element-6066-11e4-a52e-4f735466cecf'],readiness:element.readiness};
  try{await wd('POST',prefix+'/element/'+record.elementId+'/click',{}, {timeoutMs:10000});record.succeeded=true;}
  catch(error){record.error=String(error);throw error;}
  finally{record.ended=new Date().toISOString();writeFileSync(`evidence/${label}-click.json`,JSON.stringify(record,null,2));}
 }
 async function click(label,phase='calibration') {const e=await ready(phase+'-'+label.toLowerCase(),appTarget(label));await clickElement(e,phase+'-'+label.toLowerCase());}
 async function approvalReady(label) {return await ready(label,appTarget('Accept'));}
 async function completedReady(label){
  const doneTarget={...appTarget('Done'),sourceIncludes:['content-desc="100, Finished"']};
  const choices=[doneTarget,{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'}];
  const e=await ready(label,{}, {choices,timeoutMs:20000});
  if(e.readiness.choice===1){await clickElement(e,label+'-permission');return await ready(label+'-done',doneTarget,{timeoutMs:20000,sourceIncludes:doneTarget.sourceIncludes});}
  return e;
 }
 async function selectedDestination(label){
  const allowTarget=exactNativeButton({packageName:pickerPackage,resourceId:'android:id/button1',text:'Allow'});
  const e=await ready(label,{}, {choices:[allowTarget,destinationTarget],requireClickable:false});
  if(e.readiness.choice===0)await clickElement(e,label+'-allow');
  return await ready(label+'-uri',destinationTarget,{requireClickable:false,sourceIncludes:['pane-title="Options"']});
 }

 try {
  if(policyOn){
   policyModule=await import('./oneplus-policy3393.mjs');
   await policyModule.setOnePlusBackground({session,wd,enabled:true,requireInitial:false,label:'policy-enable',onMutationAttempt:()=>{policyAttempted=true;}});
  }
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows_release_ui_probe.ps1','-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-11-arm','-FixtureTimestampUtc','2026-10-11T00:00:00Z','-FixtureFileName',controlFile,'-DiagnosticPeerPort',String(senderPort)]);
  await source('control-before');await lifecycle('control-before');
  await ui('click',246,266,'windows-favorites');
  await ui('click',145,205,'windows-send');
  const controlApproval=await approvalReady('control-pending');
  await clickElement(controlApproval,'control-accept');
  await completedReady('control-completion');
  await source('control-after-accept');
  await lifecycle('control-after-accept');await ui('snapshot',0,0,'windows-after-accept');
  const saved=await wd('POST',`/session/${session}/appium/device/pull_file`,{path:`/sdcard/Download/${controlFile}`});
  const data=Buffer.from(saved,'base64');writeFileSync('evidence/control-saved-payload.txt',data);
  const expected='LocalSend 2026-10-11T00:00:00Z timestamp diagnostic';
  if(data.toString()!==expected)throw new Error('Saved receiver content differs from sender payload');
  const controlHash=createHash('sha256').update(data).digest('hex');
  writeFileSync('evidence/control-saved-hash.json',JSON.stringify({fileName:controlFile,size:data.length,expectedSha256:createHash('sha256').update(expected).digest('hex'),savedSha256:controlHash,verified:true},null,2));
  results.push({case:'direct-accept',fileName:controlFile,actualWindowsSender:true,actualAndroidReceiver:true,savedContentVerified:true});
  await source('control-completed');
  const controlDone=await completedReady('control-return');
  await clickElement(controlDone,'control-done');
  await source('control-notification-handled');
  const {default:observeSettings}=await import('./settings3393.mjs');await observeSettings({session,wd});
  if(samsungDiscovery)return;
  if(policyOn){
   const {default:timedPicker}=await import('./picker3393-timed.mjs');
   await timedPicker({session,wd,source,lifecycle,ui,click,ready,clickElement,approvalReady,completedReady,selectedDestination,editTarget,documentRow,folderTarget,results,onlyLong:true,skipInitialCompletion:true,semanticSelectionAfterHold:true});
   return;
  }
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-repeat.ps1','-Case','picker-calibration']);
  await approvalReady('calibration-pending');
  await click('Options');await source('calibration-options');
  const edit=await ready('calibration-edit',editTarget,{sourceIncludes:['pane-title="Options"']});
  await clickElement(edit,'calibration-edit');
  await ready('calibration-picker-observed',documentRow,{sourceIncludes:['package="com.google.android.documentsui"']});
  const entered=Date.now();await source('calibration-native-picker');await lifecycle('calibration-native-picker');await ui('snapshot',0,0,'windows-calibration-native-picker');
  const shot=await wd('GET',`/session/${session}/screenshot`);writeFileSync('evidence/calibration-native-picker.png',Buffer.from(shot,'base64'));
  await new Promise(resolve=>setTimeout(resolve,10000));
  await source('calibration-native-picker-after-hold');await lifecycle('calibration-native-picker-after-hold');await ui('snapshot',0,0,'windows-calibration-native-picker-after-hold');
  writeFileSync('evidence/calibration-picker-time.json',JSON.stringify({entered:new Date(entered).toISOString(),observedSincePickerReadinessMs:Date.now()-entered,exactTimingTrial:false},null,2));
  await clickElement(await ready('calibration-documents-row',documentRow),'calibration-documents-row');
  const folderButton=await ready('calibration-use-folder',folderTarget,{sourceIncludes:['class="android.widget.TextView" text="Documents"']});
  const folderButtonRect=folderButton.readiness.rect;
  writeFileSync('evidence/calibration-documents-folder.xml',readFileSync(folderButton.readiness.sourceFile));
  writeFileSync('evidence/calibration-folder-button-rect.json',JSON.stringify(folderButtonRect,null,2));
  await clickElement(folderButton,'calibration-use-folder');
  await selectedDestination('calibration-destination');
  const destination=await source('calibration-selected-destination');
  if(!destination.includes('content://com.android.externalstorage.documents/tree/primary%3ADocuments'))throw new Error('Options did not show the selected Documents SAF destination');
  const selectedShot=await wd('GET',`/session/${session}/screenshot`);writeFileSync('evidence/calibration-selected-destination.png',Buffer.from(selectedShot,'base64'));
  await lifecycle('calibration-after-folder-selection');
  await wd('POST',`/session/${session}/back`,{});
  const approval=await approvalReady('calibration-before-accept');
  await clickElement(approval,'calibration-accept');
  await completedReady('calibration-completion');
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
  const {default:timedPicker}=await import('./picker3393-timed.mjs');
  await timedPicker({session,wd,source,lifecycle,ui,click,ready,clickElement,approvalReady,completedReady,selectedDestination,editTarget,documentRow,folderTarget,results});
 } finally {
  try{if(policyAttempted)await policyModule.setOnePlusBackground({session,wd,enabled:false,label:'policy-restore'});}
  finally{writeFileSync('evidence/scenario-results.json',JSON.stringify({results,policyOnExperiment:policyOn,samsungPolicyDiscovery:samsungDiscovery,transport:transportStatus()},null,2));}
 }
}
