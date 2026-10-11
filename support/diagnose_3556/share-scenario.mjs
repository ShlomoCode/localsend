import assert from 'node:assert/strict';
import {mkdirSync,readFileSync,writeFileSync,existsSync} from 'node:fs';
import path from 'node:path';

// Caller must first complete the actual 1 MiB app-to-app control in this same session.
// This callback creates no session, starts no network send, and leaves session cleanup to its caller.
export default async function shareScenario({session,wd,output}){
 assert(session&&typeof wd==='function'&&output,'Provide the existing session, WebDriver callback, and controller evidence root');
 const directory=path.join(path.resolve(output),'share-scenario');mkdirSync(directory,{recursive:true});
 const base='/session/'+session,sleep=ms=>new Promise(ok=>setTimeout(ok,ms));
 const secrets=['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','RELAY_TOKEN','RELAY_APP','HELPER_APP','BASELINE_APP'].map(k=>process.env[k]).filter(Boolean);
 function redact(value){let text=String(value);for(const secret of secrets)text=text.replaceAll(secret,'[redacted]');return text;}
 const save=(name,value)=>writeFileSync(path.join(directory,name),redact(typeof value==='string'?value:JSON.stringify(value,null,2)));
 const report={status:'preparing',startedUtc:new Date().toISOString(),session,requestedOrientation:'PORTRAIT',
  scope:'File/Recent selection Edit and observed Back, then warm native chooser sharing and actual next UI input, after a verified 1 MiB Android-to-Windows transfer; no 16GB network transfer',
  hypothesis:'A share_handler MediaStore copy on the main thread is unproven. This module observes the unmodified app without injecting a stall.',
  limits:['Public MediaStore fixtures differ from the reporter original file','Requested portrait may not persist; record actual screenshot dimensions',
   'One warm share attempt per size does not establish deterministic reproduction','No Windows network send or 16GB transfer is attempted'],
  snapshots:[],actions:[],cases:[],editCases:[],cpuSamples:[],largeFixture:null,errors:[]};
 function decode(text){return text.replace(/&#x([0-9a-f]+);/gi,(_,n)=>String.fromCodePoint(parseInt(n,16)))
  .replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/&quot;/g,'"').replace(/&apos;/g,"'")
  .replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');}
 const nodes=xml=>[...xml.matchAll(/<[^/!?][^>]*>/g)].map(m=>Object.fromEntries(
  [...m[0].matchAll(/([\w.:-]+)=(["'])(.*?)\2/g)].map(a=>[a[1],decode(a[3])])));
 const labels=xml=>nodes(xml).flatMap(n=>[n.text||'',n['content-desc']||'']);
 const source=()=>wd('GET',base+'/source');
 async function snap(name,xml){
  const text=xml||await source();save(name+'.xml',text);
  const png=Buffer.from(await wd('GET',base+'/screenshot'),'base64');writeFileSync(path.join(directory,name+'.png'),png);
  assert(png.length>=24&&png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])),'Screenshot is not PNG');
  const metadata={name,utc:new Date().toISOString(),width:png.readUInt32BE(16),height:png.readUInt32BE(20),
   primarypackage:nodes(text).find(n=>n.package)?.package||null};
  report.snapshots.push(metadata);return {xml:text,...metadata};
 }
 async function waitFor(predicate,timeout,message){
  const deadline=Date.now()+timeout;
  do{const xml=await source();if(predicate(xml))return xml;await sleep(1000);}while(Date.now()<deadline);
  throw Error(message);
 }
 function id(element){const value=element['element-6066-11e4-a52e-4f735466cecf']||element.ELEMENT;assert(value,'Missing WebDriver element ID');return value;}
 async function bounds(using,value){
  const element=await wd('POST',base+'/element',{using,value});
  const rect=await wd('GET',base+'/element/'+id(element)+'/rect');
  assert(rect.width>0&&rect.height>0,'Observed control has no area: '+value);return rect;
 }
 async function touch(rect,label,screen){
  if(screen)assert(rect.x>=0&&rect.y>=0&&rect.x+rect.width<=screen.width&&rect.y+rect.height<=screen.height,'Observed control bounds leave the captured screen: '+label);
  report.actions.push({utc:new Date().toISOString(),label,rect});
  await wd('POST',base+'/actions',{actions:[{type:'pointer',id:'share3556',parameters:{pointerType:'touch'},actions:[
   {type:'pointerMove',duration:0,origin:'viewport',x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)},
   {type:'pointerDown',button:0},{type:'pause',duration:120},{type:'pointerUp',button:0}]}]});
 }
 const click=async name=>touch(await bounds('accessibility id',name),name);
 const ui=async expression=>touch(await bounds('-android uiautomator','new UiSelector().'+expression),expression);
 async function helperClick(name){
  await wd('POST',base+'/element',{using:'-android uiautomator',value:'new UiScrollable(new UiSelector().scrollable(true)).scrollIntoView(new UiSelector().description('+JSON.stringify(name)+'))'});
  await click(name);
 }
 async function activate(appId){
  await wd('POST',base+'/appium/device/activate_app',{appId});
  await wd('POST',base+'/orientation',{orientation:'PORTRAIT'});
  report.actions.push({utc:new Date().toISOString(),label:'Request portrait after activation',appId,observedOrientation:await wd('GET',base+'/orientation')});
 }
 async function warmReset(name){
  await wd('POST',base+'/appium/device/terminate_app',{appId:'org.localsend.localsend_app',options:{timeout:5000}});
  await activate('org.localsend.localsend_app');
  await waitFor(s=>labels(s).includes('Send\nTab 2 of 3'),30000,'Original LocalSend Send tab not available after warm restart');
  await click('Send\nTab 2 of 3');
  const before=await snap(name+'-before'),manual=await bounds('accessibility id','Manual sending');
  return {before,manual};
 }
 function parseFixture(xml,expectedBytes){
  const details=labels(xml).find(v=>v.includes('READY name='));assert(details,'Fixture READY metadata missing');
  const name=details.match(/READY name=([^\n]+)/)?.[1],uri=details.match(/\nuri=([^\n]+)/)?.[1];
  const bytes=Number(details.match(/\nbytes=(\d+)/)?.[1]),sha256=details.match(/\nsha256=([a-f0-9]{64})/)?.[1];
  const mediaDurationMs=Number(details.match(/mediaDurationMs=(\d+)/)?.[1]),frame=details.match(/decodedFrame=(\d+)x(\d+)/);
  const availableBytes=Number(details.match(/availableBytes=(\d+)/)?.[1]);
  assert(name?.endsWith('.mp4')&&uri?.startsWith('content://media/')&&sha256,'Expected this helper owned public MediaStore MP4');
  assert.equal(bytes,expectedBytes,'Unexpected fixture size');assert(mediaDurationMs>0&&frame&&Number(frame[1])>0&&Number(frame[2])>0,'Fixture video did not decode');
  return {name,uri,bytes,sha256,mediaDurationMs,decodedFrame:{width:Number(frame[1]),height:Number(frame[2])},availableBytes,details};
 }
 function selected(xml,bytes){
  return labels(xml).some(v=>v.includes('Selection\nFiles: 1\nSize: '+(bytes===1048576?'1.0 MB':'16.0 GB')));
 }
 function manualResponse(xml){
  const text=labels(xml);
  if(text.includes('Enter address'))return 'Enter address';
  // The supported Manual sending route first opens AddFileDialog when selection is not ready.
  if(text.includes('Add to selection'))return 'Add to selection';
  return null;
 }
 let cpuUnavailable=false,cpuSupported=false;
 async function sampleCpu(stage){
  if(cpuUnavailable)return;
  const sample={stage,utc:new Date().toISOString(),packageName:'org.localsend.localsend_app',dataType:'cpuinfo'};
  const started=Date.now();
  try{
   if(!cpuSupported){
    sample.advertisedTypes=await wd('POST',base+'/execute/sync',{script:'mobile: getPerformanceDataTypes',args:[]});
    assert(Array.isArray(sample.advertisedTypes)&&sample.advertisedTypes.includes('cpuinfo'),'Appium does not advertise cpuinfo');
    cpuSupported=true;
   }
   sample.raw=await wd('POST',base+'/execute/sync',{script:'mobile: getPerformanceData',args:[{packageName:sample.packageName,dataType:'cpuinfo'}]});
   sample.status='returned';
  }catch(error){sample.status='unavailable';sample.error=redact(error.message);cpuUnavailable=true;}
  sample.requestDurationMs=Date.now()-started;
  sample.limit='Appium package cpuinfo at this instant; raw headers and values are retained without assuming units or whole-device CPU';
  report.cpuSamples.push(sample);save('cpu-samples.json',report.cpuSamples);
 }
 const hasLabel=(xml,name)=>labels(xml).some(v=>v===name||v.split('\n').includes(name));
 const hasFile=(xml,name)=>labels(xml).some(v=>v===name||v.split('\n').includes(name));
 async function closeObservedEditor(fixture,name){
  let xml=await source();
  if(manualResponse(xml)){
   assert(hasLabel(xml,'Cancel'),'Open input route exposes no observed Cancel');
   await click('Cancel');xml=await waitFor(s=>!manualResponse(s),10000,'Manual dialog did not close');
  }
  // Back here is the visible Flutter navigation control, never the native Back key.
  if(hasFile(xml,fixture.name)||!selected(xml,fixture.bytes)){
   const close=['Cancel','Close','Back'].find(label=>hasLabel(xml,label));
   assert(close,'Editor exposes no semantic Cancel, Close, or Back; no blind dismissal attempted');
   const before=await snap(name+'-before-close',xml);
   await touch(await bounds('accessibility id',close),'Observed editor '+close,before);
   xml=await waitFor(s=>selected(s,fixture.bytes),10000,'Editor did not return to the original selection');
  }
  return xml;
 }
 async function manualCancel(entry,name,response,screen){
  const stage={name,response,startedUtc:new Date().toISOString(),status:'started'};
  (entry.inputStages??=[]).push(stage);save(name+'-result.json',stage);
  try{
   if(response==='Enter address'){
    assert(nodes(screen.xml).filter(n=>n.class==='android.widget.EditText').length===1,'Manual route does not expose exactly one input');
    const field=await wd('POST',base+'/element',{using:'class name',value:'android.widget.EditText'}),fieldId=id(field);
    await touch(await wd('GET',base+'/element/'+fieldId+'/rect'),'Focus observed Manual address input',screen);
    assert.equal(await wd('GET',base+'/element/'+fieldId+'/attribute/focused'),'true','Manual address input did not gain focus');
    await snap(name+'-focused');
    await wd('POST',base+'/element/'+fieldId+'/clear',{});
    await wd('POST',base+'/element/'+fieldId+'/value',{text:'127.0.0.1',value:[...'127.0.0.1']});
    screen=await snap(name+'-typed');
    assert(nodes(screen.xml).some(n=>n.class==='android.widget.EditText'&&n.text==='127.0.0.1'),'Manual input value was not rendered');
    stage.inputReadbackVerified=true;
    stage.visualEvidence=name+'-typed.png';
   }
   const dismiss=['Cancel','Close'].find(label=>hasLabel(screen.xml,label));
   assert(dismiss,'Observed dialog offers no Cancel or Close');
   await touch(await bounds('accessibility id',dismiss),'Observed '+response+' '+dismiss,screen);
   await snap(name+'-dismissed',await waitFor(s=>!manualResponse(s),10000,'Observed Manual dialog did not dismiss'));
   stage.status='input-route-dismissed';stage.dismiss=dismiss;
  }catch(error){stage.status='incomplete';stage.error=redact(error.stack||error);throw error;}
  finally{stage.finishedUtc=new Date().toISOString();save(name+'-result.json',stage);save('progress.json',report);}
 }
 async function editCancel(fixture,name){
  const entry={name,fixture,startedUtc:new Date().toISOString(),status:'started',scope:'Original v1.18.2 MP4 Selection Edit opens file management, with visible Back; it has no filename input'};
  report.editCases.push(entry);save(name+'-result.json',entry);
  try{
   await warmReset(name+'-file-selection');
   await click('File');
   await waitFor(s=>s.includes('com.google.android.documentsui'),30000,'Android File picker did not appear');
   await snap(name+'-file-picker');await click('Show roots');
   const roots=await snap(name+'-file-picker-roots');
   const recent=nodes(roots.xml).filter(n=>n.text==='Recent');assert(recent.length,'Recent root not observed');
   await ui('text("Recent").instance('+(recent.length-1)+')');
   const picker=await snap(name+'-file-picker-recent');
   assert(nodes(picker.xml).filter(n=>n.text===fixture.name).length===1,'Recent picker does not show one exact owned fixture filename');
   await touch(await bounds('-android uiautomator','new UiSelector().text('+JSON.stringify(fixture.name)+')'),'Observed owned fixture File/Recent selection',picker);
   let xml=await waitFor(s=>selected(s,fixture.bytes),60000,'File/Recent did not show one selected fixture with expected size');
   entry.fileSelectionObserved=true;save(name+'-result.json',entry);
   const before=await snap(name+'-before',xml);
   await sampleCpu(name+'-before-edit');
   await touch(await bounds('accessibility id','Edit'),'Observed selection Edit',before);
   xml=await waitFor(s=>hasFile(s,fixture.name)&&hasLabel(s,'Back'),15000,'Edit did not expose the original filename and visible Back');
   await snap(name+'-opened',xml);entry.editResponseObserved=true;
   assert(hasFile(xml,fixture.name),'Editor does not show the original fixture filename');
   // The original MP4 route only offers removal and visible Back. Never invoke Delete or invent a rename route.
   entry.originalFilenameObserved=fixture.name;
   entry.filenameInput='Not part of the original MP4 Edit route';save(name+'-result.json',entry);
   await sampleCpu(name+'-editor-open');
   await closeObservedEditor(fixture,name);
   const returned=await snap(name+'-returned');
   assert(selected(returned.xml,fixture.bytes),'Original selection size missing after closing editor');
   // Reopen to verify filename identity, because the Send selection card only exposes count and size.
   await touch(await bounds('accessibility id','Edit'),'Reopen Edit to verify retained filename',returned);
   xml=await waitFor(s=>hasFile(s,fixture.name)&&hasLabel(s,'Back'),10000,'Retained filename and visible Back were not observed when reopening Edit');
   await snap(name+'-identity-retained',xml);entry.filenameRetained=true;
   await closeObservedEditor(fixture,name+'-identity-check');await snap(name+'-complete');
   entry.selectionRetained=true;entry.status='editor-opened-and-closed-filename-retained';
  }catch(error){
   entry.status='incomplete';entry.error=redact(error.stack||error);report.errors.push(name+': '+entry.error);
   await snap(name+'-failure').catch(e=>{entry.failureCaptureError=redact(e.message);});
   // Preserve independent share evidence and recover only through controls actually present.
   await closeObservedEditor(fixture,name+'-recovery').catch(e=>{entry.recoveryError=redact(e.message);});
  }finally{
   entry.finishedUtc=new Date().toISOString();save(name+'-result.json',entry);save('progress.json',report);
  }
 }
 async function warmShare(fixture,name,seconds){
  const entry={name,fixture,startedUtc:new Date().toISOString(),selectionObserved:false,manualResponse:null,waitActions:0,observations:[]};
  report.cases.push(entry);
  save(name+'-result.json',entry);
  try{
  await sampleCpu(name+'-before-share');
  const prepared=await warmReset(name);entry.before={width:prepared.before.width,height:prepared.before.height,manualBounds:prepared.manual};
  await activate('org.localsend.fixture3556');
  const ready=await snap(name+'-helper-before-share');const activeFixture=parseFixture(ready.xml,fixture.bytes);
  assert.equal(activeFixture.uri,fixture.uri,'Helper last URI changed before sharing');assert.equal(activeFixture.sha256,fixture.sha256);
  entry.nativeShareActionUtc=new Date().toISOString();await helperClick('Share owned fixture');await snap(name+'-chooser-loading');
  const chooser=await waitFor(s=>nodes(s).some(n=>n.text==='LocalSend'&&n.enabled==='true'&&n.displayed==='true'),60000,'Native Samsung chooser did not expose LocalSend within 60 seconds');
  await snap(name+'-chooser-ready',chooser);entry.chooserLocalSendInputUtc=new Date().toISOString();await ui('text("LocalSend")');
  const first=await snap(name+'-first-frame');entry.selectionObserved=selected(first.xml,fixture.bytes);
  // Do not touch old coordinates after a rotation or layout change. Re-observe the semantic control.
  const currentManual=await bounds('accessibility id','Manual sending').catch(()=>null);
  entry.layoutComparison={before:{width:prepared.before.width,height:prepared.before.height,manual:prepared.manual},
   after:{width:first.width,height:first.height,manual:currentManual}};
  if(!currentManual){
   entry.nextInputUnavailableReason='Manual sending semantic bounds unavailable after native share; no stale coordinate input was sent';
  }
  const sameLayout=currentManual&&first.width===prepared.before.width&&first.height===prepared.before.height&&
   ['x','y','width','height'].every(k=>currentManual[k]===prepared.manual[k]);
  entry.layoutComparison.sameLayout=sameLayout;
  if(currentManual){
   try{await touch(currentManual,'Legitimate next Manual sending action after share',first);entry.nextInputUtc=new Date().toISOString();}
   catch(error){entry.nextInputUnavailableReason=redact(error.message);}
  }
  const start=Date.now(),deadline=start+seconds*1000;
  let selectionInputChecked=entry.selectionObserved&&Boolean(entry.nextInputUtc),index=0,nextCpu=0;
  do{
   const xml=await source(),names=labels(xml),anr=/isn.t responding|not responding/i.test(names.join('\n'));
   entry.selectionObserved=entry.selectionObserved||selected(xml,fixture.bytes);
   const response=manualResponse(xml);if(response)entry.manualResponse=response;
   const shot=await snap(name+'-observe-'+String(index++).padStart(3,'0'),xml);
   if(Date.now()>=nextCpu){await sampleCpu(name+'-observe-'+index);nextCpu=Date.now()+30000;}
   entry.observations.push({utc:shot.utc,elapsedMs:Date.now()-start,anr,selection:selected(xml,fixture.bytes),manualResponse:response,
    width:shot.width,height:shot.height,primarypackage:shot.primarypackage});
   if(anr){await ui('textMatches("(?i)wait")');entry.waitActions++;}
   else if(response){
    if(selectionInputChecked&&response==='Enter address')entry.responseAfterSelection=true;
    await manualCancel(entry,name+'-manual-cancel-'+index,response,shot);
   }
   // Require an actual response after a confirmed selection, not only an accessibility label.
   if(entry.selectionObserved&&!selectionInputChecked&&!response&&!anr){
    const live=await snap(name+'-selected-before-input');
    try{
     const rect=await bounds('accessibility id','Manual sending');
     await touch(rect,'Manual sending response check after observed selection',live);selectionInputChecked=true;
    }catch(error){entry.responseCheckUnavailableReason=redact(error.message);}
   }else if(selectionInputChecked&&response==='Enter address'){entry.responseAfterSelection=true;}
   save(name+'-result.json',entry);save('progress.json',report);
   if(Date.now()>=deadline)break;
   await sleep(Math.min(5000,deadline-Date.now()));
  }while(true);
  entry.finishedUtc=new Date().toISOString();
  entry.outcome=entry.waitActions?'anr-observed':entry.selectionObserved&&entry.responseAfterSelection?'selection-and-input-response-observed':'selection-or-input-response-not-established';
  save(name+'-result.json',entry);
  if(fixture.bytes===1048576)assert(entry.selectionObserved&&entry.responseAfterSelection,'Small share control did not establish Selection 1.0 MB and a real Enter address response');
  }catch(error){entry.outcome='incomplete';entry.error=redact(error.stack||error);throw error;}
  finally{entry.finishedUtc=new Date().toISOString();save(name+'-result.json',entry);save('progress.json',report);}
 }
 try{
  const windowsPath=path.join(path.resolve(output),'windows','results.json'),fixturePath=path.join(path.resolve(output),'fixture.json');
  assert(existsSync(windowsPath)&&existsSync(fixturePath),'Actual app control evidence must exist before this callback');
  const windows=JSON.parse(readFileSync(windowsPath,'utf8')),small=JSON.parse(readFileSync(fixturePath,'utf8'));
  assert.equal(windows.status,'saved-file-verified','Actual Windows save control is not verified');
  assert(windows.actions.some(a=>a.name==='Accept')&&windows.savedFiles.some(f=>f.bytes===1048576&&f.sha256.toLowerCase()===small.sha256),'Actual control Accept/hash evidence missing');
  const initialLabels=labels(await source());
  assert(initialLabels.some(v=>/^(?:100,\s*)?Finished$/.test(v.split('\n')[0].trim()))&&!initialLabels.some(v=>v.includes('Finished with error')),'Existing Android session does not show actual control Finished or 100, Finished');
  await activate('org.localsend.fixture3556');
  const helper=await snap('small-owned-fixture');const fixture=parseFixture(helper.xml,1048576);
  assert.equal(fixture.sha256,small.sha256,'Share control must use the successful actual transfer fixture');
  report.actualControlPrecondition={verified:true,bytes:1048576,sha256:fixture.sha256};
  await editCancel(fixture,'small-edit-cancel');
  await warmShare(fixture,'small-share-control',30);
  await activate('org.localsend.fixture3556');await helperClick('Refresh capacity');
  const capacity=await snap('large-capacity-before'),text=labels(capacity.xml).join('\n');
  const beforeFree=Number(text.match(/availableBytes=(\d+)/)?.[1]);
  assert(beforeFree>=16000000000+2147483648,'16GB public MediaStore staging requires its existing 2 GiB reserve');
  report.largeCapacityBeforeBytes=beforeFree;
  report.largeStaging={status:'staging',startedUtc:new Date().toISOString(),beforeFreeBytes:beforeFree,expectedBytes:16000000000};
  save('large-staging-result.json',report.largeStaging);
  await helperClick('Stage 16GB video');const deadline=Date.now()+1800000;let staged,index=0,nextScreenshot=0;
  do{
   const xml=await source(),details=labels(xml).join('\n');
   save('large-staging-'+String(index++).padStart(3,'0')+'.xml',xml);
   if(/FAILED|INSUFFICIENT_STORAGE/.test(details))throw Error('Large fixture staging failed through the public helper UI');
   if(/READY name=.*16000000000\.mp4/.test(details)){staged=xml;break;}
   if(Date.now()>=nextScreenshot){await snap('large-staging-screen-'+index,xml);nextScreenshot=Date.now()+30000;}
   report.largeStaging.observations=index;report.largeStaging.lastObservedUtc=new Date().toISOString();
   save('large-staging-result.json',report.largeStaging);
   save('progress.json',report);await sleep(3000);
  }while(Date.now()<deadline);
  assert(staged,'16GB public fixture staging exceeded 30 minutes');
  await snap('large-fixture-ready',staged);const large=parseFixture(staged,16000000000);
  assert(large.availableBytes>=2147483648,'16GB staging did not retain the required free-space reserve');
  report.largeFixture=large;save('large-fixture.json',large);
  report.largeStaging.status='ready';report.largeStaging.finishedUtc=new Date().toISOString();report.largeStaging.fixture=large;
  save('large-staging-result.json',report.largeStaging);
  await editCancel(large,'large-edit-cancel');
  await warmShare(large,'large-share-warm',300);
  report.status=report.errors.length?'observed-with-incomplete-stages':'observed';report.finishedUtc=new Date().toISOString();return report;
 }catch(error){
  report.status='incomplete';report.errors.push(redact(error.stack||error));
  if(report.largeStaging?.status==='staging'){
   report.largeStaging.status='incomplete';report.largeStaging.error=redact(error.stack||error);
   report.largeStaging.finishedUtc=new Date().toISOString();save('large-staging-result.json',report.largeStaging);
  }
  await snap('failure').catch(e=>report.errors.push('Failure capture: '+redact(e.message)));
  throw error;
 }finally{
  report.finishedUtc=new Date().toISOString();save('results.json',report);
  save('limits.txt',report.scope+'\n'+report.hypothesis+'\n'+report.limits.join('\n'));
 }
}
