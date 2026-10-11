// Diagnostic only: one uninterrupted natural-expiry recording per traced variant.
import {execFileSync, spawn} from 'node:child_process';
import fs from 'node:fs';
const out='evidence-cloud', name='whole-variant';
const path=`/sdcard/issue1864-recordings/${name}.mp4`;
const adb=(...args)=>execFileSync('adb',args,{encoding:'utf8',timeout:30000});
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const log=data=>fs.appendFileSync(`${out}/input-timings.jsonl`,JSON.stringify({time:Date.now(),...data})+'\n');
if(process.env.ISSUE1864_RECORDING_STOP!=='whole' || process.env.ISSUE1864_PHASE!=='paired-core'
  || process.env.ISSUE1864_TRACE!=='true' || !['source-baseline','source-focus'].includes(process.env.ISSUE1864_APK)) {
  throw new Error('Whole recording requires a traced paired-core source variant');
}
fs.mkdirSync(out,{recursive:true});
fs.writeFileSync(`${out}/whole-recording-provenance.txt`,
  'One uninterrupted 180-second natural-expiry recording replaces per-case recordings. Existing observations and inputs run once; segment timings identify each case. No actions or sessions are replayed.\n');
adb('shell','mkdir','-p','/sdcard/issue1864-recordings');
adb('shell','rm','-f',path);
const requestedDuration=180, durationTolerance={min:178,max:182};
const startedAt=Date.now(), observationsDeadline=startedAt+requestedDuration*1000;
log({type:'recording',action:'start',name,stopMode:'whole-natural-expiry',requestedDuration,startedAt,observationsDeadline});
const recorder=spawn('adb',['shell','screenrecord','--time-limit','180',path]);
let recorderError, recorderExit;
const finished=new Promise(resolve=>{
  recorder.once('error',error=>{
    recorderError=error;
    log({type:'recording',action:'spawn-error',name,message:error.message});
  });
  recorder.once('exit',(code,signal)=>{
    recorderExit={code,signal,time:Date.now()};
    log({type:'recording',action:'process-exit',name,...recorderExit});
  });
  recorder.once('close',()=>{ clearTimeout(watchdog); resolve(); });
});
recorder.stdout.on('data',data=>fs.appendFileSync(`${out}/${name}-screenrecord-stdout.log`,data));
recorder.stderr.on('data',data=>fs.appendFileSync(`${out}/${name}-screenrecord.log`,data));
const watchdog=setTimeout(()=>{
  recorderError=new Error('Whole recorder did not exit within 210 seconds');
  log({type:'recording',action:'timeout',name,message:recorderError.message});
  recorder.kill('SIGKILL');
},210000);
let actionError, captureError, actionsCompleteAt, duration;
try {
  await pause(900);
  if(recorderError || recorderExit) throw recorderError ?? new Error('Whole recorder exited before observations started');
  process.env.ISSUE1864_WHOLE_ACTIVE='true';
  await import('./issue1864-tv.mjs');
  actionsCompleteAt=Date.now();
  log({type:'recording',action:'observations-complete',name,actionsCompleteAt});
} catch(error) {
  actionError=error;
  log({type:'recording',action:'observations-error',name,message:error.message});
} finally {
  delete process.env.ISSUE1864_WHOLE_ACTIVE;
  // Never stop between cases, restart a recorder, recreate a session, or replay input.
  await finished;
  clearTimeout(watchdog);
  captureError=recorderError;
  if(!captureError && (!recorderExit || recorderExit.code!==0 || !actionsCompleteAt
    || actionsCompleteAt>=observationsDeadline || actionsCompleteAt>=recorderExit.time)) {
    captureError=new Error('Whole recording ended before all observations completed or exited uncleanly');
  }
  const recordingError=captureError;
  for(let attempt=1;attempt<=3;attempt++) {
    try {
      if(attempt>1) {
        await pause(1000);
        if(adb('get-state').trim()!=='device') throw new Error('ADB is not online');
        adb('shell','test','-s',path);
      }
      adb('pull',path,`${out}/${name}.mp4`);
      if(fs.statSync(`${out}/${name}.mp4`).size===0) throw new Error('Whole recording is empty');
      captureError=recordingError;
      log({type:'recording',action:'pull-success',name,attempt});
      break;
    } catch(error) {
      captureError=error;
      log({type:'recording',action:'pull-error',name,attempt,status:error.status,message:error.message,
        stdout:error.stdout?.toString(),stderr:error.stderr?.toString()});
    }
  }
  try {
    const probe=execFileSync('ffprobe',['-v','error','-show_format','-show_streams','-of','json',`${out}/${name}.mp4`],
      {encoding:'utf8',timeout:30000});
    fs.writeFileSync(`${out}/${name}-metadata.json`,probe);
    const metadata=JSON.parse(probe);
    duration=Number(metadata.format?.duration);
    if(!metadata.streams?.some(stream=>stream.codec_type==='video') || !Number.isFinite(duration)
      || duration<durationTolerance.min || duration>durationTolerance.max) {
      throw new Error('Whole recording must contain video covering the full natural duration (178–182 seconds)');
    }
    execFileSync('ffmpeg',['-v','error','-i',`${out}/${name}.mp4`,'-f','null','-'],{timeout:180000});
    log({type:'recording',action:'decode-success',name});
  } catch(error) {
    captureError=captureError ?? error;
    log({type:'recording',action:'decode-error',name,message:error.message,stderr:error.stderr?.toString()});
  }
  fs.writeFileSync(`${out}/${name}-coverage.json`,JSON.stringify({
    requestedDuration,startedAt,observationsDeadline,actionsCompleteAt:actionsCompleteAt ?? null,
    processExit:recorderExit ?? null,duration:Number.isFinite(duration) ? duration : null,durationTolerance,
    observationsBeforeDeadline:!!actionsCompleteAt && actionsCompleteAt<observationsDeadline,
    observationsBeforeExitCallback:!!actionsCompleteAt && !!recorderExit && actionsCompleteAt<recorderExit.time,
    fullDuration:Number.isFinite(duration) && duration>=durationTolerance.min && duration<=durationTolerance.max,
    actionFailed:!!actionError,captureFailed:!!captureError,
    timingBoundary:'Host exit callback time is observed after event-loop delivery; it is not the actual guest expiry time. Completion also requires the independent host start-time deadline and full-duration metadata.',
  },null,2));
  log({type:'recording',action:'end',name,startedAt,actionsCompleteAt,actionFailed:!!actionError,captureFailed:!!captureError});
}
if(actionError) throw actionError;
if(captureError) throw captureError;
