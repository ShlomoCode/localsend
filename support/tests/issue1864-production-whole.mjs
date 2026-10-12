// One natural 180s cloud capture per clean-APK phase. No action/session recovery.
import {execFileSync,spawn} from 'node:child_process';
import fs from 'node:fs';
const env=process.env,out=env.ISSUE1864_EVIDENCE_DIR;
const hostDeadline=Number(env.ISSUE1864_HOST_DEADLINE_EPOCH_MS);
if(!Number.isFinite(hostDeadline) || hostDeadline-Date.now()<600000) throw new Error('Insufficient independent job budget for full natural capture and evidence finalization');
if(!out || !['production-base','production-candidate'].includes(env.ISSUE1864_APK) || !['core','permission-denial-grant','picker-cancel','pointer-count','folders','mixed','theme-light','theme-dark'].includes(env.ISSUE1864_PHASE)) throw new Error('Explicit clean APK identity, phase and output required');
fs.mkdirSync(out,{recursive:true});
const name=`${env.ISSUE1864_APK}-${env.ISSUE1864_PHASE}`,path=`/sdcard/issue1864-production/${name}.mp4`,raw=`${out}/whole-phase.mp4`;
const hostRemaining=()=>{const remaining=hostDeadline-Date.now();if(remaining<=0) throw new Error('Hard host budget exhausted');return remaining;};
const adb=(...args)=>execFileSync('adb',args,{encoding:'utf8',timeout:Math.min(10000,hostRemaining())});
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const log=data=>fs.appendFileSync(`${out}/input-timings.jsonl`,JSON.stringify({time:Date.now(),...data})+'\n');
adb('shell','mkdir','-p','/sdcard/issue1864-production');adb('shell','rm','-f',path);
const startedAt=Date.now(),deadline=startedAt+180000;
log({type:'recording',action:'start',name,stopMode:'whole-natural-expiry',requestedDuration:180,startedAt,observationsDeadline:deadline});
const recorder=spawn('adb',['shell','screenrecord','--time-limit','180',path]);
let recorderError,exit,watchdog;
const finished=new Promise(resolve=>{
  recorder.once('error',error=>{recorderError=error;log({type:'recording',action:'spawn-error',message:error.message});});
  recorder.once('exit',(code,signal)=>{exit={code,signal,time:Date.now()};log({type:'recording',action:'process-exit',...exit});});
  recorder.once('close',()=>{clearTimeout(watchdog);resolve();});
});
recorder.stdout.on('data',d=>fs.appendFileSync(`${out}/screenrecord-stdout.txt`,d));recorder.stderr.on('data',d=>fs.appendFileSync(`${out}/screenrecord-stderr.txt`,d));
watchdog=setTimeout(()=>{recorderError=new Error('Recorder exceeded 210s watchdog');recorder.kill('SIGKILL');},210000);
let actionError,captureError,completeAt,duration,pulled=false;
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
  if(!captureError && (!exit || exit.code!==0 || !completeAt || completeAt>=deadline || completeAt>=exit.time)) captureError=new Error('Required action observations did not finish before host deadline and clean recorder exit');
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
      if(!metadata.streams?.some(s=>s.codec_type==='video') || !Number.isFinite(duration) || duration<178 || duration>182) throw new Error('Raw capture must contain 178–182s of video');
      execFileSync('ffmpeg',['-v','error','-i',raw,'-f','null','-'],{timeout:Math.min(180000,hostRemaining())});log({type:'recording',action:'raw-decode-success'});
    } catch(error) {captureError=captureError ?? error;log({type:'recording',action:'decode-error',message:error.message,stderr:error.stderr?.toString()});}
  }
  fs.writeFileSync(`${out}/whole-phase-coverage.json`,JSON.stringify({name,path,requestedDuration:180,startedAt,observationsDeadline:deadline,actionsCompleteAt:completeAt ?? null,processExit:exit ?? null,duration:duration ?? null,pulled,observationsBeforeDeadline:!!completeAt && completeAt<deadline,observationsBeforeExitCallback:!!completeAt && !!exit && completeAt<exit.time,fullDuration:Number.isFinite(duration) && duration>=178 && duration<=182,actionFailed:!!actionError,captureFailed:!!captureError,actionError:actionError?.message,captureError:captureError?.message,timingBoundary:'Host exit callback is delivery time, not guest expiry. Independent host deadline, complete raw duration and decode are also mandatory.'},null,2));
  log({type:'recording',action:'end',name,actionFailed:!!actionError,captureFailed:!!captureError});
}
// An original observation failure always remains the reported failure.
if(actionError) throw actionError;if(captureError) throw captureError;
