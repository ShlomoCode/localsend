import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdirSync,readFileSync,symlinkSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import physicalControl from './2007-physical-control.mjs';
import {waitForNativeControl} from './native-readiness.mjs';

const installDocs='https://www.browserstack.com/docs/app-automate/appium/advanced-features/test-app-upgrades';
function deriveRowTransitions(arm){
 const canonical=path=>typeof path==='string'?path.replace(/^\/sdcard\//,'/storage/emulated/0/'):path;
 const destination=canonical(arm.initialReceive.destination);
 const snapshots={};
 for(const stage of ['beforeTrash','afterTrash','afterResend']){
  const owned=arm[stage]?.report?.observations?.find(item=>item.name===arm.fixtureName);
  const unique=new Map();
  for(const query of owned?.queries||[])for(const row of query.rows||[]){
   const entry={table:query.uri,id:String(row._id),path:canonical(row._data),row,queryModes:[]};
   const key=JSON.stringify([entry.table,entry.id,entry.path]);
   if(!unique.has(key))unique.set(key,entry);
   const current=unique.get(key);
   current.queryModes.push({matchTrashed:query.matchTrashed,matchPending:query.matchPending});
   if(JSON.stringify(current.row)!==JSON.stringify(row)){
    current.differingColumnObservations??=[];
    current.differingColumnObservations.push(row);
   }
  }
  const rows=[...unique.values()];
  snapshots[stage]={collectedUtc:arm[stage]?.collectedUtc,destinationNativeStat:owned?.nativeStat,destinationExists:owned?.exists,rows,exactDestinationRows:rows.filter(entry=>entry.path===destination)};
 }
 const original=snapshots.beforeTrash.exactDestinationRows;
 const originalKeys=new Set(original.map(entry=>JSON.stringify([entry.table,entry.id])));
 const originalAt=stage=>snapshots[stage].rows.filter(entry=>originalKeys.has(JSON.stringify([entry.table,entry.id])));
 const published=entry=>entry.row.is_pending==='0'&&entry.row._size===String(arm.initialReceive.bytes)&&entry.row.owner_package_name==='org.localsend.localsend_app';
 return {fixtureName:arm.fixtureName,destination,initialBytes:arm.initialReceive.bytes,initialSha256:arm.initialReceive.sha256,deduplicationKey:['table','id','path'],snapshots,
  originalRowIds:original.map(entry=>({table:entry.table,id:entry.id,path:entry.path})),
  beforeTrashPublishedDestinationRows:original.filter(published),beforeTrashPendingDestinationRows:original.filter(entry=>entry.row.is_pending==='1'),
  originalRowsAfterTrash:originalAt('afterTrash'),originalRowsAfterResend:originalAt('afterResend'),
  afterResendPublishedDestinationRows:snapshots.afterResend.exactDestinationRows.filter(published),
  scope:'Observed row transitions for these exact owned paths and one provider session; column observations alone do not establish a universal cause'};
}
export default async function(context){
 const root=process.cwd(),run=process.env.GITHUB_RUN_ID,prefix=`/session/${context.session}`;
 assert(/^[0-9]+$/.test(run));
 assert.equal(process.env.BS_DEVICE,'Samsung Galaxy S21');assert.equal(process.env.BS_OS,'11.0');
 assert.equal(process.env.ISSUE_2007_SOURCE_COMPARISON,'1');
 const pair=JSON.parse(readFileSync(process.env.ISSUE_2007_BUILD_PAIR_JSON,'utf8'));
 const summary={session:context.session,startedUtc:new Date().toISOString(),order:['candidate','baseline','candidate','baseline'],helperScannerInvoked:false,configuredPreTrashInterventionWaitMs:0,configuredPostDeleteWaitMs:0,timingPolicy:'Identical native UI and read-only observation sequence; no fixed 45-second intervention wait',installDocs,arms:[]};
 const summaryPath=join(root,'evidence/source-session-summary.json');
 const save=()=>writeFileSync(summaryPath,JSON.stringify(summary,null,2));
 async function shell(command){return context.wd('POST',prefix+'/execute/sync',{script:'browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),args:[]});}
 const names=['candidateone','baselineone','candidatetwo','baselinetwo'];
 for(const [index,label] of summary.order.entries()){
  const armName=names[index],directory=join(root,'.diagnostic-arms',`source-${armName}`),evidence=join(root,'evidence',`source-${armName}`,'evidence');
  mkdirSync(directory,{recursive:true});mkdirSync(evidence,{recursive:true});
  symlinkSync(evidence,join(directory,'evidence'),'dir');
  for(const name of ['support','released'])symlinkSync(join(root,name),join(directory,name),'dir');
  const provenance=pair[label];
  assert(/^[0-9a-f]{40}$/.test(provenance.source_sha));assert(/^[0-9a-f]{64}$/.test(provenance.apk_sha256));
  const arm={index,label,armName,fixtureName:`2007-${run}-${armName}.txt`,startedUtc:new Date().toISOString(),sourceSha:provenance.source_sha,appUrl:provenance.browserstack_app_url,apkSha256:provenance.apk_sha256,evidenceDirectory:`source-${armName}/evidence`,install:{method:index===0?'Session otherApps candidate install':'W3C mobile:installApp',docs:installDocs}};
  summary.arms.push(arm);save();
  process.chdir(directory);
  try{
   if(index>0){
    arm.install.priorPackage=await context.wd('GET',prefix+'/appium/device/current_package');
    arm.install.priorPid=await shell('pidof org.localsend.localsend_app');
    arm.install.requestedUtc=new Date().toISOString();save();
    arm.install.terminateResult=await context.wd('POST',prefix+'/appium/device/terminate_app',{appId:'org.localsend.localsend_app'});
    await context.wd('POST',prefix+'/execute/sync',{script:'mobile:installApp',args:[{appPath:arm.appUrl}]});
    arm.install.returnedUtc=new Date().toISOString();save();
   }
   await context.wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'});
   // physicalControl owns initial readiness and the normal receive/permission
   // flow. Source identity verification must not add an earlier UI gate.
   arm.install.packagePath=await shell('pm path org.localsend.localsend_app');
   writeFileSync('evidence/installed-package-path.json',JSON.stringify(arm.install.packagePath,null,2));
   const encodedPath=typeof arm.install.packagePath==='string'?arm.install.packagePath:JSON.stringify(arm.install.packagePath);
   const paths=[...encodedPath.matchAll(/package:(\/data\/app\/[A-Za-z0-9_+./=~-]+\.apk)/g)].map(match=>match[1]);
   assert.equal(paths.length,1,'Source arm must have exactly one normal installed APK');
   const installed=Buffer.from(await context.wd('POST',prefix+'/appium/device/pull_file',{path:paths[0]}),'base64');
   arm.install.installedApkSha256=createHash('sha256').update(installed).digest('hex');
   arm.install.pid=await shell('pidof org.localsend.localsend_app');
   arm.install.packageInfo=await shell('dumpsys package org.localsend.localsend_app');
   arm.install.verifiedUtc=new Date().toISOString();
   writeFileSync('evidence/source-install.json',JSON.stringify(arm,null,2));save();
   assert.equal(arm.install.installedApkSha256,arm.apkSha256,'Installed APK must equal the immutable signed source-build APK; no cloud rewriting');
   Object.assign(process.env,{ISSUE_2007_FIXTURE_NAME:arm.fixtureName,ISSUE_2007_FIXTURE_SEED:run,ISSUE_2007_STORAGE_OBSERVER:'1',ISSUE_2007_OBSERVER_PREPARED:index===0?'0':'1',ISSUE_2007_REPEAT_RESEND:'0',ISSUE_2007_BASELINE_ONLY:'0',ISSUE_2007_RETRY_INTERVENTION:'',ISSUE_2007_FINALIZE_INTERVENTION:'',ISSUE_2007_SCAN_COMPARISON:'0',ISSUE_2007_DELETE_TIMING:'absence',ISSUE_2007_DELETE_ACTION:'trash',ISSUE_2007_VARIANT:'unchanged',ISSUE_2007_POST_DELETE_WAIT:'0',ISSUE_2007_RESTART_RECEIVER:'0',ISSUE_2007_DESTINATION:'downloads',ISSUE_2007_PRESERVE_DESTINATION:index===0?'0':'1'});
   await physicalControl(context);
   for(const [key,file] of [['initialReceive','actual-app-control.json'],['trash','actual-deletion.json'],['resend','actual-resend-result.json'],['beforeReceive','storage-before-baseline.json'],['beforeTrash','storage-before-trash.json'],['afterTrash','storage-after-trash.json'],['afterResend','storage-after-resend.json']])arm[key]=JSON.parse(readFileSync(join(evidence,file),'utf8'));
   arm.rowTransitions=deriveRowTransitions(arm);
   writeFileSync(join(evidence,'source-row-transitions.json'),JSON.stringify(arm.rowTransitions,null,2));
   arm.completedUtc=new Date().toISOString();save();
   const done=await waitForNativeControl({wd:context.wd,prefix,using:'accessibility id',value:'Done',label:armName+'-actual-done'});
   await context.wd('POST',`${prefix}/element/${done['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
   await waitForNativeControl({wd:context.wd,prefix,using:'xpath',value:'//*[contains(@content-desc,"Receive")]',label:armName+'-ready-for-install'});
  }catch(error){arm.error=String(error);throw error;}
  finally{process.chdir(root);save();}
 }
 // Save all observed outcomes before applying expected-result assertions.
 summary.observationsCompletedUtc=new Date().toISOString();save();
 try{
  assert.equal(new Set(summary.arms.map(arm=>arm.fixtureName)).size,4,'All arms need fresh owned names');
  assert.equal(new Set(summary.arms.map(arm=>arm.initialReceive.sha256)).size,1,'All four arms must send identical bytes');
  assert.equal(context.sourceAudit.scannerGuardViolations,0,'No helper scanner selector or helper coordinate action may be attempted');
  assert.equal(context.sourceAudit.events.filter(event=>event.method==='POST'&&event.path==='/session').length,1,'Exactly one device session must be allocated');
  summary.helperControlAudit={scannerGuardViolations:context.sourceAudit.scannerGuardViolations,helperClicks:context.sourceAudit.events.filter(event=>event.activePackage==='org.localsend.cloudtransport'&&event.path.endsWith('/click')).map(event=>({utc:event.utc,locator:event.locator})),fullAudit:'source-webdriver-audit.json'};
  const providerIdentities=new Set(),providerPids=new Set();
  for(const arm of summary.arms){
   assert(arm.initialReceive.byteExact);
   assert.equal(arm.trash.deletionMode,'trash');assert(arm.trash.pathAbsent);
   assert(arm.resend.accepted&&arm.resend.sameName&&arm.resend.unchangedFile);
   assert.equal(arm.resend.expectedSha256,arm.initialReceive.sha256);
   for(const stage of ['beforeReceive','beforeTrash','afterTrash','afterResend']){
    const record=arm[stage],owned=record.report.observations.find(item=>item.name===arm.fixtureName);
    assert(record.report.readOnly&&record.report.allFilesAccess&&owned);
    assert(owned.queries.length&&owned.queries.every(query=>!query.error&&!query.nullCursor),'Provider evidence must remain observable');
    assert(record.identities.length>=3,'Each stage must preserve process identity probes');
    const provider=record.report.mediaProvider;
    assert(provider?.packageName&&!provider.error,'Actual MediaStore provider identity must be observable');
    providerIdentities.add(JSON.stringify({packageName:provider.packageName,className:provider.className,versionName:provider.versionName,longVersionCode:provider.longVersionCode,buildFingerprint:record.report.buildFingerprint}));
    const providerProbe=record.identities.find(item=>item.command==='dumpsys meminfo '+provider.packageName);
    const providerPid=JSON.stringify(providerProbe?.result).match(/MEMINFO in pid (\d+)/)?.[1];
    assert(providerPid,'Actual provider PID must remain visible at '+stage);providerPids.add(providerPid);
   }
   // Dumpsys supplies the actual PID even when adbShell wraps its output.
   arm.processIds={};
   for(const stage of ['beforeTrash','afterTrash','afterResend']){
    const probe=arm[stage].identities.find(item=>item.command==='dumpsys meminfo org.localsend.localsend_app');
    const pid=JSON.stringify(probe?.result).match(/MEMINFO in pid (\d+)/)?.[1];
    assert(pid,'Receiver process identity must be visible at '+stage);
    arm.processIds[stage]=pid;
   }
   assert.equal(new Set(Object.values(arm.processIds)).size,1,'Receiver PID must stay stable through Trash and resend');
   const rows=arm.beforeTrash.report.observations.find(item=>item.name===arm.fixtureName).queries.flatMap(query=>query.rows);
   assert(rows.some(row=>row._id),'Known-present file must have a visible owned MediaStore row');
   const transition=arm.rowTransitions;
   assert(transition.originalRowIds.length,'Original exact destination row must be visible before Trash');
   assert.equal(transition.snapshots.afterTrash.destinationExists,false,'Native Trash must remove the original destination path');
   if(arm.label==='candidate'){
    assert.equal(transition.beforeTrashPublishedDestinationRows.length,transition.originalRowIds.length,'Candidate must publish original rows with pending=0, exact size and LocalSend ownership before Trash');
    assert.equal(transition.originalRowsAfterTrash.length,0,'Candidate original IDs must be absent after native Trash');
    assert(transition.afterResendPublishedDestinationRows.length,'Candidate resend must publish a row at the exact original path with exact size and LocalSend ownership');
    assert(arm.resend.resendSucceeded&&arm.resend.byteExact&&arm.resend.sameDestination&&!arm.resend.numberedPathExists&&!arm.resend.receiverFailed,'Candidate must save exact bytes under the same original path');
   }else{
    assert.equal(transition.beforeTrashPendingDestinationRows.length,transition.originalRowIds.length,'Baseline must preserve the observed pending original rows before Trash');
    assert(transition.originalRowsAfterTrash.some(entry=>entry.path===transition.destination&&entry.row.nativeStat?.errno===2),'Baseline must retain an original row referring to the now-absent original destination');
    assert(arm.resend.receiverFailed&&!arm.resend.resendSucceeded&&!arm.resend.saved&&!arm.resend.numberedPathExists,'Baseline must visibly fail the real same-name resend');
   }
  }
  assert.equal(providerIdentities.size,1,'Provider identity must remain identical across all installs and stages');
  assert.equal(providerPids.size,1,'Provider must not restart during the controlled source comparison');
  summary.strictGatesPassed=true;summary.completedUtc=new Date().toISOString();
 }catch(error){summary.strictGatesPassed=false;summary.gateError=String(error);throw error;}
 finally{save();}
}
