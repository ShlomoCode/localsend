// Cloud-only observer of unmodified normal APKs. Never imported by the app.
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import crypto from 'node:crypto';
const env=process.env, out=env.ISSUE1864_EVIDENCE_DIR, phase=env.ISSUE1864_PHASE;
const pkg='org.localsend.localsend_app';
if(env.ISSUE1864_PRODUCTION_ACTIVE!=='true' || !out || !['production-base','production-candidate'].includes(env.ISSUE1864_APK)) throw new Error('Use the production whole recorder');
if(env.ISSUE1864_TRACE==='true' || env.ISSUE1864_MOUSE!=='w3c-native') throw new Error('Clean production observation requires native mouse and no trace');
const deadline=Number(env.ISSUE1864_OBSERVATION_DEADLINE);
const check=()=>{if(!Number.isFinite(deadline) || Date.now()>=deadline) throw new Error('Independent recording observation deadline reached');};
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const log=data=>fs.appendFileSync(`${out}/input-timings.jsonl`,JSON.stringify({time:Date.now(),...data})+'\n');
const remaining=until=>{check();const ms=Math.min(deadline,until)-Date.now();if(ms<=0) throw new Error('Observation readiness budget exhausted');return ms;};
const adbUntil=(until,...args)=>{const result=execFileSync('adb',args,{encoding:'utf8',timeout:Math.min(30000,remaining(until))});remaining(until);return result;};
const adb=(...args)=>adbUntil(deadline,...args);
const nodes=xml=>[...xml.matchAll(/<[\w.$-]+\s+([^>]+)>?/g)].map(m=>Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(a=>[a[1],a[2].replaceAll('&#10;','\n').replaceAll('&amp;','&')])));
const labels=xml=>nodes(xml).map(n=>n['content-desc'] || n.text || '').join('\n');
const bounds=n=>[...n.bounds.matchAll(/-?\d+/g)].map(m=>Number(m[0]));
const assets=xml=>nodes(xml).filter(n=>/^(Image|Video)\d+,/.test(n['content-desc'] ?? '') && n.displayed!=='false');
const count=xml=>{const text=labels(xml);const m=text.match(/Confirm\s*\((\d+)\/999\)/);return m ? Number(m[1]) : /(^|\n)Confirm(\n|$)/.test(text) ? 0 : null;};
const requireCount=(xml,n)=>{if(count(xml)!==n) throw new Error(`Expected Confirm count ${n}, observed ${count(xml)}`);if(n>0 && !labels(xml).includes(`Preview (${n})`)) throw new Error(`Missing selected Preview (${n}) semantic`);};
const expectedDpad=env.ISSUE1864_APK==='production-base' ? 0 : 1;
function previewState(xml,total) {if(/(^|\n)Recent(\n|$)/.test(labels(xml)) || !new RegExp(`(^|\\n)\\d+/${total}(\\n|$)`).test(labels(xml))) throw new Error('Full-screen preview page index/absence of Recent not observed');requireCount(xml,0);}
const manifest=JSON.parse(fs.readFileSync(env.ISSUE1864_FIXTURE_MANIFEST,'utf8'));
if(manifest.files.length!==6 || manifest.files.some(f=>!f.name.endsWith('.jpg') || !/^[a-f0-9]{64}$/.test(f.sha256))) throw new Error('Exact six JPEG fixture manifest required');
fs.copyFileSync(env.ISSUE1864_FIXTURE_MANIFEST,`${out}/fixture-manifest.json`);
fs.copyFileSync(env.ISSUE1864_APP_SOURCE_MANIFEST,`${out}/source-manifest.txt`);
let session;
async function request(path,body,until=deadline) {
  check();if(Date.now()>=until) throw new Error('Observation readiness budget exhausted');const response=await fetch(`http://127.0.0.1:4723/session${path}`,{method:body ? 'POST' : 'GET',headers:{'content-type':'application/json'},body:body ? JSON.stringify(body) : undefined,signal:AbortSignal.timeout(Math.min(30000,deadline-Date.now(),until-Date.now()))});
  const result=await response.json();if(!response.ok || result.value?.error) {const error=new Error(`Appium failed ${path}: ${JSON.stringify(result)}`);error.status=response.status;error.response=result;throw error;}return result;
}
async function snapshot(name,until=deadline) {
  const remaining=()=>{check();const ms=Math.min(deadline,until)-Date.now();if(ms<=0) throw new Error('Observation readiness budget exhausted');return Math.min(30000,ms);};
  remaining();const source=await request(`/${session}/source`,undefined,until);remaining();
  if(typeof source.value!=='string') throw new Error('Missing raw XML');
  fs.writeFileSync(`${out}/${name}.xml`,source.value);
  fs.writeFileSync(`${out}/${name}.png`,execFileSync('adb',['exec-out','screencap','-p'],{timeout:remaining()}));
  fs.writeFileSync(`${out}/${name}-window.txt`,execFileSync('adb',['shell','dumpsys','window','windows'],{encoding:'utf8',timeout:remaining()}));
  fs.writeFileSync(`${out}/${name}-input.txt`,execFileSync('adb',['shell','dumpsys','input'],{encoding:'utf8',timeout:remaining()}));
  log({type:'snapshot',name});remaining();return source.value;
}
async function mouse(x,y,label,until=deadline) {
  remaining(until);
  const matches=[...fs.readFileSync(env.ISSUE1864_APPIUM_LOG,'utf8').matchAll(/http:\/\/127\.0\.0\.1:8200\/session\/([a-f\d-]+)\/source/g)];
  const id=matches.at(-1)?.[1];if(!id) throw new Error('Current native input session absent');
  const body={actions:[{type:'pointer',id:'production-mouse',parameters:{pointerType:'mouse'},actions:[{type:'pointerMove',duration:0,origin:'viewport',x,y},{type:'pointerDown',button:0},{type:'pause',duration:100},{type:'pointerUp',button:0}]}]};
  const response=await fetch(`http://127.0.0.1:8200/session/${id}/actions`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(Math.min(15000,remaining(until)))});
  const result=await response.json();log({type:'mouse',x,y,label,backend:'w3c-native',nativeSession:id,request:body,status:response.status,response:result});
  try {fs.writeFileSync(`${out}/native-mouse-events.txt`,adbUntil(until,'logcat','-d','-v','threadtime','appium:I','*:S'));}
  catch(error) {fs.appendFileSync(`${out}/native-mouse-events-errors.jsonl`,JSON.stringify({time:Date.now(),label,message:error.message,status:error.status,stderr:error.stderr?.toString(),boundary:'Optional event probe failed after persistent native input receipt; no replay. SOURCE_MOUSE request/backend still mandatory; actual event evidence limitation retained.'})+'\n');}
  if(!response.ok || result.value?.error) throw new Error('Native SOURCE_MOUSE executor rejected input');
  await pause(Math.min(900,remaining(until)));remaining(until);
}
async function tapLabel(pattern,name,{system=false}={}) {
  const xml=await snapshot(`${name}-before`);
  const candidates=nodes(xml).filter(n=>n.displayed!=='false' && (system ? n.package!==pkg : n.package===pkg) && pattern.test(n.text || n['content-desc'] || '') && n.bounds);
  if(candidates.length!==1) throw new Error(`Visible label ${pattern} ambiguous/absent (${candidates.length}); inspect ${name}-before`);
  const b=bounds(candidates[0]);await mouse(Math.round((b[0]+b[2])/2),Math.round((b[1]+b[3])/2),String(pattern));
}
async function key(code,until=deadline) {remaining(until);log({type:'dpad',key:code});adbUntil(until,'shell','input','dpad','keyevent',String(code));await pause(Math.min(650,remaining(until)));remaining(until);}
function nativeSettingsState(name,xml,{appDetails=false}={}) {
  const window=fs.readFileSync(`${out}/${name}-window.txt`,'utf8'),input=fs.readFileSync(`${out}/${name}-input.txt`,'utf8');
  const focus=input.split('  FocusedWindows:')[1]?.split('  FocusRequests:')[0] ?? '';
  const block=window.split(/(?=  Window #\d+ Window\{)/).find(b=>{
    const header=b.split('\n')[0];
    return /^  Window #\d+ Window\{/.test(header) && !header.includes('EXITING') &&
      (appDetails ? header.includes('com.android.tv.settings/com.android.tv.settings.device.apps.AppManagementActivity') : /com\.android\.tv\.settings\/|permissioncontroller\//.test(header)) &&
      b.includes('isVisible=true') && b.includes('Surface: shown=true') && b.includes('mDrawState=HAS_DRAWN') &&
      focus.includes(`name='${b.match(/Window\{(\S+) u\d+ ([^}]+)/)?.slice(1).join(' ')}`);
  });
  const identity=block?.match(/Window\{(\S+) u\d+ ([^}]+)/),packageName=identity?.[2].split('/')[0];
  const hierarchy=nodes(xml).find(n=>n.class==='hierarchy'),width=Number(hierarchy?.width),height=Number(hierarchy?.height);
  const visible=nodes(xml).filter(n=>{
    if(!packageName || n.package!==packageName || n.displayed!=='true' || n.enabled!=='true' || !n.bounds) return false;
    const b=bounds(n);return b.length===4 && b[0]>=0 && b[1]>=0 && b[2]>b[0] && b[3]>b[1] && b[2]<=width && b[3]<=height;
  });
  const named=visible.filter(n=>n.text || n['content-desc']);
  // A focused row container can expose its title on a child node.
  const rows=visible.filter(n=>(n.focused==='true' || n.selected==='true') && n.focusable==='true').map(n=>{
    const b=bounds(n),children=named.filter(child=>{const c=bounds(child);return c[0]>=b[0] && c[1]>=b[1] && c[2]<=b[2] && c[3]<=b[3];});
    const title=children.find(c=>/(^|:)id\/title$/.test(c['resource-id'] ?? '')) ?? children[0];
    return {bounds:n.bounds,id:n['resource-id'],class:n.class,title:title?.text || title?.['content-desc'] || '',labels:children.map(c=>c.text || c['content-desc'])};
  }).filter(row=>row.labels.length);
  // Summary changes such as Calculating -> size do not prove navigation.
  const signature=JSON.stringify({focusedRows:rows.map(row=>[row.id,row.class,row.title,row.bounds]),rowPositions:visible.filter(n=>n.focusable==='true').map(n=>[n['resource-id'],n.class,n.bounds])});
  return {identity:identity?.slice(1).join(' ') ?? '',visible,named,rows,signature};
}
async function settingsLabel(pattern,name,{navigate=false,until}={}) {
  remaining(until);const waitUntil=Math.min(until,Date.now()+(navigate ? 40000 : 20000)),started=Date.now();
  let previous='',stable=0,bootstrap=false,moves=0,pending='';
  for(let poll=0;Date.now()<waitUntil;poll++) {
    const pollName=`${name}-poll-${poll}`,xml=await snapshot(pollName,waitUntil),state=nativeSettingsState(pollName,xml,{appDetails:navigate});
    stable=state.identity && state.identity===previous ? stable+1 : state.identity ? 1 : 0;previous=state.identity;
    const candidates=state.named.filter(n=>pattern.test(n.text || n['content-desc'] || ''));
    log({type:'settings-readiness',name,poll,identity:state.identity,stable,rows:state.rows,moves,pendingProgress:!!pending,waitUntil,routeUntil:until});
    if(candidates.length>1) throw new Error(`Visible Settings label ${pattern} ambiguous (${candidates.length}); inspect ${pollName}`);
    if(candidates.length===1 && stable>=2) {
      const b=bounds(candidates[0]);log({type:'settings-target',name,semantic:candidates[0],snapshot:pollName});
      await mouse(Math.round((b[0]+b[2])/2),Math.round((b[1]+b[3])/2),String(pattern),waitUntil);return;
    }
    if(navigate && stable>=2) {
      if(pending && state.rows.length && state.signature!==pending) pending='';
      const canMove=state.rows.length && !pending;
      // After bounded semantic readiness, one ordinary Down can establish
      // remote focus. If no named focused row appears, observe and fail.
      const canBootstrap=!bootstrap && !moves && !state.rows.length && Date.now()-started>=5000;
      if(canMove || canBootstrap) {
        if(moves>=12) throw new Error('Exact Permissions label absent after 12 observed Settings navigation steps');
        bootstrap=true;pending=state.signature;moves++;log({type:'settings-navigation',name,moves,bootstrap:canBootstrap,beforeSnapshot:pollName,rows:state.rows});
        await key(20,waitUntil);continue;
      }
    }
    await pause(Math.min(500,remaining(waitUntil)));remaining(waitUntil);
  }
  throw new Error(`Exact visible Settings label ${pattern} absent within bounded readiness/navigation; inspect ${name}-poll snapshots`);
}
async function sequence() {for(const code of [20,20,22,23]) await key(code);}
async function ready() {
  let previous='',stable=0;
  for(let i=0;i<25;i++) {
    const window=adb('shell','dumpsys','window','windows'), input=adb('shell','dumpsys','input');
    const pid=adb('shell','pidof',pkg).trim();
    const focus=input.split('  FocusedWindows:')[1]?.split('  FocusRequests:')[0] ?? '';
    const block=window.split(/(?=  Window #\d+ Window\{)/).find(b=>/^  Window #\d+ Window\{[^\n]*org\.localsend\.localsend_app[^\n]*\}:/.test(b) && !b.split('\n')[0].includes('EXITING') && b.includes(` ${pid}:u`) && b.includes('isVisible=true') && b.includes('Surface: shown=true') && b.includes('mDrawState=HAS_DRAWN') && focus.includes(`name='${b.match(/Window\{(\S+)/)?.[1]} ${pkg}/`));
    const identity=block ? `${pid}:${block.match(/Window\{(\S+)/)?.[1]}` : '';
    stable=identity && identity===previous ? stable+1 : identity ? 1 : 0;previous=identity;
    fs.writeFileSync(`${out}/ready-${i}-window.txt`,window);fs.writeFileSync(`${out}/ready-${i}-input.txt`,input);log({type:'readiness',i,pid,identity,stable});
    if(stable>=2) return;await pause(1500);
  }
  throw new Error('No stable drawn visible native focused app window');
}
async function entry(name) {await tapLabel(/^Send(?:\nTab.*)?$/,`${name}-send`);await tapLabel(/^Media$/,`${name}-media`);await pause(2000);return snapshot(`${name}-initial`);}
function initial(xml) {requireCount(xml,0);if(!/(^|\n)Recent(\n|$)/.test(labels(xml)) || assets(xml).length!==6 || assets(xml).some(n=>n.selected==='true')) throw new Error('Core must begin Recent, six unselected JPEG semantics, Confirm zero');}
function inventory(name,xml) {
  check();const [w,h]=execFileSync('identify',['-format','%w %h',`${out}/${name}.png`],{encoding:'utf8',timeout:Math.min(10000,Math.max(1,deadline-Date.now()))}).split(' ').map(Number);
  check();const rgb=execFileSync('convert',[`${out}/${name}.png`,'-depth','8','rgb:-'],{maxBuffer:20000000,timeout:Math.min(10000,Math.max(1,deadline-Date.now()))});check();
  const colors={'red.jpg':[255,0,0],'green.jpg':[0,128,0],'blue.jpg':[0,0,255],'yellow.jpg':[255,255,0],'purple.jpg':[128,0,128],'orange.jpg':[255,165,0]};
  const ordered=assets(xml).map(n=>{
    const b=bounds(n),x=Math.floor((b[0]+b[2])/2),y=Math.floor((b[1]+b[3])/2),offset=(y*w+x)*3;
    if(x<0 || y<0 || x>=w || y>=h) throw new Error('Fixture tile outside original frame');
    const pixel=[...rgb.subarray(offset,offset+3)];
    const match=Object.entries(colors).map(([name,c])=>({name,distance:Math.hypot(...c.map((v,i)=>v-pixel[i]))})).sort((a,b)=>a.distance-b.distance)[0];
    if(match.distance>40) throw new Error('Original seeded JPEG center cannot be identified');
    if(!n['content-desc'].includes(match.name)) throw new Error('Fixture pixel identity and tile filename semantic disagree');
    return {...manifest.files.find(f=>f.name===match.name),bounds:b,semantic:n,pixel,fixtureColorDistance:match.distance};
  });
  if(new Set(ordered.map(f=>f.name)).size!==6) throw new Error('Core inventory is not the exact six distinct seeded JPEGs');
  fs.writeFileSync(`${out}/${name}-inventory.json`,JSON.stringify(ordered,null,2));
  return ordered;
}
function selectedFixture(xml,ordered) {
  const selected=assets(xml).filter(n=>n.selected==='true');if(selected.length!==1) throw new Error('Need one selected semantic for return correlation');
  const b=bounds(selected[0]);const file=ordered.find(f=>JSON.stringify(f.bounds)===JSON.stringify(b));if(!file) throw new Error('Selected tile cannot be correlated to original fixture frame');return file;
}
function tile(xml,index=0) {const n=assets(xml)[index];if(!n) throw new Error('Tile semantic missing');return bounds(n);}
async function indicator(xml,index=0) {const b=tile(xml,index),w=b[2]-b[0];await mouse(Math.round(b[2]-w/4),Math.round(b[1]+w/4),'selection-indicator');}
async function center(xml,index=0) {const b=tile(xml,index);await mouse(Math.round((b[0]+b[2])/2),Math.round((b[1]+b[3])/2),'thumbnail-preview');}
function fixtureHashes(name,files=manifest.files) {
  const observations=files.map(f=>{check();const bytes=execFileSync('adb',['exec-out','cat',f.path],{maxBuffer:30000000,timeout:Math.min(30000,Math.max(1,deadline-Date.now()))});check();const sha256=crypto.createHash('sha256').update(bytes).digest('hex');if(sha256!==f.sha256 || bytes.length!==f.size) throw new Error(`Fixture bytes changed: ${f.name}`);return {...f,observedSha256:sha256,observedSize:bytes.length};});
  fs.writeFileSync(`${out}/${name}-fixture-read.json`,JSON.stringify({observations,boundary:'Read-only fixture bytes; does not prove internal returned file path or app bytes'},null,2));
}
function emptySend(xml) {
  const ns=nodes(xml),text=labels(xml);
  const selectedSend=ns.some(n=>n.package===pkg && /^Send\nTab/.test(n['content-desc'] ?? '') && n.selected==='true');
  const visibleMedia=ns.some(n=>n.package===pkg && (n.text==='Media' || n['content-desc']==='Media') && n.displayed!=='false');
  if(!selectedSend || !visibleMedia || !text.includes('Selection') || assets(xml).length || /Files:\s*\d+/.test(text) || ns.some(n=>n.text==='Edit' || n['content-desc']==='Edit')) throw new Error('Canceled picker lacks positive Send empty-selection UI');
}
function edgeEvidence(name,xml,{baseline=false}={}) {
  const selected=baseline ? [assets(xml)[1]] : assets(xml).filter(n=>n.selected==='true');if(selected.length!==1 || !selected[0]) throw new Error('Selected tile semantic must correlate with count one');
  const b=bounds(selected[0]),w=b[2]-b[0],h=b[3]-b[1],strip=10;
  const bands={top:[w,strip,b[0],b[1]],bottom:[w,strip,b[0],b[3]-strip],left:[strip,h,b[0],b[1]],right:[strip,h,b[2]-strip,b[1]]};
  for(const [edge,[cw,ch,x,y]] of Object.entries(bands)) {check();execFileSync('convert',[`${out}/${name}.png`,'-crop',`${cw}x${ch}+${x}+${y}`,'+repage',`${out}/${name}-edge-${edge}.png`],{timeout:Math.min(10000,Math.max(1,deadline-Date.now()))});check();}
  fs.writeFileSync(`${out}/${name}-focus-review.json`,JSON.stringify({semantic:selected[0],bounds:b,bands,baselineComparison:baseline,expected:'Actual picker primary outer / onPrimary inner outline; compare all four raw bands to same tile before input and baseline, excluding tint and selection indicator',verdict:'pending independent manual raw-frame theme/palette review; no diagnostic color threshold'},null,2));
}
const sizeText=n=>n<1000 ? `${n} B` : n<1e6 ? `${(n/1000).toFixed(1)} KB` : n<1e9 ? `${(n/1e6).toFixed(1)} MB` : `${(n/1e9).toFixed(1)} GB`;
async function returned(xml,files,name) {
  requireCount(xml,files.length);await tapLabel(new RegExp(`^Confirm \\(${files.length}/999\\)$`),`${name}-confirm`);
  const send=await snapshot(`${name}-send`);
  if(assets(send).length || !labels(send).includes(`Files: ${files.length}`)) throw new Error('Real Confirm did not return expected Send count');
  await tapLabel(/^Edit$/,`${name}-edit`);const details=await snapshot(`${name}-details`),text=labels(details);
  for(const f of files) if(!text.includes(f.name) || !text.includes(sizeText(f.size))) throw new Error(`Edit lacks exact fixture filename/displayed size ${f.name} ${sizeText(f.size)}`);
  fixtureHashes(`${name}-after-return`,files);
  fs.writeFileSync(`${out}/${name}-return.json`,JSON.stringify({files,displayedSizes:files.map(f=>sizeText(f.size)),boundary:'Picker semantics -> real Confirm -> Send count -> Edit filename and formatted size. Fixture hash is a separate readable device-byte observation; internal returned path/bytes and transfer receipt unproved.'},null,2));
}
let result={apk:env.ISSUE1864_APK,phase,max999:'source-only; saturation not exercised',manualReview:'Full raw original frames/video and all relevant controls require independent review',controls:{}};
try {
  const created=await request('',{capabilities:{alwaysMatch:{platformName:'Android','appium:automationName':'UiAutomator2','appium:deviceName':'emulator-5554','appium:appPackage':pkg,'appium:appActivity':'.MainActivity','appium:noReset':true,'appium:autoGrantPermissions':false,'appium:settings[waitForIdleTimeout]':0}}});
  fs.writeFileSync(`${out}/appium-session.json`,JSON.stringify(created,null,2));session=created.value?.sessionId;if(!session) throw new Error('No observation session');
  try {fs.writeFileSync(`${out}/appium-settings.json`,JSON.stringify(await request(`/${session}/appium/settings`),null,2));}
  catch(error) {fs.writeFileSync(`${out}/appium-settings-error.json`,JSON.stringify({status:error.status ?? null,response:error.response ?? null,message:error.message,stack:error.stack,boundary:'Optional read-only settings receipt unavailable; effective driver settings remain unknown. Real UI/input/permission assertions are still mandatory.'},null,2));check();}
  adb('shell','setprop','log.tag.appium','INFO');await ready();fixtureHashes('before');
  if(phase==='permission-denial-grant') {
    const permissionBefore=adb('shell','dumpsys','package',pkg);fs.writeFileSync(`${out}/permissions-before.txt`,permissionBefore);if(/READ_MEDIA_(IMAGES|VIDEO): granted=true/.test(permissionBefore)) throw new Error('Initial permission control was pregranted');
    await tapLabel(/^Send(?:\nTab.*)?$/,'permission-send');await tapLabel(/^Media$/,'permission-media');
    const responses=[];
    for(let i=0;i<=4;i++) {
      // A successful native click precedes asynchronous OS window creation.
      // Observe readiness without clicking Media again or granting permissions.
      const waitUntil=Math.min(deadline,Date.now()+20000);
      let deny=[],terminalStable=0;
      for(let poll=0;Date.now()<waitUntil;poll++) {
        const name=`permission-denial-${i}-poll-${poll}`,xml=await snapshot(name,waitUntil);
        deny=nodes(xml).filter(n=>n.package!==pkg && /^(Don.t allow|Deny)$/i.test(n.text || n['content-desc'] || ''));
        if(deny.length>1) throw new Error('Ambiguous OS denial prompt');
        if(deny.length===1) break;
        const window=fs.readFileSync(`${out}/${name}-window.txt`,'utf8');
        const input=fs.readFileSync(`${out}/${name}-input.txt`,'utf8');
        const focus=input.split('  FocusedWindows:')[1]?.split('  FocusRequests:')[0] ?? '';
        const osVisible=window.split(/(?=  Window #\d+ Window\{)/).some(b=>/^  Window #\d+ Window\{[^\n]*permissioncontroller[^\n]*\}:/.test(b) && !b.split('\n')[0].includes('EXITING') && b.includes('isVisible=true'));
        terminalStable=responses.length && !osVisible && focus.includes(`${pkg}/`) && nodes(xml).some(n=>n.package===pkg && n.displayed!=='false') ? terminalStable+1 : 0;
        log({type:'permission-readiness',i,poll,osVisible,terminalStable,waitUntil});
        if(terminalStable>=2) break;
        await pause(Math.min(750,Math.max(0,waitUntil-Date.now())));check();
      }
      if(!deny.length) {
        if(!responses.length) throw new Error('No genuine initial OS permission denial observed within bounded readiness wait');
        if(terminalStable<2) throw new Error('Denied permission route did not reach stable app state within bounded readiness wait');
        break;
      }
      if(i===4) throw new Error('More than four OS permission denial prompts observed');
      if(Date.now()>=waitUntil) throw new Error('OS denial prompt arrived after bounded readiness wait');
      const b=bounds(deny[0]);await mouse(Math.round((b[0]+b[2])/2),Math.round((b[1]+b[3])/2),'OS-permission-deny');responses.push(deny[0]);
    }
    if(!responses.length) throw new Error('No genuine initial OS permission denial observed');
    const denied=await snapshot('permission-denied-app-state'),deniedPermissions=adb('shell','dumpsys','package',pkg);fs.writeFileSync(`${out}/permissions-denied.txt`,deniedPermissions);if(/READ_MEDIA_(IMAGES|VIDEO): granted=true/.test(deniedPermissions)) throw new Error('OS denial did not leave media permission denied');
    if(assets(denied).length || nodes(denied).some(n=>n.package!==pkg && /^(Don.t allow|Deny)$/i.test(n.text || n['content-desc'] || ''))) throw new Error('Denied route exposes fixture assets or bounded prompt count exhausted');
    if(!/^\d+$/.test(adb('shell','pidof',pkg).trim())) throw new Error('App process did not survive genuine permission denial');
    result.controls.denial={responses,appLabels:labels(denied),pickerVisible:assets(denied).length>0};
    const settingsUntil=Math.min(deadline,Date.now()+60000);
    adbUntil(settingsUntil,'shell','am','start','-a','android.settings.APPLICATION_DETAILS_SETTINGS','-d',`package:${pkg}`);
    await settingsLabel(/^Permissions$/,'os-app-permissions',{navigate:true,until:settingsUntil});
    await settingsLabel(/^Photos and videos$/i,'os-media-permission',{until:settingsUntil});
    await settingsLabel(/^Allow(?: all(?: photos and videos)?)?$/i,'os-permission-grant',{until:settingsUntil});
    const grantedPermissions=adb('shell','dumpsys','package',pkg);fs.writeFileSync(`${out}/permissions-granted.txt`,grantedPermissions);if(!/READ_MEDIA_IMAGES: granted=true/.test(grantedPermissions) || !/READ_MEDIA_VIDEO: granted=true/.test(grantedPermissions)) throw new Error('Actual OS grant did not enable images and videos');await snapshot('permission-granted-os-state');
    adb('shell','am','force-stop',pkg);adb('shell','am','start','-n',`${pkg}/.MainActivity`);await ready();
    const opened=await entry('permission-granted-route');initial(opened);await indicator(opened);requireCount(await snapshot('permission-granted-select'),1);await key(4);
    const canceled=await snapshot('permission-granted-cancel');emptySend(canceled);
    result.controls.grant={pickerOpened:true,selectionThenCancel:true};
  } else if(phase==='core') {
    // Native Settings control and exact media sequence are separate inputs.
    adb('shell','am','start','-a','android.settings.SETTINGS');await pause(1500);await snapshot('native-control-before');await key(20);await key(20);await snapshot('native-control-after');await key(4);
    adb('shell','am','force-stop','com.android.tv.settings');adb('shell','am','force-stop','com.android.settings');adb('shell','am','start','-n',`${pkg}/.MainActivity`);await ready();
    const start=await entry('short');initial(start);const ordered=inventory('short-initial',start);await indicator(start);requireCount(await snapshot('mouse-selected'),1);await indicator(start);const reset=await snapshot('short-before-dpad');initial(reset);inventory('short-before-dpad',reset);
    await sequence();const short=await snapshot('short-after-dpad');
    await key(4);const fresh=await entry('fresh');initial(fresh);const freshOrdered=inventory('fresh-initial',fresh);if(JSON.stringify(ordered.map(f=>f.name))!==JSON.stringify(freshOrdered.map(f=>f.name))) throw new Error('Fresh core inventory order changed');await sequence();const after=await snapshot('fresh-after-dpad');
    if(env.ISSUE1864_APK==='production-candidate') {const prior=JSON.parse(fs.readFileSync(`${env.ISSUE1864_CORE_BASE_DIR}/short-initial-inventory.json`,'utf8'));if(JSON.stringify(prior.map(f=>f.name))!==JSON.stringify(ordered.map(f=>f.name))) throw new Error('Candidate core fixture order differs from clean base');}
    const expected=env.ISSUE1864_APK==='production-base' ? 0 : 1;requireCount(short,expected);requireCount(after,expected);
    result.controls.core={shortCount:count(short),freshCount:count(after),expected,keySequence:[20,20,22,23],pauseMs:650,betweenKeySnapshots:false};
    if(expected===1) {edgeEvidence('short-after-dpad',short);edgeEvidence('fresh-after-dpad',after);const picked=selectedFixture(after,freshOrdered);if(picked.name!=='green.jpg') throw new Error('Exact candidate sequence did not select retained green fixture');await returned(after,[picked],'core-return');}
    else {edgeEvidence('short-after-dpad',short,{baseline:true});edgeEvidence('fresh-after-dpad',after,{baseline:true});await indicator(after);const selected=await snapshot('base-mouse-return-selected');requireCount(selected,1);await returned(selected,[ordered[0]],'base-mouse-return');}
  } else {
    let xml=await entry(phase);if(phase!=='mixed') initial(xml);
    if(phase==='picker-cancel') {
      await indicator(xml);requireCount(await snapshot('cancel-selected'),1);await key(4);const send=await snapshot('cancel-return');emptySend(send);
      const reentered=await entry('cancel-reenter');initial(reentered);result.controls.cancel={selectedThenCanceled:true,reentryZero:true};
    } else if(phase==='pointer-count') {
      await center(xml);const preview=await snapshot('pointer-preview');previewState(preview,6);await key(4);xml=await snapshot('pointer-preview-return');requireCount(xml,0);
      await indicator(xml);requireCount(await snapshot('pointer-selected'),1);await indicator(xml);requireCount(await snapshot('pointer-reset'),0);
      await sequence();const selected=await snapshot('dpad-selected');requireCount(selected,expectedDpad);edgeEvidence('dpad-selected',selected,{baseline:expectedDpad===0});
      if(expectedDpad===1) {await key(23);requireCount(await snapshot('dpad-deselected'),0);} else {await key(4);xml=await entry('pointer-core-fresh');initial(xml);}
      const ordered=inventory(expectedDpad===0 ? 'pointer-core-fresh-initial' : 'pointer-count-initial',xml);await indicator(xml,0);requireCount(await snapshot('count-one'),1);await indicator(xml,1);requireCount(await snapshot('count-two'),2);await indicator(xml,0);const one=await snapshot('count-one-again');requireCount(one,1);await returned(one,[selectedFixture(one,ordered)],'count-return');
      result.controls.pointerCount={preview:true,pointerCounts:[0,1,0],dpadCounts:expectedDpad===1 ? [1,0] : [0],candidateDeselect:expectedDpad===1,multiCounts:[1,2,1]};
    } else if(phase==='folders') {
      await tapLabel(/^Recent$/,'expand-folders');const expanded=await snapshot('folders-expanded');if(!labels(expanded).includes('issue1864')) throw new Error('Expanded folder rows not visible');
      await key(20);await key(20);await key(23);const navigated=await snapshot('folders-remote-result');requireCount(navigated,0);
      if(!labels(navigated).includes('issue1864') || /(^|\n)Recent(\n|$)/.test(labels(navigated))) throw new Error('Remote folder change not established');
      await tapLabel(/^issue1864$/,'reopen-folders');await snapshot('folders-reopened');await tapLabel(/^Recent, /,'pointer-recent');xml=await snapshot('folders-pointer-collapse');initial(xml);
      await sequence();const after=await snapshot('folders-collapsed-tile-result');requireCount(after,expectedDpad);edgeEvidence('folders-collapsed-tile-result',after,{baseline:expectedDpad===0});
      result.controls.folders={expandedRemoteCount:0,remoteNamedFolder:'issue1864',pointerFolder:'Recent',collapsedTileCount:expectedDpad,manual:'Review original expanded arrows/Center frames for focus confined to visible rows; selected count alone is insufficient'};
    } else if(phase==='mixed') {
      const mixed=JSON.parse(fs.readFileSync(env.ISSUE1864_MIXED_MANIFEST,'utf8'));fs.copyFileSync(env.ISSUE1864_MIXED_MANIFEST,`${out}/mixed-fixture-manifest.json`);fixtureHashes('mixed-before',mixed.files);
      await tapLabel(/^Recent$/,'mixed-folders');await tapLabel(/^issue1864-mixed, /,'mixed-folder');xml=await snapshot('mixed-initial');requireCount(xml,0);
      if(assets(xml).length!==2 || !assets(xml).some(n=>/^Video/.test(n['content-desc'])) || !assets(xml).some(n=>/^Image/.test(n['content-desc']))) throw new Error('Mixed folder lacks exactly image and video semantics');
      for(let i=0;i<2;i++) {await center(xml,i);const preview=await snapshot(`mixed-preview-${i}`);previewState(preview,2);await key(4);requireCount(await snapshot(`mixed-preview-return-${i}`),0);await indicator(xml,i);requireCount(await snapshot(`mixed-selected-${i}`),1);await indicator(xml,i);requireCount(await snapshot(`mixed-deselected-${i}`),0);}
      await indicator(xml,0);await indicator(xml,1);const both=await snapshot('mixed-both-selected');requireCount(both,2);await returned(both,mixed.files,'mixed-return');result.controls.mixed={previewTypes:['image','video'],selectionCounts:[0,1,0,1,0,2],typesBoundary:'Image/Video picker semantics and MediaStore MIME; Edit proves names/sizes, not internal type field'};
    } else if(['theme-light','theme-dark'].includes(phase)) {
      await sequence();const after=await snapshot(`${phase}-focused`);requireCount(after,expectedDpad);edgeEvidence(`${phase}-focused`,after,{baseline:expectedDpad===0});result.controls.theme={mode:phase,verdict:'pending manual actual picker palette/outline review; shell system mode is recorded but does not prove picker theme'};
    } else throw new Error(`Unknown production phase ${phase}`);
  }
  result.observationsCompleteAt=Date.now();check();result.automatedObservationPassed=true;
} catch(error) {result.automatedObservationPassed=false;result.error={message:error.message,stack:error.stack};throw error;}
finally {
  fs.writeFileSync(`${out}/outcome.json`,JSON.stringify(result,null,2));
  if(session) {try {const response=await fetch(`http://127.0.0.1:4723/session/${session}`,{method:'DELETE',signal:AbortSignal.timeout(5000)});log({type:'session-cleanup',status:response.status});} catch(error) {log({type:'session-cleanup',error:error.message});}}
}
