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
 async function shell(command,label){
  const attempts=[];
  for(const script of ['browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),'mobile: shell']){
   try{const result=await wd('POST',prefix+'/execute/sync',{script,args:script==='mobile: shell'?[{command:'sh',args:['-c',command],includeStderr:true}]:[]},{timeoutMs:15000});writeFileSync(`evidence/${label}.json`,JSON.stringify({command,result,attempts},null,2));return result;}
   catch(error){attempts.push(String(error));}
  }
  writeFileSync(`evidence/${label}.json`,JSON.stringify({command,attempts,unavailable:true},null,2));return null;
 }
 try{
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows_release_ui_probe.ps1','-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-11-arm','-FixtureTimestampUtc','2025-02-13T14:11:00Z','-FixtureFileName',`issue2311-${process.env.GITHUB_RUN_ID}-control.txt`,'-DiagnosticPeerPort',String(senderPort)]);
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-ui.ps1','-Action','click','-X','246','-Y','266','-Label','windows-control-favorites']);
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-ui.ps1','-Action','click','-X','145','-Y','205','-Label','windows-control-send']);
  await click('Accept');await waitForNativeControl({wd,prefix,label:'control-complete',...target('Done')});
  await capture('control-completed');
  const path=`/sdcard/Download/issue2311-${process.env.GITHUB_RUN_ID}-control.txt`;
  const bytes=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path}),'base64');
  const expected=readFileSync(`evidence/issue2311-${process.env.GITHUB_RUN_ID}-control.txt`);
  if(!bytes.equals(expected))throw new Error('Control saved bytes mismatch');
  results.push({case:'known-working-control',byteExact:true,sha256:createHash('sha256').update(bytes).digest('hex')});
  await click('Done');
  for(const [index,gallery] of ['on','off','on-repeat','off-repeat'].entries()){
   await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows2311-context.ps1','-Case',gallery,...(index?['-CompletePrevious']:[])]);
   await waitForNativeControl({wd,prefix,label:gallery+'-pending',...target('Accept')});
   await click('Options');await capture(gallery+'-options-before');
   const e=await waitForNativeControl({wd,prefix,label:gallery+'-gallery',using:'xpath',value:'//*[@package="org.localsend.localsend_app" and contains(@content-desc,"Save media to gallery")]/descendant-or-self::*[@checkable="true"]',requireClickable:false});
   const id=e['element-6066-11e4-a52e-4f735466cecf'];
   const checked=await wd('GET',prefix+'/element/'+id+'/attribute/checked');
   const desired=gallery.startsWith('on');
   if((checked==='true'||checked===true)!==desired)await wd('POST',prefix+'/element/'+id+'/click',{});
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
   results.push({case:gallery,source,savedPath,savedSha256,byteExact:true,filesystem,mediaStore});
   writeFileSync(`evidence/saved-${gallery}.png`,saved);
   await click('Done');
  }
 }finally{writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));}
}
