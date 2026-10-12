import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {randomUUID,createHash} from 'node:crypto';
import {existsSync,mkdirSync,readFileSync,readlinkSync,realpathSync,writeFileSync,renameSync,appendFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {format} from 'node:util';

export const runKey=`${process.env.GITHUB_RUN_ID||'unknown'}-${process.env.GITHUB_RUN_ATTEMPT||'1'}`;
assert(/^[A-Za-z0-9_-]+$/.test(runKey),'Unsafe Local management run identity');
export const paths={directory:`/tmp/issue1982-local-management-${runKey}`,rawDirectory:`/tmp/issue1982-local-raw-${runKey}`,ready:'evidence/local-supervisor-ready.json',state:'evidence/local-supervisor-state.json',cleanup:'evidence/local-process-cleanup.json'};
paths.request=join(paths.directory,'stop-request.json');
export const timestamp=()=>new Date().toISOString();
export const delay=ms=>new Promise(resolvePromise=>setTimeout(resolvePromise,ms));
export function redact(value){
 let text=String(value);
 const secrets=Object.entries(process.env).filter(([name,value])=>value&&/KEY|TOKEN|SECRET|PASSWORD|PASS|USERNAME/i.test(name)).map(([,value])=>value).sort((a,b)=>b.length-a.length);
 for(const secret of secrets){text=text.replaceAll(secret,'<REDACTED>');text=text.replaceAll(encodeURIComponent(secret),'<REDACTED>');}
 return text;
}
export function writeJson(path,value){
 const temporary=path+'.tmp-'+process.pid;
 writeFileSync(temporary,redact(JSON.stringify(value,null,2)),{mode:0o600});renameSync(temporary,path);
}
export function processIdentity(pid){
 assert(Number.isSafeInteger(pid)&&pid>1,'Invalid process PID');
 try{
  const raw=readFileSync(`/proc/${pid}/stat`,'utf8');
  const fields=raw.slice(raw.lastIndexOf(')')+2).trim().split(/\s+/);
  assert(fields.length>19&&/^\d+$/.test(fields[19]),'Malformed process start ticks');
  return {pid,name:raw.slice(raw.indexOf('(')+1,raw.lastIndexOf(')')),state:fields[0],parent:Number(fields[1]),startTicks:fields[19]};
 }catch(error){if(error.code==='ENOENT')return null;throw error;}
}
export function observeOwned(item){
 try{
  const current=processIdentity(item.pid);
  const status=!current?'absent':current.startTicks!==item.startTicks?'pid-reused':['Z','X'].includes(current.state)?'terminal':'running';
  return {owned:item,current,status,terminal:status==='absent'||status==='terminal',observedUtc:timestamp()};
 }catch(error){return {owned:item,status:'unavailable',terminal:false,error:redact(error),observedUtc:timestamp()};}
}
export function descendants(root){
 const found=[];
 const visit=item=>{
  if(found.some(existing=>existing.pid===item.pid&&existing.startTicks===item.startTicks))return;
  found.push(item);
  let childPids;
  try{childPids=readFileSync(`/proc/${item.pid}/task/${item.pid}/children`,'utf8').trim();}
  catch(error){if(error.code==='ENOENT')return;throw error;}
  for(const rawPid of childPids?childPids.split(/\s+/):[]){
   const child=processIdentity(Number(rawPid));
   if(child&&child.parent===item.pid)visit(child);
  }
 };
 visit(root);return found;
}
export function sanitizeRawLogs(){
 mkdirSync('evidence',{recursive:true});
 const receipt={completedUtc:timestamp(),inputs:[],unavailable:[],secretsReplaced:'Environment secret values and URL-encoded forms; values are not recorded'};
 let output='';
 for(const name of ['supervisor.log','binary.log']){
  const path=join(paths.rawDirectory,name);
  try{const raw=readFileSync(path,'utf8');output+=`\n--- ${name} (redacted) ---\n`+redact(raw);receipt.inputs.push({name,rawBytes:Buffer.byteLength(raw)});}
  catch(error){receipt.unavailable.push({name,error:redact(error)});}
 }
 writeFileSync('evidence/browserstack-local.log',output,{mode:0o600});
 writeJson('evidence/local-log-redaction.json',receipt);
 return receipt;
}

async function supervise(){
 mkdirSync('evidence',{recursive:true});mkdirSync(paths.directory,{recursive:true,mode:0o700});mkdirSync(paths.rawDirectory,{recursive:true,mode:0o700});
 // The maintained wrapper can print a complete execFile command containing
 // the access key. Keep its original console output outside artifacts.
 for(const method of ['log','error','warn','info','debug'])console[method]=(...values)=>appendFileSync(join(paths.rawDirectory,'supervisor.log'),format(...values)+'\n',{mode:0o600});
 const require=createRequire('/tmp/bs-local/package.json');
 const library=require('browserstack-local');
 const packagePath=require.resolve('browserstack-local/package.json');
 const packageJson=JSON.parse(readFileSync(packagePath,'utf8'));
 assert.equal(packageJson.version,'1.5.16','Local wrapper must be the reviewed maintained version');
 const local=new library.Local();
 const manager=processIdentity(process.pid);
 const managementId=randomUUID();
 const jobStartedMs=Number(process.env.ISSUE1982_JOB_STARTED_MS);
 assert(Number.isFinite(jobStartedMs)&&jobStartedMs>0,'Missing original job start clock');
 const cleanupBoundaryMs=jobStartedMs+35*60*1000;
 let daemon=null,daemonQualified=false,owned=[],firstFailure=null,startCallbacks=[],stopCallbacks=[],stopping=false,stopFinished=false,requestSeen=null;
 const startedMs=Date.now();
 const startupDeadlineMs=Math.min(startedMs+120000,cleanupBoundaryMs);
 let startupExpired=false,inflightLauncher=null;
 const state=()=>({managementId,manager,daemon,daemonQualified,owned,jobStartedMs,cleanupBoundaryMs,startupDeadlineMs,startupExpired,inflightLauncher,startedUtc:new Date(startedMs).toISOString(),observedUtc:timestamp(),wrapperVersion:packageJson.version,wrapperIsRunning:Boolean(local.isRunning()),daemonObservation:daemon?observeOwned(daemon):null,firstFailure,startCallbacks,stopCallbacks,stopping,stopFinished,requestSeen});
 const persist=()=>writeJson(paths.state,state());
 function fail(error){if(!firstFailure)firstFailure={utc:timestamp(),error:redact(error)};persist();}
 async function expireUnqualifiedStartup(reason){
  if(startupExpired||stopping)return;
  startupExpired=true;stopping=true;fail(reason);clearInterval(timer);
  const receipt={managementId,manager,qualified:false,firstFailure,supportedStopInvoked:false,reason,startupExpired:true,inflightLauncher,signals:[],uncertainDaemonOwnership:true};
  // Local.start uses execFile(binaryPath, --daemon start). Its launcher can
  // outlive a missing callback. Capture only that actual child and executable;
  // never infer a detached daemon PID from management ancestry.
  if(inflightLauncher){
   const before=observeOwned(inflightLauncher);receipt.launcherBefore=before;
   if(before.status==='running'){
    try{
     assert.equal(readlinkSync(`/proc/${inflightLauncher.pid}/exe`),realpathSync(local.binaryPath),'Inflight launcher executable changed; refuse signal');
     assert.equal(observeOwned(inflightLauncher).status,'running','Inflight launcher identity changed; refuse signal');
     process.kill(inflightLauncher.pid,'SIGTERM');receipt.signals.push({pid:inflightLauncher.pid,startTicks:inflightLauncher.startTicks,signal:'SIGTERM',utc:timestamp()});
     const end=Date.now()+3000;
     while(Date.now()<end&&!observeOwned(inflightLauncher).terminal)await delay(100);
    }catch(error){receipt.launcherStopError=redact(error);}
   }
   receipt.launcherFinal=observeOwned(inflightLauncher);
  }
  if(daemonQualified){
   // A connected callback can settle while the launcher grace is observed.
   // It has captured its exact executable/PID identity; stop that same Local
   // object instead of exiting and stranding a newly known daemon.
   stopping=false;await stop('connected-during-startup-expiry');return;
  }
  receipt.completedUtc=timestamp();writeJson(paths.cleanup,receipt);persist();
  // No qualified daemon or supported stop claim. Exit cancels future wrapper
  // callbacks in this process; unknown detached processes remain unqualified.
  process.exit(1);
 }
 async function stop(reason){
  if(stopping)return;
  stopping=true;
  const report={managementId,manager,reason,requestedUtc:timestamp(),firstFailure,supportedStopInvoked:false,callbackObservations:stopCallbacks,qualified:false,ownedBeforeStop:owned,final:[]};
  try{
   assert(daemon&&daemonQualified,'No source/executable-validated connected daemon identity; cleanup is unqualified and no stop signal is safe');
   const daemonBefore=observeOwned(daemon);
   assert(!['pid-reused','unavailable'].includes(daemonBefore.status),'Daemon PID identity unavailable/reused; refuse supported stop');
   if(daemonBefore.status==='running'){
    const newlyObserved=descendants(daemonBefore.current);
    for(const item of newlyObserved){if(!owned.some(saved=>saved.pid===item.pid&&saved.startTicks===item.startTicks))owned.push(item);}
   }
   report.ownedBeforeStop=owned;
   report.before=owned.map(observeOwned);
   assert(report.before.every(item=>!['pid-reused','unavailable'].includes(item.status)),'Owned daemon/descendant identity unavailable/reused; refuse stop');
   assert.equal(local.pid,daemon.pid,'Maintained Local object changed its connected daemon PID');
   // isRunning alone uses kill(0) and a cached flag. The /proc receipt above
   // supplies actual PID/start identity, even after daemon reparenting.
   const immediatelyBefore=observeOwned(daemon);
   assert(!['pid-reused','unavailable'].includes(immediatelyBefore.status),'Daemon identity changed before stop; refuse signaling');
   report.supportedStopInvoked=true;report.stopCallUtc=timestamp();
   local.stop(error=>{
    // 1.5.16 invokes callback(error) and then callback() on tree-kill errors.
    // Keep both calls and retain the first error rather than resolving early.
    stopCallbacks.push({utc:timestamp(),call:stopCallbacks.length+1,error:error?redact(error):null});
    if(stopFinished){
     report.callbackObservations=stopCallbacks;report.callbackCount=stopCallbacks.length;
     report.firstCallbackError=stopCallbacks.find(item=>item.error)?.error??null;
     report.final=owned.map(observeOwned);
     report.qualified=!report.firstCallbackError&&report.final.every(item=>item.terminal);
     writeJson(paths.cleanup,{...report,phase:'late-supported-stop-callback'});
    }else writeJson(paths.cleanup,{...report,callbackObservations:stopCallbacks,qualified:false,phase:'awaiting-independent-terminal-proof'});
   });
   const deadline=Date.now()+20000;
   do{
    report.final=owned.map(observeOwned);
    if(stopCallbacks.length>0&&report.final.every(item=>item.terminal)){
     // Let the same callback stack and a short bounded observation settle.
     await delay(250);report.final=owned.map(observeOwned);break;
    }
    await delay(100);
   }while(Date.now()<deadline);
   report.callbackObservations=stopCallbacks;
   report.callbackCount=stopCallbacks.length;
   report.firstCallbackError=stopCallbacks.find(item=>item.error)?.error??null;
   report.wrapperIsRunningAfter=Boolean(local.isRunning());
   report.qualified=stopCallbacks.length>0&&!report.firstCallbackError&&report.final.every(item=>item.terminal);
   if(!report.qualified)report.cleanupError='Supported stop callback and independently terminal owned daemon/descendants did not all qualify';
  }catch(error){report.cleanupError=redact(error);report.final=owned.map(observeOwned);}
  report.completedUtc=timestamp();report.firstFailure=firstFailure;
  stopFinished=true;writeJson(paths.cleanup,report);persist();
  clearInterval(timer);process.exitCode=report.qualified&&!firstFailure?0:1;
 }
 const timer=setInterval(()=>{
  try{
   persist();
   if(!daemonQualified&&local.tunnel?.pid&&!inflightLauncher){
    const candidate=processIdentity(Number(local.tunnel.pid));
    if(candidate&&candidate.parent===process.pid&&readlinkSync(`/proc/${candidate.pid}/exe`)===realpathSync(local.binaryPath))inflightLauncher=candidate;
   }
   if(existsSync(paths.request)&&!requestSeen){
    const request=JSON.parse(readFileSync(paths.request,'utf8'));
    assert.equal(request.managementId,managementId,'Stop request belongs to another manager');
    requestSeen={...request,observedUtc:timestamp()};
    if(daemon)void stop('owned-cleanup-client-request');
   }
   if(requestSeen&&daemon&&!stopping)void stop('owned-cleanup-client-request-after-start');
   if(!daemonQualified&&Date.now()>=startupDeadlineMs&&!stopping)void expireUnqualifiedStartup('Local startup exceeded original bounded setup deadline');
   if(Date.now()>=cleanupBoundaryMs&&!stopping){
    if(daemonQualified){fail('Original job 35-minute cleanup boundary reached');void stop('job-cleanup-boundary');}
    else void expireUnqualifiedStartup('Original job cleanup boundary reached before daemon qualification');
   }
  }catch(error){fail(error);void stop('management-observation-error');}
 },250);
 process.on('SIGTERM',()=>{requestSeen={reason:'manager-SIGTERM',observedUtc:timestamp()};if(daemon)void stop('manager-SIGTERM');});
 process.on('SIGINT',()=>{requestSeen={reason:'manager-SIGINT',observedUtc:timestamp()};if(daemon)void stop('manager-SIGINT');});
 persist();
 try{
  local.start({key:process.env.BROWSERSTACK_ACCESS_KEY,localIdentifier:process.env.BS_LOCAL_ID,forceLocal:true,onlyAutomate:true,logFile:join(paths.rawDirectory,'binary.log')},error=>{
   startCallbacks.push({utc:timestamp(),call:startCallbacks.length+1,error:error?redact(error):null});
   if(error){fail(error);void stop('supported-start-callback-error');return;}
   try{
    assert(startCallbacks.length===1,'Unexpected repeated Local start callback');
    const pid=Number(local.pid);
    daemon=processIdentity(pid);
    assert(daemon&&!['Z','X'].includes(daemon.state),'Connected daemon PID is not running');
    assert.equal(Boolean(local.isRunning()),true,'Maintained Local isRunning did not qualify');
    const binaryPath=realpathSync(local.binaryPath);
    const executable=readlinkSync(`/proc/${pid}/exe`);
    assert.equal(executable,binaryPath,'Connected daemon executable differs from the maintained wrapper binary');
    daemonQualified=true;
    owned=descendants(daemon);
    if(requestSeen||startupExpired||Date.now()>=startupDeadlineMs||Date.now()>=cleanupBoundaryMs){
     fail('Connected callback arrived after original startup/cleanup deadline');
     void stop('late-connected-callback-supported-stop');return;
    }
    const ready={...state(),connectedDaemonPidSource:'browserstack-local 1.5.16 Local.start connected JSON local.pid',binaryPath,executable,binarySha256:createHash('sha256').update(readFileSync(binaryPath)).digest('hex'),librarySourceSha256:createHash('sha256').update(readFileSync(join(resolve(packagePath,'..'),'lib/Local.js'))).digest('hex'),readyUtc:timestamp()};
    assert(ready.owned.every(item=>observeOwned(item).status==='running'),'Daemon readiness process identity changed');
    writeJson(paths.ready,ready);
    mkdirSync('/tmp/helper',{recursive:true});writeFileSync('/tmp/helper/local-ready','Source-validated daemon PID/start ticks and maintained isRunning qualified\n');
    persist();
    if(requestSeen)void stop('owned-cleanup-client-request-after-start');
   }catch(startError){fail(startError);void stop('daemon-readiness-identity-failure');}
  });
 }catch(error){fail(error);await stop('supported-start-threw');}
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{await supervise();}catch(error){
  mkdirSync('evidence',{recursive:true});writeJson(paths.cleanup,{qualified:false,firstFailure:redact(error),cleanupError:'Management initialization failed; no owned supported stop established',completedUtc:timestamp()});process.exitCode=1;
 }
}
