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
  await wd('POST',prefix+'/element',{using:'-android uiautomator',value:'new UiScrollable(new UiSelector().scrollable(true)).scrollIntoView(new UiSelector().description("Save media to gallery"))'});
  const locator={using:'xpath',value:'//*[@package="org.localsend.localsend_app" and @content-desc="Save media to gallery"]/following::android.widget.Switch[1]'};
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
 try{
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows2311-desktop.ps1']);
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows_release_ui_probe.ps1','-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-11-arm','-FixtureTimestampUtc','2025-02-13T14:11:00Z','-FixtureFileName',`issue2311-${process.env.GITHUB_RUN_ID}-control.txt`,'-DiagnosticPeerPort',String(senderPort)]);
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
   writeFileSync(`evidence/saved-${gallery}.png`,saved);
   await click('Done');
  }
 }finally{writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));}
}
