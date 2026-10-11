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
  scope:'Warm native chooser sharing and actual next UI input, after a verified 1 MiB Android-to-Windows transfer; no 16GB network transfer',
  hypothesis:'A share_handler MediaStore copy on the main thread is unproven. This module observes the unmodified app without injecting a stall.',
  limits:['Public MediaStore fixtures differ from the reporter original file','Requested portrait may not persist; record actual screenshot dimensions',
   'One warm share attempt per size does not establish deterministic reproduction','No Windows network send or 16GB transfer is attempted'],
  snapshots:[],actions:[],cases:[],largeFixture:null,errors:[]};
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
 async function warmShare(fixture,name,seconds){
  const entry={name,fixture,startedUtc:new Date().toISOString(),selectionObserved:false,manualResponse:null,waitActions:0,observations:[]};
  report.cases.push(entry);
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
   try{await touch(sameLayout?prepared.manual:currentManual,'Legitimate next Manual sending action after share',first);entry.nextInputUtc=new Date().toISOString();}
   catch(error){entry.nextInputUnavailableReason=redact(error.message);}
  }
  const start=Date.now(),deadline=start+seconds*1000;
  let canceledResponse=false,selectionInputChecked=false,index=0;
  do{
   const xml=await source(),names=labels(xml),anr=/isn.t responding|not responding/i.test(names.join('\n'));
   entry.selectionObserved=entry.selectionObserved||selected(xml,fixture.bytes);
   const response=manualResponse(xml);if(response)entry.manualResponse=response;
   const shot=await snap(name+'-observe-'+String(index++).padStart(3,'0'),xml);
   entry.observations.push({utc:shot.utc,elapsedMs:Date.now()-start,anr,selection:selected(xml,fixture.bytes),manualResponse:response,
    width:shot.width,height:shot.height,primarypackage:shot.primarypackage});
   if(anr){await ui('textMatches("(?i)wait")');entry.waitActions++;}
   else if(response&&!canceledResponse){await click('Cancel');canceledResponse=true;}
   // Require an actual response after a confirmed selection, not only an accessibility label.
   if(entry.selectionObserved&&!selectionInputChecked&&!response&&!anr){
    const live=await snap(name+'-selected-before-input');
    try{
     const rect=await bounds('accessibility id','Manual sending');
     await touch(rect,'Manual sending response check after observed selection',live);selectionInputChecked=true;
    }catch(error){entry.responseCheckUnavailableReason=redact(error.message);}
   }else if(selectionInputChecked&&response==='Enter address'){entry.responseAfterSelection=true;}
   save('progress.json',report);
   if(Date.now()>=deadline)break;
   await sleep(Math.min(5000,deadline-Date.now()));
  }while(true);
  entry.finishedUtc=new Date().toISOString();
  entry.outcome=entry.waitActions?'anr-observed':entry.selectionObserved&&entry.responseAfterSelection?'selection-and-input-response-observed':'selection-or-input-response-not-established';
  save(name+'-result.json',entry);
  if(fixture.bytes===1048576)assert(entry.selectionObserved&&entry.responseAfterSelection,'Small share control did not establish Selection 1.0 MB and a real Enter address response');
 }
 try{
  const windowsPath=path.join(path.resolve(output),'windows','results.json'),fixturePath=path.join(path.resolve(output),'fixture.json');
  assert(existsSync(windowsPath)&&existsSync(fixturePath),'Actual app control evidence must exist before this callback');
  const windows=JSON.parse(readFileSync(windowsPath,'utf8')),small=JSON.parse(readFileSync(fixturePath,'utf8'));
  assert.equal(windows.status,'saved-file-verified','Actual Windows save control is not verified');
  assert(windows.actions.some(a=>a.name==='Accept')&&windows.savedFiles.some(f=>f.bytes===1048576&&f.sha256.toLowerCase()===small.sha256),'Actual control Accept/hash evidence missing');
  const initialLabels=labels(await source());
  assert(initialLabels.some(v=>v==='Finished'||v.startsWith('Finished\n'))&&!initialLabels.some(v=>v.includes('Finished with error')),'Existing Android session does not show actual control Finished');
  await activate('org.localsend.fixture3556');
  const helper=await snap('small-owned-fixture');const fixture=parseFixture(helper.xml,1048576);
  assert.equal(fixture.sha256,small.sha256,'Share control must use the successful actual transfer fixture');
  report.actualControlPrecondition={verified:true,bytes:1048576,sha256:fixture.sha256};
  await warmShare(fixture,'small-share-control',30);
  await activate('org.localsend.fixture3556');await helperClick('Refresh capacity');
  const capacity=await snap('large-capacity-before'),text=labels(capacity.xml).join('\n');
  const beforeFree=Number(text.match(/availableBytes=(\d+)/)?.[1]);
  assert(beforeFree>=16000000000+2147483648,'16GB public MediaStore staging requires its existing 2 GiB reserve');
  report.largeCapacityBeforeBytes=beforeFree;
  await helperClick('Stage 16GB video');const deadline=Date.now()+1800000;let staged,index=0,nextScreenshot=0;
  do{
   const xml=await source(),details=labels(xml).join('\n');
   save('large-staging-'+String(index++).padStart(3,'0')+'.xml',xml);
   if(/FAILED|INSUFFICIENT_STORAGE/.test(details))throw Error('Large fixture staging failed through the public helper UI');
   if(/READY name=.*16000000000\.mp4/.test(details)){staged=xml;break;}
   if(Date.now()>=nextScreenshot){await snap('large-staging-screen-'+index,xml);nextScreenshot=Date.now()+30000;}
   save('progress.json',report);await sleep(3000);
  }while(Date.now()<deadline);
  assert(staged,'16GB public fixture staging exceeded 30 minutes');
  await snap('large-fixture-ready',staged);const large=parseFixture(staged,16000000000);
  assert(large.availableBytes>=2147483648,'16GB staging did not retain the required free-space reserve');
  report.largeFixture=large;save('large-fixture.json',large);
  await warmShare(large,'large-share-warm',300);
  report.status='observed';report.finishedUtc=new Date().toISOString();return report;
 }catch(error){
  report.status='incomplete';report.errors.push(redact(error.stack||error));
  await snap('failure').catch(e=>report.errors.push('Failure capture: '+redact(e.message)));
  throw error;
 }finally{
  report.finishedUtc=new Date().toISOString();save('results.json',report);
  save('limits.txt',report.scope+'\n'+report.hypothesis+'\n'+report.limits.join('\n'));
 }
}
