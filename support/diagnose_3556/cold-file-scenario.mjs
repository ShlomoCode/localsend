import assert from 'node:assert/strict';
import {openSync,writeSync,closeSync,createWriteStream} from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';

const minute=60000,original='org.localsend.localsend_app',helper='org.localsend.fixture3556';
const httpsUrl=value=>{const url=new URL(value);assert(url.protocol==='https:','Provider artifact must use HTTPS');return url;};
const publicUrl=value=>{const url=httpsUrl(value);url.search='';url.hash='';return url.href;};
async function metadata(session,auth,deadline){
 const response=await fetch('https://api-cloud.browserstack.com/app-automate/sessions/'+encodeURIComponent(session)+'.json',{
  headers:{authorization:auth},signal:AbortSignal.timeout(Math.max(1,Math.min(30000,deadline-Date.now())))});
 assert(response.ok,'Owned recording metadata request failed: '+response.status);
 const value=(await response.json()).automation_session;
 assert(value?.hashed_id===session,'Recording metadata did not identify the exact owned session');return value;
}
export async function recordingPreflight({session,auth,save}){
 const value=await metadata(session,auth,Date.now()+30000);
 assert(value.video_url&&value.device_logs_url,'Recording precondition: video/native log artifact references unavailable');
 const result={status:'configured+artifactreference',requestedVideo:true,checkedUtc:new Date().toISOString(),session,
  videoReference:publicUrl(value.video_url),deviceLogReference:publicUrl(value.device_logs_url),
  limitation:'No documented live recording-ready field. References do not prove playable continuous coverage.'};
 save('cold-recording-preflight.json',result);return result;
}

export async function runColdFileScenario(api){
 const {wd,base,source,snap,nodes,labels,touch,activate,save,report,sleep,sessionStart,counters,setDeadline}=api;
 const cold=report.coldFile={status:'setup',launchLedger:[],events:[],gaps:[],earlyProbe:{status:'unavailable'},postWindowProbe:{status:'unavailable'},
  limits:{setupReads:40,windowReads:150,terminalReads:10,windowImages:20,queryMs:10000,windowMs:10*minute,cleanupAgeMs:25*minute},
  scope:'Process-cold first fixture File selection; staging/decoding may warm OS/media/storage caches. No Send or same-session small control.'};
 report.scenario='Cold original 1.18.2 File/Recent first 16GB fixture selection and ten-minute onset observation';
 report.boundaries=['S20 cloud Android 10; reporter picker and Android version unspecified','Padded one-second valid MP4; process cold does not imply cold storage/media cache','Historical 64 MiB results provide retrospective harness support only'];
 const event=(type,detail={})=>{cold.events.push({type,utc:new Date().toISOString(),ageMs:Date.now()-sessionStart,...detail});save('cold-file-events.json',cold);};
 const setupStart=counters().sourceCount;
 const read=async(deadline,phase='setup')=>{
  const before=counters().sourceCount;
  assert(phase!=='setup'||before-setupStart<38,'Cold setup hierarchy budget exhausted');
  assert(phase!=='window'||before-cold.windowSourceStart<148,'Cold window hierarchy budget exhausted');
  assert(phase!=='terminal'||before-cold.terminalSourceStart<8,'Cold terminal hierarchy budget exhausted');
  const started=Date.now();try{const xml=await source(Math.min(deadline,started+10000),phase==='terminal');
   save('cold-'+phase+'-hierarchy-'+counters().sourceCount+'.xml',xml);
   event('hierarchy',{phase,startedUtc:new Date(started).toISOString(),elapsedMs:Date.now()-started,attempts:counters().sourceCount-before});return xml;
  }catch(error){event('instrumentation-gap',{phase,startedUtc:new Date(started).toISOString(),elapsedMs:Date.now()-started,
   attempts:counters().sourceCount-before,error:String(error.message),backendCancellationEstablished:false});throw error;}
 };
 const visible=(xml,label)=>nodes(xml).find(n=>(n.text===label||n['content-desc']===label)&&n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||''));
 const rect=n=>{const [x,y,right,bottom]=n.bounds.match(/\d+/g).map(Number);return {x,y,width:right-x,height:bottom-y};};
 const tap=async(xml,label)=>{const node=visible(xml,label);assert(node,'Actual visible enabled control missing: '+label);await touch(rect(node),'Cold File: '+label);};
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
 assert(name?.endsWith('.mp4')&&bytes===16000000000&&/mediaDurationMs=[1-9]\d*/.test(details)&&/decodedFrame=[1-9]\d*x[1-9]\d*/.test(details),'Exact valid 16GB fixture evidence missing');
 report.fixture={name,bytes,uri:details.match(/\nuri=([^\n]+)/)?.[1],details,sha256:null};save('fixture.json',report.fixture);await snap('cold-fixture-ready',staged);
 // Ordinary onboarding, if needed, is not guessed: retain actual UI and fail setup for explicit review.
 await wd('POST',base()+'/appium/device/terminate_app',{appId:original},0,Date.now()+10000);
 const stopped=await ledger('ordinary-terminate-before-cold-launch');assert(stopped.state===1,'Original is not observed installed/not-running');
 const checked=await capacity('Check picker storage',16000000000+2*1024*1024*1024);
 event('normal-activate-original');await activate(original);await ledger('normal-cold-launch');
 let xml=await until(s=>labels(s).includes('Send\nTab 2 of 3'),Math.min(Date.now()+30000,sessionStart+10*minute));
 if(!nodes(xml).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true')){await tap(xml,'Send\nTab 2 of 3');xml=await read(sessionStart+10*minute);}
 assert(nodes(xml).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true')&&visible(xml,'File')&&!labels(xml).some(s=>/Selection\nFiles: [1-9]/.test(s)),'Original empty Send page not established');
 assert(Date.now()-checked<60000,'Picker capacity evidence became stale; cold setup must be repeated');await snap('cold-empty-send',xml);await tap(xml,'File');
 xml=await until(s=>s.includes('com.google.android.documentsui'),Date.now()+30000);await tap(xml,'Show roots');
 xml=await read(sessionStart+10*minute);
 assert(nodes(xml).some(n=>/roots_list$/.test(n['resource-id']||'')),'Actual DocumentsUI roots drawer not observed');
 const recent=nodes(xml).filter(n=>n.text==='Recent'&&n['resource-id']==='android:id/title'&&n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||'')).at(-1);
 assert(recent,'Actual enabled Recent drawer row missing');await touch(rect(recent),'Cold File: DocumentsUI Recent drawer row');
 xml=await until(s=>!nodes(s).some(n=>/roots_list$/.test(n['resource-id']||'')),Date.now()+30000);
 xml=await until(s=>!!visible(s,name),Date.now()+30000);await snap('cold-exact-picker-row',xml);
 assert(Date.now()-checked<60000,'Picker capacity evidence stale at T0; no fixture row touch admitted');
 assert(Date.now()<sessionStart+10*minute,'T0 admission exceeded session age ten minutes');
 assert(report.coldRecording?.status==='configured+artifactreference','Recording precondition unavailable');
 cold.setupReads=counters().sourceCount-setupStart;assert(cold.setupReads<=40,'Setup hierarchy allocation exceeded');
 const t0=Date.now(),end=t0+10*minute;cold.t0Utc=new Date(t0).toISOString();cold.windowEndUtc=new Date(end).toISOString();
 cold.windowSourceStart=counters().sourceCount;cold.windowImages=0;setDeadline(end);event('T0-exact-picker-row-touch',{name,rect:rect(visible(xml,name))});
 try{await tap(xml,name);event('picker-row-touch-command-result',{status:'returned'});}
 catch(error){event('picker-row-touch-command-result',{status:'instrumentation-gap',error:String(error.message),backendCancellationEstablished:false});
  cold.gaps.push({utc:new Date().toISOString(),stage:'T0 touch',error:String(error.message),backendCancellationEstablished:false});
  // The exact actual touch was issued once. Preserve the window even when its HTTP response is unknown.
 }
 const selected=s=>labels(s).some(v=>v.includes('Selection\nFiles: 1\nSize: 16.0 GB'))&&nodes(s).some(n=>n['content-desc']==='Send\nTab 2 of 3'&&n.selected==='true');
 const anr=s=>labels(s).some(v=>/isn.t responding|not responding/i.test(v));
 let probe=null,lastImage=0,firstSelection=false,lastObservation=Date.now(),priorState=null;
 const image=async(name,s)=>{if(cold.windowImages>=20){if(!cold.windowImageBudgetExhausted){cold.windowImageBudgetExhausted=true;event('window-image-budget-exhausted');}return false;}
  cold.windowImages++;lastImage=Date.now();await snap(name,s);return true;};
 const processFrame=async(s,terminal=false)=>{
  const now=Date.now();if(selected(s)&&!firstSelection){firstSelection=true;event('first-selected-one-file');}
  const state={picker:s.includes('com.google.android.documentsui'),loading:labels(s).some(v=>/^loading(?:\.{3}|…)?$/i.test(v.trim())),selected:selected(s),anr:anr(s)};
  if(JSON.stringify(state)!==JSON.stringify(priorState)){event('observed-ui-transition',state);priorState=state;}
  if(anr(s)){
   event('actual-native-anr',{afterEarlyInput:!!cold.earlyProbe.startedUtc});
   try{const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(Date.now()+10000,terminal?postEnd:end));event('anr-foreground',{foreground});}
   catch(error){event('anr-foreground-gap',{error:String(error.message)});}
   if(!terminal)await image('cold-anr-'+cold.events.length,s);
   try{
    const refreshed=await read(Math.min(Date.now()+10000,terminal?postEnd:end),terminal?'terminal':'window');
    const wait=anr(refreshed)&&nodes(refreshed).find(n=>/^wait$/i.test(n.text||n['content-desc']||'')&&n.enabled==='true'&&n.displayed!=='false'&&/^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds||''));
    if(wait&&Date.now()<(terminal?postEnd:end)){event('actual-Wait-touch',{rect:rect(wait),freshDialogVerified:true});await touch(rect(wait),'Cold File: actual native Wait');}
    else event('actual-Wait-unavailable',{reason:'Fresh ANR/Wait not visible or phase expired'});
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
  if(!probe&&result.status==='unavailable'&&selected(s)&&visible(s,'Favorites')&&(terminal||(now>=t0+minute&&now<t0+4*minute))){
   result.status='started';result.startedUtc=new Date(now).toISOString();event('Favorites-probe-start',{terminal});
   probe={stage:'open',result,touchAt:Date.now(),deadline:Math.min(Date.now()+10000,terminal?postEnd:Math.min(end,t0+4*minute))};
   if(Date.now()>=probe.deadline){result.status='transition-unavailable';event('probe-transition-timeout',result);probe=null;return;}
   setDeadline(probe.deadline);try{await tap(s,'Favorites');}finally{setDeadline(terminal?postEnd:end);}
  }
 };
 while(Date.now()<end){
  if(probe&&Date.now()>=probe.deadline){probe.result.status='transition-unavailable';event('probe-transition-timeout',probe.result);probe=null;}
  const started=Date.now();if(counters().sourceCount-cold.windowSourceStart>=148){event('window-hierarchy-budget-exhausted');
   while(Date.now()<end)await sleep(Math.min(30000,Math.max(0,end-Date.now())));break;}
  try{xml=await read(Math.min(end,probe?.deadline??end),'window');event('window-frame',{gapMs:started-lastObservation});lastObservation=started;
   await processFrame(xml);if(Date.now()-lastImage>=30000)await image('cold-window-'+cold.windowImages,xml);
  }catch(error){cold.gaps.push({utc:new Date().toISOString(),error:String(error.message),backendCancellationEstablished:false});
   // A bounded HTTP read does not establish backend cancellation. Never replay input or activate the app.
   try{const foreground=await wd('GET',base()+'/appium/device/current_package',undefined,0,Math.min(Date.now()+10000,end));event('independent-gap-foreground',{foreground});}
   catch(recoveryError){event('independent-gap-foreground-unavailable',{error:String(recoveryError.message)});}
   try{const retained=await image('cold-gap-image-'+cold.events.length,xml);event(retained?'independent-gap-image':'independent-gap-image-budget-exhausted',{hierarchyIsLastRetainedFrame:true});}
   catch(recoveryError){event('independent-gap-image-unavailable',{error:String(recoveryError.message)});}
  }
  await sleep(Math.min(4000,Math.max(0,end-Date.now())));
 }
 if(probe){probe.result.status='transition-unavailable';probe=null;}
 cold.windowReads=counters().sourceCount-cold.windowSourceStart;event('window-ended');
 const postEnd=Math.min(Date.now()+30000,sessionStart+25*minute);setDeadline(postEnd);cold.terminalSourceStart=counters().sourceCount;
 try{xml=await read(postEnd,'terminal');await snap('cold-terminal',xml);await processFrame(xml,true);
  while(probe&&Date.now()<postEnd){xml=await read(Math.min(postEnd,probe.deadline),'terminal');await processFrame(xml,true);if(probe)await sleep(Math.min(1000,Math.max(0,probe.deadline-Date.now())));}
 }catch(error){event('post-window-check-unavailable',{error:String(error.message)});}
 if(probe)probe.result.status='transition-unavailable';
 cold.terminalReads=counters().sourceCount-cold.terminalSourceStart;cold.status='observation-retained-pending-continuous-video-validation';
 report.status='incomplete';event('cold-scenario-ended');
}

export async function retainColdRecording({session,auth,save,output,report}){
 const deadline=Date.now()+5*minute,value=await metadata(session,auth,deadline);
 const videoDeadline=deadline-minute; // Reserve two bounded 30-second native/Appium fetches.
 const retained={status:'incomplete',session,artifacts:[],coverage:'Requires decode, original PTS and actual T0/window/event frame inspection; elapsed session duration alone is insufficient.'};
 report.coldRecordingRetention=retained;
 let videoRetained=false;
 const download=async(field,file)=>{
  const artifactDeadline=field==='video_url'?Math.min(videoDeadline,Date.now()+2*minute):Math.min(deadline,Date.now()+30000);
  try{
  assert(value[field],'Provider artifact reference missing: '+field);let url=httpsUrl(value[field]);let response;
  const apiHosts=new Set(['api.browserstack.com','api-cloud.browserstack.com']);
  // Populate only from the independently verified provider contract/observed historical redirect hosts.
  const mediaHosts=new Set(['app-automate.browserstack.com']);
  const trusted=target=>{assert(!target.username&&!target.password&&(!target.port||target.port==='443'),'Artifact URL contains credentials or unexpected port');
   assert(apiHosts.has(target.hostname)||mediaHosts.has(target.hostname),'Unexpected provider artifact host: '+target.hostname);return target;};
  trusted(url);
  for(let redirects=0;redirects<=5;redirects++){
   assert(Date.now()<artifactDeadline,'Recording artifact deadline exceeded');
   response=await fetch(url,{redirect:'manual',headers:field!=='video_url'&&apiHosts.has(url.hostname)?{authorization:auth}:{},signal:AbortSignal.timeout(Math.max(1,artifactDeadline-Date.now()))});
   if(response.status>=300&&response.status<400){assert(redirects<5,'Provider artifact redirect limit exceeded');
    url=trusted(httpsUrl(new URL(response.headers.get('location'),url).href));continue;}break;
  }
  assert(response.ok,'Provider artifact download failed: '+field+' '+response.status);
  const cap=field==='video_url'?1024*1024*1024:100*1024*1024;
  assert(!response.headers.get('content-length')||Number(response.headers.get('content-length'))<=cap,'Provider artifact exceeds byte cap');
  const destination=openSync(path.join(output,file),'w');let bytes=0;
  try{for await(const chunk of response.body){assert(Date.now()<artifactDeadline,'Artifact body deadline exceeded');bytes+=chunk.length;assert(bytes<=cap,'Provider artifact exceeds byte cap');writeSync(destination,chunk);}}
  finally{closeSync(destination);}
  assert(bytes>0,'Provider artifact empty: '+field);if(field==='video_url')videoRetained=true;
  retained.artifacts.push({field,file,bytes,byteCap:cap,reference:publicUrl(value[field])});
  }catch(error){retained.artifacts.push({field,file,status:'incomplete',error:String(error.message).replace(/https?:\/\/\S+/g,'[artifact URL redacted]')});}
  save('cold-recording-retention.json',retained);
 };
 try{
 await download('video_url','cold-provider-original.mp4');
 assert(videoRetained,'Original continuous video was not retained; inspect artifact receipt');
 const decodeDeadline=Math.min(videoDeadline,Date.now()+2*minute);
 const run=async(command,args,onOutput)=>{
  assert(Date.now()<decodeDeadline,'Recording decode deadline exceeded; native log time reserved');
  const child=spawn(command,args,{windowsHide:true,stdio:['ignore','pipe','pipe']});let stderr='';
  child.stdout.on('data',onOutput);child.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-8000);});
  await new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{child.kill();reject(Error(command+' retention deadline exceeded; native log time reserved'));},Math.max(1,decodeDeadline-Date.now()));
   child.once('error',error=>{clearTimeout(timer);reject(error);});
   child.once('exit',code=>{clearTimeout(timer);if(code===0)resolve();else reject(Error(command+' failed '+code+': '+stderr));});
  });return stderr;
 };
 const video=path.join(output,'cold-provider-original.mp4'),ptsFile='cold-provider-video-pts.csv';
 const pts=createWriteStream(path.join(output,ptsFile));let pending='',count=0,firstPts=null,lastPts=null,previousPts=null,regressions=0,maxGap=0;
 const inspect=line=>{const value=Number(line.split(',')[0]);if(!Number.isFinite(value)||!line.trim())return;
  count++;firstPts??=value;if(previousPts!==null){if(value<previousPts)regressions++;maxGap=Math.max(maxGap,value-previousPts);}previousPts=value;lastPts=value;};
 try{await run('ffprobe',['-v','error','-select_streams','v:0','-show_frames','-show_entries','frame=best_effort_timestamp_time,pkt_duration_time','-of','csv=p=0',video],chunk=>{
  pts.write(chunk);pending+=chunk.toString();const lines=pending.split('\n');pending=lines.pop();for(const line of lines)inspect(line);
 });if(pending)inspect(pending);}finally{await new Promise(resolve=>pts.end(resolve));}
 assert(count>0&&firstPts!==null&&lastPts>firstPts,'Video did not provide a positive original frame timeline');
 retained.timeline={file:ptsFile,frames:count,firstPts,lastPts,durationSeconds:lastPts-firstPts,regressions,maxGapSeconds:maxGap,
  mappingToT0:'unproven; requires actual visual/native input alignment'};save('cold-recording-retention.json',retained);
 const decodeErrors=await run('ffmpeg',['-v','error','-xerror','-i',video,'-map','0:v:0','-f','null','-'],()=>{});
 retained.decode={status:'complete',errors:decodeErrors};
 }catch(error){retained.videoValidationFailure=String(error.message).replace(/https?:\/\/\S+/g,'[artifact URL redacted]');save('cold-recording-retention.json',retained);throw error;}
 finally{
  // Primary native evidence remains independently retrievable when the video or decoder fails.
  await download('device_logs_url','cold-provider-device.log');await download('appium_logs_url','cold-provider-appium.log');
 }
 // Successful decode/duration cannot establish the wall-clock alignment or uninterrupted onset coverage.
 retained.status='coverage-pending-independent-audit';save('cold-recording-retention.json',retained);
}
