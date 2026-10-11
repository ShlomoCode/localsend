import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {existsSync,writeFileSync,readFileSync,createWriteStream} from 'node:fs';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {waitForNativeControl} from './native-readiness.mjs';

export default async function({session,wd,senderHost,senderPort,transportStatus}) {
 const prefix=`/session/${session}`;
 const deletionTiming=process.env.ISSUE_2007_DELETE_TIMING||'absence';
 const requestedDeletionAction=process.env.ISSUE_2007_DELETE_ACTION||'permanent';
 const purgeTrash=requestedDeletionAction==='trash-purge';
 const persistentSaf=process.env.ISSUE_2007_DESTINATION==='saf-documents-persistent';
 const safDocuments=persistentSaf||process.env.ISSUE_2007_DESTINATION==='saf-documents';
 const deviceFolder=safDocuments?'/sdcard/Documents':'/sdcard/Download';
 const windows=process.platform==='win32';
 const samsungFiles=(process.env.BS_DEVICE||'').startsWith('Samsung ');
 const fileManagerPackage=samsungFiles?'com.sec.android.app.myfiles':'com.google.android.apps.nbu.files';
 const fileManagerName=samsungFiles?'Samsung My Files':'Google Files';
 await wd('POST',prefix+'/appium/settings',{settings:{waitForIdleTimeout:0}});
 async function snapshot(stage){
  writeFileSync(`evidence/android-${stage}.xml`,await wd('GET',prefix+'/source'));
  writeFileSync(`evidence/android-${stage}.png`,Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
 }
 async function returnedApproval(stage){
  const element=await waitForNativeControl({wd,prefix,using:'accessibility id',value:'Accept',label:stage+'-returned-approval'});
  await snapshot(stage+'-approval-ready');
  return element;
 }
 async function chooseSafDocuments(stage){
  if(!safDocuments)return;
  let controlIndex=0;
  async function click(using,value){
   const element=await waitForNativeControl({wd,prefix,using,value,label:stage+'-saf-control-'+controlIndex++});
   await wd('POST',prefix+'/element/'+element['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  }
  if(persistentSaf&&stage!=='settings'){
   await click('accessibility id','Options');
   await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[contains(@content-desc,"primary%3ADocuments") or contains(@content-desc,"primary:Documents")]',label:stage+'-persistent-saf-destination'});
   await snapshot(stage+'-persistent-saf-options');
   writeFileSync('evidence/'+stage+'-saf-selection.json',JSON.stringify({selectionTiming:'Persistent Settings selection before first transfer; Options verification only at each approval',actualNativePicker:false,persistentNativeSelection:'settings-saf-selection.json',selectedDocumentsObserved:true,physicalPath:deviceFolder,source:'android-'+stage+'-persistent-saf-options.xml'},null,2));
   await wd('POST',prefix+'/back',{});
   return;
  }
  if(persistentSaf){
   await click('xpath','//*[contains(@content-desc,"Settings") and @clickable="true"]');
   await snapshot('settings-before-scroll');
   await waitForNativeControl({wd,prefix,using:'-android uiautomator',value:'new UiScrollable(new UiSelector().scrollable(true)).scrollIntoView(new UiSelector().description("(Downloads)"))',label:'settings-save-folder-scroll'});
   await snapshot('settings-destination-ready');
   await click('xpath','//android.widget.Button[@content-desc="(Downloads)"]');
  }else{
   await click('accessibility id','Options');
   await snapshot(stage+'-options');
   await click('xpath','//*[@content-desc="Save to folder"]/following-sibling::android.widget.Button[1]');
  }
  let nativeSource;
  const pickerDeadline=Date.now()+10000;
  let pickerAttempt=0;
  do{
   await snapshot(stage+'-native-picker-'+pickerAttempt);
   nativeSource=readFileSync(`evidence/android-${stage}-native-picker-${pickerAttempt++}.xml`,'utf8');
   if(/com\.(google\.)?android\.documentsui/.test(nativeSource))break;
   await new Promise(r=>setTimeout(r,200));
  }while(Date.now()<pickerDeadline);
  assert(/com\.(google\.)?android\.documentsui/.test(nativeSource),'Real native SAF picker not observed');
  // The observed resend activity lacked a directory-selection footer. Record the
  // actual activity/intent and allow one Back/reopen from the verified Options
  // page; never treat an ordinary Documents browser as directory selection.
  for(let launch=0;launch<2;launch++){
   const activity={};
   for(const field of ['current_activity','current_package']){
    activity[field]=await wd('GET',prefix+'/appium/device/'+field).catch(error=>{
     if(!/unsupported|unknown command|not implemented/i.test(String(error)))throw error;
     return {unsupported:String(error)};
    });
   }
   writeFileSync('evidence/'+stage+'-native-activity-'+launch+'.json',JSON.stringify(activity,null,2));
   if(/text="(?:Use this folder|USE THIS FOLDER)"/.test(nativeSource))break;
   const footerDeadline=Date.now()+3000;
   do{
    nativeSource=await wd('GET',prefix+'/source');
    writeFileSync('evidence/'+stage+'-native-footer-'+launch+'.xml',nativeSource);
    if(/text="(?:Use this folder|USE THIS FOLDER)"/.test(nativeSource))break;
    await new Promise(r=>setTimeout(r,200));
   }while(Date.now()<footerDeadline);
   // The Android 11 storage root can show a disabled selection footer.
   // Presence proves selection mode; enabled state is checked in Documents.
   if(/text="(?:Use this folder|USE THIS FOLDER)"/.test(nativeSource))break;
   if(launch===1)throw new Error('Actual native directory-selection footer absent after one verified reopen');
   await wd('POST',prefix+'/back',{});
   const backDeadline=Date.now()+10000;
   let backAttempt=0;
   do{
    nativeSource=await wd('GET',prefix+'/source');
    writeFileSync('evidence/'+stage+'-native-after-back-'+(backAttempt++)+'.xml',nativeSource);
    if(/text="(?:Use this folder|USE THIS FOLDER)"/.test(nativeSource)||nativeSource.includes('content-desc="Save to folder"'))break;
    await new Promise(r=>setTimeout(r,200));
   }while(Date.now()<backDeadline);
   // On the observed repeat picker, Back reaches its storage parent and
   // restores the selection footer; it does not exit to LocalSend Options.
   if(/text="(?:Use this folder|USE THIS FOLDER)"/.test(nativeSource)){
    writeFileSync('evidence/'+stage+'-native-recovery.json',JSON.stringify({method:'Native Back to selector parent, then select Documents again',source:stage+'-native-after-back-'+(backAttempt-1)+'.xml'},null,2));
    break;
   }
   await waitForNativeControl({wd,prefix,using:'accessibility id',value:'Save to folder',label:stage+'-options-after-native-back'});
   await click('xpath','//*[@content-desc="Save to folder"]/following-sibling::android.widget.Button[1]');
   await waitForNativeControl({wd,prefix,using:'id',value:'com.google.android.documentsui:id/toolbar',label:stage+'-reopened-native-picker'});
   nativeSource=await wd('GET',prefix+'/source');
  }
  const documentsSelected=(nativeSource.match(/<[^>]+>/g)||[]).some(tag=>tag.includes('text="Documents"')&&tag.includes('resource-id="com.google.android.documentsui:id/breadcrumb_text"'));
  if(!documentsSelected){
   const row=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="Documents" and @resource-id="android:id/title"]',label:stage+'-native-documents-row',stableRect:true});
   const rect=await wd('GET',prefix+'/element/'+row['element-6066-11e4-a52e-4f735466cecf']+'/rect');
   const point={x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)};
   writeFileSync('evidence/'+stage+'-native-documents-input.json',JSON.stringify({method:'Actual W3C touch tap at freshly observed native Documents row label',utc:new Date().toISOString(),rect,point},null,2));
   await wd('POST',prefix+'/actions',{actions:[{type:'pointer',id:'folder-finger',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,...point},{type:'pointerDown',button:0},{type:'pointerUp',button:0}]}]});
  }
  await snapshot(stage+'-native-documents');
  await click('xpath','//*[@text="Use this folder" or @text="USE THIS FOLDER"]');
  await snapshot(stage+'-native-permission');
  let permissionPromptObserved=/text="(?:Allow|ALLOW)"/.test(readFileSync(`evidence/android-${stage}-native-permission.xml`,'utf8'));
  let permissionAccepted=false;
  if(permissionPromptObserved){await click('xpath','//*[@text="Allow" or @text="ALLOW"]');permissionAccepted=true;}
  let selected;
  const selectionDeadline=Date.now()+10000;
  let selectionAttempt=0;
  do{
   await snapshot(stage+'-selected-directory-'+selectionAttempt);
   selected=readFileSync(`evidence/android-${stage}-selected-directory-${selectionAttempt++}.xml`,'utf8');
   if(!permissionAccepted&&/text="(?:Allow|ALLOW)"/.test(selected)){
    permissionPromptObserved=true;
    await click('xpath','//*[@text="Allow" or @text="ALLOW"]');
    permissionAccepted=true;
   }
   if(selected.includes('/storage/emulated/0/Documents')||selected.includes('primary%3ADocuments')||selected.includes('primary:Documents'))break;
   await new Promise(r=>setTimeout(r,200));
  }while(Date.now()<selectionDeadline);
  assert(selected.includes('/storage/emulated/0/Documents')||selected.includes('primary%3ADocuments')||selected.includes('primary:Documents'),'Selected Documents destination not observed');
  writeFileSync(`evidence/${stage}-saf-selection.json`,JSON.stringify({selectionTiming:persistentSaf?'Persistent Settings selection before first transfer':'Per-transfer Options selection before Accept',actualNativePicker:true,permissionPromptObserved,permissionAccepted,selectedDocumentsObserved:true,physicalPath:deviceFolder,source:`android-${stage}-selected-directory-${selectionAttempt-1}.xml`,apiBasis:'Official 1.17 source selects pickDirectoryPathAndroid on SDK27+ and SafStream for content URI. Native Documents selection observed, not inferred from path alone.'},null,2));
  if(persistentSaf)await click('xpath','//*[contains(@content-desc,"Receive") and @clickable="true"]');
  else await wd('POST',prefix+'/back',{});
 }
 async function waitFile(file,ms){
  const end=Date.now()+ms;
  while(!existsSync(file)){
   if(desktop.exitCode!==null)throw new Error('Desktop GUI driver exited '+desktop.exitCode);
   if(Date.now()>end)throw new Error('Desktop GUI milestone timeout: '+file);
   await new Promise(r=>setTimeout(r,500));
  }
 }
 async function closeReceiverFinished(){
  let done;
  const deadline=Date.now()+5000;
  do {
   done=await wd('POST',prefix+'/element',{using:'xpath',value:'//*[@content-desc="Done" and @clickable="true"]'}).catch(error=>{
    if(!String(error).includes('no such element'))throw error;
    return null;
   });
   if(done)break;
   await new Promise(r=>setTimeout(r,100));
  } while(Date.now()<deadline);
  assert(done,'Original receiver Finished screen did not render its actual Done button');
  await wd('POST',prefix+'/element/'+done['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
 }
 writeFileSync('evidence/browserstack-session.json',JSON.stringify({session,device:process.env.BS_DEVICE||'Vivo Y21',os:'Android '+(process.env.BS_OS||'11.0')},null,2));
 let receiverReady=false;
 for(let attempt=0;attempt<20;attempt++){
  await snapshot('initial-'+attempt);
  const source=readFileSync(`evidence/android-initial-${attempt}.xml`,'utf8');
  if(source.includes('Receive')){receiverReady=true;break;}
  await new Promise(r=>setTimeout(r,2000));
 }
 assert(receiverReady,'Original Android app did not render Receive within 40 seconds');
 if(persistentSaf)await chooseSafDocuments('settings');
 const fileManagerInventory=[];
 for(const appId of ['com.vivo.filemanager','com.android.filemanager','com.google.android.apps.nbu.files','com.sec.android.app.myfiles']){
  const installed=await wd('POST',prefix+'/appium/device/app_installed',{appId}).catch(error=>({error:String(error)}));
  fileManagerInventory.push({appId,installed});
 }
 writeFileSync('evidence/installed-file-managers.json',JSON.stringify({method:'Read-only Appium isAppInstalled for normal preinstalled file managers',apps:fileManagerInventory},null,2));
 const installedPackages=await wd('POST',prefix+'/execute/sync',{script:'browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command:'pm list packages'}}),args:[]}).catch(error=>({error:String(error)}));
 writeFileSync('evidence/installed-packages.json',JSON.stringify({method:'Read-only BrowserStack adbShell pm list packages',result:installedPackages},null,2));
 if(process.env.ISSUE_2007_VARIANT==='provider-probe'){
  const {probeInstalledProviders}=await import('./2007-provider-probe.mjs');
  await probeInstalledProviders({wd,prefix});
  return;
 }
 const before=await wd('POST',prefix+'/appium/device/pull_file',{path:deviceFolder+'/A.txt'}).catch(error=>{
  if(!String(error).includes('No such file or directory'))throw error;
  return null;
 });
 assert.equal(before,null,'Baseline A.txt already exists on the device; do not mistake an old file for this transfer');
 const beforeNumbered=await wd('POST',prefix+'/appium/device/pull_file',{path:deviceFolder+'/A-2.txt'}).catch(error=>{
  if(!String(error).includes('No such file or directory'))throw error;
  return null;
 });
 assert.equal(beforeNumbered,null,'Baseline A-2.txt already exists; numbered-path observation would be ambiguous');
 writeFileSync('evidence/baseline-path-absence.json',JSON.stringify({path:deviceFolder+'/A.txt',absent:true,utc:new Date().toISOString()},null,2));
 const desktop=windows?spawn('pwsh',['-NoProfile','-File','support/diagnostics/2007-windows-sender.ps1'],{env:{...process.env,TRANSPORT_SENDER_PORT:String(senderPort)}}):spawn('dbus-run-session',['--','xvfb-run','-a','-s','-screen 0 1200x800x24','bash','support/diagnostics/2007-physical-sender.sh'],{env:{...process.env,ISSUE_2007_RESEND:'1'}});
 const log=createWriteStream('evidence/desktop-process.log');desktop.stdout.pipe(log);desktop.stderr.pipe(log);
 let proxy;
 const ownedProxySockets=new Set();
 try {
  if(!windows){
  await waitFile('evidence/desktop-stopped',120000);
  proxy=net.createServer({allowHalfOpen:true},client=>{
   const remote=net.connect({host:senderHost,port:senderPort,allowHalfOpen:true});
   for(const socket of [client,remote]){ownedProxySockets.add(socket);socket.once('close',()=>ownedProxySockets.delete(socket));}
   client.pipe(remote);remote.pipe(client);
   client.on('error',()=>remote.destroy());remote.on('error',()=>client.destroy());
  });
  await new Promise((resolve,reject)=>{proxy.once('error',reject);proxy.listen(53317,'127.0.0.1',resolve);});
  writeFileSync('evidence/transport-ready','transparent TCP forwarding only\n');
  }
  await waitFile('evidence/transfer-requested',windows?240000:90000);
  let accept;
  for(let i=0;i<20;i++){
   await snapshot('request-'+i);
   accept=await wd('POST',prefix+'/element',{using:'accessibility id',value:'Accept'}).catch(()=>null);
   if(accept)break;
   await new Promise(r=>setTimeout(r,1000));
  }
  assert(accept,'Original Android app did not render receive approval');
  await chooseSafDocuments('baseline');
  if(safDocuments)accept=await returnedApproval('baseline');
  const acceptRect=await wd('GET',prefix+'/element/'+accept['element-6066-11e4-a52e-4f735466cecf']+'/rect');
  writeFileSync('evidence/android-input.json',JSON.stringify({action:'Accept',utc:new Date().toISOString(),rect:acceptRect},null,2));
  await wd('POST',prefix+'/element/'+accept['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await new Promise(r=>setTimeout(r,3500));
  await snapshot('after-accept');
  const permissionSource=readFileSync('evidence/android-after-accept.xml','utf8');
  if(permissionSource.includes('permission_allow_button')){
   const allow=await wd('POST',prefix+'/element',{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'});
   writeFileSync('evidence/android-permission-input.json',JSON.stringify({action:'Allow photos and media',utc:new Date().toISOString()},null,2));
   await wd('POST',prefix+'/element/'+allow['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   await new Promise(r=>setTimeout(r,3500));
   await snapshot('after-storage-permission');
  }
  const expected=readFileSync(windows?'evidence/A.txt':'/tmp/issue-2007/A.txt');
  const encoded=await wd('POST',prefix+'/appium/device/pull_file',{path:deviceFolder+'/A.txt'});
  const actual=Buffer.from(encoded,'base64');
  writeFileSync('evidence/android-saved-A.txt',actual);
  assert.deepEqual(actual,expected,'Saved Android file differs from selected desktop file');
  writeFileSync('evidence/actual-app-control.json',JSON.stringify({device:process.env.BS_DEVICE||'Vivo Y21',os:'Android '+(process.env.BS_OS||'11.0'),release:process.env.ISSUE_2007_RELEASE||'1.18.2',sender:windows?'Original Windows desktop app through real file picker':'Original Linux desktop app through real file picker',receiver:'Original Android app, actual Accept action',destination:deviceFolder+'/A.txt',bytes:actual.length,sha256:createHash('sha256').update(actual).digest('hex'),byteExact:true,transport:transportStatus()},null,2));
  writeFileSync('evidence/control-completed','verified\n');
  await waitFile('evidence/sender-first-finished',30000);
  if(deletionTiming!=='absence'){
   await snapshot('receiver-finished-before-files');
   await closeReceiverFinished();
   await snapshot('receiver-ready-before-files');
  }
  // Inspect the physical device's legitimate file-manager entry point only
  // after saved-file byte equality succeeds. No file is deleted here.
  await wd('POST',prefix+'/appium/device/press_keycode',{keycode:3});
  await new Promise(r=>setTimeout(r,1500));
  await snapshot('file-manager-home');
  const manager=samsungFiles?null:await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="File Manager" or @content-desc="File Manager" or @text="Files" or @content-desc="Files"]',label:'home-file-manager-entry',optional:true});
  if(manager){
   await wd('POST',prefix+'/element/'+manager['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   writeFileSync('evidence/file-manager-launch.json',JSON.stringify({method:'Observed native Files launcher control',package:'com.google.android.apps.nbu.files'},null,2));
  }else{
   assert(fileManagerInventory.some(app=>app.appId===fileManagerPackage&&app.installed===true),'No confirmed installed '+fileManagerName);
   await wd('POST',prefix+'/appium/device/activate_app',{appId:fileManagerPackage});
   writeFileSync('evidence/file-manager-launch.json',JSON.stringify({method:'Normal Appium activateApp for confirmed installed provider',package:fileManagerPackage},null,2));
  }
  {
   const onboardingDeadline=Date.now()+10000;
   let onboardingAttempt=0;
   do{
    await snapshot('file-manager-open-'+onboardingAttempt++);
    const managerSource=readFileSync('evidence/android-file-manager-open-'+(onboardingAttempt-1)+'.xml','utf8');
    if(managerSource.includes('id/agree_button')){
     const agree=await waitForNativeControl({wd,prefix,using:'id',value:'com.google.android.apps.nbu.files:id/agree_button',label:'files-onboarding-continue'});
     await wd('POST',prefix+'/element/'+agree['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }else if(managerSource.includes('permission_allow_button')){
     const allow=await waitForNativeControl({wd,prefix,using:'id',value:'com.android.permissioncontroller:id/permission_allow_button',label:'files-onboarding-permission'});
     await wd('POST',prefix+'/element/'+allow['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }else if(managerSource.includes(safDocuments?'text="Documents &amp; other"':'text="Downloads"')){
     break;
    }
    await new Promise(r=>setTimeout(r,200));
   }while(Date.now()<onboardingDeadline);
   const actualManagerPackage=await wd('GET',prefix+'/appium/device/current_package');
   const actualManagerSource=await wd('GET',prefix+'/source');
   assert.equal(actualManagerPackage,fileManagerPackage,'File manager foreground package differs from confirmed provider');
   assert(actualManagerSource.includes('package="'+fileManagerPackage+'"'),'File manager source does not match provider package');
   writeFileSync('evidence/file-manager-provenance.json',JSON.stringify({actualManagerPackage,sourcePackageMatched:true},null,2));
   const downloads=await waitForNativeControl({wd,prefix,using:'xpath',value:safDocuments?'//*[@text="Documents & other"]':'//*[@text="Downloads"]',label:'file-manager-category'});
   await wd('POST',prefix+'/element/'+downloads['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   await new Promise(r=>setTimeout(r,2000));
   await snapshot('files-downloads');
   const file=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="A.txt"]',label:'file-manager-saved-A'});
   const rect=await wd('GET',prefix+'/element/'+file['element-6066-11e4-a52e-4f735466cecf']+'/rect');
   await wd('POST',prefix+'/actions',{actions:[{type:'pointer',id:'finger',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},{type:'pointerDown',button:0},{type:'pause',duration:1000},{type:'pointerUp',button:0}]}]});
   await new Promise(r=>setTimeout(r,1000));
   await snapshot('files-A-selected');
   let remove;
   if(samsungFiles){
    await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="1 selected"]',label:'samsung-one-owned-selection'});
    await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@resource-id="com.sec.android.app.myfiles:id/file_detail_list_item" and ((starts-with(@content-desc,"Checked, A.txt") and .//*[@text="A.txt"]) or (.//*[@text="A.txt"] and .//*[@resource-id="com.sec.android.app.myfiles:id/checkbox" and @checked="true"]))]',label:'samsung-owned-A-checked-row'});
    remove=await waitForNativeControl({wd,prefix,using:'id',value:'com.sec.android.app.myfiles:id/menu_delete',label:'samsung-files-delete-action'});
   }else if(requestedDeletionAction==='trash'){
    const options=await waitForNativeControl({wd,prefix,using:'accessibility id',value:'More options',label:'file-manager-more-options'});
    await wd('POST',prefix+'/element/'+options['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    await snapshot('files-delete-options');
    remove=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="Move to trash" or @text="Move to Trash" or @content-desc="Move to trash" or @content-desc="Move to Trash"]',label:'file-manager-trash-action',optional:true});
    writeFileSync('evidence/trash-capability.json',JSON.stringify({app:'Google Files',actualNativeOptionsInspected:true,trashActionObserved:remove!==null,source:'android-files-delete-options.xml',screenshot:'android-files-delete-options.png',deletionAttempted:false},null,2));
    assert(remove,'Actual Google Files More options does not expose Move to trash; no trash deletion or resend trial occurred');
   }else{
    remove=await waitForNativeControl({wd,prefix,using:'accessibility id',value:'Delete',label:'file-manager-delete-action'});
   }
   await wd('POST',prefix+'/element/'+remove['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   const confirm=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@clickable="true" and (@text="Delete" or @text="DELETE" or @text="Move to trash" or @text="Move to Trash")]',label:'file-manager-deletion-confirmation'});
   await snapshot('files-delete-dialog');
   const deleteSource=readFileSync('evidence/android-files-delete-dialog.xml','utf8');
   const deletionMode=/trash/i.test(deleteSource)?'trash':/permanent/i.test(deleteSource)?'permanent':'delete confirmation; permanence unspecified';
   assert.equal(deletionMode,purgeTrash?'trash':requestedDeletionAction,'Native confirmation does not match the requested deletion action; do not substitute another deletion mode');
   await waitFile('evidence/resend-address-ready',90000);
   const deleteUtc=new Date().toISOString();
   await wd('POST',prefix+'/element/'+confirm['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   const deleteClickReturnedUtc=new Date().toISOString();
   if(deletionTiming==='requested')writeFileSync('evidence/resend-ready','Actual native Delete request returned; no deletion acknowledgement or absence gate\n');
   let absenceError;
   let absent;
   const absenceObservations=[];
   let firstToastObservedUtc;
   let firstEmptyListObservedUtc;
   const deletionDeadline=Date.now()+10000;
   do {
    let pathObservedUtc;
    const [pathValue,sourceObservation]=await Promise.all([
     wd('POST',prefix+'/appium/device/pull_file',{path:deviceFolder+'/A.txt'}).catch(error=>{
      if(!String(error).includes('No such file or directory'))throw error;
      absenceError=String(error);
      return null;
     }).then(value=>{pathObservedUtc=new Date().toISOString();return value;}),
     wd('GET',prefix+'/source').then(source=>{
      const utc=new Date().toISOString();
      if(deletionTiming==='acknowledged'&&(source.includes('1 file deleted')||source.includes("There's nothing here.")||(samsungFiles&&source.includes('No files'))))writeFileSync('evidence/resend-ready','Actual deletion toast or empty list observed; path existence does not gate resend\n');
      return {source,utc};
     }),
    ]);
    absent=pathValue;
    const toastVisible=sourceObservation.source.includes('1 file deleted');
    const emptyListVisible=sourceObservation.source.includes("There's nothing here.")||(samsungFiles&&sourceObservation.source.includes('No files'));
    if(toastVisible&&!firstToastObservedUtc)firstToastObservedUtc=sourceObservation.utc;
    if(emptyListVisible&&!firstEmptyListObservedUtc)firstEmptyListObservedUtc=sourceObservation.utc;
    const sourceFile=`evidence/android-delete-observation-${absenceObservations.length}.xml`;
    writeFileSync(sourceFile,sourceObservation.source);
    absenceObservations.push({pathObservedUtc,pathExists:absent!==null,sourceObservedUtc:sourceObservation.utc,toastVisible,emptyListVisible,sourceFile});
    writeFileSync('evidence/deletion-path-observations.json',JSON.stringify({deletionTiming,deleteUtc,deleteClickReturnedUtc,firstToastObservedUtc,firstEmptyListObservedUtc,observations:absenceObservations,absenceError},null,2));
    if(deletionTiming==='requested'||(deletionTiming==='acknowledged'&&(toastVisible||emptyListVisible))||(deletionTiming==='absence'&&absent===null))break;
    await new Promise(r=>setTimeout(r,100));
   } while(Date.now()<deletionDeadline);
   if(deletionTiming==='absence')assert.equal(absent,null,'Confirmed file-manager deletion did not remove A.txt from its path');
   if(deletionTiming==='acknowledged')assert(firstToastObservedUtc||firstEmptyListObservedUtc,'Native UI never acknowledged deletion');
   const pathAbsenceUtc=absent===null?absenceObservations.at(-1).pathObservedUtc:null;
   writeFileSync('evidence/actual-deletion.json',JSON.stringify({app:fileManagerName,package:fileManagerPackage,deletionMode,deletionTiming,utc:deleteUtc,deleteClickReturnedUtc,path:deviceFolder+'/A.txt',pathAbsent:absent===null,pathAbsenceUtc,firstToastObservedUtc,firstEmptyListObservedUtc,toastToAbsenceObservedMs:firstToastObservedUtc&&pathAbsenceUtc?Date.parse(pathAbsenceUtc)-Date.parse(firstToastObservedUtc):null,absenceError,confirmation:'android-files-delete-dialog.xml'},null,2));
   if(samsungFiles&&purgeTrash){
    assert.equal(deletionTiming,'absence','Permanent trash purge control requires observed path absence before opening Trash');
    async function nativeClick(using,value,label){
     const element=await waitForNativeControl({wd,prefix,using,value,label});
     await wd('POST',prefix+'/element/'+element['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }
    await nativeClick('accessibility id','Go to My Files home','purge-my-files-home');
    await nativeClick('xpath','//*[starts-with(@content-desc,"More options")]','purge-my-files-menu');
    await nativeClick('xpath','//*[@text="Trash"]','purge-trash-entry');
    const trashFile=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="A.txt"]',label:'purge-trash-owned-A',stableRect:true});
    await snapshot('trash-retained-A');
    assert.equal(await wd('GET',prefix+'/appium/device/current_package'),fileManagerPackage,'Trash foreground provider differs');
    const trashRect=await wd('GET',prefix+'/element/'+trashFile['element-6066-11e4-a52e-4f735466cecf']+'/rect');
    await wd('POST',prefix+'/actions',{actions:[{type:'pointer',id:'finger',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,x:Math.round(trashRect.x+trashRect.width/2),y:Math.round(trashRect.y+trashRect.height/2)},{type:'pointerDown',button:0},{type:'pause',duration:1000},{type:'pointerUp',button:0}]}]});
    await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="1 selected"]',label:'purge-single-owned-file-selection'});
    await snapshot('trash-owned-A-selected');
    await nativeClick('id','com.sec.android.app.myfiles:id/menu_delete','purge-selected-trash-file');
    const purgeConfirm=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@clickable="true" and (@text="Delete" or @text="DELETE")]',label:'purge-permanent-confirmation'});
    await snapshot('trash-permanent-delete-dialog');
    const purgeSource=readFileSync('evidence/android-trash-permanent-delete-dialog.xml','utf8');
    assert(/permanent|forever/i.test(purgeSource),'Trash file purge confirmation does not explicitly establish permanent deletion');
    const purgeUtc=new Date().toISOString();
    await wd('POST',prefix+'/element/'+purgeConfirm['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="No files or folders"]',label:'purge-empty-trash'});
    await snapshot('trash-after-owned-A-purge');
    writeFileSync('evidence/actual-trash-purge.json',JSON.stringify({package:fileManagerPackage,ownedFile:'A.txt',retainedFileObserved:true,oneSelected:true,permanentConfirmation:true,purgeUtc,emptyTrashObserved:true,confirmation:'android-trash-permanent-delete-dialog.xml'},null,2));
   }
   await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});
   if(deletionTiming==='absence'){
    await closeReceiverFinished();
    writeFileSync('evidence/resend-ready','Actual file-manager deletion and path absence verified\n');
   }
   await waitFile('evidence/resend-requested',90000);
   const resendInput=JSON.parse(readFileSync('evidence/resend-input.json','utf8'));
   const resendExpected=readFileSync(resendInput.path);
   const resendDestination=deviceFolder+'/'+resendInput.name;
   let secondAccept;
   for(let i=0;i<20;i++){
    secondAccept=await wd('POST',prefix+'/element',{using:'accessibility id',value:'Accept'}).catch(()=>null);
    if(secondAccept)break;
    await new Promise(r=>setTimeout(r,1000));
   }
   assert(secondAccept,'Actual resend did not render Android approval');
   await chooseSafDocuments('resend');
   if(safDocuments)secondAccept=await returnedApproval('resend');
   const acceptUtc=new Date().toISOString();
   await wd('POST',prefix+'/element/'+secondAccept['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   let saved;
   let receiverSource='';
   for(let attempt=0;attempt<10;attempt++){
    await new Promise(r=>setTimeout(r,1000));
    await snapshot('after-resend-accept-'+attempt);
    receiverSource=readFileSync(`evidence/android-after-resend-accept-${attempt}.xml`,'utf8');
    const value=await wd('POST',prefix+'/appium/device/pull_file',{path:resendDestination}).catch(error=>{
     if(!String(error).includes('No such file or directory'))throw error;
     return null;
    });
    if(value!==null){
     saved=Buffer.from(value,'base64');
     if(saved.equals(resendExpected)&&receiverSource.includes('100%, Finished')&&receiverSource.includes('&#10;Done'))break;
    }
   }
   const byteExact=saved?.equals(resendExpected)??false;
   const receiverFileDone=receiverSource.includes('100%, Finished')&&receiverSource.includes('&#10;Done');
   const numberedEncoded=await wd('POST',prefix+'/appium/device/pull_file',{path:deviceFolder+'/A-2.txt'}).catch(error=>{
    if(!String(error).includes('No such file or directory'))throw error;
    return null;
   });
   const numbered=numberedEncoded===null?null:Buffer.from(numberedEncoded,'base64');
   const numberedByteExact=numbered?.equals(resendExpected)??false;
   if(numbered)writeFileSync('evidence/android-numbered-A-2.txt',numbered);
   const actualSavedPath=receiverFileDone?(numberedByteExact?deviceFolder+'/A-2.txt':byteExact?resendDestination:null):null;
   const submission=JSON.parse(readFileSync('evidence/resend-submission.json','utf8'));
   if(saved)writeFileSync('evidence/android-resaved-'+resendInput.name,saved);
   writeFileSync('evidence/actual-resend-result.json',JSON.stringify({release:process.env.ISSUE_2007_RELEASE||'1.18.2',deletionMode,deletionTiming,deleteUtc,deleteClickReturnedUtc,firstToastObservedUtc,firstEmptyListObservedUtc,submissionUtc:submission.utc,acceptUtc,deleteToSubmissionMs:Date.parse(submission.utc)-Date.parse(deleteUtc),deleteToAcceptMs:Date.parse(acceptUtc)-Date.parse(deleteUtc),variant:resendInput.variant,unchangedFile:resendInput.variant!=='changed',sameName:resendInput.name==='A.txt',fileName:resendInput.name,destination:resendDestination,accepted:true,saved:saved!==undefined,byteExact,receiverFileDone,actualSavedPath,sameDestination:actualSavedPath===resendDestination,numberedPathExists:numbered!==null,numberedByteExact,numberedSha256:numbered?createHash('sha256').update(numbered).digest('hex'):null,resendSucceeded:(byteExact||numberedByteExact)&&receiverFileDone,expectedBytes:resendExpected.length,expectedSha256:createHash('sha256').update(resendExpected).digest('hex'),baselineSha256:createHash('sha256').update(expected).digest('hex'),bytes:saved?.length??null,sha256:saved?createHash('sha256').update(saved).digest('hex'):null,transport:transportStatus()},null,2));
   writeFileSync('evidence/resend-completed','Resend outcome observed; inspect byteExact and endpoint evidence\n');
   if(receiverSource.includes('Finished with error')){
    const errorRow=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[contains(@content-desc,"A.txt") and contains(@content-desc,"Error") and @clickable="true"]',label:'receiver-file-error-details',optional:true});
    if(errorRow){
     await wd('POST',prefix+'/element/'+errorRow['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
     await snapshot('resend-file-error-details');
    }
   }
   if(desktop.exitCode===null)await new Promise(r=>desktop.once('exit',r));
   assert.equal(desktop.exitCode,0,'Desktop resend observation did not complete');
   if(saved&&!numberedByteExact)assert(byteExact,'Resaved file differs from selected original file');
  }
 } finally {
  if(desktop.exitCode===null)desktop.kill('SIGTERM');
  for(const socket of ownedProxySockets)socket.destroy();
  proxy?.close();
  await snapshot('final').catch(()=>{});
 }
}
