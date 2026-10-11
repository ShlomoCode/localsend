import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {existsSync,writeFileSync,readFileSync,createWriteStream} from 'node:fs';
import net from 'node:net';
import {createHash} from 'node:crypto';

export default async function({session,wd,senderHost,senderPort,transportStatus}) {
 const prefix=`/session/${session}`;
 await wd('POST',prefix+'/appium/settings',{settings:{waitForIdleTimeout:0}});
 async function snapshot(stage){
  writeFileSync(`evidence/android-${stage}.xml`,await wd('GET',prefix+'/source'));
  writeFileSync(`evidence/android-${stage}.png`,Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
 }
 async function waitFile(file,ms){
  const end=Date.now()+ms;
  while(!existsSync(file)){
   if(desktop.exitCode!==null)throw new Error('Desktop GUI driver exited '+desktop.exitCode);
   if(Date.now()>end)throw new Error('Desktop GUI milestone timeout: '+file);
   await new Promise(r=>setTimeout(r,500));
  }
 }
 writeFileSync('evidence/browserstack-session.json',JSON.stringify({session,device:'Vivo Y21',os:'Android 11'},null,2));
 let receiverReady=false;
 for(let attempt=0;attempt<20;attempt++){
  await snapshot('initial-'+attempt);
  const source=readFileSync(`evidence/android-initial-${attempt}.xml`,'utf8');
  if(source.includes('Receive')){receiverReady=true;break;}
  await new Promise(r=>setTimeout(r,2000));
 }
 assert(receiverReady,'Original Android app did not render Receive within 40 seconds');
 const before=await wd('POST',prefix+'/appium/device/pull_file',{path:'/sdcard/Download/A.txt'}).catch(error=>{
  if(!String(error).includes('No such file or directory'))throw error;
  return null;
 });
 assert.equal(before,null,'Baseline A.txt already exists on the device; do not mistake an old file for this transfer');
 writeFileSync('evidence/baseline-path-absence.json',JSON.stringify({path:'/sdcard/Download/A.txt',absent:true,utc:new Date().toISOString()},null,2));
 const desktop=spawn('dbus-run-session',['--','xvfb-run','-a','-s','-screen 0 1200x800x24','bash','support/diagnostics/2007-physical-sender.sh'],{env:{...process.env,ISSUE_2007_RESEND:'1'}});
 const log=createWriteStream('evidence/desktop-process.log');desktop.stdout.pipe(log);desktop.stderr.pipe(log);
 let proxy;
 try {
  await waitFile('evidence/desktop-stopped',120000);
  proxy=net.createServer({allowHalfOpen:true},client=>{
   const remote=net.connect({host:senderHost,port:senderPort,allowHalfOpen:true});
   client.pipe(remote);remote.pipe(client);
   client.on('error',()=>remote.destroy());remote.on('error',()=>client.destroy());
  });
  await new Promise((resolve,reject)=>{proxy.once('error',reject);proxy.listen(53317,'127.0.0.1',resolve);});
  writeFileSync('evidence/transport-ready','transparent TCP forwarding only\n');
  await waitFile('evidence/transfer-requested',90000);
  let accept;
  for(let i=0;i<20;i++){
   await snapshot('request-'+i);
   accept=await wd('POST',prefix+'/element',{using:'accessibility id',value:'Accept'}).catch(()=>null);
   if(accept)break;
   await new Promise(r=>setTimeout(r,1000));
  }
  assert(accept,'Original Android app did not render receive approval');
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
  const expected=readFileSync('/tmp/issue-2007/A.txt');
  const encoded=await wd('POST',prefix+'/appium/device/pull_file',{path:'/sdcard/Download/A.txt'});
  const actual=Buffer.from(encoded,'base64');
  writeFileSync('evidence/android-saved-A.txt',actual);
  assert.deepEqual(actual,expected,'Saved Android file differs from selected desktop file');
  writeFileSync('evidence/actual-app-control.json',JSON.stringify({device:'Vivo Y21',os:'Android 11',release:process.env.ISSUE_2007_RELEASE||'1.18.2',sender:'Original Linux desktop app through real file picker',receiver:'Original Android app, actual Accept action',destination:'/sdcard/Download/A.txt',bytes:actual.length,sha256:createHash('sha256').update(actual).digest('hex'),byteExact:true,transport:transportStatus()},null,2));
  writeFileSync('evidence/control-completed','verified\n');
  await waitFile('evidence/sender-first-finished',30000);
  // Inspect the physical device's legitimate file-manager entry point only
  // after saved-file byte equality succeeds. No file is deleted here.
  await wd('POST',prefix+'/appium/device/press_keycode',{keycode:3});
  await new Promise(r=>setTimeout(r,1500));
  await snapshot('file-manager-home');
  const manager=await wd('POST',prefix+'/element',{using:'xpath',value:'//*[@text="File Manager" or @content-desc="File Manager" or @text="Files" or @content-desc="Files"]'}).catch(()=>null);
  if(manager){
   await wd('POST',prefix+'/element/'+manager['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   await new Promise(r=>setTimeout(r,1500));
   await snapshot('file-manager-open');
   const managerSource=readFileSync('evidence/android-file-manager-open.xml','utf8');
   if(managerSource.includes('id/agree_button')){
    const agree=await wd('POST',prefix+'/element',{using:'id',value:'com.google.android.apps.nbu.files:id/agree_button'});
    await wd('POST',prefix+'/element/'+agree['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    await new Promise(r=>setTimeout(r,1500));
    await snapshot('files-after-continue');
    if(readFileSync('evidence/android-files-after-continue.xml','utf8').includes('permission_allow_button')){
     const allow=await wd('POST',prefix+'/element',{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'});
     await wd('POST',prefix+'/element/'+allow['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
     await new Promise(r=>setTimeout(r,1500));
     await snapshot('files-after-permission');
    }
   }
   const downloads=await wd('POST',prefix+'/element',{using:'xpath',value:'//*[@text="Downloads"]'});
   await wd('POST',prefix+'/element/'+downloads['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   await new Promise(r=>setTimeout(r,2000));
   await snapshot('files-downloads');
   const file=await wd('POST',prefix+'/element',{using:'xpath',value:'//*[@text="A.txt"]'});
   const rect=await wd('GET',prefix+'/element/'+file['element-6066-11e4-a52e-4f735466cecf']+'/rect');
   await wd('POST',prefix+'/actions',{actions:[{type:'pointer',id:'finger',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},{type:'pointerDown',button:0},{type:'pause',duration:1000},{type:'pointerUp',button:0}]}]});
   await new Promise(r=>setTimeout(r,1000));
   await snapshot('files-A-selected');
   const remove=await wd('POST',prefix+'/element',{using:'accessibility id',value:'Delete'});
   await wd('POST',prefix+'/element/'+remove['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   await new Promise(r=>setTimeout(r,1000));
   await snapshot('files-delete-dialog');
   const deleteSource=readFileSync('evidence/android-files-delete-dialog.xml','utf8');
   const deletionMode=/trash/i.test(deleteSource)?'trash':/permanent/i.test(deleteSource)?'permanent':'delete confirmation; permanence unspecified';
   const confirm=await wd('POST',prefix+'/element',{using:'xpath',value:'//*[@clickable="true" and (@text="Delete" or @text="DELETE" or @text="Move to trash" or @text="Move to Trash")]'});
   await waitFile('evidence/resend-address-ready',90000);
   const deleteUtc=new Date().toISOString();
   await wd('POST',prefix+'/element/'+confirm['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   let absenceError;
   let absent;
   const absenceObservations=[];
   const deletionDeadline=Date.now()+10000;
   do {
    absent=await wd('POST',prefix+'/appium/device/pull_file',{path:'/sdcard/Download/A.txt'}).catch(error=>{
     if(!String(error).includes('No such file or directory'))throw error;
     absenceError=String(error);
     return null;
    });
    absenceObservations.push({utc:new Date().toISOString(),pathExists:absent!==null});
    writeFileSync('evidence/deletion-path-observations.json',JSON.stringify({deleteUtc,observations:absenceObservations,absenceError},null,2));
    if(absent===null)break;
    await new Promise(r=>setTimeout(r,100));
   } while(Date.now()<deletionDeadline);
   assert.equal(absent,null,'Confirmed file-manager deletion did not remove A.txt from its path');
   writeFileSync('evidence/actual-deletion.json',JSON.stringify({app:'Google Files',deletionMode,utc:deleteUtc,path:'/sdcard/Download/A.txt',pathAbsent:true,pathAbsenceUtc:new Date().toISOString(),absenceError,confirmation:'android-files-delete-dialog.xml'},null,2));
   await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});
   const done=await wd('POST',prefix+'/element',{using:'xpath',value:'//*[@content-desc="Done" and @clickable="true"]'});
   await wd('POST',prefix+'/element/'+done['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   writeFileSync('evidence/resend-ready','Actual file-manager deletion and path absence verified\n');
   await waitFile('evidence/resend-requested',90000);
   const resendInput=JSON.parse(readFileSync('evidence/resend-input.json','utf8'));
   const resendExpected=readFileSync(resendInput.path);
   const resendDestination='/sdcard/Download/'+resendInput.name;
   let secondAccept;
   for(let i=0;i<20;i++){
    secondAccept=await wd('POST',prefix+'/element',{using:'accessibility id',value:'Accept'}).catch(()=>null);
    if(secondAccept)break;
    await new Promise(r=>setTimeout(r,1000));
   }
   assert(secondAccept,'Actual resend did not render Android approval');
   const acceptUtc=new Date().toISOString();
   await wd('POST',prefix+'/element/'+secondAccept['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
   let saved;
   for(let attempt=0;attempt<10;attempt++){
    await new Promise(r=>setTimeout(r,1000));
    await snapshot('after-resend-accept-'+attempt);
    const value=await wd('POST',prefix+'/appium/device/pull_file',{path:resendDestination}).catch(error=>{
     if(!String(error).includes('No such file or directory'))throw error;
     return null;
    });
    if(value!==null){
     saved=Buffer.from(value,'base64');
     if(saved.equals(resendExpected))break;
    }
   }
   const byteExact=saved?.equals(resendExpected)??false;
   const submission=JSON.parse(readFileSync('evidence/resend-submission.json','utf8'));
   if(saved)writeFileSync('evidence/android-resaved-'+resendInput.name,saved);
   writeFileSync('evidence/actual-resend-result.json',JSON.stringify({release:process.env.ISSUE_2007_RELEASE||'1.18.2',deletionMode,deleteUtc,submissionUtc:submission.utc,acceptUtc,deleteToSubmissionMs:Date.parse(submission.utc)-Date.parse(deleteUtc),deleteToAcceptMs:Date.parse(acceptUtc)-Date.parse(deleteUtc),variant:resendInput.variant,unchangedFile:resendInput.variant!=='changed',sameName:resendInput.name==='A.txt',fileName:resendInput.name,destination:resendDestination,accepted:true,saved:saved!==undefined,byteExact,expectedBytes:resendExpected.length,expectedSha256:createHash('sha256').update(resendExpected).digest('hex'),baselineSha256:createHash('sha256').update(expected).digest('hex'),bytes:saved?.length??null,sha256:saved?createHash('sha256').update(saved).digest('hex'):null,transport:transportStatus()},null,2));
   writeFileSync('evidence/resend-completed','Resend outcome observed; inspect byteExact and endpoint evidence\n');
   await new Promise(r=>desktop.once('exit',r));
   assert.equal(desktop.exitCode,0,'Desktop resend observation did not complete');
   if(saved)assert(byteExact,'Resaved file differs from selected original file');
  }
 } finally {
  if(desktop.exitCode===null)desktop.kill('SIGTERM');
  proxy?.close();
  await snapshot('final').catch(()=>{});
 }
}
