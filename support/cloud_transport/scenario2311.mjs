import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {waitForNativeControl} from './native-readiness.mjs';
const exec=promisify(execFile);
export default async function({session,wd,senderPort,transportStatus}){
 const prefix=`/session/${session}`,results=[],precisionFailures=[],mtimeFailures=[];
 const extended=process.env.VALIDATION_SUITE==='extended';
 const precisionSourceControl=process.env.VALIDATION_SUITE==='precision-source-control';
 if(precisionSourceControl&&(process.env.SOURCE_APP_FAMILY!=='current'||process.env.SOURCE_APK_KIND!=='tagged'))throw new Error('Precision source control requires the current tagged observer APK');
 const fixtureDirectory=process.env.MEDIA_FIXTURE_DIRECTORY;
 const fixtureManifest=extended?JSON.parse(readFileSync(join(fixtureDirectory||'__missing_media_fixture_artifact__','manifest.json'))):null;
 const cases=precisionSourceControl
  ?[false,true].map(gallery=>({label:'source-precision-'+(gallery?'on':'off'),gallery,extension:'png',fixtureModifiedUtc:'2025-02-13T14:11:00.123Z',sourceBoundaryObservation:true}))
  :['on','off','on-repeat','off-repeat'].map(label=>({label,gallery:label.startsWith('on'),extension:'png'}));
 if(extended){
  cases.push({label:'precision-on',gallery:true,extension:'png',fixtureModifiedUtc:'2025-02-13T14:11:00.123Z'});
  for(const [type,extension,artifactName] of [['jpeg','jpg','capture.jpg'],['video','mp4','capture.mp4']]){
   const fixtureSource=join(fixtureDirectory,artifactName),bytes=readFileSync(fixtureSource);
   const sourceMetadata=fixtureManifest.files.find(file=>file.name===artifactName);
   if(!sourceMetadata||createHash('sha256').update(bytes).digest('hex')!==sourceMetadata.sha256||bytes.length!==sourceMetadata.bytes)throw new Error('Immutable media fixture artifact mismatch: '+artifactName);
   for(const gallery of [true,false])cases.push({label:type+'-'+(gallery?'on':'off'),gallery,extension,fixtureSource,sourceMetadata});
  }
  writeFileSync('evidence/media-fixture-manifest.json',JSON.stringify(fixtureManifest,null,2));
 }
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
  const outputTarget={using:'xpath',value:`//*[@package="org.localsend.cloudtransport" and starts-with(@content-desc,"Image metadata: ") and contains(@content-desc,"${filename}")]`};
  const choices=[outputTarget,{using:'xpath',value:'//*[contains(@resource-id,"permission_allow_all_button") or contains(@resource-id,"permission_allow_button")]'}];
  let e=await waitForNativeControl({wd,prefix,label:label+'-metadata-or-permission',choices,requireClickable:false});
  if(e.readiness.choice===1){await capture(label+'-normal-media-permission');await wd('POST',prefix+'/element/'+e['element-6066-11e4-a52e-4f735466cecf']+'/click',{});e=await waitForNativeControl({wd,prefix,label:label+'-metadata-output',...outputTarget,requireClickable:false});}
  const value=await wd('GET',prefix+'/element/'+e['element-6066-11e4-a52e-4f735466cecf']+'/attribute/content-desc');
  const result=JSON.parse(value.slice('Image metadata: '.length));writeFileSync(`evidence/${label}-normal-metadata.json`,JSON.stringify(result,null,2));await capture(label+'-normal-metadata');
  const expectedSdk=Number(process.env.BS_OS)===10?29:(Number(process.env.BS_OS)===15?35:null);
  if(expectedSdk!==null&&result.androidSdk!==expectedSdk)throw new Error('Native Android SDK differs from selected receiver; raw metadata retained');
  await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});
  return result;
 }
 async function fileManagerDetails(filename,label,desired){
  const appId='com.google.android.apps.nbu.files';
  const installed=await wd('POST',prefix+'/appium/device/app_installed',{appId});
  if(!installed)throw new Error('Google Files is not installed; normal file-manager details require another observed entry');
  await wd('POST',prefix+'/appium/device/activate_app',{appId});
  await waitForNativeControl({wd,prefix,label:label+'-files-foreground',using:'xpath',value:`//*[@package="${appId}"]`,requireClickable:false});
  for(let attempt=0;attempt<5;attempt++){
   await capture(label+'-files-entry-'+attempt);
   const source=await wd('GET',prefix+'/source');
   const choice=source.includes('id/agree_button')?{using:'id',value:appId+':id/agree_button'}:source.includes('permission_allow_button')?{using:'id',value:'com.android.permissioncontroller:id/permission_allow_button'}:source.includes('text="Got it"')?{using:'xpath',value:'//*[@text="Got it"]'}:null;
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
  const category=await waitForNativeControl({wd,prefix,label:label+'-files-category',using:'xpath',value:`//*[@text="${desired?'Images':'Downloads'}" or @text="${desired?'Pictures':'Download'}"]/ancestor-or-self::*[@clickable="true"][1]`});
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
 async function galleryImportDiagnostic(filename){
  await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.cloudtransport'});
  const input=await waitForNativeControl({wd,prefix,label:'causal-input',using:'accessibility id',value:'Metadata filename'});
  await wd('POST',prefix+'/element/'+input['element-6066-11e4-a52e-4f735466cecf']+'/value',{text:filename});
  await click('Run gallery import diagnostic');
  const output=await waitForNativeControl({wd,prefix,label:'causal-output',using:'xpath',value:'//*[@package="org.localsend.cloudtransport" and starts-with(@content-desc,"Gallery import diagnostic: ")]',requireClickable:false,timeoutMs:30000});
  const value=await wd('GET',prefix+'/element/'+output['element-6066-11e4-a52e-4f735466cecf']+'/attribute/content-desc');
  const diagnostic=JSON.parse(value.slice('Gallery import diagnostic: '.length));
  writeFileSync('evidence/gallery-import-diagnostic.json',JSON.stringify(diagnostic,null,2));
  await capture('gallery-import-diagnostic');
  if(diagnostic.error)throw new Error('Native gallery component diagnostic failed: '+diagnostic.error);
  if(diagnostic.cases?.length!==3||diagnostic.cases.some(entry=>entry.error))throw new Error('Native gallery comparison did not observe every component case');
  return diagnostic;
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
  for(const testCase of cases){
   const gallery=testCase.label,desired=testCase.gallery;
   await globalGallery(desired,gallery);
   // The control also leaves the Windows sender on its Finished route.
   // Close that route before every Explorer Send to invocation.
   const contextArgs=['-NoProfile','-File','support/diagnostics/windows2311-context.ps1','-Case',gallery,'-CompletePrevious'];
   if(testCase.fixtureSource)contextArgs.push('-FixtureSource',testCase.fixtureSource,'-FixtureExtension',testCase.extension);
   if(testCase.fixtureModifiedUtc)contextArgs.push('-FixtureModifiedUtc',testCase.fixtureModifiedUtc);
   await exec('pwsh',contextArgs);
   await waitForNativeControl({wd,prefix,label:gallery+'-pending',...target('Accept')});
   await click('Options');await capture(gallery+'-options-before');
   // Current Flutter merges this section into one semantics node. Inspect its
   // exact gallery label/value lines; no click or inferred screen coordinate.
   const merged=['current','candidate'].includes(process.env.SOURCE_APP_FAMILY);
   const galleryLocator={using:'xpath',value:merged
    ?'//*[@package="org.localsend.localsend_app" and contains(@content-desc,"Save media to gallery") and contains(@content-desc,"Save to folder") and @clickable="true"]'
    :'//*[@package="org.localsend.localsend_app" and (@content-desc="On" or @content-desc="Off") and @clickable="true"]'};
   const e=await waitForNativeControl({wd,prefix,label:gallery+'-gallery',...galleryLocator,sourceIncludes:['Save media to gallery']});
   const matches=await wd('POST',prefix+'/elements',galleryLocator);
   if(matches.length!==1)throw new Error('Receive Options gallery semantics are not unique');
   const id=e['element-6066-11e4-a52e-4f735466cecf'];
   const description=await wd('GET',prefix+'/element/'+id+'/attribute/content-desc');
   const lines=description.split('\n'),galleryLabels=lines.filter(line=>line==='Save media to gallery');
   if(merged&&galleryLabels.length!==1)throw new Error('Receive Options gallery label is not unique');
   const selected=merged?lines[lines.indexOf('Save media to gallery')+1]:description;
   if(selected!==(desired?'On':'Off'))throw new Error('Receive Options did not inherit the global gallery setting');
   writeFileSync(`evidence/${gallery}-options-gallery.json`,JSON.stringify({desired,selected,description,merged,matches:matches.length,selectionTiming:'Inherited global setting before acceptance'},null,2));
   await capture(gallery+'-options-selected');await wd('POST',prefix+'/back',{});
   await click('Accept');await waitForNativeControl({wd,prefix,label:gallery+'-complete',...target('Done')});
   await capture(gallery+'-completed');
   const filename=`issue2311-${process.env.GITHUB_RUN_ID}-${gallery}.${testCase.extension}`;
   const savedPath=`/sdcard/${desired?(testCase.extension==='mp4'?'Movies':'Pictures'):'Download'}/${filename}`;
   if(testCase.sourceBoundaryObservation){
    const source=JSON.parse(readFileSync(`evidence/source-${gallery}.json`));
    const requestedMtimeMs=Date.parse(testCase.fixtureModifiedUtc);
    const sourceExact=source.mtimeMs===requestedMtimeMs&&source.requestedMtimeMs===requestedMtimeMs;
    const fixtureExact=source.bytes===1042&&source.sha256.toLowerCase()==='561fa660b1ee2b0a3ab29d36c157ae238a0b27d4db0b6aa4154e892b4699a7ef';
    const normalMetadata=await helperMetadata(filename,gallery),observed=[];
    for(const file of normalMetadata.filesystem||[]){
     if(file.error||!file.sha256)continue;
     const entry={...file};
     try{
      const bytes=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path:file.path}),'base64');
      entry.pulledSha256=createHash('sha256').update(bytes).digest('hex');entry.pulledBytes=bytes.length;
      entry.byteExact=entry.pulledSha256===source.sha256.toLowerCase()&&file.sha256===entry.pulledSha256&&file.size===bytes.length;
      const destination=file.path.includes('/Pictures/')?'gallery':'directory';
      writeFileSync(`evidence/saved-${gallery}-${destination}.png`,bytes);
     }catch(error){entry.pullError=String(error);}
     observed.push(entry);
    }
    const galleryFile=observed.find(file=>file.path===`/sdcard/Pictures/${filename}`),directoryFile=observed.find(file=>file.path===`/sdcard/Download/${filename}`);
    const expectedFile=desired?galleryFile:directoryFile;
    const observation={case:gallery,mode:'precision-source-control',galleryEnabled:desired,mediaType:'png',source,requestedMtimeMs,sourceExact,fixtureExact,
     expectedSavedPath:savedPath,observed,normalMetadata,
     expectedDestinationObserved:!!expectedFile,byteExact:expectedFile?.byteExact===true,
     filesystemMtimeMs:expectedFile?.filesystemMtimeMs??null,
     filesystemMatchesWindowsSource:expectedFile?.filesystemMtimeMs===source.mtimeMs,
     saveOutcome:galleryFile?(directoryFile?'gallery-and-directory-observed':'gallery-observed'):(directoryFile?(desired?'directory-fallback-observed':'directory-observed'):'no-saved-file-observed'),
     precisionGate:'Observational source boundary only; does not assert fractional timestamp preservation',
     receiverObserver:{sourceFamily:process.env.SOURCE_APP_FAMILY,sourceApkKind:process.env.SOURCE_APK_KIND,filename,correlation:'Match this filename with the tagged APK incoming-metadata and cache-before-Gal logs'}};
    results.push(observation);writeFileSync(`evidence/${gallery}-source-boundary.json`,JSON.stringify(observation,null,2));
    writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));
    if(!sourceExact||!fixtureExact)throw new Error('Precision source-control Windows fixture differs from the requested timestamp or original PNG; raw evidence retained');
    if(!expectedFile?.byteExact||!Number.isFinite(expectedFile.filesystemMtimeMs))throw new Error('Precision source-control expected destination did not independently verify saved PNG bytes and native millisecond timestamp; raw evidence retained');
    if(normalMetadata.mediaStoreError)throw new Error('Precision source-control MediaStore observation failed: '+normalMetadata.mediaStoreError);
    await click('Done');continue;
   }
   if(testCase.fixtureModifiedUtc){
    const source=JSON.parse(readFileSync(`evidence/source-${gallery}.json`));
    const normalMetadata=await helperMetadata(filename,gallery);
    const observed=[];
    for(const file of normalMetadata.filesystem||[]){
     if(file.error||!file.sha256)continue;
     const entry={...file};
     try{
      const bytes=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path:file.path}),'base64');
      entry.pulledSha256=createHash('sha256').update(bytes).digest('hex');entry.pulledBytes=bytes.length;
      entry.byteExact=entry.pulledSha256===source.sha256.toLowerCase()&&file.sha256===entry.pulledSha256&&file.size===bytes.length;
      const directory=file.path.includes('/Pictures/')?'gallery':'fallback';writeFileSync(`evidence/saved-${gallery}-${directory}.png`,bytes);
     }catch(error){entry.pullError=String(error);}
     observed.push(entry);
    }
    const requestedMtimeMs=Date.parse(testCase.fixtureModifiedUtc);
    const sourceExact=source.mtimeMs===requestedMtimeMs&&source.requestedMtimeMs===requestedMtimeMs;
    const galleryFile=observed.find(file=>file.path===savedPath),fallbackFile=observed.find(file=>file.path===`/sdcard/Download/${filename}`);
    const galleryRows=normalMetadata.mediaStore?.filter(row=>row._display_name===filename&&row._data?.endsWith('/Pictures/'+filename));
    const senderReport=JSON.parse(readFileSync('evidence/release-ui-report.json'));
    const senderMatchesObserver=senderReport.release==='v1.17.0'&&senderReport.assetArchitecture==='x86-64'
     &&senderReport.archive?.sha256?.toLowerCase()==='a4ffb41fcbc3bd0f2f0cbd30b62a58d9a478eaf1da63eb410886886064abe70c';
    if(!senderMatchesObserver)throw new Error('Precision received-metadata contract requires the exact released Windows sender archive observed in run38188599818');
    const expectedReceivedMtimeMs=1739455860000;
    const expectedModifiedSeconds=Math.floor(expectedReceivedMtimeMs/1000);
    const mediaStoreModifiedSeconds=(galleryRows||[]).map(row=>row.date_modified==null?null:Number(row.date_modified));
    const filesystemEqual=Number.isFinite(source.mtimeMs)&&galleryFile?.filesystemMtimeMs===source.mtimeMs;
    const mediaStoreEqual=!normalMetadata.mediaStoreError&&galleryRows?.length===1&&Number.isFinite(mediaStoreModifiedSeconds[0])&&mediaStoreModifiedSeconds[0]===expectedModifiedSeconds;
    const required=process.env.SOURCE_APP_FAMILY==='candidate'&&process.env.SOURCE_APK_KIND==='candidate';
    const receivedFilesystemEqual=galleryFile?.filesystemMtimeMs===expectedReceivedMtimeMs;
    const mtimeVerdict={expectedMtimeMs:source.mtimeMs,expectedReceivedMtimeMs,expectedModifiedSeconds,filesystemMtimeMs:galleryFile?.filesystemMtimeMs??null,filesystemEqual,
     receivedFilesystemEqual,mediaStoreApplicable:true,mediaStoreModifiedSeconds,mediaStoreEqual,fallbackObserved:!!fallbackFile,required,
     passed:receivedFilesystemEqual&&mediaStoreEqual&&!fallbackFile,endToEndPassed:filesystemEqual&&mediaStoreEqual&&!fallbackFile};
    const strictGalleryResult=sourceExact&&galleryFile?.byteExact===true&&mtimeVerdict.endToEndPassed;
    const receivedMetadataGalleryResult=sourceExact&&galleryFile?.byteExact===true&&mtimeVerdict.passed;
    const precision={case:gallery,mediaType:'png',source,expectedSavedPath:savedPath,requestedMtimeMs,observed,normalMetadata,sourceExact,strictGalleryResult,receivedMetadataGalleryResult,mtimeVerdict,
     validationContract:{scope:'Preserve received metadata; fractional Windows-to-receiver loss remains unresolved',observerRun:'38188599818',
      expectedReceivedMtimeMs,basis:'Exact archive sender; filename-correlated incoming/cache logs and gallery-Off native stat observed .123 source arriving as .000. This run does not directly log incoming metadata.'},
     saveOutcome:galleryFile?(fallbackFile?'gallery-and-fallback-observed':'gallery-observed'):(fallbackFile?'directory-fallback-observed':'no-saved-file-observed')};
    results.push(precision);writeFileSync(`evidence/${gallery}-precision-result.json`,JSON.stringify(precision,null,2));
    writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));
    if(!sourceExact)throw new Error('Precision source Windows timestamp differs from the requested milliseconds; raw evidence retained');
    if(!receivedMetadataGalleryResult&&required)precisionFailures.push(precision);
    await click('Done');continue;
   }
   let actualSavedPath=savedPath,saved,galleryPullError=null;
   try{saved=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path:savedPath}),'base64');}
   catch(error){
    if(!desired)throw error;
    galleryPullError=String(error);actualSavedPath=`/sdcard/Download/${filename}`;
    try{saved=Buffer.from(await wd('POST',prefix+'/appium/device/pull_file',{path:actualSavedPath}),'base64');}
    catch(fallbackError){
     writeFileSync(`evidence/${gallery}-missing-save.json`,JSON.stringify({case:gallery,expectedSavedPath:savedPath,fallbackPath:actualSavedPath,galleryPullError,fallbackPullError:String(fallbackError)},null,2));
     throw fallbackError;
    }
   }
   writeFileSync(`evidence/saved-${gallery}.${testCase.extension}`,saved);
   const source=JSON.parse(readFileSync(`evidence/source-${gallery}.json`));
   if(testCase.sourceMetadata&&source.sha256.toLowerCase()!==testCase.sourceMetadata.sha256)throw new Error('Explorer selected a different fixture than the immutable artifact');
   const savedSha256=createHash('sha256').update(saved).digest('hex');
   if(savedSha256!==source.sha256.toLowerCase())throw new Error('Saved media bytes mismatch');
   const filesystem=await shell(`stat -c '%n|%s|%Y|%y' '${actualSavedPath}'`,gallery+'-filesystem');
   const collection=testCase.extension==='mp4'?'video':'images';
   const mediaStore=await shell(`content query --uri content://media/external/${collection}/media --projection _id:_display_name:_data:date_modified:date_added:datetaken --where "_display_name='${filename}'"`,gallery+'-mediastore');
   const normalMetadata=await helperMetadata(filename,gallery);
   const measuredFile=normalMetadata.filesystem?.find(file=>file.path===actualSavedPath);
   const rows=normalMetadata.mediaStore?.filter(row=>row._display_name===filename)||[];
   const expectedMtimeMs=source.mtimeMs,expectedModifiedSeconds=Math.floor(expectedMtimeMs/1000);
   const filesystemEqual=Number.isFinite(expectedMtimeMs)&&measuredFile?.filesystemMtimeMs===expectedMtimeMs;
   const mediaStoreModifiedSeconds=rows.map(row=>row.date_modified==null?null:Number(row.date_modified));
   const mediaStoreEqual=!desired||(!normalMetadata.mediaStoreError&&rows.length===1&&Number.isFinite(mediaStoreModifiedSeconds[0])&&mediaStoreModifiedSeconds[0]===expectedModifiedSeconds);
   const fallbackObserved=desired&&(actualSavedPath!==savedPath||(normalMetadata.filesystem||[]).some(file=>file.path===`/sdcard/Download/${filename}`&&!file.error&&file.sha256));
   const required=!desired||(process.env.SOURCE_APP_FAMILY==='candidate'&&process.env.SOURCE_APK_KIND==='candidate');
   const mtimeVerdict={expectedMtimeMs,expectedModifiedSeconds,filesystemMtimeMs:measuredFile?.filesystemMtimeMs??null,filesystemEqual,
    mediaStoreApplicable:desired,mediaStoreModifiedSeconds,mediaStoreEqual,fallbackObserved,required,passed:filesystemEqual&&mediaStoreEqual&&!fallbackObserved};
   const result={case:gallery,mediaType:testCase.extension,source,savedPath,actualSavedPath,savedSha256,byteExact:true,filesystem,mediaStore,normalMetadata,
    fixtureArtifact:testCase.sourceMetadata||null,galleryPullError,mtimeVerdict,saveOutcome:fallbackObserved?'directory-fallback-observed':(desired?'gallery-observed':'directory-observed')};
   results.push(result);writeFileSync(`evidence/${gallery}-mtime-result.json`,JSON.stringify(result,null,2));
   writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));
   if(required&&!mtimeVerdict.passed)mtimeFailures.push({case:gallery,mtimeVerdict});
   if(extended&&(!measuredFile||measuredFile.error||measuredFile.sha256!==savedSha256||measuredFile.size!==saved.length))throw new Error('Independent normal-permission filesystem observation did not verify saved bytes/path');
   if(extended&&normalMetadata.mediaStoreError)throw new Error('Correct-collection MediaStore observation failed: '+normalMetadata.mediaStoreError);
   if(extended&&desired&&!fallbackObserved){
    const directory=testCase.extension==='mp4'?'Movies':'Pictures';
    if(rows?.length!==1||!rows[0]._data?.endsWith('/'+directory+'/'+filename))throw new Error('Owned gallery item did not appear in expected MediaStore collection/directory');
   }
   if(testCase.extension==='jpg'){
    if(measuredFile.rawExifError||measuredFile.rawExif?.DateTimeOriginal!==fixtureManifest.jpeg.dateTimeOriginal||measuredFile.rawExif?.DateTimeDigitized!==fixtureManifest.jpeg.dateTimeDigitized)throw new Error('Saved JPEG capture EXIF differs from the immutable source artifact');
   }
   if(testCase.extension==='mp4'){
    const raw=measuredFile.rawVideoMetadata;
    if(measuredFile.rawVideoMetadataError||!raw?.date||!(Number(raw.durationMs)>0)||Number(raw.width)!==32||Number(raw.height)!==24)throw new Error('Saved video native metadata is missing or differs from fixture dimensions/duration');
    const normalized=raw.date.replace(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(.*)$/,'$1-$2-$3T$4:$5:$6$7');
    if(Date.parse(normalized)!==Date.parse(fixtureManifest.video.format.tags.creation_time))throw new Error('Saved video capture time differs from immutable source artifact');
   }
   try {if(testCase.extension==='mp4')results.at(-1).fileManagerDetails={captured:false,reason:'Raw native video metadata and filesystem observations collected separately'};else{await fileManagerDetails(filename,gallery,desired);results.at(-1).fileManagerDetails={captured:true};}}
   catch(error){results.at(-1).fileManagerDetails={captured:false,error:String(error)};await capture(gallery+'-files-detail-blocker');}
   finally{await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});}
   await click('Done');
  }
  if(!precisionSourceControl)await galleryImportDiagnostic(`issue2311-${process.env.GITHUB_RUN_ID}-off-repeat.png`);
  if(precisionFailures.length)throw new Error('Candidate gallery received-metadata preservation failed; separate end-to-end fractional verdict and gallery/fallback artifacts retained');
  if(mtimeFailures.length)throw new Error('Required media modification-time verdicts failed: '+mtimeFailures.map(result=>result.case).join(', ')+'; raw per-case results retained');
 }finally{writeFileSync('evidence/scenario-results.json',JSON.stringify({results,transport:transportStatus()},null,2));}
}
