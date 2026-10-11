import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync,writeFileSync,appendFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const exec=promisify(execFile);

export default async function({session,wd,source,lifecycle,ui,click,ready,clickElement,approvalReady,completedReady,selectedDestination,editTarget,documentRow,folderTarget,results,onlyLong=false,skipInitialCompletion=false,semanticSelectionAfterHold=false,samsungPicker=false}) {
 const prefix=`/session/${session}`;
 function phase(caseName,name){const event={phase:name,utc:new Date().toISOString()};writeFileSync(`evidence/${caseName}-phase.json`,JSON.stringify(event,null,2));appendFileSync(`evidence/${caseName}-phases.jsonl`,JSON.stringify(event)+'\n');}
 async function returnToOptions(caseName){
  const deadline=Date.now()+10000,observations=[];
  const choices=[{...editTarget,sourceIncludes:['pane-title="Options"','/storage/emulated/0/Download']},{using:'xpath',value:'//*[@package="com.google.android.documentsui"][1]'}];
  while(Date.now()<deadline){
   const state=await ready(`${caseName}-preflight-return-${observations.length}`,{}, {choices,requireClickable:false,timeoutMs:deadline-Date.now()});
   observations.push({utc:new Date().toISOString(),choice:state.readiness.choice,sourceFile:state.readiness.sourceFile});
   writeFileSync(`evidence/${caseName}-preflight-back.json`,JSON.stringify({deadline:new Date(deadline).toISOString(),observations},null,2));
   if(state.readiness.choice===0)return state;
   const remaining=deadline-Date.now();if(remaining<=0)break;
   await wd('POST',prefix+'/back',{}, {timeoutMs:remaining});
  }
  throw new Error(`${caseName}: preflight picker did not return to original Options/default Download`);
 }
 const longDwellMs=Number(process.env.PICKER_LONG_DWELL_MS||10000);
 if(![10000,20000,30000].includes(longDwellMs))throw new Error('Unsupported diagnostic long dwell');
 let firstCase=true;
 for(const dwellMs of onlyLong?[longDwellMs]:[2000,longDwellMs]) {
  const caseName=`picker-${dwellMs/1000}s`,fileName=`issue3393-${process.env.GITHUB_RUN_ID}-${caseName}.txt`;
  if(!firstCase||!skipInitialCompletion)await clickElement(await completedReady(`${caseName}-previous-completion`),`${caseName}-previous-done`);
  firstCase=false;
  await exec('pwsh',['-NoProfile','-File','support/diagnostics/windows3393-repeat.ps1','-Case',caseName]);
  await approvalReady(`${caseName}-pending`);
  await click('Options',caseName);
  let folderRect;
  if(!semanticSelectionAfterHold){
   // Obtain current native identity and geometry in a separate, recorded preflight.
   const preflightStarted=Date.now();
   phase(caseName,'preflight');
   await clickElement(await ready(`${caseName}-preflight-edit`,editTarget,{sourceIncludes:['pane-title="Options"']}),`${caseName}-preflight-edit`);
   const preflight=await ready(`${caseName}-preflight-picker`,{}, {choices:[{...folderTarget,sourceIncludes:['class="android.widget.TextView" text="Documents"']},documentRow],sourceIncludes:['package="com.google.android.documentsui"']});
   if(preflight.readiness.choice===1)await clickElement(preflight,`${caseName}-preflight-documents`);
   const folder=await ready(`${caseName}-preflight-folder`,folderTarget,{sourceIncludes:['class="android.widget.TextView" text="Documents"']});
   folderRect=folder.readiness.rect;
   await lifecycle(`${caseName}-preflight-native-picker`);
   await returnToOptions(caseName);
   writeFileSync(`evidence/${caseName}-preflight-exposure.json`,JSON.stringify({started:new Date(preflightStarted).toISOString(),returned:new Date().toISOString(),elapsedMs:Date.now()-preflightStarted,separateNativeExposure:true,resetDuringThisPhaseCannotBeAttributedToTimedBatch:true},null,2));
  }
  if(process.env.HELPER_SERVICE_MODE==='ordinary')await lifecycle(`${caseName}-before-timed-opening`);
  await ui('snapshot',0,0,`windows-${caseName}-before-timed-opening`);
  const edit=await ready(`${caseName}-timed-edit`,editTarget,{sourceIncludes:['pane-title="Options"','/storage/emulated/0/Download']});
  const center=rect=>({x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)});
  const opening=center(edit.readiness.rect);
  const actions=[{type:'pointer',id:'folder-picker-touch',parameters:{pointerType:'touch'},actions:[
   {type:'pointerMove',duration:0,origin:'viewport',...opening},
   {type:'pointerDown',button:0},{type:'pause',duration:125},{type:'pointerUp',button:0},
   {type:'pause',duration:dwellMs-125}
  ]}];
  if(!semanticSelectionAfterHold)actions[0].actions.push(
   {type:'pointerMove',duration:0,origin:'viewport',...center(folderRect)},
   {type:'pointerDown',button:0},{type:'pause',duration:125},{type:'pointerUp',button:0}
  );
  phase(caseName,'timed-actions');
  const started=Date.now(),timing={started:new Date().toISOString(),timingObservedViaVideo:false,requiresVideoValidation:true,editRect:edit.readiness.rect,actions,...(semanticSelectionAfterHold?{
   scheduledOpeningToHoldEndMs:dwellMs,noRpcBetweenOpeningAndHoldEnd:true,selectionAfterNativeReadiness:true,exactWallClockDwellClaimed:false
  }:{scheduledOpeningToFolderClickMs:dwellMs,selectionGeometrySource:'same-case native preflight; video must confirm timed reopening in Documents',folderRect,noRpcBetweenOpeningAndSelection:true})};
  writeFileSync(`evidence/${caseName}-timing.json`,JSON.stringify(timing,null,2));
  try{await wd('POST',prefix+'/actions',{actions},{timeoutMs:dwellMs+10000});timing.completed=true;}
  catch(error){timing.error=String(error);throw error;}
  finally{timing.ended=new Date().toISOString();timing.requestElapsedMs=Date.now()-started;writeFileSync(`evidence/${caseName}-timing.json`,JSON.stringify(timing,null,2));}
  if(semanticSelectionAfterHold){
   phase(caseName,'native-readiness-after-hold');
   await source(`${caseName}-after-timed-hold`);
   writeFileSync(`evidence/${caseName}-after-timed-hold.png`,Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
   await lifecycle(`${caseName}-after-timed-hold`,{exposureInterval:{started:timing.started,ended:timing.ended}});
   await ui('snapshot',0,0,`windows-${caseName}-after-timed-hold`);
   // A Documents row at the storage root is not the current Documents folder.
   const documentsFolder={...folderTarget,sourceIncludes:['text="Documents" resource-id="com.google.android.documentsui:id/breadcrumb_text"']};
   const documentsBreadcrumb='//*[@package="com.google.android.documentsui" and @resource-id="com.google.android.documentsui:id/breadcrumb_text" and @text="Documents"]';
   const documentsTitle='//*[@package="com.google.android.documentsui" and @resource-id="android:id/title" and @text="Documents" and @displayed="true"]';
   // Samsung discovery has not observed a picker header. Navigate the unique
   // observed row only when Documents is not the current breadcrumb; the exact
   // selected URI is still checked before accepting the upload.
   const rootDocumentsRow=samsungPicker?{using:'xpath',value:`${documentsTitle}/ancestor::*[@package="com.google.android.documentsui" and @clickable="true" and @enabled="true" and @displayed="true"][1][count(${documentsTitle})=1 and count(${documentsBreadcrumb})=0]`}:{...documentRow,sourceIncludes:['text="Files on OnePlus 13R" resource-id="com.google.android.documentsui:id/header_title"']};
   const current=await ready(`${caseName}-native-picker-after-hold`,{}, {choices:[documentsFolder,rootDocumentsRow],sourceIncludes:['package="com.google.android.documentsui"']});
   if(current.readiness.choice===1)await clickElement(current,`${caseName}-documents-after-hold`);
   const folderButton=await ready(`${caseName}-use-folder-after-hold`,documentsFolder,{sourceIncludes:documentsFolder.sourceIncludes});
   timing.folderSelectionAttempted=new Date().toISOString();timing.folderSelectionReadiness=folderButton.readiness;
   writeFileSync(`evidence/${caseName}-timing.json`,JSON.stringify(timing,null,2));
   await clickElement(folderButton,`${caseName}-use-folder-after-hold`);
   timing.folderSelectionCompleted=new Date().toISOString();
   writeFileSync(`evidence/${caseName}-timing.json`,JSON.stringify(timing,null,2));
  }
  await source(`${caseName}-after-timed-selection`);
  writeFileSync(`evidence/${caseName}-after-timed-selection.png`,Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
  await lifecycle(`${caseName}-after-timed-selection`);
  await ui('snapshot',0,0,`windows-${caseName}-after-timed-selection`);
  phase(caseName,'destination');
  await selectedDestination(`${caseName}-destination`);
  await source(`${caseName}-selected-destination`);
  await wd('POST',prefix+'/back',{}, {timeoutMs:10000});
  phase(caseName,'accept');
  await clickElement(await approvalReady(`${caseName}-before-accept`),`${caseName}-accept`);
  await completedReady(`${caseName}-completion`);
  await source(`${caseName}-after-accept`);await lifecycle(`${caseName}-after-accept`);
  await ui('snapshot',0,0,`windows-${caseName}-after-accept`);
  writeFileSync(`evidence/${caseName}-after-accept.png`,Buffer.from(await wd('GET',prefix+'/screenshot'),'base64'));
  const saved=await wd('POST',prefix+'/appium/device/pull_file',{path:`/sdcard/Documents/${fileName}`});
  const data=Buffer.from(saved,'base64');writeFileSync(`evidence/${caseName}-saved-payload.txt`,data);
  if(data.toString()!==`LocalSend issue3393 ${caseName} unique payload`)throw new Error(`${caseName}: saved contents differ from original sender file`);
  const senderHash=createHash('sha256').update(readFileSync(`evidence/${fileName}`)).digest('hex');
  const savedHash=createHash('sha256').update(data).digest('hex');
  writeFileSync(`evidence/${caseName}-saved-hash.json`,JSON.stringify({fileName,size:data.length,senderSha256:senderHash,savedSha256:savedHash,verified:savedHash===senderHash},null,2));
  if(savedHash!==senderHash)throw new Error(`${caseName}: saved hash differs from actual Windows fixture`);
  phase(caseName,'saved-hash-verified');
  results.push({case:caseName,fileName,destination:'/sdcard/Documents',savedContentVerified:true,savedSha256:savedHash,timingObservedViaVideo:false,requiresVideoValidation:true,...(semanticSelectionAfterHold?{scheduledOpeningToHoldEndMs:dwellMs,selectionAfterNativeReadiness:true,exactWallClockDwellClaimed:false}:{scheduledOpeningToFolderClickMs:dwellMs})});
 }
}
