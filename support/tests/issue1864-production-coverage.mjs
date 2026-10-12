// Read-only evidence inventory. Pixel/sequence acceptance remains independent manual review.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const phases=['permission-denial-grant','core','picker-cancel','pointer-count','folders','theme-light','theme-dark','mixed'];
export const variants=['production-base','production-candidate'];
const entry=name=>[`${name}-send-before`,`${name}-media-before`,`${name}-initial`];
const returned=name=>[`${name}-confirm-before`,`${name}-send`,`${name}-edit-before`,`${name}-details`];
export function requirements(phase,apk) {
  if(!phases.includes(phase) || !variants.includes(apk)) throw new Error('Unknown coverage identity');
  const candidate=apk==='production-candidate';
  const plan={snapshots:['phase-initial'],sequences:[],final:null};
  if(phase==='permission-denial-grant') {
    plan.snapshots.push('permission-send-before','permission-media-before','permission-denied-app-state','permission-granted-os-state',...entry('permission-granted-route'),'permission-granted-select');
    plan.final='permission-granted-cancel';
  } else if(phase==='core') {
    plan.snapshots.push('native-control-before','native-control-after',...entry('short'),'mouse-selected','short-before-dpad','short-after-dpad',...entry('fresh'),'fresh-after-dpad');
    plan.sequences=['short','fresh'];
    const name=candidate?'core-return':'base-mouse-return';
    if(!candidate) plan.snapshots.push('base-mouse-return-selected');
    plan.snapshots.push(...returned(name));plan.final=`${name}-details`;
  } else if(phase==='picker-cancel') {
    plan.snapshots.push(...entry(phase),'cancel-selected','cancel-return',...entry('cancel-reenter'));plan.final='cancel-reenter-initial';
  } else if(phase==='pointer-count') {
    plan.snapshots.push(...entry(phase),'pointer-preview','pointer-preview-return','pointer-selected','pointer-reset','dpad-selected');
    plan.snapshots.push(...(candidate?['dpad-deselected']:entry('pointer-core-fresh')),'count-one','count-two','count-one-again',...returned('count-return'));
    plan.sequences=['pointer-count'];plan.final='count-return-details';
  } else if(phase==='folders') {
    plan.snapshots.push(...entry(phase),'expand-folders-before','folders-expanded','folders-remote-result','reopen-folders-before','folders-reopened','pointer-recent-before','folders-pointer-collapse');
    plan.sequences=['folders-collapsed'];plan.final='folders-collapsed-tile-result';
  } else if(phase==='mixed') {
    plan.snapshots.push('mixed-send-before','mixed-media-before','mixed-entry-initial','mixed-folders-before','mixed-folder-before','mixed-initial');
    for(let i=0;i<2;i++) plan.snapshots.push(`mixed-preview-${i}`,`mixed-preview-return-${i}`,`mixed-selected-${i}`,`mixed-deselected-${i}`);
    plan.snapshots.push('mixed-both-selected',...returned('mixed-return'));plan.final='mixed-return-details';
  } else {
    plan.snapshots.push(...entry(phase));plan.sequences=[phase];plan.final=`${phase}-focused`;
  }
  if(!plan.snapshots.includes(plan.final)) plan.snapshots.push(plan.final);
  return plan;
}

const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const ensure=(condition,message)=>{if(!condition) throw new Error(message);};
const readJson=file=>JSON.parse(fs.readFileSync(file,'utf8'));
function nativeDiagnostics(raw,packets,timeBase) {
  // Optional correlation aid only: no sample-table provenance or no-suspend proof.
  try {
    const magic=Buffer.from('#VV1NSC0PET1ME2#'),start=raw.indexOf(magic);
    ensure(start>=0 && raw.indexOf(magic,start+1)<0,'Absent or ambiguous native v2 marker');
    ensure(start+32<=raw.length && raw.readUInt32LE(start+16)===2,'Unsupported/truncated native metadata');
    const count=raw.readUInt32LE(start+28),length=32+8*count;
    ensure(count>0 && count===packets.length && start+length<=raw.length,'Native metadata/video packet count mismatch');
    const [numerator,denominator]=timeBase.split('/').map(BigInt);
    ensure(numerator>0n && denominator>0n,'Invalid native correlation timebase');
    const native=[];let first,previous,maxResidual=0n;
    const firstPts=BigInt(packets[0].pts);
    for(let i=0;i<count;i++) {
      const elapsed=raw.readBigUInt64LE(start+32+i*8);
      ensure(previous===undefined || elapsed>previous,'Nonmonotonic native frame metadata');
      first??=elapsed;previous=elapsed;
      const residual=(elapsed-first)*denominator-(BigInt(packets[i].pts)-firstPts)*numerator*1000000000n;
      const absolute=residual<0n?-residual:residual;if(absolute>maxResidual) maxResidual=absolute;
      ensure(absolute<=numerator*1000000000n+denominator*1000n,'Native timestamp/packet disagreement beyond one tick plus codec microsecond quantization');
      native.push({packetIndex:i,elapsedNs:elapsed.toString()});
    }
    return {status:'uncertain',parsed:true,markerOffset:start,count,offsetNs:raw.readBigInt64LE(start+20).toString(),maxResidualNumerator:maxResidual.toString(),maxResidualDenominator:denominator.toString(),frames:native,
      limitations:['Marker-based optional aid; metadata sample-table provenance not established','No per-operation guest elapsed brackets','Completion-time elapsed-minus-monotonic offset may shift earlier frames after guest suspend','No host/guest clock alignment is qualified'],acceptanceUse:false};
  } catch(error) {return {status:'unknown',parsed:false,error:error.message,acceptanceUse:false};}
}

export function recordingInventory(out) {
  const raw=fs.readFileSync(path.join(out,'whole-phase.mp4'));
  const frames=readJson(path.join(out,'whole-phase-frames.json')).frames;
  ensure(Array.isArray(frames) && frames.length>0 && frames.some(f=>f.media_type==='video'),'Empty actual decoded video frame inventory');
  const timingErrors=[];
  const optionalJson=name=>{try{return readJson(path.join(out,name));}catch(error){timingErrors.push(`${name}: ${error.message}`);return {};}};
  const metadata=optionalJson('whole-phase-metadata.json');
  const streams=(metadata.streams ?? []).filter(s=>s.codec_type==='video');
  const stream=streams.length===1?streams[0]:null,packetData=optionalJson('whole-phase-packets.json');
  const packets=Array.isArray(packetData.packets)?packetData.packets:[];
  const integer=(value,label)=>{
    if((typeof value==='string' && /^-?\d+$/.test(value)) || (typeof value==='number' && Number.isSafeInteger(value))) return BigInt(value);
    timingErrors.push(`${label}: unavailable or noninteger timestamp`);return null;
  };
  const timeBase=stream?.time_base ?? null;
  const validTimeBase=typeof timeBase==='string' && /^[1-9]\d*\/[1-9]\d*$/.test(timeBase);
  if(!validTimeBase) timingErrors.push('Video timebase unavailable or unsupported');
  if(streams.length!==1) timingErrors.push('Video stream identity ambiguous or unavailable');
  if(!packets.length) timingErrors.push('Video packet inventory unavailable; actual decoded frames retained');
  const timestamps=[];
  const indexed=frames.map((frame,index)=>{
    if(frame.media_type!=='video' || (stream && frame.stream_index!==stream.index)) timingErrors.push(`Frame ${index}: stream identity uncertain`);
    const pts=integer(frame.pts ?? frame.best_effort_timestamp,`Frame ${index}`);timestamps.push(pts);
    const matches=pts===null?[]:packets.map((p,i)=>({p,i})).filter(({p})=>String(p.pts)===pts.toString() && String(p.pos)===String(frame.pkt_pos));
    return {index,rawPts:frame.pts ?? null,rawBestEffortTimestamp:frame.best_effort_timestamp ?? null,pts:pts?.toString() ?? null,timeBase,packetMatch:matches.length===1?'matched':'uncertain',packetIndex:matches.length===1?matches[0].i:null,packetPosition:frame.pkt_pos,packetSize:matches.length===1?matches[0].p.size:null,keyFrame:frame.key_frame,width:frame.width,height:frame.height};
  });
  let maximumPositiveGap=0n,orderingUncertain=!validTimeBase || timestamps.some(pts=>pts===null) || streams.length!==1;const gaps=[];
  for(let i=1;i<indexed.length;i++) {
    const ticks=timestamps[i]===null || timestamps[i-1]===null?null:timestamps[i]-timestamps[i-1];
    if(ticks===null || ticks<=0n) orderingUncertain=true;
    if(ticks!==null && ticks>maximumPositiveGap) maximumPositiveGap=ticks;
    gaps.push({before:i-1,after:i,ticks:ticks?.toString() ?? null,status:ticks===null?'unknown':ticks>0n?'positive':'nonincreasing'});
  }
  const span=timestamps[0]===null || timestamps.at(-1)===null?null:timestamps.at(-1)-timestamps[0];
  const result={schemaVersion:1,rawSha256:hash(raw),timeBase,duration:metadata.format?.duration,frameCount:indexed.length,packetCount:packets.length,
    firstPts:indexed[0].pts,lastPts:indexed.at(-1).pts,spanTicks:span?.toString() ?? null,presentationOrdering:orderingUncertain?'uncertain':'increasing',timingErrors,
    maximumPositiveGapTicks:maximumPositiveGap.toString(),positiveGapBoundary:'Largest positive adjacent PTS difference only; signed actual gaps retained, no coverage or ordering acceptance claim',gaps,frames:indexed,
    nativeCorrelation:nativeDiagnostics(raw,packets,timeBase),boundary:'Actual decoded frame indexes remain usable when PTS/timebase/order is uncertain. Timing, frame duration and nominal FPS do not manufacture captured states or qualify pixels.'};
  fs.writeFileSync(path.join(out,'raw-frame-index.json'),JSON.stringify(result,null,2));return result;
}

export function actionInventory(out,apk,phase,recording) {
  const identity={runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT,harnessSha:process.env.GITHUB_SHA};
  const sameRun=receipt=>Object.entries(identity).every(([key,value])=>value && receipt[key]===value);
  const result={schemaVersion:1,apk,phase,...identity,automatedEvidenceComplete:false,manualVisualQualification:'pending',recordingQualification:'pending manual original-frame review',correlation:'uncertain',errors:[],observations:[],directionalWindows:[]};
  try {
    const outcome=readJson(path.join(out,'outcome.json'));
    ensure(sameRun(outcome) && outcome.apk===apk && outcome.phase===phase && outcome.automatedObservationPassed===true,'Missing/failed/stale/wrong-identity phase outcome');
    const events=fs.readFileSync(path.join(out,'input-timings.jsonl'),'utf8').trim().split('\n').map(line=>JSON.parse(line));
    const receipts=events.filter(e=>e.type==='coverage-operation');
    const operations=[];
    for(const start of receipts.filter(e=>e.edge==='start')) {
      ensure(sameRun(start) && start.apk===apk && start.phase===phase,'Wrong/stale event identity');
      const ends=receipts.filter(e=>e.id===start.id && e.edge==='end');
      ensure(receipts.filter(e=>e.id===start.id && e.edge==='start').length===1 && ends.length===1,`Unpaired/duplicate operation ${start.id}`);
      const end=ends[0];ensure(sameRun(end) && end.apk===apk && end.phase===phase && end.kind===start.kind && end.ok===true && BigInt(end.hostMonoNs)>=BigInt(start.hostMonoNs),`Failed/stale/nonmonotonic operation ${start.id}`);
      operations.push({...start,end});
    }
    ensure(receipts.length===operations.length*2,'Orphan operation end');
    const actions=operations.filter(e=>['mouse','dpad','lifecycle'].includes(e.kind));
    ensure(actions.length>0,'No real input/lifecycle receipts');
    const plan=requirements(phase,apk),manifest=readJson(path.join(out,'observation-manifest.json'));
    ensure(sameRun(manifest) && manifest.apk===apk && manifest.phase===phase && manifest.finalSnapshot===plan.final,'Wrong/stale observation manifest identity/final state');
    const required=[...plan.snapshots,...manifest.dynamic.map(d=>d.snapshotName)];
    ensure(new Set(required).size===required.length,'Duplicated required observation');
    if(phase==='permission-denial-grant') {
      ensure(manifest.dynamic.some(d=>d.role==='os-denial-prompt'),'Missing actual OS denial prompt observation');
      for(const name of ['os-app-permissions','os-media-permission','os-permission-grant']) ensure(manifest.dynamic.filter(d=>d.role===name).length===1,`Missing successful native Settings target ${name}`);
      const denyCount=actions.filter(e=>e.kind==='mouse' && e.label==='OS-permission-deny').length;
      ensure(denyCount===outcome.controls.denial.responses.length && denyCount===manifest.dynamic.filter(d=>d.role==='os-denial-prompt').length,'Denial observations/actions/count mismatch');
    }
    for(const snapshotName of required) {
      const snapshot=readJson(path.join(out,`${snapshotName}-capture.json`));
      ensure(sameRun(snapshot) && snapshot.name===snapshotName && snapshot.apk===apk && snapshot.phase===phase,'Wrong/stale snapshot identity');
      const png=fs.readFileSync(path.join(out,`${snapshotName}.png`)),xml=fs.readFileSync(path.join(out,`${snapshotName}.xml`));
      ensure(png.length>0 && xml.length>0 && snapshot.pngSha256===hash(png) && snapshot.xmlSha256===hash(xml),'Missing/changed original snapshot');
      const capture=operations.filter(e=>e.kind==='png' && e.name===snapshotName);ensure(capture.length===1,'Missing/duplicate PNG interval');
      const following=actions.find(e=>BigInt(e.hostMonoNs)>BigInt(capture[0].end.hostMonoNs));
      result.observations.push({snapshotName,pngSha256:snapshot.pngSha256,xmlSha256:snapshot.xmlSha256,pngOperation:capture[0],nextActionId:following?.id ?? null,terminal:snapshotName===plan.final,
        originalFrameIndexes:null,manualVerdict:'pending',boundary:'Host intervals locate review regions approximately; original video must visibly show this state before the next actual input. No clock-based pixel acceptance.'});
    }
    const complete=operations.filter(e=>e.kind==='observations-complete');ensure(complete.length===1,'Missing original observation completion boundary');
    const lastPng=operations.find(e=>e.kind==='png' && e.name===plan.final);
    ensure(BigInt(lastPng.end.hostMonoNs)<=BigInt(complete[0].hostMonoNs),'Final snapshot follows observation completion');
    for(const label of plan.sequences) {
      const keys=operations.filter(e=>e.kind==='dpad' && e.sequence===label);
      ensure(JSON.stringify(keys.map(e=>e.key))==='[20,20,22,23]',`Missing/changed exact key sequence ${label}`);
    }
    ensure(operations.filter(e=>e.kind==='dpad' && e.sequence).every(e=>plan.sequences.includes(e.sequence)),'Unexpected exact sequence label');
    for(const action of actions.filter(e=>e.kind==='dpad')) {
      const holds=operations.filter(e=>e.kind==='dpad-hold' && e.parentId===action.id);
      ensure(holds.length===1 && holds[0].requestedMs===650,'Missing/changed existing650ms D-pad hold');
      if([20,22].includes(action.key)) {
        const following=actions.find(e=>BigInt(e.hostMonoNs)>BigInt(action.end.hostMonoNs));
        ensure(following,'Directional focus observation lacks next actual input boundary');
        result.directionalWindows.push({actionId:action.id,key:action.key,sequence:action.sequence ?? null,commandEnd:action.end,nextActionId:following.id,nextActionStart:following,
          criticalPreCenter:following.kind==='dpad' && following.key===23,originalFrameIndexes:null,manualVerdict:'pending',requirement:'Review the continuous action group for visible unselected focus before its Center, then selection of the same tile. Individual650ms hold frames and clock alignment are supplementary; a later selected frame alone cannot prove pre-Center focus.'});
      }
    }
    result.originalCompletion=complete[0];result.rawSha256=recording.rawSha256;result.automatedEvidenceComplete=true;
    result.manualRequirements=['Every listed state and real input order visibly covered in original continuous recording','Both core short/fresh pre-Center focus states and actual selection/return outcomes','Expanded/collapsed folder focus and pointer deselection retained focus','Actual image/video viewer controls/content, not labels alone','Actual distinct light/dark palettes and full outline edges','Terminal required state within original observation/completion window; missing late evidence fails manual qualification'];
  } catch(error) {result.errors.push(error.message);}
  fs.writeFileSync(path.join(out,'action-coverage.json'),JSON.stringify(result,null,2));return result;
}
