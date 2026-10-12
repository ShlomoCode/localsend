import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {existsSync,readFileSync} from 'node:fs';
import {paths,timestamp,delay,observeOwned,writeJson,sanitizeRawLogs} from './local-supervisor.mjs';

const mode=process.argv[2]||'stop';
assert(['stop','record','check'].includes(mode),'Unknown owned Local cleanup mode');
const client={requestedUtc:timestamp(),mode,qualified:false,managementProof:null,daemonProof:null,cleanupReceipt:null,final:[],error:null};
const save=()=>writeJson('evidence/local-cleanup-client.json',client);

try{
 const path=existsSync(paths.ready)?paths.ready:paths.state;
 assert(existsSync(path),'Missing manager/connected-daemon receipt; cleanup is unqualified');
 const receipt=JSON.parse(readFileSync(path,'utf8'));
 assert(receipt.managementId&&receipt.manager,'Missing exact management identity receipt');
 const manager=observeOwned(receipt.manager);
 client.managementProof=manager;
 assert.equal(manager.status,'running','Original management process lost, terminal, reused, or unavailable; no same-object supported stop can be established');
 const currentState=JSON.parse(readFileSync(paths.state,'utf8'));
 assert.equal(currentState.managementId,receipt.managementId,'Current manager receipt identity changed');
 assert.equal(currentState.manager.startTicks,receipt.manager.startTicks,'Current manager process receipt changed');
 assert(Date.now()-Date.parse(currentState.observedUtc)<=5000,'Management state is stale; cleanup is unqualified');
 if(mode!=='stop'){
  assert.equal(currentState.daemonQualified,true,'Connected daemon qualification is missing');
  assert(!currentState.stopping&&!currentState.stopFinished&&!currentState.requestSeen&&!currentState.firstFailure&&!currentState.startupExpired,'Local management is stopping, failed, or expired; do not admit a device');
  assert(!existsSync(paths.request),'Owned stop was requested; do not admit a device');
  assert(Number.isFinite(currentState.cleanupBoundaryMs)&&Date.now()<currentState.cleanupBoundaryMs,'Original cleanup boundary has been reached');
  assert(existsSync(paths.ready),'Connected Local daemon readiness receipt is missing');
  assert(receipt.daemon,'Daemon PID/start identity receipt is missing');
  client.daemonProof=observeOwned(receipt.daemon);
  assert.equal(client.daemonProof.status,'running','Connected Local daemon identity/liveness failed');
  assert.equal(currentState.wrapperIsRunning,true,'Maintained Local isRunning is false');
  assert.equal(currentState.daemon.pid,receipt.daemon.pid,'Maintained Local daemon PID changed');
  assert.equal(currentState.daemon.startTicks,receipt.daemon.startTicks,'Maintained Local daemon start ticks changed');
  client.final=receipt.owned.map(observeOwned);
  assert(client.final.every(item=>item.status==='running'),'Readiness descendant identity changed');
  client.qualified=true;client.completedUtc=timestamp();save();
 }else{
  // The management process may still be waiting for Local.start. Request stop
  // from the same retained object; no signals or guessed daemon ancestry.
  const request={managementId:receipt.managementId,requestId:randomUUID(),requestedUtc:timestamp(),manager:receipt.manager};
  client.request=request;save();writeJson(paths.request,request);
  const end=Date.now()+25000;
  let stopped=null;
  while(Date.now()<end){
   if(existsSync(paths.cleanup)){
    const candidate=JSON.parse(readFileSync(paths.cleanup,'utf8'));
    if(candidate.managementId===receipt.managementId&&candidate.completedUtc){stopped=candidate;break;}
   }
   const currentManager=observeOwned(receipt.manager);
   client.lastManagerObservation=currentManager;
   // A terminal manager can leave its completed receipt just before exit.
   if(currentManager.status==='pid-reused'||currentManager.status==='unavailable')throw new Error('Management process identity changed during stop; no fallback signaling');
   await delay(100);
  }
  assert(stopped,'Same-object supported stop produced no completed receipt within 25 seconds');
  client.cleanupReceipt=stopped;
  assert.equal(stopped.supportedStopInvoked,true,'Maintained Local.stop invocation was not established');
  assert.equal(stopped.manager.startTicks,receipt.manager.startTicks,'Stop receipt came from a different manager process');
  assert.equal(stopped.manager.pid,receipt.manager.pid,'Stop receipt manager PID differs');
  assert(Array.isArray(stopped.ownedBeforeStop)&&stopped.ownedBeforeStop.length>0,'Missing connected daemon/descendant ownership receipts');
  client.final=stopped.ownedBeforeStop.map(observeOwned);
  assert(client.final.every(item=>item.terminal),'Actual owned daemon/descendants remain alive, unavailable, or reused after stop');
  assert.equal(stopped.qualified,true,'Supported stop callback/terminal proof was unqualified; preserve callback errors and counts');
  const managerEnd=Date.now()+Math.max(0,end-Date.now());
  while(Date.now()<managerEnd&&observeOwned(receipt.manager).status==='running')await delay(100);
  client.managementAfter=observeOwned(receipt.manager);
  assert(client.managementAfter.terminal,'Local manager did not finish after completed supported stop');
  client.qualified=true;client.completedUtc=timestamp();save();
 }
}catch(error){
 client.error=String(error);client.completedUtc=timestamp();save();
 // Preserve an existing supervisor receipt, especially its first fault and
 // callback count. Missing/lost manager establishes no cleanup success.
 if(!existsSync(paths.cleanup))writeJson(paths.cleanup,{qualified:false,firstFailure:client.error,cleanupError:'Cleanup client could not establish same-object supported stop and terminal proof',completedUtc:timestamp()});
 process.exitCode=1;
}finally{
 if(mode==='stop'){
  try{client.logRedaction=sanitizeRawLogs();}
  catch(error){client.logRedactionError=String(error);client.qualified=false;process.exitCode=1;}
  save();
 }
}
