// Diagnostic only. Run on the Actions runner connected to the issue1864 TV AVD.
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
const out = 'evidence-cloud';
const adb = (...args) => execFileSync('adb', args, { encoding: 'utf8', timeout: 30000 });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = data => fs.appendFileSync(`${out}/input-timings.jsonl`, JSON.stringify({ time: Date.now(), ...data }) + '\n');
function optionalAdb(name,...args) {
  try { fs.writeFileSync(`${out}/${name}.txt`,adb(...args)); }
  catch(error) {
    fs.writeFileSync(`${out}/${name}.txt`,error.stdout ?? '');
    fs.writeFileSync(`${out}/${name}-error.json`,JSON.stringify({status:error.status,signal:error.signal,stderr:error.stderr,message:error.message},null,2));
  }
}
const response = await fetch('http://127.0.0.1:4723/session', {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ capabilities: { alwaysMatch: {
    platformName: 'Android', 'appium:automationName': 'UiAutomator2',
    'appium:deviceName': 'emulator-5554', 'appium:appPackage': 'org.localsend.localsend_app',
    'appium:appActivity': '.MainActivity', 'appium:noReset': true,
    'appium:settings[waitForIdleTimeout]': 0,
  } } }),
});
const sessionData = await response.json();
fs.writeFileSync(`${out}/appium-session.json`, JSON.stringify(sessionData, null, 2));
const session = sessionData.value?.sessionId;
if (!session) throw new Error('Appium did not create a UI snapshot session');
if(process.env.ISSUE1864_TRACE==='true') adb('logcat','-c');
async function snapshot(name) {
  const source = await (await fetch(`http://127.0.0.1:4723/session/${session}/source`)).json();
  if (typeof source.value !== 'string') throw new Error(`No XML snapshot for ${name}`);
  fs.writeFileSync(`${out}/${name}.xml`, source.value);
  fs.writeFileSync(`${out}/${name}.png`, execFileSync('adb', ['exec-out', 'screencap', '-p']));
  fs.writeFileSync(`${out}/${name}-window.txt`, adb('shell', 'dumpsys', 'window', 'windows'));
  fs.writeFileSync(`${out}/${name}-activity.txt`, adb('shell', 'dumpsys', 'activity', 'activities'));
  return fs.readFileSync(`${out}/${name}.xml`, 'utf8');
}
function ocr(name) {
  const path=`${out}/${name}-ocr.tsv`;
  if (!fs.existsSync(path)) execFileSync('tesseract', [`${out}/${name}.png`, `${out}/${name}-ocr`, '--psm', '11', 'tsv'], {
    timeout:45000,env:{...process.env,OMP_THREAD_LIMIT:'1'},
  });
  return fs.readFileSync(path,'utf8');
}
async function mouseTap(x,y,label) {
  const backend=process.env.ISSUE1864_MOUSE ?? 'adb';
  log({type:'mouse',action:'tap',label,x,y,backend});
  if(backend==='adb') { adb('shell','input','mouse','tap',String(x),String(y)); return; }
  // Appium's public driver may rewrite pointerType to touch. Address the
  // existing UiAutomator2 native executor, which preserves TOOL_TYPE_MOUSE,
  // SOURCE_MOUSE and button0 -> BUTTON_PRIMARY. No accessibility click.
  const matches=[...fs.readFileSync(`${out}/appium.log`,'utf8').matchAll(/http:\/\/127\.0\.0\.1:8200\/session\/([a-f\d-]+)\/source/g)];
  const ids=[...new Set(matches.map(m=>m[1]))];
  if(ids.length!==1) throw new Error('Existing native input session is absent or ambiguous');
  const request={actions:[{type:'pointer',id:'diagnostic-mouse',parameters:{pointerType:'mouse'},actions:[
    {type:'pointerMove',duration:0,origin:'viewport',x,y},{type:'pointerDown',button:0},
    {type:'pause',duration:100},{type:'pointerUp',button:0},
  ]}]};
  const result=await fetch(`http://127.0.0.1:8200/session/${ids[0]}/actions`,{
    method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(request),
  });
  const body=await result.json();
  fs.appendFileSync(`${out}/native-mouse-actions.jsonl`,JSON.stringify({time:Date.now(),x,y,label,request,status:result.status,body})+'\n');
  optionalAdb('native-mouse-events','logcat','-d','-v','threadtime','appium:I','*:S');
  if(!result.ok || body.value?.error) throw new Error('Native mouse executor rejected the action');
}
function nodes(xml) {
  return [...xml.matchAll(/<[\w.$-]+\s+([^>]+)>?/g)].map(m => Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(a => [a[1], a[2]])));
}
async function mouseNode(label, name) {
  let bounds;
  for(let attempt=0;attempt<6;attempt++) {
    const capture=attempt===0 ? `${name}-before` : `${name}-before-retry-${attempt}`;
    const xml=await snapshot(capture);
    const node=nodes(xml).find(n=>n.package==='org.localsend.localsend_app' && n.displayed!=='false'
      && (n.text===label || n['content-desc']===label || n['content-desc']?.startsWith(`${label}&#10;`)));
    if(node) bounds=[...node.bounds.matchAll(/\d+/g)].map(n=>Number(n[0]));
    else {
      const words=ocr(capture).trim().split('\n').slice(1).map(line=>line.split('\t'));
      const hits=words.filter(w=>w[11]===label && Number(w[10])>40);
      if(hits.length>1) throw new Error(`Ambiguous visible OCR label ${label}; inspect ${capture}.png`);
      if(hits.length===1) {
        const word=hits[0];
        bounds=[Number(word[6]),Number(word[7]),Number(word[6])+Number(word[8]),Number(word[7])+Number(word[9])];
      }
    }
    if(bounds) break;
    log({type:'readiness',label,capture,attempt,observation:'label-not-yet-visible'});
    await pause(1500);
  }
  if(!bounds) throw new Error(`Visible label ${label} absent after bounded readiness snapshots`);
  const x = Math.round((bounds[0] + bounds[2]) / 2), y = Math.round((bounds[1] + bounds[3]) / 2);
  await mouseTap(x,y,label);
  await pause(1200);
}
async function waitForAppWindow() {
  const captureId=Date.now();
  let stable=0;
  let previousIdentity='';
  for (let attempt=0;attempt<30;attempt++) {
    const window=adb('shell','dumpsys','window','windows');
    const input=adb('shell','dumpsys','input');
    let pid='';
    try { pid=adb('shell','pidof','org.localsend.localsend_app').trim(); }
    catch(error) { log({type:'readiness',action:'pid',attempt,status:error.status,stderr:error.stderr}); }
    const focus=input.split('  FocusedWindows:')[1]?.split('  FocusRequests:')[0] ?? '';
    const blocks=window.split(/(?=  Window #\d+ Window\{)/);
    const readyWindow=pid!=='' && blocks.find(block=>/^  Window #\d+ Window\{[^\n]*org\.localsend\.localsend_app[^\n]*\}:/.test(block)
      && !block.split('\n')[0].includes('EXITING')
      && block.includes(` ${pid}:u`) && block.includes('isVisible=true')
      && focus.includes(`name='${block.match(/Window\{(\S+)/)?.[1]} org.localsend.localsend_app/`)
      && block.includes('Surface: shown=true') && block.includes('mDrawState=HAS_DRAWN'));
    const ready=!!readyWindow;
    const identity=ready ? `${pid}:${readyWindow.match(/Window\{(\S+)/)?.[1]}` : '';
    fs.writeFileSync(`${out}/launch-readiness-${captureId}-${attempt}-window.txt`,window);
    fs.writeFileSync(`${out}/launch-readiness-${captureId}-${attempt}-input.txt`,input);
    stable=ready ? (identity===previousIdentity ? stable+1 : 1) : 0;
    previousIdentity=identity;
    log({type:'readiness',action:'app-window',captureId,attempt,ready,stable,pid});
    if (stable>=2) { await snapshot(`launch-ready-${captureId}`); return; }
    await pause(2000);
  }
  throw new Error('Current non-exiting app window did not finish drawing within 60 seconds');
}
async function remote(key) {
  log({ type: 'dpad', action: 'keyevent', key });
  adb('shell', 'input', 'dpad', 'keyevent', String(key));
  await pause(650);
}
async function record(name, action) {
  if(process.env.ISSUE1864_RECORDING_STOP==='whole') {
    if(process.env.ISSUE1864_WHOLE_ACTIVE!=='true') throw new Error('Whole recording requires issue1864-whole.mjs');
    log({type:'segment',action:'start',name,recording:'whole-variant'});
    await pause(900);
    const actionStartedAt=Date.now();
    log({type:'segment',action:'action-start',name,actionStartedAt});
    let actionCompletedAt, actionError;
    try { await action(); actionCompletedAt=Date.now(); await pause(1200); }
    catch(error) { actionError=error; }
    finally { log({type:'segment',action:'end',name,actionStartedAt,actionCompletedAt,actionFailed:!!actionError}); }
    if(actionError) throw actionError;
    return;
  }
  const path = `/sdcard/issue1864-recordings/${name}.mp4`;
  const natural=process.env.ISSUE1864_RECORDING_STOP==='natural';
  const requestedDuration=natural ? 15 : 45;
  const recorder = spawn('adb', ['shell', 'screenrecord', '--time-limit', String(requestedDuration), path]);
  const finished = new Promise(resolve => recorder.once('exit', (code, signal) => resolve({ code, signal, time:Date.now() })));
  recorder.stderr.on('data', data => fs.appendFileSync(`${out}/${name}-screenrecord.log`, data));
  log({ type: 'recording', action: 'start', name, stopMode:natural ? 'natural-expiry' : 'SIGINT', requestedDuration });
  await pause(900);
  let actionError, captureError, actionCompletedAt;
  try { await action(); actionCompletedAt=Date.now(); await pause(1200); }
  catch(error) { actionError=error; }
  finally {
    if(!natural) {
      try { adb('shell', 'pkill', '-INT', 'screenrecord'); }
      catch(error) { log({type:'recording',action:'stop-error',name,status:error.status,message:error.message}); }
    }
    const exit=await finished;
    log({type:'recording',action:'process-exit',name,...exit});
    if(natural && (exit.code!==0 || !actionCompletedAt || actionCompletedAt>=exit.time)) {
      captureError=new Error('Natural recording ended before required actions completed or exited uncleanly');
    }
    const recordingError=captureError;
    // A completed recording survives a transient ADB transport loss. Retry only
    // reading this exact file; never repeat the actions that produced it.
    for(let attempt=1;attempt<=3;attempt++) {
      try {
        if(attempt>1) {
          await pause(1000);
          if(adb('get-state').trim()!=='device') throw new Error('ADB is not online');
          adb('shell','test','-s',path);
        }
        adb('pull', path, `${out}/${name}.mp4`);
        captureError=recordingError;
        log({type:'recording',action:'pull-success',name,attempt});
        break;
      } catch(error) {
        captureError=error;
        log({type:'recording',action:'pull-error',name,attempt,status:error.status,message:error.message,
          stdout:error.stdout?.toString(),stderr:error.stderr?.toString()});
      }
    }
    log({type:'recording',action:'end',name,actionCompletedAt,actionFailed:!!actionError,captureFailed:!!captureError});
  }
  if(actionError) throw actionError;
  if(captureError) throw captureError;
}
adb('shell', 'settings', 'put', 'system', 'show_touches', '1');
adb('shell','setprop','log.tag.appium','INFO');
adb('shell', 'mkdir', '-p', '/sdcard/issue1864-recordings');
adb('shell', 'touch', '/sdcard/issue1864-recordings/.nomedia');
adb('shell', 'am', 'start', '-a', 'android.settings.SETTINGS');
await pause(2500);
await snapshot('native-control-before');
await record('native-dpad-control', async () => { await remote(20); await remote(20); });
await snapshot('native-control-after');
// TV Settings is a side-panel overlay; launching another Activity leaves it visible.
// Close only the Settings control started by this diagnostic on this fresh runner.
await remote(4);
adb('shell', 'am', 'force-stop', 'com.android.tv.settings');
adb('shell', 'am', 'force-stop', 'com.android.settings');
adb('shell', 'am', 'force-stop', 'org.localsend.localsend_app');
adb('shell', 'am', 'start', '-n', 'org.localsend.localsend_app/.MainActivity');
await waitForAppWindow();
await mouseNode('Send', 'open-send');
await mouseNode('Media', 'open-media');
await pause(3000);
const media = await snapshot('media-initial');
const photo = nodes(media).find(n => /^Image\d+,/.test(n['content-desc'] ?? ''));
let bounds;
if (photo) bounds = [...photo.bounds.matchAll(/\d+/g)].map(n => Number(n[0]));
else {
  // Sparse TV accessibility trees require an independent image observation.
  // Locate only the seeded orange rectangle in this exact screenshot.
  const [w, h] = execFileSync('identify', ['-format', '%w %h', `${out}/media-initial.png`], { encoding: 'utf8' }).split(' ').map(Number);
  const rgb = execFileSync('convert', [`${out}/media-initial.png`, '-depth', '8', 'rgb:-'], { maxBuffer: 20000000 });
  let left=w, top=h, right=0, bottom=0, count=0;
  for (let y=0;y<h;y++) for (let x=0;x<w;x++) {
    const p=(y*w+x)*3;
    if (rgb[p]>210 && rgb[p+1]>130 && rgb[p+1]<185 && rgb[p+2]<25) {
      left=Math.min(left,x);top=Math.min(top,y);right=Math.max(right,x);bottom=Math.max(bottom,y);count++;
    }
  }
  bounds=[left,top,right+1,bottom+1];
  fs.writeFileSync(`${out}/photo-image-observation.json`, JSON.stringify({width:w,height:h,bounds,count},null,2));
  if (count<10000 || right-left<100 || bottom-top<100) throw new Error('Seeded orange thumbnail not visibly located');
}
// The original picker's selection indicator occupies the thumbnail's top end.
// Read the actual semantic bounds rather than substitute an accessibility click.
const width = bounds[2] - bounds[0];
const x = Math.round(bounds[2] - width / 4), y = Math.round(bounds[1] + width / 4);
async function mousePhoto() {
  await mouseTap(x,y,'photo-selection-indicator');
  await pause(900);
}
await record('mouse-photo-control', mousePhoto);
const selected = await snapshot('mouse-photo-selected');
function selectedCount(xml, name) {
  const labels = nodes(xml).map(n => n['content-desc'] || n.text || '');
  if (labels.includes('Confirm')) return 0;
  const label = labels.find(label => /^Confirm \(\d+\/999\)$/.test(label));
  if (label) return Number(label.match(/\((\d+)/)[1]);
  const words=ocr(name).trim().split('\n').slice(1).map(line=>line.split('\t')).filter(w=>Number(w[10])>40).map(w=>w[11]).join(' ');
  const match=words.match(/Confirm\s*\((\d+)\s*\/\s*999\)/);
  return match ? Number(match[1]) : /\bConfirm\b/.test(words) ? 0 : null;
}
if (selectedCount(selected,'mouse-photo-selected') !== 1) throw new Error('Mouse control did not visibly select one photo');
await mousePhoto();
const reset=await snapshot('media-reset-before-dpad');
if (selectedCount(reset,'media-reset-before-dpad') !== 0) throw new Error('Mouse reset did not visibly return to zero');
async function replay(name) {
  await record(name,async()=>{
    for(const key of [20,20,22,23]) await remote(key);
  });
}
await replay('media-dpad-original');
const after = await snapshot('media-after-dpad');
await remote(4);
await mouseNode('Media','fresh-open-media');
await pause(2000);
await snapshot('fresh-media-before-dpad');
await replay('fresh-media-dpad-original');
const freshAfter=await snapshot('fresh-media-after-dpad');
let returnedFileControl;
if(process.env.ISSUE1864_TRACE==='true') {
  // This mouse confirmation control is separate from the unchanged D-pad
  // observations above. It proves the picker-to-Send file return path only.
  const before=selectedCount(freshAfter,'fresh-media-after-dpad');
  if(before===0) await mousePhoto();
  else if(before!==1) throw new Error('Returned-file control has unexpected initial selection');
  const ready=await snapshot('returned-file-before-confirm');
  if(selectedCount(ready,'returned-file-before-confirm')!==1) throw new Error('Returned-file control needs exactly one selected photo');
  await mouseNode('Confirm (1/999)','returned-file-confirm');
  await pause(2500);
  const send=await snapshot('returned-file-send-list');
  const labels=nodes(send).map(node=>node['content-desc'] || node.text || '').join(' ');
  const pickerStillPresent=nodes(send).some(node=>/^Image\d+,/.test(node['content-desc'] ?? ''));
  if(pickerStillPresent || !/Files: 1\b/.test(labels)
    || !nodes(send).some(node=>node.text==='Send' || node['content-desc']?.startsWith('Send&#10;Tab'))) {
    throw new Error('Picker did not close to Send with one selected file');
  }
  // Send's collapsed selection card shows thumbnails/count/size, not filenames.
  // Observe the existing Edit page only after both unchanged D-pad snapshots.
  await mouseNode('Edit','returned-file-open-edit');
  const details=await snapshot('returned-file-details');
  const detailLabels=nodes(details).map(node=>node['content-desc'] || node.text || '').join(' ');
  const visible=detailLabels.match(/\b(?:orange|green|yellow|purple|blue|red)\.jpg\b/);
  if(!visible || !/Files: 1\b/.test(detailLabels)) throw new Error('Selected-file details lack one visible seeded filename');
  const currentPid=adb('shell','pidof','org.localsend.localsend_app').trim();
  if(!/^\d+$/.test(currentPid)) throw new Error('Returned-file control has no unique current app PID');
  const deviceLog=adb('logcat','-d','-v','threadtime',`--pid=${currentPid}`);
  fs.writeFileSync(`${out}/focus-trace-logcat.txt`,deviceLog);
  const traces=deviceLog.split('\n').filter(line=>line.includes('ISSUE1864_TRACE ')).map(line=>JSON.parse(line.split('ISSUE1864_TRACE ')[1]));
  fs.writeFileSync(`${out}/focus-trace-events.json`,JSON.stringify(traces,null,2));
  const returnedIndex=traces.findLastIndex(trace=>trace.stage==='picker-return' && Array.isArray(trace.ids) && trace.ids.length===1);
  const returned=traces[returnedIndex];
  const converted=traces.slice(returnedIndex+1).find(trace=>trace.stage==='converted-file' && trace.id===returned?.ids[0]
    && trace.name===visible[0] && trace.size>0 && typeof trace.path==='string');
  const added=traces.slice(returnedIndex+1).find(trace=>trace.stage==='send-files-added'
    && trace.files?.some(file=>file.name===converted?.name && file.size===converted?.size));
  if(returnedIndex<0 || !converted || !added) throw new Error('Visible Send filename lacks correlated picker return/conversion/added evidence');
  returnedFileControl={method:'native mouse Confirm then Edit filename observation after D-pad snapshots; not a D-pad success claim',name:converted.name,size:converted.size,path:converted.path};
}
async function freshEntry(name) {
  adb('shell','am','force-stop','org.localsend.localsend_app');
  adb('shell','am','start','-n','org.localsend.localsend_app/.MainActivity');
  await waitForAppWindow();
  await mouseNode('Send',`${name}-send`);
  await mouseNode('Media',`${name}-media`);
  await pause(3000);
  return snapshot(`${name}-initial`);
}
// The causal pair uses only its required controls and exact short/fresh inputs.
// Extended and keyboard observations remain available in the diagnostic phase.
const pairedCore=process.env.ISSUE1864_PHASE==='paired-core';
if(!pairedCore) {
  await freshEntry('no-input');
  for(let index=1;index<=4;index++) {
    await pause(850); await snapshot(`no-input-step-${index}`);
  }
  await freshEntry('extended-arrows');
  await record('extended-arrows',async()=>{
    for(const [index,key] of [20,20,20,20,20,20,22,22,21,19,23].entries()) {
      await remote(key); await snapshot(`extended-arrows-key-${index+1}-${key}`);
    }
  });
  await freshEntry('keyboard-control');
  await record('keyboard-control',async()=>{
    for(const [index,key] of [61,61,66].entries()) {
      log({type:'keyboard',action:'keyevent',key});
      adb('shell','input','keyboard','keyevent',String(key));
      await pause(650); await snapshot(`keyboard-control-key-${index+1}-${key}`);
    }
  });
}
function cyanFocusPixels(name) {
  const rgb=execFileSync('convert',[`${out}/${name}.png`,'-depth','8','rgb:-'],{maxBuffer:20000000});
  let count=0;
  for(let p=0;p<rgb.length;p+=3) if(rgb[p]<35 && rgb[p+1]>235 && rgb[p+2]>235) count++;
  return count;
}
const visualAssertions={
  shortSelectionCount:selectedCount(after,'media-after-dpad'),
  freshSelectionCount:selectedCount(freshAfter,'fresh-media-after-dpad'),
  shortFocusPixels:cyanFocusPixels('media-after-dpad'),
  freshFocusPixels:cyanFocusPixels('fresh-media-after-dpad'),
};
fs.writeFileSync(`${out}/outcome.json`, JSON.stringify({
  mouseSelected: true,
  apkTarget:process.env.ISSUE1864_APK ?? 'original',
  phase:pairedCore ? 'paired-core' : 'full-diagnostic',
  returnedFileControl,
  supplementaryScenarios:pairedCore ? 'not requested in paired-core; retained in previous diagnostic runs' : 'no-input, extended-arrows, keyboard-control',
  visualAssertions,
  selectedPhotosAfterDpad: nodes(after).filter(n => /Image\d+,/.test(n['content-desc'] ?? '') && n.selected === 'true'),
  focusedNodesAfterDpad: nodes(after).filter(n => n.focused === 'true'),
  boundary: 'Exact diagnostic APK, supplementary compatible emulator; not physical Sony Android TV 10',
}, null, 2));
await fetch(`http://127.0.0.1:4723/session/${session}`, { method: 'DELETE' });
