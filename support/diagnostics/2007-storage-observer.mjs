import assert from 'node:assert/strict';
import {writeFileSync} from 'node:fs';
import {waitForNativeControl} from './native-readiness.mjs';

export function storageObserver({wd,prefix,session}) {
 async function click(using,value,label){
  const e=await waitForNativeControl({wd,prefix,using,value,label});
  await wd('POST',`${prefix}/element/${e['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
 }
 async function activate(appId){await wd('POST',prefix+'/appium/device/activate_app',{appId});}
 async function observe(stage){
  const previous=await wd('GET',prefix+'/appium/device/current_package');
  await activate('org.localsend.cloudtransport');
  await click('accessibility id','Observe owned storage',stage+'-observe');
  await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[starts-with(@text,"Observer complete;")]',label:stage+'-observer-completed'});
  const encoded=await wd('POST',prefix+'/appium/device/pull_file',{path:'/sdcard/Android/data/org.localsend.cloudtransport/files/storage-observer.json'});
  const report=JSON.parse(Buffer.from(encoded,'base64').toString());
  assert(report.readOnly&&report.allFilesAccess,'Observer lacks declared read-only mode or storage visibility permission');
  const identities=[];
  for(const appId of ['org.localsend.localsend_app','com.google.android.providers.media.module','com.sec.android.app.myfiles']){
   const command='dumpsys meminfo '+appId;
   const result=await wd('POST',prefix+'/execute/sync',{script:'browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),args:[]}).catch(error=>({error:String(error)}));
   identities.push({command,result});
  }
  writeFileSync(`evidence/storage-${stage}.json`,JSON.stringify({session,stage,collectedUtc:new Date().toISOString(),previousPackage:previous,report,identities},null,2));
  await activate(previous);
  return report;
 }
 async function prepare(){
  await activate('org.localsend.cloudtransport');
  await click('accessibility id','Observer storage access','observer-permission-entry');
  writeFileSync('evidence/observer-permission-before.xml',await wd('GET',prefix+'/source'));
  writeFileSync('evidence/observer-permission-before.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
  const toggle=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@class="android.widget.Switch" or @class="android.widget.SwitchCompat"]',label:'observer-storage-setting'});
  const enabled=await wd('GET',`${prefix}/element/${toggle['element-6066-11e4-a52e-4f735466cecf']}/attribute/checked`);
  if(enabled!=='true')await wd('POST',`${prefix}/element/${toggle['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
  writeFileSync('evidence/observer-permission-after.xml',await wd('GET',prefix+'/source'));
  writeFileSync('evidence/observer-permission-after.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
  await activate('org.localsend.localsend_app');
  return observe('before-baseline');
 }
 return {observe,prepare};
}
