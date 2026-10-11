// Diagnostic only. Run on the Actions runner connected to the issue1864 TV AVD.
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
const out = 'evidence-cloud';
const adb = (...args) => execFileSync('adb', args, { encoding: 'utf8', timeout: 30000 });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = data => fs.appendFileSync(`${out}/input-timings.jsonl`, JSON.stringify({ time: Date.now(), ...data }) + '\n');
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
function nodes(xml) {
  return [...xml.matchAll(/<[\w.$-]+\s+([^>]+)>?/g)].map(m => Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(a => [a[1], a[2]])));
}
async function mouseNode(label, name) {
  const xml = await snapshot(`${name}-before`);
  const node = nodes(xml).find(n => (n.text === label || n['content-desc'] === label || n['content-desc']?.startsWith(`${label}&#10;`)));
  let bounds;
  if (node) bounds = [...node.bounds.matchAll(/\d+/g)].map(n => Number(n[0]));
  else {
    const words = ocr(`${name}-before`).trim().split('\n').slice(1).map(line => line.split('\t'));
    const hits = words.filter(w => w[11] === label && Number(w[10]) > 40);
    if (hits.length !== 1) throw new Error(`Missing or ambiguous visible OCR label ${label}; inspect ${name}-before.png`);
    const word = hits[0];
    bounds = [Number(word[6]), Number(word[7]), Number(word[6]) + Number(word[8]), Number(word[7]) + Number(word[9])];
  }
  const x = Math.round((bounds[0] + bounds[2]) / 2), y = Math.round((bounds[1] + bounds[3]) / 2);
  log({ type: 'mouse', action: 'tap', label, x, y });
  adb('shell', 'input', 'mouse', 'tap', String(x), String(y));
  await pause(1200);
}
async function remote(key) {
  log({ type: 'dpad', action: 'keyevent', key });
  adb('shell', 'input', 'dpad', 'keyevent', String(key));
  await pause(650);
}
async function record(name, action) {
  const path = `/sdcard/issue1864-recordings/${name}.mp4`;
  const process = spawn('adb', ['shell', 'screenrecord', '--time-limit', '45', path]);
  const finished = new Promise(resolve => process.once('exit', (code, signal) => resolve({ code, signal })));
  process.stderr.on('data', data => fs.appendFileSync(`${out}/${name}-screenrecord.log`, data));
  log({ type: 'recording', action: 'start', name });
  await pause(900);
  await action();
  await pause(1200);
  adb('shell', 'pkill', '-INT', 'screenrecord');
  await finished;
  adb('pull', path, `${out}/${name}.mp4`);
  log({ type: 'recording', action: 'end', name });
}
adb('shell', 'settings', 'put', 'system', 'show_touches', '1');
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
await pause(2500);
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
  log({ type: 'mouse', action: 'tap', target: 'photo-1-selection-indicator', x, y });
  adb('shell', 'input', 'mouse', 'tap', String(x), String(y));
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
    for(const [index,key] of [20,20,22,23].entries()) {
      await remote(key); await snapshot(`${name}-key-${index+1}-${key}`);
    }
  });
}
await replay('media-dpad-original');
const after = await snapshot('media-after-dpad');
await remote(4);
await mouseNode('Media','fresh-open-media');
await pause(2000);
await snapshot('fresh-media-before-dpad');
await replay('fresh-media-dpad-original');
await snapshot('fresh-media-after-dpad');
fs.writeFileSync(`${out}/outcome.json`, JSON.stringify({
  mouseSelected: true,
  selectedPhotosAfterDpad: nodes(after).filter(n => /Image\d+,/.test(n['content-desc'] ?? '') && n.selected === 'true'),
  focusedNodesAfterDpad: nodes(after).filter(n => n.focused === 'true'),
  boundary: 'Original 1.15.4 APK, supplementary compatible emulator; not physical Sony Android TV 10',
}, null, 2));
await fetch(`http://127.0.0.1:4723/session/${session}`, { method: 'DELETE' });
