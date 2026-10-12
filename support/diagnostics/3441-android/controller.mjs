import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,appendFileSync,mkdirSync,existsSync,renameSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import path from 'node:path';
import {retainProviderArtifacts} from './provider-artifacts.mjs';

const original='org.localsend.localsend_app',fixture='org.localsend.fixture3441',transport='org.localsend.cloudtransport';
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function decode(value) {return value.replace(/&#x([a-f0-9]+);/gi,(_,n)=>String.fromCodePoint(parseInt(n,16))).replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');}
// Appium chooses single quotes when an attribute contains the fixture JSON's double quotes.
const nodes=xml=>[...xml.matchAll(/<[^/!?][^>]*>/g)].map(m=>Object.fromEntries([...m[0].matchAll(/([\w.:-]+)=(["'])([\s\S]*?)\2/g)].map(a=>[a[1],decode(a[3])])));
const label=n=>n['content-desc']||n.text||'';
const rect=n=>{const m=n.bounds?.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);assert(m,'UI bounds missing');return {x:+m[1],y:+m[2],width:+m[3]-m[1],height:+m[4]-m[2]};};
const elementId=e=>e['element-6066-11e4-a52e-4f735466cecf']||e.ELEMENT;

export async function runAndroidSender({output,fixtureDirectory,receiver}) {
 assert(process.env.GITHUB_RUN_ID&&process.env.ISSUE3441_ADMITTED==='1','Require explicit fork cloud transfer admission');
 const username=process.env.BROWSERSTACK_USERNAME||process.env.BS_SPRINT_USERNAME,key=process.env.BROWSERSTACK_ACCESS_KEY||process.env.BS_SPRINT_ACCESS_KEY;
 for(const name of ['HELPER_APP','BASELINE_APP','RELAY_APP','BS_LOCAL_ID','RELAY_TOKEN','BROWSERSTACK_LOCAL_BINARY','ISSUE3441_JOB_DEADLINE_UTC'])assert(process.env[name],name+' required');
 assert(username&&key,'BrowserStack credentials required');
 mkdirSync(output,{recursive:true});
 const secrets=[username,key,username+':'+key,Buffer.from(username+':'+key).toString('base64'),process.env.RELAY_TOKEN,process.env.HELPER_APP,process.env.BASELINE_APP,process.env.RELAY_APP];
 const redact=value=>{let text=String(value);for(const secret of secrets)text=text.replaceAll(secret,'[redacted]');return text.replace(/bs:\/\/[a-f0-9]+/gi,'[redacted app reference]');};
 const save=(name,value)=>writeFileSync(path.join(output,name),redact(typeof value==='string'?value:JSON.stringify(value,null,2)));
 const auth='Basic '+Buffer.from(username+':'+key).toString('base64');
 const manifest=JSON.parse(readFileSync(path.join(fixtureDirectory,'manifest.json'),'utf8'));
 const originalReceipt=JSON.parse(readFileSync(path.join(output,'original-android-apk.json'),'utf8'));
 assert(originalReceipt.sha256==='82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3'&&originalReceipt.bytes===46558706,'Original arm64 release identity required');
 assert(originalReceipt.uploadReferenceSha256===createHash('sha256').update(process.env.BASELINE_APP).digest('hex'),'Baseline provider reference must be bound to verified APK bytes');
 const cases=manifest.cases;
 assert.deepEqual(cases.map(c=>c.id),['control','initial207','retry73']);
 assert.deepEqual(cases.map(c=>c.names.length),[1,207,73]);
 const files=new Map(manifest.files.map(f=>[f.name,f]));assert(files.size===manifest.files.length,'Source names must be distinct');
 for(const c of cases) {
  assert(new Set(c.names).size===c.names.length&&c.names.every(name=>files.has(name)),'Invalid case source identity');
  for(const name of c.names){const f=files.get(name),bytes=readFileSync(path.join(fixtureDirectory,name));assert(bytes.length===f.bytes&&createHash('sha256').update(bytes).digest('hex')===f.sha256,'Runner source identity differs: '+name);}
 }
 assert(cases[2].names.every(name=>cases[1].names.includes(name)),'Retry must reselect original sources');
 assert(cases[2].names.reduce((sum,name)=>sum+files.get(name).bytes,0)===85600000,'Retry declared bytes must be85,600,000');
 const report={status:'preparing',startedUtc:new Date().toISOString(),cases:[],actions:[],cleanupErrors:[],boundaries:['Samsung S23 Android13 differs from original Samsung model unspecified','Actual OneUI version requires native evidence','macOS15 cloud arm64 differs from reported M1 macOS12.7.6','Opaque reverse TLS cloud route differs from reported LAN','Generated207 media differ from unavailable original media; reported69 first save was approximate']};
 let session,tunnel,tunnelExited,tunnelExitPromise,sourceReads=0,screenshots=0,createAttempted=false,cleaning=false;
 const started=Date.now(),jobDeadline=Date.parse(process.env.ISSUE3441_JOB_DEADLINE_UTC);
 assert(Number.isFinite(jobDeadline)&&jobDeadline-started>=20*60000,'Require actual job deadline with20minutesremaining before allocation');
 assert(/^\d+$/.test(process.env.GITHUB_RUN_ID)&&/^\d+$/.test(process.env.GITHUB_RUN_ATTEMPT),'Run and attempt must be numeric');
 const deadline=jobDeadline-10*60000,cleanupDeadline=jobDeadline-8*60000,buildName='issue3441-'+process.env.GITHUB_RUN_ID+'-attempt-'+process.env.GITHUB_RUN_ATTEMPT;
 const privatePrefix=buildName+'-';
 const ownership={runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT,buildName,localIdentifier:process.env.BS_LOCAL_ID,creationAttempted:false,session:null,tunnel:null};
 const persistOwnership=()=>{const target=path.join(output,'android-ownership.json');writeFileSync(target+'.tmp',JSON.stringify(ownership,null,2));renameSync(target+'.tmp',target);};
 persistOwnership();
 report.budget={totalMaximumMinutes:45,scenarioMaximumMinutes:35,controllerCleanupMinutes:2,externalCleanupAndUploadReservedMinutes:8,remainingJobMs:jobDeadline-started,scenarioDeadlineUtc:new Date(deadline).toISOString(),cleanupDeadlineUtc:new Date(cleanupDeadline).toISOString()};
 report.stages=[];
 const stage=(name,detail={})=>{report.stages.push({name,utc:new Date().toISOString(),ageMs:Date.now()-started,scenarioRemainingMs:Math.max(0,deadline-Date.now()),sourceReads,screenshots,...detail});save('android-stage-budget.json',report.stages);};
 const base=()=>'/session/'+session;
 async function api(url) {const remaining=(cleaning?cleanupDeadline:deadline)-Date.now();assert(remaining>0,'Provider API budget expired');const response=await fetch('https://api-cloud.browserstack.com/app-automate/'+url,{headers:{authorization:auth},signal:AbortSignal.timeout(Math.min(cleaning?10000:30000,remaining))});assert(response.ok,'Provider API HTTP '+response.status);return response.json();}
 async function wd(method,url,body) {
  assert(Date.now()<(cleaning?cleanupDeadline:deadline),'Owned session budget expired');
  const time=Date.now(),timeout=Math.max(1,Math.min(cleaning?10000:url==='/session'?180000:45000,(cleaning?cleanupDeadline:deadline)-time));
  const response=await fetch('https://hub-cloud.browserstack.com/wd/hub'+url,{method,headers:{authorization:auth,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(timeout)});
  const json=await response.json();appendFileSync(path.join(output,'android-commands.jsonl'),redact(JSON.stringify({utc:new Date(time).toISOString(),method,path:url,status:response.status,elapsedMs:Date.now()-time,body:url==='/session'?'[private capability references]':body}))+'\n');
  assert(response.ok&&!json.value?.error,'WebDriver HTTP '+response.status+' '+redact(json.value?.error||''));return json.value;
 }
 async function source(){assert(++sourceReads<=1800,'Hierarchy budget exhausted');return wd('GET',base()+'/source');}
 async function snap(name,xml){save(name+'.xml',xml||await source());assert(++screenshots<=90,'Screenshot budget exhausted');const png=Buffer.from(await wd('GET',base()+'/screenshot'),'base64');writeFileSync(path.join(output,name+'.png'),png);assert(png.length>=24&&png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])),'Provider screenshot is not PNG');return {width:png.readUInt32BE(16),height:png.readUInt32BE(20)};}
 async function wait(predicate,timeout=30000){const end=Math.min(deadline,Date.now()+timeout);do{const xml=await source();if(predicate(xml))return xml;await sleep(Math.min(timeout>60000?3000:750,Math.max(0,end-Date.now())));}while(Date.now()<end);throw Error('Expected observable UI not reached');}
 let activePackage,activationCount=0,touchCount=0,establishedUi;
 function geometry(xml,viewport) {
  const root=nodes(xml).find(n=>n.class==='hierarchy');
  const width=Number(root?.width),height=Number(root?.height),rotation=Number(root?.rotation);
  if(!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=width||rotation!==0||viewport.width!==width||viewport.height<height||viewport.width>=viewport.height)return null;
  return {width,height,rotation,viewport};
 }
 const inBounds=(r,g)=>r.width>0&&r.height>0&&r.x>=0&&r.y>=0&&r.x+r.width<=g.width&&r.y+r.height<=g.height;
 async function settledUi(expectedPackage,selector,timeout=20000) {
  const end=Math.min(deadline,Date.now()+timeout);let previousKey,observed;
  do {
   const currentPackage=await wd('GET',base()+'/appium/device/current_package');
   const orientation=await wd('GET',base()+'/orientation');
   const viewport=await wd('GET',base()+'/window/rect');
   const xml=await source(),g=geometry(xml,viewport);
   const candidates=selector?nodes(xml).filter(selector):[];
   const control=candidates.length===1?candidates[0]:null;
   const valid=currentPackage===expectedPackage&&orientation==='PORTRAIT'&&g&&(!selector||control&&control.package===expectedPackage&&control.enabled!=='false'&&control.displayed!=='false'&&inBounds(rect(control),g));
   const key=valid?JSON.stringify({currentPackage,orientation,g,bounds:control?.bounds,label:control?label(control):null}):null;
   observed={xml,currentPackage,orientation,geometry:g,control,key};
   if(key&&key===previousKey){establishedUi=observed;return observed;}
   previousKey=key;await sleep(Math.min(500,Math.max(0,end-Date.now())));
  }while(Date.now()<end);
  if(observed)save('ui-settlement-failure.xml',observed.xml);
  throw Error('Expected active package, portrait geometry and exact in-bounds control did not settle');
 }
 async function tapNode(node,reason,{expectedPackage=activePackage,selectIndicator=false}={}) {
  const selector=n=>label(n)===label(node)&&n.class===node.class&&(!node['resource-id']||n['resource-id']===node['resource-id'])&&Boolean(n.bounds);
  let state;
  if(selectIndicator&&establishedUi?.currentPackage===expectedPackage) {
   // Fresh native geometry/package checks reuse the established portrait context;
   // GET orientation takes about 2 seconds on this provider and is reserved for transitions.
   const xml=await source(),currentPackage=await wd('GET',base()+'/appium/device/current_package'),viewport=await wd('GET',base()+'/window/rect');
   const g=geometry(xml,viewport),matches=nodes(xml).filter(selector);
   if(currentPackage===expectedPackage&&g&&JSON.stringify(g)===JSON.stringify(establishedUi.geometry)&&matches.length===1&&matches[0].package===expectedPackage&&matches[0].enabled==='true'&&matches[0].displayed==='true'&&matches[0].selected!=='true'&&inBounds(rect(matches[0]),g))
    state={xml,currentPackage,orientation:establishedUi.orientation,geometry:g,control:matches[0],orientationObservation:'Established at full transition guard; live root rotation/dimensions and package checked for this touch'};
  }
  if(!state)state=await settledUi(expectedPackage,selector);
  const name='touch-'+String(++touchCount).padStart(4,'0')+'-before';save(name+'.xml',state.xml);
  let preActionScreenshot,pixelGeometry;
  if(!reason.startsWith('Select Media source ')) {
   let matches=false;
   for(let attempt=0;attempt<3;attempt++) {
    const screenshotName=name+'-observation-'+attempt;pixelGeometry=await snap(screenshotName,state.xml);
    const fresh=await settledUi(expectedPackage,selector);
    // Keep the pictured exact control and the final coordinates in the same observed layout.
    matches=fresh.key===state.key&&pixelGeometry.width===fresh.geometry.width&&pixelGeometry.height>=fresh.geometry.height&&pixelGeometry.width<pixelGeometry.height;
    state=fresh;if(matches){preActionScreenshot=screenshotName+'.png';break;}
   }
   assert(matches,'Exact pre-touch screenshot and fresh portrait control did not agree');save(name+'-final.xml',state.xml);
  }
  const r=rect(state.control);assert(inBounds(r,state.geometry),'Exact touch control exceeds observed portrait bounds');
  if(selectIndicator) {
   assert(state.control.selected!=='true','Fresh source is already selected; do not toggle it');
   assert(Math.abs(r.width-r.height)<=1,'Fresh media cell is clipped; do not infer its indicator position');
  }
  // v1.18.2 pins picker10.1.3: gridCount4, indicatorSize=width/4/3,
  // top/end selector outer hitbox=indicatorSize*1.5 including its margins.
  const indicatorOffset=state.geometry.width/4/3*.75;
  const x=Math.round(selectIndicator?r.x+r.width-indicatorOffset:r.x+r.width/2),y=Math.round(selectIndicator?r.y+indicatorOffset:r.y+r.height/2);
  assert(x>=r.x&&x<r.x+r.width&&y>=r.y&&y<r.y+r.height,'Source-defined touch target exceeds exact control');
  assert(x>=0&&x<state.geometry.width&&y>=0&&y<state.geometry.height,'Exact touch center is outside the observed viewport');
  report.actions.push({utc:new Date().toISOString(),reason,label:label(state.control),rect:r,touchPoint:{x,y},target:selectIndicator?'picker10.1.3 top/end selectIndicator hitbox':'exact control center',geometry:state.geometry,currentPackage:state.currentPackage,orientation:state.orientation,orientationObservation:state.orientationObservation||'Fresh full settlement',preActionXml:name+(reason.startsWith('Select Media source ')?'.xml':'-final.xml'),preActionScreenshot,pixelGeometry});
  await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'finger3441',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,origin:'viewport',x,y},{type:'pointerDown',button:0},{type:'pause',duration:100},{type:'pointerUp',button:0}]}]});
 }
 async function click(exact){const xml=await source(),matches=nodes(xml).filter(n=>label(n)===exact&&n.enabled!=='false'&&n.bounds);assert(matches.length===1,'Expected one visible control: '+exact);await tapNode(matches[0],exact);}
 async function activate(appId){await wd('POST',base()+'/appium/device/activate_app',{appId});await wd('POST',base()+'/orientation',{orientation:'PORTRAIT'});activePackage=appId;const state=await settledUi(appId);await snap('activation-'+String(++activationCount).padStart(2,'0')+'-settled',state.xml);}
 async function configureFavorite(){
  await click('Favorites');await click('Add');
  const all=await wd('POST',base()+'/elements',{using:'class name',value:'android.widget.EditText'});assert(all.length===3,'Favorite requires three observed fields');
  const fields=[];for(const item of all){const id=elementId(item);fields.push({id,rect:await wd('GET',base()+'/element/'+id+'/rect')});}fields.sort((a,b)=>a.rect.y-b.rect.y);
  const values=['issue3441-cloud-receiver','127.0.0.1','53318'];
  for(const i of [2,0,1]) {
   const text=values[i];report.actions.push({utc:new Date().toISOString(),reason:'Focus favorite field',index:i,rect:fields[i].rect});
   await wd('POST',base()+'/element/'+fields[i].id+'/click',{});
   assert(await wd('GET',base()+'/element/'+fields[i].id+'/attribute/focused')==='true','Favorite field did not gain focus');
   await wd('POST',base()+'/element/'+fields[i].id+'/clear',{});await wd('POST',base()+'/element/'+fields[i].id+'/value',{text,value:[...text]});
   assert(await wd('GET',base()+'/element/'+fields[i].id+'/text')===text,'Favorite field value changed');
  }
  await wd('POST',base()+'/element/'+fields[0].id+'/click',{});
  for(let i=0;i<3;i++)assert(await wd('GET',base()+'/element/'+fields[i].id+'/text')===values[i],'Favorite value changed after blur');
  await snap('favorite-filled');await click('Confirm');await wait(xml=>nodes(xml).some(n=>label(n).includes('issue3441-cloud-receiver')));
 }
 async function selectMedia(c){
  await click('Media');
  let xml=await source();
  for(let attempt=0;attempt<3;attempt++) {
   const permission=nodes(xml).find(n=>n['resource-id']?.match(/permission_allow_(foreground_only_)?button$/));
   if(!permission)break;await snap(c.id+'-permission-'+attempt,xml);await tapNode(permission,'Allow normal media permission',{expectedPackage:permission.package});xml=await source();
  }
  await snap(c.id+'-picker-raw',xml);
  // Android exports the current path name, not the picker's onTapHint.
  const pathNames=new Set(['Recent',...manifest.cases.map(row=>'Issue3441_'+row.id)]);
  const pathMatch=n=>n.class==='android.view.View'&&n.package===original&&pathNames.has(label(n))&&n.clickable==='true'&&n.enabled==='true'&&n.displayed==='true';
  xml=await wait(value=>nodes(value).some(pathMatch));await snap(c.id+'-picker-open',xml);
  const pathControl=nodes(xml).filter(pathMatch);assert(pathControl.length===1,'Observed current path control must be unique');await tapNode(pathControl[0],'Open Media album selector');
  xml=await source();await snap(c.id+'-album-list-raw',xml);
  const albumLabel='Issue3441_'+c.id+', count: '+c.names.length;
  xml=await wait(value=>nodes(value).some(n=>label(n)===albumLabel));await snap(c.id+'-album-list',xml);
  const album=nodes(xml).filter(n=>label(n)===albumLabel&&n.clickable==='true'&&n.enabled==='true'&&n.displayed==='true');
  assert(album.length===1,'Exact source album name/count must be uniquely observable');await tapNode(album[0],'Select exact fixture album');
  await wait(value=>nodes(value).some(n=>pathMatch(n)&&label(n)==='Issue3441_'+c.id));
  const albumState=await settledUi(original);save(c.id+'-album-transition-settled.xml',albumState.xml);
  const selected=[],remaining=new Set(c.names);
  const mediaName=n=>/^(Image|Video)\d+, /.test(label(n))?label(n).split(', ').at(-1):null;
  for(let scroll=0;scroll<60&&remaining.size;scroll++) {
    xml=await source();save(c.id+'-grid-'+scroll+'.xml',xml);
    if(scroll===0)await snap(c.id+'-album-grid-raw',xml);
    const candidates=nodes(xml).filter(n=>remaining.has(mediaName(n))&&n.bounds&&n.clickable==='true'&&n.enabled==='true'&&n.displayed==='true'&&Math.abs(rect(n).width-rect(n).height)<=1);
    assert(new Set(candidates.map(mediaName)).size===candidates.length,'Duplicate observable exact media title');
    candidates.sort((a,b)=>rect(a).y-rect(b).y||rect(a).x-rect(b).x);
    for(const node of candidates) {
     const name=mediaName(node);assert(node.selected!=='true','Unexpected preselected source');
     await tapNode(node,'Select Media source '+name,{selectIndicator:true});
     let checked=await source();save(c.id+'-selected-'+(selected.length+1)+'-raw.xml',checked);
     const postSelected=value=>nodes(value).some(n=>mediaName(n)===name&&n.selected==='true')&&nodes(value).some(n=>label(n)==='Confirm ('+(selected.length+1)+'/999)'&&n.enabled==='true');
     if(!postSelected(checked))checked=await wait(postSelected,5000);
     save(c.id+'-selected-'+(selected.length+1)+'.xml',checked);
     assert(nodes(checked).some(n=>mediaName(n)===name&&n.selected==='true'),'Actual selector touch did not set selected state');
     assert(nodes(checked).some(n=>label(n)==='Confirm ('+(selected.length+1)+'/999)'&&n.enabled==='true'),'Picker selected count did not increment');
     const action=report.actions.at(-1);selected.push({order:selected.length+1,name,observedLabel:action.label,bounds:action.rect,touchPoint:action.touchPoint});remaining.delete(name);
     save(c.id+'-media-selection-order.json',selected);
    }
    if(!remaining.size)break;
    const swipeState=await settledUi(original),{width,height}=swipeState.geometry;
    save(c.id+'-scroll-before-'+selected.length+'-'+scroll+'.xml',swipeState.xml);
    await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'finger3441',parameters:{pointerType:'touch'},actions:[{type:'pointerMove',duration:0,x:Math.round(width/2),y:Math.round(height*.72)},{type:'pointerDown',button:0},{type:'pointerMove',duration:500,x:Math.round(width/2),y:Math.round(height*.32)},{type:'pointerUp',button:0}]}]});
  }
  assert(!remaining.size,'Exact expected media sources remain unselected: '+[...remaining].join(','));
  save(c.id+'-media-selection-order.json',selected);
  xml=await source();await snap(c.id+'-picker-selected',xml);const confirm=nodes(xml).filter(n=>label(n)==='Confirm ('+c.names.length+'/999)'&&n.enabled==='true'&&n.clickable==='true');
  assert(confirm.length===1,'Picker does not declare complete selected count before confirmation');await tapNode(confirm[0],'Confirm exact selected count');
  await snap(c.id+'-selection-return-raw');
  const summaryLines=value=>nodes(value).filter(n=>n.displayed!=='false').flatMap(n=>label(n).split(/\r?\n/)).map(line=>line.trim());
  const selectedApp=await wait(value=>{const lines=summaryLines(value);return lines.includes('Selection')&&lines.includes('Files: '+c.names.length)&&lines.some(line=>/^Size: \S/.test(line));});
  save(c.id+'-selection-summary.json',summaryLines(selectedApp).filter(line=>line==='Selection'||line.startsWith('Files: ')||line.startsWith('Size: ')));
  await snap(c.id+'-app-before-send',selectedApp);return selected;
 }
 try {
  const capacity=await api('plan.json');save('capacity-before-creation.json',{running:capacity.parallel_sessions_running,max:capacity.parallel_sessions_max_allowed});
  assert(capacity.parallel_sessions_running<Math.min(5,capacity.parallel_sessions_max_allowed),'No shared BrowserStack capacity');
  assert(existsSync(process.env.BROWSERSTACK_LOCAL_BINARY),'Cloud BrowserStackLocal binary missing');
  let localOutput='';tunnel=spawn(process.env.BROWSERSTACK_LOCAL_BINARY,['--key',key,'--local-identifier',process.env.BS_LOCAL_ID,'--only-automate'],{stdio:['ignore','pipe','pipe']});
  for(const stream of [tunnel.stdout,tunnel.stderr])stream.on('data',chunk=>{localOutput=(localOutput+redact(chunk.toString())).slice(-30000);});
  tunnelExitPromise=new Promise(resolve=>{tunnel.once('exit',code=>{tunnelExited=code;resolve();});tunnel.once('error',error=>{tunnelExited=-1;report.cleanupErrors.push('BrowserStackLocal spawn: '+redact(error.message));resolve();});});
  if(tunnel.pid){
   const identity=execFileSync('/bin/ps',['-p',String(tunnel.pid),'-o','lstart=','-o','comm='],{encoding:'utf8',timeout:3000}).trim();
   assert(identity,'Owned tunnel process identity unavailable');
   ownership.tunnel={pid:tunnel.pid,identity,binary:process.env.BROWSERSTACK_LOCAL_BINARY,localIdentifier:process.env.BS_LOCAL_ID};persistOwnership();
  }
  const localDeadline=Date.now()+60000;while(!/You can now access your local server/.test(localOutput)){assert(tunnelExited===undefined&&Date.now()<localDeadline,'BrowserStackLocal readiness not reached');await sleep(500);}
  save('local-tunnel-ready.txt',localOutput);
  stage('local-tunnel-ready');
  createAttempted=true;ownership.creationAttempted=true;persistOwnership();
  const created=await wd('POST','/session',{capabilities:{alwaysMatch:{platformName:'Android','appium:automationName':'UiAutomator2','appium:deviceName':'Samsung Galaxy S23','appium:platformVersion':'13.0','appium:app':process.env.HELPER_APP,'appium:otherApps':[process.env.BASELINE_APP,process.env.RELAY_APP],'appium:autoGrantPermissions':false,'appium:newCommandTimeout':300,'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,projectName:'LocalSend bug sprint',buildName,sessionName:'issue3441 original Media207+retry73',debug:true,video:true,networkLogs:false}},firstMatch:[{}]}});
  session=created.sessionId;assert(session,'Owned session ID missing');ownership.session=session;persistOwnership();save('session.json',{session,buildName});
  stage('owned-session-created');
  await activate(fixture);
  await click('Stage and verify all fixtures');
  const staged=await wait(xml=>{assert(!xml.includes('FIXTURE_FAILED'),'Native fixture staging failed');return xml.includes('FIXTURE_READY');},300000);
  const details=nodes(staged).filter(n=>label(n).startsWith('FIXTURE_READY\n'));assert(details.length===1,'Exactly one complete readback manifest must be observable');
  const actual=JSON.parse(label(details[0]).slice('FIXTURE_READY\n'.length));save('source-media-native-manifest.json',actual);
  assert(actual.files.length===manifest.files.length,'Native staged count mismatch');
  assert.deepEqual(actual.files.map(item=>item.name),manifest.files.map(item=>item.name),'Native source name/order mismatch');
  assert(new Set(actual.files.map(item=>item.uri)).size===actual.files.length,'Native source URIs must be distinct');
  for(const item of actual.files){const expected=files.get(item.name);assert(expected&&item.bytes===expected.bytes&&item.sha256===expected.sha256&&item.decodedWidth>0&&item.decodedHeight>0,'Native source hash/decode mismatch');}
  await snap('source-fixtures-verified',staged);
  stage('all208-native-readback-hash-and-decode-complete');
  await activate(transport);await click('Relay from LocalSend');
  let observedRelay;
  const relayReady=await wait(xml=>nodes(xml).some(n=>{
   const text=label(n),marker='HELPER_SERVICE_STATUS\n';if(!text.includes(marker))return false;
   observedRelay=JSON.parse(text.slice(text.indexOf(marker)+marker.length));
   save('opaque-helper-last-status.json',observedRelay);
   if(observedRelay.observationStatus==='failed'||observedRelay.observationStatus==='timed-out'||observedRelay.lastFailure&&!observedRelay.running)throw Error('Owned helper start failed; inspect its observed lifecycle/request status');
   return observedRelay.ready===true&&observedRelay.running===true&&observedRelay.servicePresent===true&&observedRelay.firstPullSucceeded===true&&observedRelay.listenerHost==='127.0.0.1'&&observedRelay.listenerPort===53318&&observedRelay.transport==='stream';
  }),45000);
  save('opaque-helper-service-ready.json',observedRelay);
  await snap('opaque-helper-ready',relayReady);await activate(original);await click('Send\nTab 2 of 3');
  for(const c of cases) {
   assert(deadline-Date.now()>({'control':5,'initial207':14,'retry73':8}[c.id])*60000,'Insufficient scenario budget before '+c.id+' selection; cleanup reserve preserved');
   stage(c.id+'-selection-start');
   await activate(fixture);await click('Expose '+c.id+' album');await wait(xml=>xml.includes('FIXTURE_CASE_READY')&&xml.includes(c.id));
   await snap(c.id+'-source-album');await activate(original);
   const selection=await selectMedia(c);
   stage(c.id+'-selection-complete',{selectedCount:selection.length});
   assert(deadline-Date.now()>(c.id==='control'?2:4)*60000,'Insufficient scenario budget before actual Send');
   await receiver.startCase(c.id);
   if(c.id==='control')await configureFavorite();else await click('Favorites');
   const xml=await source(),target=nodes(xml).filter(n=>label(n).includes('issue3441-cloud-receiver')&&label(n).includes('127.0.0.1'));
   assert(target.length===1,'Actual favorite send target missing');
   const caseReport={id:c.id,expectedNames:c.names,bytes:c.names.reduce((sum,name)=>sum+files.get(name).bytes,0),selection,sendUtc:new Date().toISOString()};report.cases.push(caseReport);
   await tapNode(target[0],'Send selected originals to actual macOS receiver');
   const terminal=await wait(value=>nodes(value).some(n=>/Finished/.test(label(n))),(c.id==='control'?3:6)*60000);
   caseReport.finishedLabels=nodes(terminal).map(label).filter(Boolean);caseReport.senderFinishedUtc=new Date().toISOString();
   caseReport.senderReportedError=caseReport.finishedLabels.some(v=>/Finished with error/.test(v));
   caseReport.terminalEvidenceScope=caseReport.senderReportedError
    ?'The sender reported an error. This differs from the report\'s successful Finished display and is retained as a discriminating experiment.'
    :'The sender displayed Finished. Saved content and the receiver approval remain separate observations.';
   await snap(c.id+'-sender-terminal',terminal);caseReport.receiver=await receiver.finishCase();save(c.id+'-result.json',caseReport);
   stage(c.id+'-receiver-full-inventory-hashed',{senderFinished:true,receiverPassed:caseReport.receiver.passed,inventoryCount:caseReport.receiver.inventory.length});
   if(c.id==='control') {
    assert(!caseReport.senderReportedError,'One-file control sender reported error');
    assert(caseReport.receiver.actualUIAccept,'One-file control actual receiver Accept absent');
    assert(caseReport.receiver.passed,'Working one-file app control did not verify');
   }
   // Preserve batch errors and inventories before continuing to the same original retry sources.
   if(c.id!=='retry73') {
    // Pinned SendPage's terminal control is general.close, not a file-row Done.
    await click('Close');
    let returned=await wait(value=>nodes(value).some(n=>label(n)==='Send\nTab 2 of 3'));
    await snap(c.id+'-after-close-raw',returned);
    // closeSession clears successful single-mode selections only. Error sessions
    // keep them, so use the source's Edit -> Delete all UI before the next case.
    if(nodes(returned).some(n=>label(n).split(/\r?\n/).some(line=>/^Files: \d+$/.test(line.trim())))) {
     await click('Edit');await wait(value=>nodes(value).some(n=>label(n)==='Delete all'));
     await snap(c.id+'-selection-clear-raw');await click('Delete all');
    }
    returned=await wait(value=>nodes(value).some(n=>label(n)==='Media'&&n.clickable==='true'&&n.enabled==='true')&&!nodes(value).some(n=>label(n).split(/\r?\n/).some(line=>/^Files: \d+$/.test(line.trim()))));
    await snap(c.id+'-selection-reset',returned);stage(c.id+'-selection-reset-observed');
   }
  }
  report.status='completed-original-app-cases';
 } catch(error) {report.status='incomplete';report.error=redact(error.stack);if(session)await snap('failure').catch(()=>{});throw error;}
 finally {
  cleaning=true;
  // Recover a timed-out creation by this unique Actions run/attempt only.
  if(!session&&createAttempted)try {
   const builds=(await api('builds.json')).map(b=>b.automation_build).filter(b=>b.name===buildName);assert(builds.length<=1,'Ambiguous owned build');
   if(builds.length){const sessions=(await api('builds/'+builds[0].hashed_id+'/sessions.json')).map(s=>s.automation_session);assert(sessions.length<=1,'Ambiguous owned session');session=sessions[0]?.hashed_id;}
  }catch(error){report.cleanupErrors.push('Startup recovery: '+redact(error.message));}
  if(session) {
   // Release the owned device before optional app/log operations consume cleanup time.
   await wd('DELETE',base()).catch(async error=>{
    report.cleanupErrors.push('Owned session delete first attempt: '+redact(error.message));
    await wd('DELETE',base()).catch(retry=>report.cleanupErrors.push('Owned session delete retry: '+redact(retry.message)));
   });
   try{
    const receipt=await retainProviderArtifacts({session,auth,output,privatePrefix,deadline:cleanupDeadline,redact,save});
    if(receipt.status==='partial-retention')report.cleanupErrors.push('Provider evidence incomplete; inspect response generations and validation receipts');
   }catch(error){report.cleanupErrors.push('Recording retention: '+redact(error.message));}
  }
  if(tunnel&&tunnelExited===undefined) {
   tunnel.kill('SIGTERM');await Promise.race([tunnelExitPromise,sleep(Math.max(0,Math.min(5000,cleanupDeadline-Date.now())))]);
   if(tunnelExited===undefined){tunnel.kill('SIGKILL');await Promise.race([tunnelExitPromise,sleep(Math.max(0,Math.min(3000,cleanupDeadline-Date.now())))]);}
   if(tunnelExited===undefined)report.cleanupErrors.push('Owned BrowserStackLocal did not exit after SIGKILL');
  }
  report.finishedUtc=new Date().toISOString();report.sourceReads=sourceReads;report.screenshots=screenshots;save('android-results.json',report);
 }
 return report;
}
