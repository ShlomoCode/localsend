import {writeFileSync} from 'node:fs';
import {waitForNativeControl} from './native-readiness.mjs';

// Inspect normal entry points of already-installed apps, never create a trash
// surrogate or replace a system provider. This is not a transfer experiment.
export async function probeInstalledProviders({wd,prefix}) {
 const observations=[];
 const providers=['com.google.android.apps.nbu.files','com.sec.android.app.myfiles','com.google.android.documentsui','com.yozo.vivo.office','com.vivo.easyshare'];
 for(let index=0;index<providers.length;index++){
  const appId=providers[index],label='provider-probe-'+index,record={appId,utc:new Date().toISOString(),observations:[],transferTrial:false};
  observations.push(record);
  try{
   record.installed=await wd('POST',prefix+'/appium/device/app_installed',{appId});
   if(!record.installed)continue;
   await wd('POST',prefix+'/appium/device/activate_app',{appId});
   const deadline=Date.now()+20000;
   let attempt=0;
   do{
    const source=await wd('GET',prefix+'/source');
    const sourceFile=label+'-source-'+attempt+'.xml';
    writeFileSync('evidence/'+sourceFile,source);
    const activity=await wd('GET',prefix+'/appium/device/current_activity');
    const actualPackage=await wd('GET',prefix+'/appium/device/current_package');
    const sourcePackageMatched=source.includes('package="'+appId+'"');
    record.observations.push({utc:new Date().toISOString(),sourceFile,activity,actualPackage,sourcePackageMatched});
    record.trashLabels=(source.match(/(?:text|content-desc)="[^\"]*(?:trash|Trash|recycle|Recycle|回收站|垃圾箱|最近删除)[^\"]*"/g)||[]);
    if(sourcePackageMatched&&source.includes(appId+':id/agree_button')){
     const agree=await waitForNativeControl({wd,prefix,using:'id',value:appId+':id/agree_button',label:label+'-agree'});
     await wd('POST',prefix+'/element/'+agree['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }else if(appId==='com.google.android.apps.nbu.files'&&actualPackage==='com.android.permissioncontroller'&&source.includes('permission_allow_button')){
     const allow=await waitForNativeControl({wd,prefix,using:'id',value:'com.android.permissioncontroller:id/permission_allow_button',label:label+'-permission'});
     await wd('POST',prefix+'/element/'+allow['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
    }else if(actualPackage===appId&&sourcePackageMatched&&!/SplashScreenActivity/.test(activity)&&((appId==='com.google.android.apps.nbu.files'&&source.includes('text="Browse"'))||(appId!=='com.google.android.apps.nbu.files'&&/(?:text|content-desc)="[^"]+"/.test(source)))){
     record.actualEntryPointObserved=true;
     record.sourceFile=sourceFile;
     break;
    }
    attempt++;
    await new Promise(resolve=>setTimeout(resolve,200));
   }while(Date.now()<deadline);
   if(!record.actualEntryPointObserved){record.unavailable='Normal launch observed, but matching source/main page did not become ready before bounded deadline';writeFileSync('evidence/'+label+'-unavailable.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));continue;}
   writeFileSync('evidence/'+label+'-entry.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
   const menu=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@content-desc="Show navigation menu" or @content-desc="Show roots" or @content-desc="Open navigation drawer" or @content-desc="Menu" or starts-with(@content-desc,"More options")]',label:label+'-menu',timeoutMs:3000,optional:true});
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
    const trash=await waitForNativeControl({wd,prefix,using:'xpath',value:'//*[@text="Trash" or @text="Recycle bin" or @content-desc="Trash" or @content-desc="Recycle bin"]',label:label+'-trash-entry',timeoutMs:3000,optional:true});
    if(trash){
     await wd('POST',prefix+'/element/'+trash['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
     // Inspect only. Do not alter existing files or empty an unrelated bin.
     for(let trashAttempt=0;trashAttempt<3;trashAttempt++){
      writeFileSync('evidence/'+label+'-trash-'+trashAttempt+'.xml',await wd('GET',prefix+'/source'));
      await new Promise(resolve=>setTimeout(resolve,200));
     }
     writeFileSync('evidence/'+label+'-trash.png',Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
     record.trashEntryOpened=true;
     record.trashActualPackage=await wd('GET',prefix+'/appium/device/current_package');
    }
   }
   record.menuControlObserved=menu!==null;
   record.limit='Only this observed normal entry/menu is inspected; missing label does not establish absence of all trash paths.';
  }catch(error){record.unavailable=String(error);}
  finally{writeFileSync('evidence/installed-provider-probe.json',JSON.stringify({providers:observations,transferTrial:false},null,2));}
 }
}
