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
 const desktop=spawn('dbus-run-session',['--','xvfb-run','-a','-s','-screen 0 1200x800x24','bash','support/diagnostics/2007-physical-sender.sh']);
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
  writeFileSync('evidence/actual-app-control.json',JSON.stringify({device:'Vivo Y21',os:'Android 11',release:'1.18.2',sender:'Original Linux desktop app through real file picker',receiver:'Original Android app, actual Accept action',destination:'/sdcard/Download/A.txt',bytes:actual.length,sha256:createHash('sha256').update(actual).digest('hex'),byteExact:true,transport:transportStatus()},null,2));
  writeFileSync('evidence/control-completed','verified\n');
  await new Promise(r=>desktop.once('exit',r));
  assert.equal(desktop.exitCode,0,'Desktop control did not complete');
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
  }
 } finally {
  if(desktop.exitCode===null)desktop.kill('SIGTERM');
  proxy?.close();
  await snapshot('final').catch(()=>{});
 }
}
