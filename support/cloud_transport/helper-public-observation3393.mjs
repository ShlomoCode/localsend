import {writeFileSync} from 'node:fs';

const maximumWaitMs=18000; // Existing 15 s renewal plus 3 s bounded transport margin.
const component='org.localsend.cloudtransport/org.localsend.cloudtransport.RelayService';
let helperIdentity;
let identityBaselineMs;
const monotonic=()=>Number(process.hrtime.bigint())/1e6;
const identity=s=>JSON.stringify({pid:s.pid,uid:s.uid,processNonce:s.processNonce,serviceActiveSinceMs:s.service.activeSinceMs});

function qualify(s,{expectedMode,expectBackground}) {
 if(s.serviceMatches!==1||s.service.component!==component||s.service.pid!==s.pid||s.service.uid!==s.uid||s.memoryState.pid!==s.pid||s.memoryState.uid!==s.uid)throw new Error('Public helper service/process identity is missing or inconsistent');
 const foreground=expectedMode==='foreground';
 if(s.serviceMode!==expectedMode||!s.service.started||!s.service.startedFlag||!(s.service.flags&1)||s.service.foreground!==foreground||s.service.foregroundFlag!==foreground||!!(s.service.flags&2)!==foreground)throw new Error('Public helper service mode/start/foreground flags disagree');
 if(!s.activityStable||JSON.stringify(s.activityBefore)!==JSON.stringify(s.activity))return false;
 if(s.activity.elapsedNs>s.sampleEndNs||s.sampleEndNs>s.emittedElapsedNs)throw new Error('Public helper sample chronology is inconsistent');
 if(expectBackground){
  if(s.activity.started!==0||s.activity.resumed!==0||s.importance<300)return false;
 }else if(s.activity.started<1||s.activity.resumed<1||s.importance>100)return false;
 return true;
}

// This supplementary observer performs no device RPC, poll or socket operation.
// Receipt is before the current pull response; a later sample proves advancement.
export async function observeHelper({label,transportSnapshot,expectBackground=true,expectedMode='ordinary',exposureInterval}) {
 if(!['ordinary','foreground'].includes(expectedMode))throw new Error('Unsupported expected helper service mode');
 if(typeof label!=='string'||! /^[a-zA-Z0-9_-]+$/.test(label))throw new Error('Invalid public-observation evidence label');
 const startedMs=monotonic(),deadline=startedMs+maximumWaitMs;
 if(identityBaselineMs===undefined)identityBaselineMs=startedMs;
 const record={schema:1,started:new Date().toISOString(),observerStartMonotonicMs:startedMs,maximumWaitMs,freshnessReason:'15 s existing pull renewal plus 3 s bounded network margin',expectedMode,expectBackground,exposureInterval:exposureInterval||null,freezeState:'unknown',nativeCurProcState:'unavailable',evidenceLevel:'supplementary own-app public framework samples',transportHealthRequiresIndependentTraceReview:true,sampleDoesNotProveCurrentPullCompleted:true,observations:[]};
 const save=()=>writeFileSync(`evidence/${label}-public-helper.json`,JSON.stringify(record,null,2));
 let interval;
 if(exposureInterval){
  interval={started:Date.parse(exposureInterval.started),ended:Date.parse(exposureInterval.ended)};
  if(!Number.isFinite(interval.started)||!Number.isFinite(interval.ended)||interval.ended<interval.started)throw new Error('Invalid helper exposure interval');
 }
 const seen=new Set();
 try{
  record.transportBefore=transportSnapshot();save();
  while(monotonic()<deadline){
   const snapshot=transportSnapshot();record.transportAfter=snapshot;
   if(!Array.isArray(snapshot.trace))throw new Error('Public helper relay trace unavailable');
   if(snapshot.trace.some(e=>e.origin==='public-observation-error'))throw new Error('Public helper observation header rejected by receiver');
   // Control-service replacement before the first baseline is intentional.
   // Preserve its trace but only enforce identity stability from this baseline.
   const samples=snapshot.trace.filter(e=>e.origin==='public-observation'&&e.runnerMonotonicMs>=identityBaselineMs);
   let previous;
   for(const e of samples){
    const s=e.observation;
    if(!s||!Number.isFinite(e.runnerMonotonicMs)||!Number.isFinite(Date.parse(e.utc)))throw new Error('Public helper receipt metadata unavailable');
    const current=identity(s);
    if(helperIdentity&&helperIdentity!==current)throw new Error('Public helper restarted or identity changed');
    if(previous&&(identity(previous.observation)!==current||s.sequence<=previous.observation.sequence||s.sampleStartNs<=previous.observation.sampleEndNs||s.emittedElapsedNs<=previous.observation.emittedElapsedNs))throw new Error('Public helper sequence/monotonic sample did not advance');
    const admitted=qualify(s,{expectedMode,expectBackground});
    if(!seen.has(s.sequence)){seen.add(s.sequence);record.observations.push({sequence:s.sequence,receivedUtc:e.utc,receivedMonotonicMs:e.runnerMonotonicMs,modeAdmitted:admitted,sampleDurationMs:(s.sampleEndNs-s.sampleStartNs)/1e6,sampleToEmissionMs:(s.emittedElapsedNs-s.sampleStartNs)/1e6,clockDomains:'device monotonic and runner monotonic are not synchronized; emission-to-receipt latency unavailable'});}
    previous=e;
   }
   // Require the prior sequential pull's successful server finish after observer
   // start, followed by a later sample. This rejects old in-flight observations.
   const fresh=samples.find(e=>qualify(e.observation,{expectedMode,expectBackground})&&e.runnerMonotonicMs>=startedMs&&e.runnerMonotonicMs<=deadline&&snapshot.trace.some(p=>p.origin==='poll-response'&&p.processNonce===e.observation.processNonce&&p.observationSequence===e.observation.sequence-1&&p.runnerMonotonicMs>=startedMs&&p.runnerMonotonicMs<e.runnerMonotonicMs));
   const exposureBoundary=e=>snapshot.trace.find(p=>p.origin==='poll-response'&&p.processNonce===e.observation.processNonce&&p.observationSequence===e.observation.sequence-1&&Date.parse(p.utc)>=interval.started&&Date.parse(p.utc)<Date.parse(e.utc)&&p.runnerMonotonicMs<e.runnerMonotonicMs);
   const exposed=interval?samples.find(e=>Date.parse(e.utc)>=interval.started&&Date.parse(e.utc)<=interval.ended&&qualify(e.observation,{expectedMode,expectBackground})&&exposureBoundary(e)):null;
   if(fresh&&(!interval||exposed)){
    helperIdentity=identity(fresh.observation);
    record.qualified=true;record.acceptedSample=fresh;record.exposureSample=exposed;record.exposureBoundary=exposed?exposureBoundary(exposed):null;
    record.freshnessBoundary=snapshot.trace.find(p=>p.origin==='poll-response'&&p.processNonce===fresh.observation.processNonce&&p.observationSequence===fresh.observation.sequence-1&&p.runnerMonotonicMs>=startedMs&&p.runnerMonotonicMs<fresh.runnerMonotonicMs);
    record.receiptAgeAtAdmissionMs=monotonic()-fresh.runnerMonotonicMs;
    if(record.receiptAgeAtAdmissionMs>maximumWaitMs)throw new Error('Public helper sample exceeded freshness threshold');
    return record;
   }
   save();await new Promise(resolve=>setTimeout(resolve,Math.min(100,Math.max(0,deadline-monotonic()))));
  }
  throw new Error(interval?'No fresh qualified public helper sample and in-exposure receipt within 18 s':'No fresh qualified public helper sample within 18 s');
 }catch(error){record.qualified=false;record.error=String(error);throw error;}
 finally{record.ended=new Date().toISOString();record.observerWaitMs=monotonic()-startedMs;save();}
}
