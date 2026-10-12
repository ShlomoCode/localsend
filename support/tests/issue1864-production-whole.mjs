// One natural 180s cloud capture per clean-APK phase. No action/session recovery.
import {execFileSync,spawn} from 'node:child_process';
import fs from 'node:fs';
import {recordingInventory,actionInventory} from './issue1864-production-coverage.mjs';
const env=process.env,out=env.ISSUE1864_EVIDENCE_DIR;
const hostDeadline=Number(env.ISSUE1864_HOST_DEADLINE_EPOCH_MS);
if(!Number.isFinite(hostDeadline) || hostDeadline-Date.now()<600000) throw new Error('Insufficient independent job budget for full natural capture and evidence finalization');
if(!out || !['production-base','production-candidate'].includes(env.ISSUE1864_APK) || !['core','permission-denial-grant','picker-cancel','pointer-count','folders','mixed','theme-light','theme-dark'].includes(env.ISSUE1864_PHASE)) throw new Error('Explicit clean APK identity, phase and output required');
fs.mkdirSync(out,{recursive:true});
const name=`${env.ISSUE1864_APK}-${env.ISSUE1864_PHASE}`,path=`/sdcard/issue1864-production/${name}.mp4`,raw=`${out}/whole-phase.mp4`;
const hostRemaining=()=>{const remaining=hostDeadline-Date.now();if(remaining<=0) throw new Error('Hard host budget exhausted');return remaining;};
const adb=(...args)=>execFileSync('adb',args,{encoding:'utf8',timeout:Math.min(10000,hostRemaining())});
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const log=data=>fs.appendFileSync(`${out}/input-timings.jsonl`,JSON.stringify({time:Date.now(),hostMonoNs:process.hrtime.bigint().toString(),apk:env.ISSUE1864_APK,phase:env.ISSUE1864_PHASE,...data})+'\n');
adb('shell','mkdir','-p','/sdcard/issue1864-production');adb('shell','rm','-f',path);
const startedAt=Date.now(),deadline=startedAt+180000;
log({type:'recording',action:'start',name,stopMode:'whole-natural-expiry',requestedDuration:180,startedAt,observationsDeadline:deadline});
// Verbose retains the native time-limit branch receipt; it adds no display overlay.
const recorderStartedMonoNs=process.hrtime.bigint();
const recorder=spawn('adb',['shell','screenrecord','--verbose','--time-limit','180',path]);
let recorderError,exit,watchdog,recorderStdout='';
const finished=new Promise(resolve=>{
  recorder.once('error',error=>{recorderError=error;log({type:'recording',action:'spawn-error',message:error.message});});
  recorder.once('exit',(code,signal)=>{const monoNs=process.hrtime.bigint();exit={code,signal,time:Date.now(),hostMonoNs:monoNs.toString(),elapsedNs:(monoNs-recorderStartedMonoNs).toString()};log({type:'recording',action:'process-exit',...exit});});
  recorder.once('close',()=>{clearTimeout(watchdog);resolve();});
});
recorder.stdout.on('data',d=>{recorderStdout+=d.toString();fs.appendFileSync(`${out}/screenrecord-stdout.txt`,d);});recorder.stderr.on('data',d=>fs.appendFileSync(`${out}/screenrecord-stderr.txt`,d));
watchdog=setTimeout(()=>{recorderError=new Error('Recorder exceeded 210s watchdog');recorder.kill('SIGKILL');},210000);
let actionError,captureError,evidenceError,completeAt,duration,pulled=false,decoded=false,inventory;
try {
  await pause(900);if(recorderError || exit) throw recorderError ?? new Error('Recorder ended before actions');
  env.ISSUE1864_PRODUCTION_ACTIVE='true';env.ISSUE1864_OBSERVATION_DEADLINE=String(deadline);
  await import('./issue1864-production.mjs');completeAt=Date.now();log({type:'recording',action:'observations-complete',completeAt});
} catch(error) {actionError=error;log({type:'recording',action:'observations-error',message:error.message,stack:error.stack});}
finally {
  delete env.ISSUE1864_PRODUCTION_ACTIVE;delete env.ISSUE1864_OBSERVATION_DEADLINE;
  // Preserve natural expiry after failed actions too. Never restart or replay.
  await finished;clearTimeout(watchdog);
  captureError=recorderError;
  const limitSet=[...recorderStdout.matchAll(/^Time limit set to 180 seconds\r?$/gm)],limitReached=[...recorderStdout.matchAll(/^Time limit reached\r?$/gm)];
  const nativeExpiryObserved=limitSet.length===1 && limitReached.length===1 && limitSet[0].index<limitReached[0].index;
  const lifecycleAtLeastRequested=!!exit && BigInt(exit.elapsedNs)>=180000000000n;
  const naturalExpiry={schemaVersion:1,apk:env.ISSUE1864_APK,phase:env.ISSUE1864_PHASE,runId:env.GITHUB_RUN_ID,runAttempt:env.GITHUB_RUN_ATTEMPT,harnessSha:env.GITHUB_SHA,requestedDuration:180,recorderStartedMonoNs:recorderStartedMonoNs.toString(),processExit:exit ?? null,nativeLimitSetReceipts:limitSet.length,nativeLimitReachedReceipts:limitReached.length,nativeExpiryObserved,lifecycleAtLeastRequested,qualified:nativeExpiryObserved && lifecycleAtLeastRequested && !!exit && exit.code===0 && !exit.signal && !recorderError,
    boundary:'Native verbose time-limit branch plus at least180s host monotonic spawn-to-exit and clean exit/no watchdog. Host callback alone and encoded media span do not prove native expiry.'};
  naturalExpiry.status=naturalExpiry.qualified?'qualified':'unknown';
  try {fs.writeFileSync(`${out}/natural-expiry.json`,JSON.stringify(naturalExpiry,null,2));}
  catch(error) {captureError=captureError ?? error;}
  if(!captureError && !naturalExpiry.qualified) captureError=new Error('Natural180s recorder expiry unknown or incomplete: native expiry receipt, full monotonic lifecycle and clean exit are required');
  if(!captureError && (!exit || exit.code!==0 || exit.signal || !completeAt || completeAt>=deadline || completeAt>=exit.time)) captureError=new Error('Required action observations did not finish before host deadline and clean recorder exit');
  const originalCaptureError=captureError;
  for(let attempt=1;attempt<=3;attempt++) {
    try {
      if(attempt>1) await pause(1000);
      if(adb('get-state').trim()!=='device') throw new Error('Device unavailable for exact-file read');
      adb('shell','test','-s',path);adb('pull',path,raw);
      if(!fs.statSync(raw).size) throw new Error('Pulled raw recording empty');
      captureError=originalCaptureError;pulled=true;log({type:'recording',action:'pull-success',attempt,path,raw});break;
    } catch(error) {captureError=originalCaptureError ?? error;log({type:'recording',action:'pull-error',attempt,path,message:error.message,stderr:error.stderr?.toString()});}
  }
  if(pulled) {
    try {
      const probe=execFileSync('ffprobe',['-v','error','-show_format','-show_streams','-of','json',raw],{encoding:'utf8',timeout:Math.min(30000,hostRemaining())});fs.writeFileSync(`${out}/whole-phase-metadata.json`,probe);
      const metadata=JSON.parse(probe);duration=Number(metadata.format?.duration);
      if(!metadata.streams?.some(s=>s.codec_type==='video') || !Number.isFinite(duration)) throw new Error('Original capture has invalid video metadata');
    } catch(error) {evidenceError=error;log({type:'recording',action:'metadata-error',message:error.message,stderr:error.stderr?.toString()});}
    // A short encoded span does not skip independent full original-file decode.
    try {
      execFileSync('ffmpeg',['-v','error','-i',raw,'-f','null','-'],{timeout:Math.min(180000,hostRemaining())});log({type:'recording',action:'raw-decode-success'});
      decoded=true;
    } catch(error) {captureError=captureError ?? error;log({type:'recording',action:'decode-error',message:error.message,stderr:error.stderr?.toString()});}
    try {
      fs.writeFileSync(`${out}/ffprobe-version.txt`,execFileSync('ffprobe',['-version'],{encoding:'utf8',timeout:Math.min(10000,hostRemaining())}));
      for(const [kind,option] of [['packets','-show_packets'],['frames','-show_frames']]) {
        fs.writeFileSync(`${out}/whole-phase-${kind}.json`,execFileSync('ffprobe',['-v','error','-select_streams','v:0',option,'-of','json',raw],{encoding:'utf8',maxBuffer:64000000,timeout:Math.min(180000,hostRemaining())}));
      }
      inventory=recordingInventory(out);
    } catch(error) {evidenceError=evidenceError ?? error;log({type:'recording',action:'frame-inventory-error',message:error.message,stderr:error.stderr?.toString()});}
  }
  let coverage={automatedEvidenceComplete:false,errors:['Action evidence inventory unavailable']};
  try {coverage=actionInventory(out,env.ISSUE1864_APK,env.ISSUE1864_PHASE,inventory ?? {rawSha256:null});}
  catch(error) {evidenceError=evidenceError ?? error;log({type:'recording',action:'action-inventory-error',message:error.message});}
  if(!coverage.automatedEvidenceComplete) evidenceError=evidenceError ?? new Error(`Incomplete phase receipts: ${coverage.errors.join('; ')}`);
  fs.writeFileSync(`${out}/whole-phase-coverage.json`,JSON.stringify({schemaVersion:2,apk:env.ISSUE1864_APK,phase:env.ISSUE1864_PHASE,runId:env.GITHUB_RUN_ID,runAttempt:env.GITHUB_RUN_ATTEMPT,harnessSha:env.GITHUB_SHA,name,path,requestedDuration:180,stopMode:'whole-natural-expiry',naturalExpiry,startedAt,observationsDeadline:deadline,actionsCompleteAt:completeAt ?? null,processExit:exit ?? null,duration:duration ?? null,pulled,decoded,
    observationsBeforeDeadline:!!completeAt && completeAt<deadline,observationsBeforeExitCallback:!!completeAt && !!exit && completeAt<exit.time,fullDuration:Number.isFinite(duration) && duration>=178 && duration<=182,fullDurationBoundary:'Historical178–182s diagnostic only; future acceptance requires actual state/action visual coverage',
    automatedEvidenceComplete:coverage.automatedEvidenceComplete,eligibleForManualReview:!actionError && !captureError && !evidenceError && decoded && !!inventory,
    manualVisualQualification:'pending',preciseCorrelation:'uncertain',actionFailed:!!actionError,captureFailed:!!captureError,evidenceFailed:!!evidenceError,actionError:actionError?.message,captureError:captureError?.message,evidenceError:evidenceError?.message,
    timingBoundary:'Host order/latency is retained; native absolute alignment is supplementary. Raw duration/gaps/packet timestamps do not accept pixels, pre-Center focus or missing late states. All16 original episodes require independent visual review.'},null,2));
  log({type:'recording',action:'end',name,actionFailed:!!actionError,captureFailed:!!captureError});
}
// An original observation failure always remains the reported failure.
if(actionError) throw actionError;if(captureError) throw captureError;if(evidenceError) throw evidenceError;
