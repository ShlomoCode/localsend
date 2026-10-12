import assert from 'node:assert/strict';
import {readFileSync,openSync,writeSync,closeSync,renameSync,createWriteStream} from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
const minute=60000,original='org.localsend.localsend_app',helper='org.localsend.fixture3556';

// Keep signed references in memory; public receipts omit their queries and fragments.
export async function coldShareRecordingPreflight({session,auth,save}){
 const response=await fetch('https://api-cloud.browserstack.com/app-automate/sessions/'+encodeURIComponent(session)+'.json',{
  headers:{authorization:auth},signal:AbortSignal.timeout(10000)});
 const chunks=[];let bytes=0;for await(const chunk of response.body){bytes+=chunk.length;assert(bytes<=1024*1024,'Share preflight metadata byte cap exceeded');chunks.push(Buffer.from(chunk));}
 assert(response.ok,'Owned Share preflight metadata failed '+response.status);const value=JSON.parse(Buffer.concat(chunks).toString()).automation_session;
 assert(value?.hashed_id===session,'Share preflight metadata does not identify the exact owned session');
 assert(value.video_url&&value.device_logs_url,'Share recording precondition: video/native log references unavailable');
 const references={hashed_id:session};const publicReferences={};
 for(const field of ['video_url','device_logs_url','appium_logs_url'])if(value[field]){
  const u=new URL(value[field]);assert(u.protocol==='https:'&&!u.username&&!u.password&&(!u.port||u.port==='443')&&
   ['api.browserstack.com','api-cloud.browserstack.com','app-automate.browserstack.com'].includes(u.hostname),'Unexpected Share preflight artifact origin');
  references[field]=u.href;u.search='';u.hash='';publicReferences[field]=u.href;
 }
 const receipt={status:'configured+artifactreference',requestedVideo:true,checkedUtc:new Date().toISOString(),session,
  videoReference:publicReferences.video_url,deviceLogReference:publicReferences.device_logs_url,appiumLogReference:publicReferences.appium_logs_url,
  limitation:'References do not prove playable continuous coverage; private same-session references retained in memory only.'};
 save('cold-recording-preflight.json',receipt);return {receipt,references};
}

export async function runColdShareScenario(api){
 const {wd,base,source,snap,nodes,labels,touch,activate,save,report,sleep,sessionStart,counters,setDeadline,output,session}=api;
 const cold=report.coldShare={status:'setup',launchLedger:[],events:[],gaps:[],earlyProbe:{status:'unavailable'},postWindowProbe:{status:'unavailable'},
  limits:{setupReads:40,windowReads:150,terminalReads:10,windowImages:20,queryMs:10000,windowMs:10*minute,cleanupAgeMs:25*minute},
  scope:'Process-cold first fixture startup Share selection; staging/decoding may warm OS/media/storage caches. No Send or same-session small control.'};
 report.scenario='Cold original 1.18.2 native Share first 16GB fixture selection and ten-minute onset observation';
 report.boundaries=['S20 cloud Android 10; reporter Share route and Android version unspecified','Padded one-second valid MP4; process cold does not imply cold storage/media cache',
  'Pinned helper/seed preserve the content recipe; prior full fixture-byte equality is unverified','Source-to-APK callback/thread mapping and continuous visual coverage remain unverified'];
 const event=(type,detail={})=>{cold.events.push({type,utc:new Date().toISOString(),ageMs:Date.now()-sessionStart,
  runnerMonotonicMs:performance.now(),monotonicScope:'This runner process; event/Share trigger command ledger only',...detail});save('cold-share-events.json',cold);};
 const setupStart=counters().sourceCount;
 const read=async(deadline,phase='setup')=>{
  const before=counters().sourceCount;
  assert(phase!=='setup'||before-setupStart<38,'Cold setup hierarchy budget exhausted');
  assert(phase!=='window'||before-cold.windowSourceStart<148,'Cold window hierarchy budget exhausted');
  assert(phase!=='terminal'||before-cold.terminalSourceStart<8,'Cold terminal hierarchy budget exhausted');
  const started=Date.now();try{const xml=await source(Math.min(deadline,started+10000),phase==='terminal');
   save('cold-share-'+phase+'-hierarchy-'+counters().sourceCount+'.xml',xml);
   event('hierarchy',{phase,startedUtc:new Date(started).toISOString(),elapsedMs:Date.now()-started,attempts:counters().sourceCount-before});return xml;
  }catch(error){event('instrumentation-gap',{phase,startedUtc:new Date(started).toISOString(),elapsedMs:Date.now()-started,
   attempts:counters().sourceCount-before,error:String(error.message),backendCancellationEstablished:false});throw error;}
 };
 const visible=(xml,label)=>nodes(xml).find(n=>(n.text===label||n['content-desc']===label)&&n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||''));
 const rect=n=>{const [x,y,right,bottom]=n.bounds.match(/\d+/g).map(Number);return {x,y,width:right-x,height:bottom-y};};
 const tap=async(xml,label)=>{const node=visible(xml,label);assert(node,'Actual visible enabled control missing: '+label);await touch(rect(node),'Cold Share: '+label);};
 const until=async(predicate,end,phase='setup')=>{do{const xml=await read(end,phase);if(predicate(xml))return xml;await sleep(Math.min(4000,Math.max(0,end-Date.now())));}while(Date.now()<end);throw Error('Cold '+phase+' UI transition unavailable before deadline');};
 const ledger=async(stage)=>{
  const state=await wd('POST',base()+'/appium/device/app_state',{appId:original},0,Date.now()+10000);
  const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Date.now()+10000);
  const entry={stage,utc:new Date().toISOString(),state,foreground};cold.launchLedger.push(entry);event('launch-state',entry);return entry;
 };
 const capacity=async(button,required)=>{
  const before=await read(sessionStart+10*minute),previous=Number(labels(before).join('\n').match(/storageCheckedUtcMs=(\d+)/)?.[1])||0;
  await tap(before,button);const xml=await until(s=>Number(labels(s).join('\n').match(/storageCheckedUtcMs=(\d+)/)?.[1])>previous,Date.now()+30000);
  const text=labels(xml).join('\n'),available=Number(text.match(/availableBytes=(\d+)/)?.[1]),checked=Number(text.match(/storageCheckedUtcMs=(\d+)/)?.[1]);
  assert(Number.isSafeInteger(available)&&available>=required,'Fresh fixture capacity insufficient');event('capacity',{button,available,required,checked});return Date.now();
 };
 await ledger('provider-startup-before-explicit-original-launch');
 await activate(helper);await capacity('Refresh capacity',32000000000+2*1024*1024*1024);
 const fixtureUi=await read(sessionStart+10*minute);await tap(fixtureUi,'Stage 16GB video');
 const staged=await until(s=>{const text=labels(s).join('\n');assert(!/FAILED|INSUFFICIENT_STORAGE/.test(text),'Fixture staging failed');return /READY name=.*\.mp4/.test(text);},sessionStart+8*minute);
 const details=labels(staged).find(s=>s.includes('READY name='));
 const name=details?.match(/READY name=([^\n]+)/)?.[1],bytes=Number(details?.match(/\nbytes=(\d+)/)?.[1]);
 assert(name?.endsWith('.mp4')&&bytes===16000000000&&/mediaDurationMs=1000(?:\s|$)/.test(details)&&/decodedFrame=320x240(?:\n|$)/.test(details),'Exact valid pinned-seed 16GB fixture evidence missing');
 report.fixture={name,bytes,recipeIdentityOnly:true,uri:details.match(/\nuri=([^\n]+)/)?.[1],details,sha256:null};save('fixture.json',report.fixture);await snap('cold-fixture-ready',staged);
 // Stage before the original receives this URI, then prepare installed/not-running startup entry.
 assert(/^content:\/\/media\/external\/video\/media\/\d+$/.test(report.fixture.uri||''),'Pinned MediaStore video route missing');
 await wd('POST',base()+'/appium/device/terminate_app',{appId:original},0,Date.now()+10000);
 const stopped=await ledger('ordinary-terminate-before-incoming-Share');assert(stopped.state===1,'Original is not observed installed/not-running');
 const checked=await capacity('Check picker storage',16000000000+2*1024*1024*1024);
 const beforeShare=await read(sessionStart+10*minute);await tap(beforeShare,'Share owned fixture');
 const searchEnd=Math.min(Date.now()+minute,sessionStart+10*minute);
 setDeadline(searchEnd);
 cold.chooser={status:'searching',maxGestures:8,observations:[],gestures:[],visualGate:'observed-native-layout; custom painted loading unknown without independent visual review'};
 const hashFile=file=>createHash('sha256').update(readFileSync(path.join(output,file))).digest('hex');
 const enabled=n=>n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||'');
 const signature=s=>JSON.stringify(nodes(s).filter(n=>n.package==='android'&&(n.text||n['resource-id']||n['content-desc']))
  .map(n=>({text:n.text,description:n['content-desc'],id:n['resource-id'],bounds:n.bounds,scrollable:n.scrollable})));
 const targets=s=>nodes(s).filter(n=>n.package==='android'&&n.text==='LocalSend'&&enabled(n));
 const spinner=s=>nodes(s).some(n=>n.displayed!=='false'&&(/ProgressBar$/.test(n.class||'')||/progressbar|loading|spinner/i.test(n['resource-id']||'')));
 const itemPositions=s=>{const list=nodes(s),container=list.find(n=>n['resource-id']==='android:id/resolver_list'&&enabled(n));
  assert(container,'Fresh native chooser container unavailable after gesture');const top=rect(container).y;
  return list.filter(n=>n.package==='android'&&n['resource-id']==='android:id/text1'&&n.text&&enabled(n)).map(n=>({label:n.text,y:rect(n).y-top}));};
 let xml,lastLayout=null,stable=0,falseGestures=0,swipeUsed=false,targetPair=[],gestureCount=0,index=0;
 while(Date.now()<searchEnd){
  xml=await read(searchEnd);const list=nodes(xml),containers=list.filter(n=>n.package==='android'&&n['resource-id']==='android:id/resolver_list'&&enabled(n));
  assert(containers.length<=1,'Native chooser container ambiguous');
  const found=targets(xml);assert(found.length<=1,'Native chooser LocalSend target ambiguous');
  const layout=signature(xml),loading=spinner(xml),changed=layout!==lastLayout;
  stable=changed?1:stable+1;lastLayout=layout;
  const observed={utc:new Date().toISOString(),index:index++,changed,stable,loading,targets:found.length,gestures:gestureCount};cold.chooser.observations.push(observed);
  if(found.length&&containers.length===1&&!loading){
   // App-state queries precede the final stable target pair, so input uses the final chooser snapshot.
   if(!targetPair.length){assert((await ledger('before-final-chooser-pair')).state===1,'Original warmed before incoming Share');xml=await read(searchEnd);
    assert(targets(xml).length===1&&!spinner(xml),'Chooser changed during original-state query');lastLayout=signature(xml);stable=1;}
   assert(counters().imageCount<16,'Cold Share setup image allocation exhausted');
   const snapshot='cold-share-chooser-'+observed.index;await snap(snapshot,xml);
   const current={snapshot,sourceSha256:createHash('sha256').update(xml).digest('hex'),imageSha256:hashFile(snapshot+'.png'),layout:signature(xml),targetBounds:targets(xml)[0].bounds,utc:new Date().toISOString()};
   if(targetPair.length&&current.layout!==targetPair[0].layout)targetPair=[];
   targetPair.push(current);
   if(targetPair.length===2){
    cold.chooser.targetPair=targetPair;save('cold-share-chooser-gate.json',{session,runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT,targetPair,
     qualification:'Stable enabled target/no accessible loading observed; custom painted loading is unknown without independent visual review'});
    cold.chooser.visualGate='two-stable-target-frames-and-retained-pixels; custom-loading-unverified';cold.chooser.status='target-ready';break;
   }
   await sleep(Math.min(1500,Math.max(0,searchEnd-Date.now())));continue;
  }
  targetPair=[];
  if(loading||containers.length!==1||stable<2||gestureCount>=8||(falseGestures>=2&&swipeUsed)){await sleep(Math.min(1500,Math.max(0,searchEnd-Date.now())));continue;}
  const container=containers[0],bounds=rect(container);assert(bounds.width>0&&bounds.height>0,'Native chooser container has no bounds');
  const before=itemPositions(xml),fallback=falseGestures>=2;
  const action={utc:new Date().toISOString(),method:fallback?'one-current-container-swipe':'mobile: scrollGesture',bounds,before,canScrollMore:null};
  cold.chooser.gestures.push(action);gestureCount++;
  if(fallback){swipeUsed=true;const x=Math.round(bounds.x+bounds.width/2);
   await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'coldShareChooser',parameters:{pointerType:'touch'},actions:[
    {type:'pointerMove',duration:0,origin:'viewport',x,y:Math.round(bounds.y+bounds.height*0.85)},{type:'pointerDown',button:0},
    {type:'pointerMove',duration:800,origin:'viewport',x,y:Math.round(bounds.y+bounds.height*0.2)},{type:'pointerUp',button:0}]}]},0,searchEnd);
  }else{const element=await wd('POST',base()+'/element',{using:'id',value:'android:id/resolver_list'},0,searchEnd),id=element['element-6066-11e4-a52e-4f735466cecf']||element.ELEMENT;
   assert(id,'Current chooser resolver element unavailable');const result=await wd('POST',base()+'/execute/sync',{script:'mobile: scrollGesture',args:[{elementId:id,direction:'down',percent:0.75}]},0,searchEnd);
   assert(typeof result==='boolean','Chooser gesture returned no supported result');action.canScrollMore=result;falseGestures=result?0:falseGestures+1;}
  const after=await read(searchEnd);action.after=itemPositions(after);action.itemMovement=before.some(p=>action.after.some(q=>q.label===p.label&&q.y!==p.y));
  action.limit='False/no movement does not prove scroll end; spinner and sheet expansion remain distinct';lastLayout=null;stable=0;event('chooser-gesture',action);
 }
 assert(cold.chooser.status==='target-ready','Native chooser target/readiness unavailable within finite setup');
 assert(Date.now()<searchEnd,'Chooser search/trigger deadline expired; no target touch admitted');
 assert(Date.now()-checked<60000,'Share-copy capacity evidence stale at T0; no target touch admitted');
 assert(Date.now()<sessionStart+10*minute,'T0 admission exceeded session age ten minutes');
 assert(report.coldRecording?.status==='configured+artifactreference','Recording precondition unavailable');
 cold.setupReads=counters().sourceCount-setupStart;assert(cold.setupReads<=40,'Setup hierarchy allocation exceeded');
 const target=targets(xml);assert(target.length===1&&!spinner(xml),'Final actual chooser target unavailable');
 const t0=Date.now(),end=t0+10*minute;cold.t0Utc=new Date(t0).toISOString();cold.t0RunnerMonotonicMs=performance.now();cold.windowEndUtc=new Date(end).toISOString();
 cold.windowSourceStart=counters().sourceCount;cold.windowImages=0;event('T0-native-LocalSend-target-touch',{name,uri:report.fixture.uri,rect:rect(target[0])});
 event('chooser-target-command-start',{rect:rect(target[0]),deadlineUtc:new Date(searchEnd).toISOString()});
 try{await touch(rect(target[0]),'Cold Share: actual native LocalSend target');event('chooser-target-command-result',{status:'returned'});}
 catch(error){event('chooser-target-command-result',{status:'instrumentation-gap',error:String(error.message),backendCancellationEstablished:false});
  cold.gaps.push({utc:new Date().toISOString(),stage:'T0 touch',error:String(error.message),backendCancellationEstablished:false});}
 setDeadline(end);
 const selected=s=>labels(s).some(v=>v.includes('Selection\nFiles: 1\nSize: 16.0 GB'))&&nodes(s).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true');
 const anrCandidate=s=>labels(s).some(v=>/isn.t responding|not responding/i.test(v));
 const nativeAnrWait=s=>{
  // Android native IDs are an admission filter, never evidence unless actually observed in this hierarchy.
  const native=nodes(s).filter(n=>n.package==='android'&&n.displayed!=='false');
  const titles=native.filter(n=>['android:id/alertTitle','android:id/aerr_message'].includes(n['resource-id'])&&
   /^LocalSend\s+(?:isn[’']t responding|is not responding|not responding)[.!]?$/i.test((n.text||n['content-desc']||'').trim()));
  const waits=native.filter(n=>n['resource-id']==='android:id/aerr_wait'&&/^wait$/i.test(n.text||n['content-desc']||'')&&enabled(n));
  const errorControls=native.filter(n=>['android:id/aerr_close','android:id/aerr_report'].includes(n['resource-id'])&&enabled(n));
  return titles.length===1&&waits.length===1&&errorControls.length>0?waits[0]:null;
 };
 let probe=null,nextImageSlot=0,firstSelection=false,lastObservation=Date.now(),priorState=null;
 const image=async(name,s)=>{
  if(nextImageSlot>=20){if(!cold.windowImageBudgetExhausted){cold.windowImageBudgetExhausted=true;event('window-image-budget-exhausted');}return false;}
  const slot=nextImageSlot++,due=t0+slot*30000;const started=Date.now();cold.windowImages++;
  event('window-image-slot',{slot,nominalUtc:new Date(due).toISOString(),startedUtc:new Date(started).toISOString(),latenessMs:started-due,reason:name,
   displacedRoutine:name.includes('anr')||name.includes('gap')});
  try{await snap(name,s);event('window-image-finished',{slot,reason:name,startedUtc:new Date(started).toISOString(),finishedUtc:new Date().toISOString(),elapsedMs:Date.now()-started,status:'retained'});return true;}
  catch(error){event('window-image-finished',{slot,reason:name,startedUtc:new Date(started).toISOString(),finishedUtc:new Date().toISOString(),elapsedMs:Date.now()-started,status:'unavailable',error:String(error.message)});throw error;}
 };
 const routineImage=async(s)=>{
  if(nextImageSlot>=20||Date.now()<t0+nextImageSlot*30000)return;
  const dueSlot=Math.min(19,Math.floor((Date.now()-t0)/30000));
  while(nextImageSlot<dueSlot){event('window-image-slot-missed',{slot:nextImageSlot,nominalUtc:new Date(t0+nextImageSlot*30000).toISOString()});nextImageSlot++;}
  await image('cold-share-window-'+nextImageSlot,s);
 };
 const processFrame=async(s,terminal=false)=>{
  const now=Date.now();if(selected(s)&&!firstSelection){firstSelection=true;event('first-selected-one-file');}
  const state={nativeChooser:nodes(s).some(n=>n.package==='android'&&n['resource-id']==='android:id/resolver_list'),loading:labels(s).some(v=>/^loading(?:\.{3}|…)?$/i.test(v.trim())),selected:selected(s),anrCandidate:anrCandidate(s)};
  if(JSON.stringify(state)!==JSON.stringify(priorState)){event('observed-ui-transition',state);priorState=state;}
  if(anrCandidate(s)){
   event('anr-candidate',{afterEarlyInput:!!cold.earlyProbe.startedUtc,qualification:'Candidate only until fresh native ownership and LocalSend identity verified'});
   try{const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(Date.now()+10000,terminal?postEnd:end));event('anr-foreground',{foreground});}
   catch(error){event('anr-foreground-gap',{error:String(error.message)});}
   if(!terminal)await image('cold-share-anr-'+cold.events.length,s);
   try{
    const refreshed=await read(Math.min(Date.now()+10000,terminal?postEnd:end),terminal?'terminal':'window');
    const wait=nativeAnrWait(refreshed),foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(Date.now()+10000,terminal?postEnd:end));
    const coherentForeground=foreground===original||foreground==='android';
    event('fresh-anr-context',{foreground,nativeLocalSendDialog:!!wait,coherentForeground});
    if(wait&&coherentForeground&&Date.now()<(terminal?postEnd:end)){
     event('actual-native-anr',{afterEarlyInput:!!cold.earlyProbe.startedUtc,freshDialogVerified:true,affectedApp:original,foreground});
     event('actual-Wait-touch',{rect:rect(wait),nativeResourceId:wait['resource-id'],freshDialogVerified:true,affectedApp:original});await touch(rect(wait),'Cold Share: actual native LocalSend Wait');}
    else event('actual-Wait-unavailable',{reason:'Fresh native LocalSend dialog/Wait or coherent foreground unavailable, ambiguous, or phase expired'});
   }catch(error){event('actual-Wait-unavailable',{reason:'Fresh verification/command unavailable',error:String(error.message),backendCancellationEstablished:false});}
   return;
  }
  if(probe&&now>=probe.deadline){probe.result.status='transition-unavailable';probe=null;return;}
  if(probe?.stage==='open'&&visible(s,'Cancel')&&visible(s,'Add')&&labels(s).includes('Favorites')){
   probe.result.modalObservedUtc=new Date(now).toISOString();probe.result.openResponseMs=now-probe.touchAt;
   probe.stage='return';probe.touchAt=Date.now();probe.deadline=Math.min(probe.touchAt+10000,terminal?postEnd:Math.min(end,t0+4*minute));
   if(Date.now()>=probe.deadline){probe.result.status='transition-unavailable';event('probe-transition-timeout',probe.result);probe=null;return;}
   setDeadline(probe.deadline);try{await tap(s,'Cancel');}finally{setDeadline(terminal?postEnd:end);}return;
  }
  if(probe?.stage==='return'&&selected(s)&&!visible(s,'Cancel')){probe.result.status='responsive';probe.result.returnResponseMs=now-probe.touchAt;probe.result.finishedUtc=new Date(now).toISOString();event('responsive-probe',probe.result);probe=null;return;}
  const result=terminal?cold.postWindowProbe:cold.earlyProbe;
  if(!probe&&result.status==='unavailable'&&selected(s)&&visible(s,'Favorites')&&!visible(s,'Cancel')&&(terminal||(now>=t0+minute&&now<t0+4*minute))){
   result.status='started';result.startedUtc=new Date(now).toISOString();event('Favorites-probe-start',{terminal});
   probe={stage:'open',result,touchAt:Date.now(),deadline:Math.min(Date.now()+10000,terminal?postEnd:Math.min(end,t0+4*minute))};
   if(Date.now()>=probe.deadline){result.status='transition-unavailable';event('probe-transition-timeout',result);probe=null;return;}
   setDeadline(probe.deadline);try{await tap(s,'Favorites');}finally{setDeadline(terminal?postEnd:end);}
  }
 };
 while(Date.now()<end){
  if(probe&&Date.now()>=probe.deadline){probe.result.status='transition-unavailable';event('probe-transition-timeout',probe.result);probe=null;}
  const started=Date.now();if(counters().sourceCount-cold.windowSourceStart>=148){event('window-hierarchy-budget-exhausted');
   // Nonactivating serial instrumentation only; provider idle-timeout behavior remains unverified.
   for(let attempt=1;attempt<=20&&Date.now()<end;attempt++){
    const heartbeatStart=Date.now();try{const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(heartbeatStart+10000,end));
     event('budget-exhaustion-keepalive',{attempt,startedUtc:new Date(heartbeatStart).toISOString(),finishedUtc:new Date().toISOString(),foreground,
      scope:'Instrumentation keepalive only; no hierarchy, ANR, or original responsiveness evidence',providerIdleContract:'unverified'});}
    catch(error){event('budget-exhaustion-keepalive-unavailable',{attempt,startedUtc:new Date(heartbeatStart).toISOString(),finishedUtc:new Date().toISOString(),error:String(error.message),providerIdleContract:'unverified'});}
    await sleep(Math.min(Math.max(0,heartbeatStart+30000-Date.now()),Math.max(0,end-Date.now())));
   }
   while(Date.now()<end)await sleep(Math.min(30000,Math.max(0,end-Date.now())));break;}
  try{xml=await read(Math.min(end,probe?.deadline??end),'window');event('window-frame',{gapMs:started-lastObservation});lastObservation=started;
   await processFrame(xml);await routineImage(xml);
  }catch(error){cold.gaps.push({utc:new Date().toISOString(),error:String(error.message),backendCancellationEstablished:false});
   // A bounded HTTP read does not establish backend cancellation. Never replay input or activate the app.
   try{const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(Date.now()+10000,end));event('independent-gap-foreground',{foreground});}
   catch(recoveryError){event('independent-gap-foreground-unavailable',{error:String(recoveryError.message)});}
   try{const retained=await image('cold-share-gap-image-'+cold.events.length,xml);event(retained?'independent-gap-image':'independent-gap-image-budget-exhausted',{hierarchyIsLastRetainedFrame:true});}
   catch(recoveryError){event('independent-gap-image-unavailable',{error:String(recoveryError.message)});}
  }
  const nextPoll=started+4000;
  if(Date.now()>nextPoll)event('window-poll-missed',{nominalUtc:new Date(nextPoll).toISOString(),lateMs:Date.now()-nextPoll});
  await sleep(Math.min(Math.max(0,nextPoll-Date.now()),Math.max(0,end-Date.now())));
 }
 if(probe){probe.result.status='transition-unavailable';probe=null;}
 cold.windowReads=counters().sourceCount-cold.windowSourceStart;event('window-ended');
 while(nextImageSlot<20){event('window-image-slot-missed',{slot:nextImageSlot,nominalUtc:new Date(t0+nextImageSlot*30000).toISOString(),reason:'window ended without capture'});nextImageSlot++;}
 const postEnd=Math.min(Date.now()+30000,sessionStart+25*minute);setDeadline(postEnd);cold.terminalSourceStart=counters().sourceCount;
 try{xml=await read(postEnd,'terminal');await snap('cold-share-terminal',xml);await processFrame(xml,true);
  while(probe&&Date.now()<postEnd){xml=await read(Math.min(postEnd,probe.deadline),'terminal');await processFrame(xml,true);if(probe)await sleep(Math.min(1000,Math.max(0,probe.deadline-Date.now())));}
 }catch(error){event('post-window-check-unavailable',{error:String(error.message)});}
 if(probe)probe.result.status='transition-unavailable';
 cold.terminalReads=counters().sourceCount-cold.terminalSourceStart;cold.status='observation-retained-pending-continuous-video-validation';
 report.status='incomplete';event('cold-scenario-ended');
}

// Share-only retention: delayed artifacts never create another episode or alter File-mode behavior.
export async function retainColdShareRecording({session,auth,save,output,report,preflightReferences}){
 const deadline=Math.min(Date.now()+5*minute,Date.parse(process.env.COLD_JOB_DEADLINE_UTC));
 assert(Number.isFinite(deadline)&&deadline>Date.now(),'Cold Share retention deadline expired');
 const receipt=report.coldShareRecordingRetention={status:'incomplete',session,attempts:[],deadlineUtc:new Date(deadline).toISOString(),
  coverage:'Decode and duration do not establish first-touch alignment, continuous visibility, or global ANR absence.'};
 const scrub=error=>String(error.message||error).replace(/https?:\/\/\S+/g,'[artifact URL redacted]');
 const safeUrl=value=>{const u=new URL(value);u.search='';u.hash='';return u.href;};
 const apiHosts=new Set(['api.browserstack.com','api-cloud.browserstack.com']);
 const checkedUrl=value=>{const u=new URL(value);assert(u.protocol==='https:'&&!u.username&&!u.password&&(!u.port||u.port==='443')&&
  (apiHosts.has(u.hostname)||u.hostname==='app-automate.browserstack.com'),'Unexpected artifact HTTPS origin');return u;};
 const bound=end=>{const ms=Math.floor(Math.min(end,deadline)-Date.now());assert(ms>0,'Share artifact phase expired');return ms;};
 const completed=(entry,phaseEnd,requestEnd)=>{const now=Date.now();entry.finishedUtc=new Date(now).toISOString();
  entry.phaseDeadlineUtc=new Date(phaseEnd).toISOString();entry.requestDeadlineUtc=new Date(requestEnd).toISOString();
  entry.finishedAfterPhaseDeadline=now>=phaseEnd;entry.finishedAfterRequestDeadline=now>=requestEnd;entry.finishedAfterAggregateDeadline=now>=deadline;
  return !entry.finishedAfterPhaseDeadline&&!entry.finishedAfterRequestDeadline&&!entry.finishedAfterAggregateDeadline;};
 let metadata=preflightReferences?.hashed_id===session?{...preflightReferences}:{};
 receipt.preflightFallback=preflightReferences?.hashed_id===session?'validated-same-session-private-references':'unavailable';receipt.metadataRefreshes=[];
 const refreshMetadata=async(end)=>{
  const attempt={startedUtc:new Date().toISOString(),status:'incomplete'};receipt.metadataRefreshes.push(attempt);
  const requestEnd=Math.min(end,deadline,Date.now()+10000),previousMetadata=metadata;
  try{
  const response=await fetch('https://api-cloud.browserstack.com/app-automate/sessions/'+encodeURIComponent(session)+'.json',{
   headers:{authorization:auth},signal:AbortSignal.timeout(bound(requestEnd))});
  const chunks=[];let bytes=0;for await(const chunk of response.body){bytes+=chunk.length;assert(bytes<=1024*1024,'Session metadata byte cap exceeded');chunks.push(Buffer.from(chunk));}
  assert(response.ok,'Owned session metadata failed '+response.status);const value=JSON.parse(Buffer.concat(chunks).toString()).automation_session;
  assert(value?.hashed_id===session,'Metadata does not identify the exact owned session');
  const candidate={...metadata,hashed_id:session};
  for(const field of ['video_url','device_logs_url','appium_logs_url'])if(value[field])candidate[field]=checkedUrl(value[field]).href;
  assert(completed(attempt,end,requestEnd),'Metadata completed after its request, phase, or aggregate deadline');
  metadata=candidate;attempt.status='validated';
  }catch(error){attempt.error=scrub(error);throw error;}
  finally{const onTime=completed(attempt,end,requestEnd);if(!onTime){metadata=previousMetadata;attempt.status='late-unusable';}
   save('cold-share-recording-retention.json',receipt);
   if(!completed(attempt,end,requestEnd)){metadata=previousMetadata;attempt.status='late-unusable';save('cold-share-recording-retention.json',receipt);throw Error('Metadata completion exceeded its immutable deadline');}}
 };
 try{await refreshMetadata(deadline-minute);}catch(error){receipt.initialMetadataRefreshError=scrub(error);save('cold-share-recording-retention.json',receipt);}
 const download=async(field,file,end)=>{
  let totalBytes=0;const cap=field==='video_url'?1024*1024*1024:100*1024*1024;
  for(let attempt=1;attempt<=3&&Date.now()<end;attempt++){
   const entry={field,attempt,startedUtc:new Date().toISOString(),status:'incomplete',file:file+'.attempt-'+attempt+'.response'};receipt.attempts.push(entry);
   const responseFile=entry.file;
   const attemptEnd=Math.min(end,Date.now()+(field==='video_url'?35000:10000));
   try{
    let url=checkedUrl(metadata[field]);entry.reference=safeUrl(url);let response;
    for(let redirects=0;redirects<=5;redirects++){
     response=await fetch(url,{redirect:'manual',headers:field!=='video_url'&&apiHosts.has(url.hostname)?{authorization:auth}:{},
      signal:AbortSignal.timeout(bound(attemptEnd))});
     if(response.status>=300&&response.status<400){assert(redirects<5,'Artifact redirect cap exceeded');const location=response.headers.get('location');
      entry.redirects??=[];const next=checkedUrl(new URL(location,url).href);entry.redirects.push({status:response.status,to:safeUrl(next)});
      await response.body?.cancel();url=next;continue;}break;
    }
    entry.httpStatus=response.status;entry.headers=Object.fromEntries(['content-type','content-length','date','etag','last-modified','retry-after']
     .map(key=>[key,response.headers.get(key)]).filter(([,value])=>value!==null));
    entry.contentType=response.headers.get('content-type');
    const destination=openSync(path.join(output,entry.file),'w'),hash=createHash('sha256');let bytes=0,header=Buffer.alloc(0);
    try{for await(const chunk of response.body){bound(attemptEnd);bytes+=chunk.length;totalBytes+=chunk.length;assert(totalBytes<=cap,'Artifact cumulative byte cap exceeded');
     if(header.length<32)header=Buffer.concat([header,Buffer.from(chunk).subarray(0,32-header.length)]);hash.update(chunk);writeSync(destination,chunk);}}
    finally{closeSync(destination);entry.bytes=bytes;entry.sha256=hash.digest('hex');entry.totalArtifactBytes=totalBytes;
     completed(entry,end,attemptEnd);entry.bodyFinishedUtc=entry.finishedUtc;}
    assert(completed(entry,end,attemptEnd),'Artifact body completed after its request, phase, or aggregate deadline; raw response retained');
    assert(response.ok&&bytes>0,'Artifact not ready/usable: HTTP '+response.status);
    if(field==='video_url')assert(/video\/mp4/i.test(entry.contentType||'')&&header.length>=12&&header.subarray(4,8).toString()==='ftyp','Video response is not a usable MP4; raw response retained');
    else assert(!/xml|html/i.test(entry.contentType||'')&&!/^\s*<(?:\?xml|html|Error)/i.test(header.toString()),'Log endpoint returned error document; raw response retained');
    assert(completed(entry,end,attemptEnd),'Artifact validation completed late; raw response retained');
    renameSync(path.join(output,entry.file),path.join(output,file));entry.file=file;entry.renamedUtc=new Date().toISOString();
    assert(completed(entry,end,attemptEnd),'Artifact rename completed late; unmodified response retained');
    entry.status='retained';save('cold-share-recording-retention.json',receipt);
    assert(completed(entry,end,attemptEnd),'Artifact receipt completed late; unmodified response retained');return true;
   }catch(error){entry.error=scrub(error);if(!completed(entry,end,attemptEnd)){
     entry.status='late-unusable';
     if(entry.file===file)try{renameSync(path.join(output,file),path.join(output,responseFile));entry.file=responseFile;}
     catch(preservationError){entry.latePreservationError=scrub(preservationError);save('cold-share-recording-retention.json',receipt);return false;}
    }save('cold-share-recording-retention.json',receipt);}
   if(attempt<3&&Date.now()+1000<end){await new Promise(ok=>setTimeout(ok,Math.min(3000,Math.max(0,end-Date.now()))));
    try{await refreshMetadata(end);}catch(error){entry.metadataRefreshError=scrub(error);save('cold-share-recording-retention.json',receipt);}}
  }
  receipt.attempts.push({field,status:'unavailable',reason:'Finite attempts/phase exhausted',utc:new Date().toISOString()});save('cold-share-recording-retention.json',receipt);return false;
 };
 const video=await download('video_url','cold-share-provider-original.mp4',Math.min(deadline-minute,Date.now()+2*minute));
 // Both primary log artifacts are attempted independently before decoder failure can end retention.
 await download('device_logs_url','cold-share-provider-device.log',Math.min(deadline,Date.now()+30000));
 await download('appium_logs_url','cold-share-provider-appium.log',Math.min(deadline,Date.now()+30000));
 assert(video,'Original Share video unavailable; native/error receipts retained');
 const decodeEnd=Math.min(deadline,Date.now()+2*minute);
 const run=async(command,args,onData)=>{
  const timeout=bound(decodeEnd),child=spawn(command,args,{windowsHide:true,stdio:['ignore','pipe','pipe']});let stderr='';
  child.stdout.on('data',onData);child.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-8000);});
  await new Promise((ok,no)=>{const timer=setTimeout(()=>{child.kill();no(Error(command+' aggregate retention deadline'));},timeout);
   child.once('error',error=>{clearTimeout(timer);no(error);});child.once('exit',code=>{clearTimeout(timer);code===0?ok():no(Error(command+' failed '+code+': '+stderr));});});return stderr;
 };
 const videoPath=path.join(output,'cold-share-provider-original.mp4'),ptsFile='cold-share-provider-frame-pts.csv';
 const stream=createWriteStream(path.join(output,ptsFile));let pending='',frames=0,first=null,last=null,previous=null,maxGap=0,regressions=0;
 const inspect=line=>{const pts=Number(line.split(',')[0]);if(!line.trim()||!Number.isFinite(pts))return;frames++;first??=pts;
  if(previous!==null){maxGap=Math.max(maxGap,pts-previous);if(pts<previous)regressions++;}previous=pts;last=pts;};
 try{try{await run('ffprobe',['-v','error','-select_streams','v:0','-show_frames','-show_entries','frame=best_effort_timestamp_time,pkt_duration_time','-of','csv=p=0',videoPath],chunk=>{
   stream.write(chunk);pending+=chunk.toString();const lines=pending.split('\n');pending=lines.pop();for(const line of lines)inspect(line);});if(pending)inspect(pending);}
  finally{await new Promise(ok=>stream.end(ok));}
  assert(frames>0&&last>first,'Original frame timeline unavailable');receipt.timeline={ptsFile,frames,firstPts:first,lastPts:last,maxGapSeconds:maxGap,regressions,mapping:'Pending independent native input/source-frame audit'};
  receipt.decode={status:'complete',stderr:await run('ffmpeg',['-v','error','-xerror','-i',videoPath,'-map','0:v:0','-f','null','-'],()=>{})};
  receipt.status='coverage-pending-independent-audit';
 }catch(error){receipt.validationError=scrub(error);throw error;}finally{save('cold-share-recording-retention.json',receipt);}
}

