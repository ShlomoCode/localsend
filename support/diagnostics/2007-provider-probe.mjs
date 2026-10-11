import {writeFileSync} from 'node:fs';
import {waitForNativeControl} from './native-readiness.mjs';

// Inspect normal entry points of already-installed apps, never create a trash
// surrogate or replace a system provider. This is not a transfer experiment.
export async function probeInstalledProviders({wd,prefix}) {
 const observations=[];
 const providers=['com.google.android.apps.nbu.files','com.google.android.documentsui','com.yozo.vivo.office','com.vivo.easyshare'];
 for(let index=0;index<providers.length;index++){
  const appId=providers[index],label='provider-probe-'+index,record={appId,utc:new Date().toISOString(),observations:[],transferTrial:false};
  observations.push(record);
  try{
   record.installed=await wd('POST',prefix+'/appium/device/app_installed',{appId});
   if(!record.installed)continue;
   await wd('POST',prefix+'/appium/device/activate_app',{appId});
   const deadline=Date.now()+7000;
   let attempt=0;
   do{
    const source=await wd('GET',prefix+'/source');
    const sourceFile=label+'-source-'+attempt+'.xml';
    writeFileSync('evidence/'+sourceFile,source);
    const activity=await wd('GET',prefix+'/appium/device/current_activity');
    const actualPackage=await wd('GET',prefix+'/appium/device/current_package');
    record.observations.push({utc:new Date().toISOString(),sourceFile,activity,actualPackage});
    record.trashLabels=(source.match(/(?:text|content-desc)="[^\"]*(?:trash|Trash|recycle|Recycle|回收站|垃圾箱|最近删除)[^\"]*"/g)||[]);
    if(source.includes('id/agree_button')){
     const agree=await waitForNativeControl({wd,prefix,using:'id',value:'com.google.android.apps.nbu.files:id/agree_button',label:label+'-agree'});
     await wd('POST',prefix+'/element/'+agree['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }else if(source.includes('permission_allow_button')){
     const allow=await waitForNativeControl({wd,prefix,using:'id',value:'com.android.permissioncontroller:id/permission_allow_button',label:label+'-permission'});
     await wd('POST',prefix+'/element/'+allow['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }else if(actualPackage===appId&&source.length>1500){
     record.actualEntryPointObserved=true;
     record.sourceFile=sourceFile;
     break;
    }
    attempt++;
    await new Promise(resolve=>setTimeout(resolve,200));
   }while(Date.now()<deadline);
   writeFileSync('evidence/'+label+'-entry.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
   const menu=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@content-desc="Show roots" or @content-desc="Open navigation drawer" or @content-desc="Menu" or @content-desc="More options"]',label:label+'-menu',timeoutMs:3000,optional:true});
   if(menu){
    await wd('POST',prefix+'/element/'+menu['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    // Observe the menu with fresh reads, not the entry-page snapshot.
    for(let menuAttempt=0;menuAttempt<3;menuAttempt++){
     const source=await wd('GET',prefix+'/source');
     writeFileSync('evidence/'+label+'-menu-'+menuAttempt+'.xml',source);
     record.menuTrashLabels=(source.match(/(?:text|content-desc)="[^\"]*(?:trash|Trash|recycle|Recycle)[^\"]*"/g)||[]);
     record.menuSource=label+'-menu-'+menuAttempt+'.xml';
     if(record.menuTrashLabels.length)break;
     await new Promise(resolve=>setTimeout(resolve,200));
    }
    writeFileSync('evidence/'+label+'-menu.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
   }
   record.menuControlObserved=menu!==null;
   record.limit='Only this observed normal entry/menu is inspected; missing label does not establish absence of all trash paths.';
  }catch(error){record.unavailable=String(error);}
  finally{writeFileSync('evidence/installed-provider-probe.json',JSON.stringify({providers:observations,transferTrial:false},null,2));}
 }
}
