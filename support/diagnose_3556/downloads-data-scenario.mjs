import assert from 'node:assert/strict';

const minute=60000,original='org.localsend.localsend_app',helper='org.localsend.fixture3556';

// Ordinary Send -> File entry. No process-cold condition or transfer is part of this diagnostic.
export async function runDownloadsDataScenario(api){
 const {wd,base,source,snap,nodes,labels,touch,activate,save,report,sleep,sessionStart,counters,setDeadline}=api;
 const prepEnd=sessionStart+10*minute,cleanupEnd=sessionStart+20*minute;
 const run=report.downloadsData={status:'preparing',events:[],gaps:[],route:[],preSelectionProbe:{status:'unavailable'},postWindowProbe:{status:'unavailable'},
  limits:{prepMs:10*minute,windowMs:5*minute,cleanupAgeMs:20*minute,setupReads:80,windowReads:100,terminalReads:16,windowImages:12,queryMs:10000},
  scope:'Original 1.18.2 normal opening and actual File/Downloads data selection, pre-Send only; no transfer, receiver, hash pass or process-cold gate.'};
 report.scenario='Original 1.18.2 File/Downloads 16GB data selection and five-minute pre-Send observation';
 report.boundaries=['Samsung Galaxy S20 cloud Android 10 differs from any unspecified reporter environment',
  'Pinned historical helper stages non-video data; fixture SHA-256 is UNKNOWN/deferred and prior byte equality unverified',
  'Provider video/log references alone do not prove continuous coverage; independent original-frame and native-input audit required',
  'Pre-Send selection diagnostic only; the reported full transfer remains unvalidated'];
 const event=(type,detail={})=>{run.events.push({type,utc:new Date().toISOString(),ageMs:Date.now()-sessionStart,runnerMonotonicMs:performance.now(),...detail});save('downloads-data-events.json',run);};
 const setupStart=counters().sourceCount;
 const read=async(end,phase='setup')=>{
  const limit=phase==='setup'?78:phase==='window'?98:14,start=phase==='setup'?setupStart:phase==='window'?run.windowSourceStart:run.terminalSourceStart;
  assert(counters().sourceCount-start<limit,'Downloads '+phase+' hierarchy budget exhausted');
  const started=Date.now(),before=counters().sourceCount;
  const queryEnd=Math.min(end,started+10000);
  try{const xml=await source(queryEnd,phase==='terminal');save('downloads-'+phase+'-'+counters().sourceCount+'.xml',xml);
   assert(Date.now()<queryEnd,'Hierarchy completed outside immutable query deadline; raw frame retained but unusable');
   event('hierarchy',{phase,elapsedMs:Date.now()-started,attempts:counters().sourceCount-before});return xml;
  }catch(error){event('instrumentation-gap',{phase,elapsedMs:Date.now()-started,error:String(error.message),backendCancellationEstablished:false});throw error;}
 };
 const visible=(xml,label)=>nodes(xml).find(n=>(n.text===label||n['content-desc']===label)&&n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||''));
 const rect=n=>{const [x,y,r,b]=n.bounds.match(/\d+/g).map(Number);return {x,y,width:r-x,height:b-y};};
 const tap=async(xml,label)=>{const n=visible(xml,label);assert(n,'Actual visible enabled control unavailable: '+label);event('input-start',{label,rect:rect(n)});
  const started=Date.now();await touch(rect(n),'Downloads data: '+label);event('input-return',{label,elapsedMs:Date.now()-started});};
 const until=async(predicate,end,phase='setup')=>{end=Math.min(end,phase==='setup'?prepEnd:cleanupEnd);
  while(Date.now()<end){const xml=await read(end,phase);if(predicate(xml))return xml;await sleep(Math.min(4000,Math.max(0,end-Date.now())));}
  throw Error('Downloads '+phase+' UI transition unavailable before deadline');};
 const selected=xml=>labels(xml).some(v=>v.includes('Selection\nFiles: 1\nSize: 16.0 GB'))&&nodes(xml).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true');
 const empty=xml=>nodes(xml).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true')&&!!visible(xml,'File')&&!labels(xml).some(v=>/Selection\nFiles: [1-9]/.test(v));
 const optionalState=async(stage,end)=>{
  try{const state=await wd('POST',base()+'/appium/device/app_state',{appId:original},0,Math.min(end,Date.now()+10000));event('available-app-state',{stage,state,limitation:'Native queryAppState observation only; no PID or cold-process proof'});}
  catch(error){event('app-state-unavailable',{stage,error:String(error.message)});}
 };
 const probe=async(xml,result,end,phase,returned)=>{
  if(!returned(xml)||!visible(xml,'Favorites')){result.reason='Legitimate visible enabled Favorites control unavailable';event('touch-control-unavailable',result);return xml;}
  const savedEnd=phase==='setup'?prepEnd:cleanupEnd,probeEnd=Math.min(end,Date.now()+30000);setDeadline(probeEnd);
  try{result.startedUtc=new Date().toISOString();const started=Date.now();await tap(xml,'Favorites');
   xml=await until(s=>!!visible(s,'Cancel')&&!!visible(s,'Add')&&labels(s).includes('Favorites'),Math.min(probeEnd,Date.now()+10000),phase);
   result.openResponseMs=Date.now()-started;await snap('downloads-'+phase+'-favorites',xml);
   const cancelAt=Date.now();await tap(xml,'Cancel');xml=await until(s=>returned(s)&&!visible(s,'Cancel'),Math.min(probeEnd,Date.now()+10000),phase);
   result.cancelResponseMs=Date.now()-cancelAt;result.elapsedMs=Date.now()-started;result.status='responsive';result.finishedUtc=new Date().toISOString();
  }catch(error){result.status='transition-unavailable';result.error=String(error.message);throw error;}
  finally{setDeadline(savedEnd);event('touch-control-result',result);}return xml;
 };
 const capacity=async(button,required)=>{
  const before=await read(prepEnd),previous=Number(labels(before).join('\n').match(/storageCheckedUtcMs=(\d+)/)?.[1])||0;
  await tap(before,button);const xml=await until(s=>Number(labels(s).join('\n').match(/storageCheckedUtcMs=(\d+)/)?.[1])>previous,Math.min(prepEnd,Date.now()+30000));
  const text=labels(xml).join('\n'),available=Number(text.match(/availableBytes=(\d+)/)?.[1]);
  assert(Number.isSafeInteger(available)&&available>=required,'Fresh capacity insufficient for staging/picker copy');event('capacity',{button,available,required});return Date.now();
 };
 setDeadline(prepEnd);await activate(helper);await capacity('Refresh capacity',32000000000+2*1024*1024*1024);
 let xml=await read(prepEnd);await tap(xml,'Stage 16GB data');
 xml=await until(s=>{const text=labels(s).join('\n');assert(!/FAILED|INSUFFICIENT_STORAGE/.test(text),'Data staging failed');return /READY name=.*\.bin/.test(text);},Math.min(prepEnd,sessionStart+8*minute));
 const details=labels(xml).find(v=>v.includes('READY name=')),name=details?.match(/READY name=([^\n]+)/)?.[1],bytes=Number(details?.match(/\nbytes=(\d+)/)?.[1]),uri=details?.match(/\nuri=([^\n]+)/)?.[1];
 assert(name?.endsWith('.bin')&&bytes===16000000000&&uri?.startsWith('content://')&&/\nsha256=deferred-until-app-completion(?:\n|$)/.test(details),'Exact staged data metadata/deferred hash missing');
 report.fixture={name,bytes,uri,details,sha256:null,hashStatus:'UNKNOWN/deferred; no pre-Send full hash',expectedRelativePath:'Download/Issue3556',priorFixtureByteEquality:'unverified'};
 save('fixture.json',report.fixture);await snap('downloads-data-staged',xml);
 const checked=await capacity('Check picker storage',16000000000+2*1024*1024*1024);
 event('normal-original-activation');await activate(original);
 xml=await until(s=>labels(s).includes('Send\nTab 2 of 3'),Math.min(prepEnd,Date.now()+30000));
 if(!nodes(xml).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true')){await tap(xml,'Send\nTab 2 of 3');xml=await read(prepEnd);}
 assert(empty(xml),'Ordinary empty Send page unavailable; onboarding is not guessed');await snap('downloads-empty-send',xml);
 await optionalState('ordinary-empty-Send',prepEnd);
 xml=await probe(xml,run.preSelectionProbe,prepEnd,'setup',empty);
 assert(run.preSelectionProbe.status==='responsive','Required actual preselection Favorites/Cancel touch control not established; File and T0 not admitted');
 assert(empty(xml),'Empty Send did not return after touch control');
 assert(report.coldRecording?.status==='configured+artifactreference','Continuous video/native log preflight missing before actual File touch');
 event('recording-before-File',{preflightUtc:report.coldRecording.checkedUtc,sessionStartBeforePostUtc:report.sessionStartBeforePostUtc,
  limitation:'Coverage begins before File only if independent provider video audit aligns these actual input events'});
 assert(Date.now()-checked<60000,'Picker capacity stale before File; no picker selection admitted');await tap(xml,'File');
 xml=await until(s=>s.includes('com.google.android.documentsui'),Math.min(prepEnd,Date.now()+30000));await tap(xml,'Show roots');xml=await read(prepEnd);
 assert(nodes(xml).some(n=>/roots_list$/.test(n['resource-id']||'')),'Actual DocumentsUI roots drawer unavailable');await snap('downloads-visible-roots',xml);
 const roots=nodes(xml).filter(n=>n['resource-id']==='android:id/title'&&n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||''));
 const download=roots.find(n=>n.text==='Downloads');
 // A visible local document root is admitted only when its exact label and ID are retained; never Recent.
 const local=download||roots.find(n=>/^(?:Internal storage|Internal shared storage|Galaxy S20|SM-G981B|Samsung Galaxy S20)$/.test(n.text||''));
 assert(local,'Downloads and supported visible local document root unavailable; no Recent fallback');
 run.route.push({label:local.text,resourceId:local['resource-id'],routeType:download?'Downloads':'visible-local-document-root'});
 event('actual-root-touch',run.route.at(-1));await touch(rect(local),'Downloads data: actual document root '+local.text);
 xml=await until(s=>!nodes(s).some(n=>/roots_list$/.test(n['resource-id']||'')),Math.min(prepEnd,Date.now()+30000));
 if(!download){xml=await until(s=>!!visible(s,'Download')||!!visible(s,'Downloads'),Math.min(prepEnd,Date.now()+30000));
  const folder=visible(xml,'Download')?'Download':'Downloads';run.route.push({label:folder});await tap(xml,folder);xml=await read(prepEnd);}
 if(!visible(xml,name)){xml=await until(s=>!!visible(s,name)||!!visible(s,'Issue3556'),Math.min(prepEnd,Date.now()+30000));
  if(!visible(xml,name)){run.route.push({label:'Issue3556'});await tap(xml,'Issue3556');}}
 xml=await until(s=>!!visible(s,name),Math.min(prepEnd,Date.now()+30000));run.route.push({label:name});save('downloads-route.json',run.route);await snap('downloads-exact-staged-row',xml);
 assert(Date.now()<prepEnd&&Date.now()-checked<60000,'T0 admission exceeded prep10 or fresh capacity; exact row not touched');
 run.setupReads=counters().sourceCount-setupStart;run.windowSourceStart=counters().sourceCount;run.windowImages=0;
 const t0=Date.now(),end=t0+5*minute;run.t0Utc=new Date(t0).toISOString();run.windowEndUtc=new Date(end).toISOString();setDeadline(end);
 event('T0-exact-staged-row-touch',{name,uri,bytes,rect:rect(visible(xml,name)),sourceHash:'UNKNOWN/deferred'});
 try{await tap(xml,name);}catch(error){run.gaps.push({stage:'T0-command-return',error:String(error.message),backendCancellationEstablished:false});event('row-touch-return-unknown',run.gaps.at(-1));}
 const anrCandidate=s=>labels(s).some(v=>/isn.t responding|not responding/i.test(v));
 const nativeAnrWait=s=>{
  const enabled=n=>n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||'');
  const native=nodes(s).filter(n=>n.package==='android'&&n.displayed!=='false');
  const titles=native.filter(n=>['android:id/alertTitle','android:id/aerr_message'].includes(n['resource-id'])&&
   /^LocalSend\s+(?:isn[’']t responding|is not responding|not responding)[.!]?$/i.test((n.text||n['content-desc']||'').trim()));
  const waits=native.filter(n=>n['resource-id']==='android:id/aerr_wait'&&/^wait$/i.test(n.text||n['content-desc']||'')&&enabled(n));
  const controls=native.filter(n=>['android:id/aerr_close','android:id/aerr_report'].includes(n['resource-id'])&&enabled(n));
  return titles.length===1&&waits.length===1&&controls.length>0?waits[0]:null;
 };let prior=null,lastImage=0,waitResponseUnknown=false;
 while(Date.now()<end){
  if(counters().sourceCount-run.windowSourceStart>=98){event('window-hierarchy-budget-exhausted');while(Date.now()<end)await sleep(Math.min(30000,end-Date.now()));break;}
  try{xml=await read(end,'window');const state={picker:xml.includes('com.google.android.documentsui'),selected:selected(xml),anrCandidate:anrCandidate(xml)};
   if(JSON.stringify(state)!==JSON.stringify(prior)){event('observed-transition',{...state,sinceRowTouchMs:Date.now()-t0});prior=state;}
   if(state.selected&&!run.firstSelectedUtc){run.firstSelectedUtc=new Date().toISOString();run.selectionReturnMs=Date.now()-t0;event('first-selected-return',{elapsedMs:run.selectionReturnMs});}
   if(Date.now()-lastImage>=30000&&run.windowImages<12){run.windowImages++;lastImage=Date.now();await snap('downloads-window-'+run.windowImages,xml);}
   if(state.anrCandidate){event('unidentified-anr-candidate',{sinceRowTouchMs:Date.now()-t0,qualification:'Text candidate only; original native Android dialog identity unverified'});
    const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(end,Date.now()+10000));
    const fresh=await read(Math.min(end,Date.now()+10000),'window'),wait=nativeAnrWait(fresh);
    const coherentForeground=foreground===original||foreground==='android';
    event('fresh-native-anr-context',{foreground,nativeLocalSendDialog:!!wait,coherentForeground});
    if(wait&&coherentForeground&&!waitResponseUnknown&&Date.now()<end){event('actual-native-anr',{affectedApp:original,sinceRowTouchMs:Date.now()-t0,freshDialogVerified:true,foreground});
     event('actual-fresh-native-Wait-touch',{rect:rect(wait),nativeResourceId:wait['resource-id'],ownerPackage:wait.package,affectedApp:original,sinceRowTouchMs:Date.now()-t0});
     try{await touch(rect(wait),'Downloads data: actual fresh native LocalSend Wait');}
     catch(error){waitResponseUnknown=true;event('Wait-command-response-unknown',{error:String(error.message),backendCancellationEstablished:false,replaySuppressed:true});throw error;}}
    else event('fresh-native-Wait-unavailable',{reason:waitResponseUnknown?'Prior Wait command response unknown; further Wait input suppressed':'Fresh LocalSend Android ANR dialog identity, coherent foreground, exact Wait or phase unavailable; candidate remains unidentified'});
   }
  }catch(error){run.gaps.push({utc:new Date().toISOString(),error:String(error.message),backendCancellationEstablished:false});event('window-gap',run.gaps.at(-1));}
  await sleep(Math.min(4000,Math.max(0,end-Date.now())));
 }
 run.windowReads=counters().sourceCount-run.windowSourceStart;event('five-minute-window-ended');
 setDeadline(cleanupEnd);run.terminalSourceStart=counters().sourceCount;
 try{xml=await read(Math.min(cleanupEnd,Date.now()+10000),'terminal');await snap('downloads-terminal',xml);
  xml=await probe(xml,run.postWindowProbe,Math.min(cleanupEnd,Date.now()+30000),'terminal',selected);
  await optionalState('after-five-minute-window',cleanupEnd);
 }catch(error){event('post-window-control-unavailable',{error:String(error.message)});}
 run.terminalReads=counters().sourceCount-run.terminalSourceStart;run.finalCounters=counters();
 run.status='observation-retained-pending-original-video-and-native-log-audit';report.status='incomplete';event('downloads-scenario-ended');
}
