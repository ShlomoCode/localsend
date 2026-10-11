import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {waitForNativeControl} from './native-readiness.mjs';
const exec=promisify(execFile);
export default async function({session,wd,senderPort,transportStatus}){
 const prefix=`/session/${session}`,results=[];
 const target=label=>({using:'accessibility id',value:label});
 async function click(label){const e=await waitForNativeControl({wd,prefix,label:'2311-'+label,...target(label)});await wd('POST',prefix+'/element/'+e['element-6066-11e4-a52e-4f735466cecf']+'/click',{});}
 async function capture(label){writeFileSync(`evidence/${label}.xml`,await wd('GET',prefix+'/source'));writeFileSync(`evidence/${label}.png`,Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));}
 async function globalGallery(desired,label){
  const settings=await waitForNativeControl({wd,prefix,label:label+'-settings',using:'xpath',value:'//*[@package="org.localsend.localsend_app" and contains(@content-desc,"Settings") and @clickable="true"]'});
  await wd('POST',prefix+'/element/'+settings['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await capture(label+'-settings-before-scroll');
  const scroll=await waitForNativeControl({wd,prefix,label:label+'-settings-scroll-view',using:'xpath',value:'//android.widget.ScrollView[@package="org.localsend.localsend_app" and @scrollable="true"]',requireClickable:false});
  const rect=await wd('GET',prefix+'/element/'+scroll['element-6066-11e4-a52e-4f735466cecf']+'/rect');
  const x=Math.round(rect.x+rect.width/2),bottom=Math.round(rect.y+rect.height*0.8),top=Math.round(rect.y+rect.height*0.4);
  await wd('POST',prefix+'/actions',{actions:[{type:'pointer',id:'settings-scroll',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,x,y:bottom},{type:'pointerDown',button:0},{type:'pointerMove',duration:500,x,y:top},{type:'pointerUp',button:0}]}]});
  await capture(label+'-settings-after-scroll');
  // Release 1.17 merges Receive labels into one parent. Its observed child index 4
  // is the gallery switch, following three Quick Save/PIN switches and folder.
  const locator={using:'xpath',value:'//*[@package="org.localsend.localsend_app" and contains(@content-desc,"Save media to gallery")]/android.widget.Switch[@index="4"]'};
  let toggle=await waitForNativeControl({wd,prefix,label:label+'-global-gallery-switch',...locator,sourceIncludes:['Save media to gallery']});
  const id=toggle['element-6066-11e4-a52e-4f735466cecf'];
  const before=await wd('GET',prefix+'/element/'+id+'/attribute/checked');
  await capture(label+'-global-gallery-before');
  if((before===true||before==='true')!==desired)await wd('POST',prefix+'/element/'+id+'/click',{});
  toggle=await waitForNativeControl({wd,prefix,label:label+'-global-gallery-after',using:'xpath',value:locator.value+`[@checked="${desired}"]`,sourceIncludes:['Save media to gallery']});
  const after=await wd('GET',prefix+'/element/'+toggle['element-6066-11e4-a52e-4f735466cecf']+'/attribute/checked');
  if((after===true||after==='true')!==desired)throw new Error('Global gallery switch did not match requested state');
  await capture(label+'-global-gallery-selected');
  writeFileSync(`evidence/${label}-global-gallery.json`,JSON.stringify({desired,before,after,selectionTiming:'Global Settings before transfer'},null,2));
  const receive=await waitForNativeControl({wd,prefix,label:label+'-receive-tab',using:'xpath',value:'//*[@package="org.localsend.localsend_app" and contains(@content-desc,"Receive") and @clickable="true"]'});
  await wd('POST',prefix+'/element/'+receive['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await capture(label+'-receive-ready');
 }
 async function shell(command,label){
  const attempts=[];
  for(const script of ['browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),'mobile: shell']){
   try{const result=await wd('POST',prefix+'/execute/sync',{script,args:script==='mobile: shell'?[{command:'sh',args:['-c',command],includeStderr:true}]:[]},{timeoutMs:15000});writeFileSync(`evidence/${label}.json`,JSON.stringify({command,result,attempts},null,2));return result;}
   catch(error){attempts.push(String(error));}
  }
  writeFileSync(`evidence/${label}.json`,JSON.stringify({command,attempts,unavailable:true},null,2));return null;
 }
 async function helperMetadata(filename,label){
  await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.cloudtransport'});
  const input=await waitForNativeControl({wd,prefix,label:label+'-metadata-filename',using:'accessibility id',value:'Metadata filename'});
  await wd('POST',prefix+'/element/'+input['element-6066-11e4-a52e-4f735466cecf']+'/value',{text:filename});
  await click('Read image metadata');
  const outputTarget={using:'xpath',value:'//*[@package="org.localsend.cloudtransport" and starts-with(@content-desc,"Image metadata: ")]'};
  const choices=[outputTarget,{using:'xpath',value:'//*[contains(@resource-id,"permission_allow_all_button") or contains(@resource-id,"permission_allow_button")]'}];
  let e=await waitForNativeControl({wd,prefix,label:label+'-metadata-or-permission',choices,requireClickable:false});
  if(e.readiness.choice===1){await capture(label+'-normal-media-permission');await wd('POST',prefix+'/element/'+e['element-6066-11e4-a52e-4f735466cecf']+'/click',{});e=await waitForNativeControl({wd,prefix,label:label+'-metadata-output',...outputTarget,requireClickable:false});}
  const value=await wd('GET',prefix+'/element/'+e['element-6066-11e4-a52e-4f735466cecf']+'/attribute/content-desc');
  const result=JSON.parse(value.slice('Image metadata: '.length));writeFileSync(`evidence/${label}-normal-metadata.json`,JSON.stringify(result,null,2));await capture(label+'-normal-metadata');
  await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});
  return result;
 }
 async function fileManagerDetails(filename,label,desired){
  const appId='com.google.android.apps.nbu.files';
  const installed=await wd('POST',prefix+'/appium/device/app_installed',{appId});
  if(!installed)throw new Error('Google Files is not installed; normal file-manager details require another observed entry');
  await wd('POST',prefix+'/appium/device/activate_app',{appId});
  for(let attempt=0;attempt<5;attempt++){
   await capture(label+'-files-entry-'+attempt);
   const source=await wd('GET',prefix+'/source');
   const choice=source.includes('id/agree_button')?{using:'id',value:appId+':id/agree_button'}:source.includes('permission_allow_button')?{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'}:null;
   if(!choice)break;
   const e=await waitForNativeControl({wd,prefix,label:label+'-files-onboarding-'+attempt,...choice});
   await wd('POST',prefix+'/element/'+e['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  }
  const actualPackage=await wd('GET',prefix+'/appium/device/current_package');
  writeFileSync(`evidence/${label}-files-provenance.json`,JSON.stringify({appId,installed,actualPackage},null,2));
  if(actualPackage!==appId)throw new Error('Normal Google Files foreground package differs');
  const browse=await waitForNativeControl({wd,prefix,label:label+'-files-browse',using:'xpath',value:'//*[@text="Browse" or @content-desc="Browse"]',optional:true,timeoutMs:3000});
  if(browse)await wd('POST',prefix+'/element/'+browse['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await capture(label+'-files-browse');
  const category=await waitForNativeControl({wd,prefix,label:label+'-files-category',using:'xpath',value:`//*[@text="${desired?'Images':'Downloads'}"]`});
  await wd('POST',prefix+'/element/'+category['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await capture(label+'-files-category');
  const file=await waitForNativeControl({wd,prefix,label:label+'-files-owned-image',using:'xpath',value:`//*[@text="${filename}" or contains(@content-desc,"${filename}")]`});
  const rect=await wd('GET',prefix+'/element/'+file['element-6066-11e4-a52e-4f735466cecf']+'/rect');
  await wd('POST',prefix+'/actions',{actions:[{type:'pointer',id:'owned-image',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},{type:'pointerDown',button:0},{type:'pause',duration:1000},{type:'pointerUp',button:0}]}]});
  await capture(label+'-files-owned-selected');
  const menu=await waitForNativeControl({wd,prefix,label:label+'-files-menu',using:'accessibility id',value:'More options'});
  await wd('POST',prefix+'/element/'+menu['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await capture(label+'-files-menu');
  const info=await waitForNativeControl({wd,prefix,label:label+'-files-info',using:'xpath',value:'//*[@text="File info" or @text="Details" or @content-desc="File info" or @content-desc="Details"]'});
  await wd('POST',prefix+'/element/'+info['element-6066-11e4-a52e-4f735466cecf']+'/click',{});
  await capture(label+'-files-details');
  await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});
 }
 try{
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows2311-desktop.ps1']);
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows_release_ui_probe.ps1','-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel',process.env.DIAGNOSTIC_RUNNER_LABEL||'windows-11-arm','-FixtureTimestampUtc','2025-02-13T14:11:00Z','-FixtureFileName',`issue2311-${process.env.GITHUB_RUN_ID}-control.txt`,'-DiagnosticPeerPort',String(senderPort)]);
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-ui.ps1','-Action','click','-X','246','-Y','266','-Label','windows-control-favorites']);
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-ui.ps1','-Action','click','-X','145','-Y','205','-Label','windows-control-send']);
  try{await click('Accept');}catch(error){
   await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-ui.ps1','-Action','click','-X','127','-Y','258','-Label','windows-control-error-detail']);
   await capture('control-no-approval');throw error;
  }
  await waitForNativeControl({wd,prefix,label:'control-complete',...target('Done')});
  await capture('control-completed');
  const path=`/sdcard/Download/issue2311-${process.env.GITHUB_RUN_ID}-control.txt`;
  const bytes=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path}),'base64');
  const expected=readFileSync(`evidence/issue2311-${process.env.GITHUB_RUN_ID}-control.txt`);
  if(!bytes.equals(expected))throw new Error('Control saved bytes mismatch');
  results.push({case:'known-working-control',byteExact:true,sha256:createHash('sha256').update(bytes).digest('hex')});
  await click('Done');
  for(const [index,gallery] of ['on','off','on-repeat','off-repeat'].entries()){
   const desired=gallery.startsWith('on');
   await globalGallery(desired,gallery);
   await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows2311-context.ps1','-Case',gallery,...(index?['-CompletePrevious']:[])]);
   await waitForNativeControl({wd,prefix,label:gallery+'-pending',...target('Accept')});
   await click('Options');await capture(gallery+'-options-before');
   const e=await waitForNativeControl({wd,prefix,label:gallery+'-gallery',using:'xpath',value:'//*[@package="org.localsend.localsend_app" and (@content-desc="On" or @content-desc="Off") and @clickable="true"]'});
   const id=e['element-6066-11e4-a52e-4f735466cecf'];
   const selected=await wd('GET',prefix+'/element/'+id+'/attribute/content-desc');
   if(selected!==(desired?'On':'Off'))throw new Error('Receive Options did not inherit the global gallery setting');
   await waitForNativeControl({wd,prefix,label:gallery+'-gallery-verified',using:'xpath',value:`//*[@package="org.localsend.localsend_app" and @content-desc="${desired?'On':'Off'}" and @clickable="true"]`,sourceIncludes:['Save media to gallery']});
   await capture(gallery+'-options-selected');await wd('POST',prefix+'/back',{});
   await click('Accept');await waitForNativeControl({wd,prefix,label:gallery+'-complete',...target('Done')});
   await capture(gallery+'-completed');
   const filename=`issue2311-${process.env.GITHUB_RUN_ID}-${gallery}.png`;
   const savedPath=`/sdcard/${desired?'Pictures':'Download'}/${filename}`;
   const saved=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path:savedPath}),'base64');
   const source=JSON.parse(readFileSync(`evidence/source-${gallery}.json`));
   const savedSha256=createHash('sha256').update(saved).digest('hex');
   if(savedSha256!==source.sha256.toLowerCase())throw new Error('Image saved bytes mismatch');
   const filesystem=await shell(`stat -c '%n|%s|%Y|%y' '${savedPath}'`,gallery+'-filesystem');
   const mediaStore=await shell(`content query --uri content://media/external/images/media --projection _id:_display_name:_data:date_modified:date_added:datetaken --where "_display_name='${filename}'"`,gallery+'-mediastore');
   const normalMetadata=await helperMetadata(filename,gallery);
   results.push({case:gallery,source,savedPath,savedSha256,byteExact:true,filesystem,mediaStore,normalMetadata});
   writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));
   writeFileSync(`evidence/saved-${gallery}.png`,saved);
   await fileManagerDetails(filename,gallery,desired);
   await click('Done');
  }
 }finally{writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));}
}
