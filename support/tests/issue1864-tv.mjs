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
  return fs.readFileSync(`${out}/${name}.xml`, 'utf8');
}
function nodes(xml) {
  return [...xml.matchAll(/<[\w.$-]+\s+([^>]+)>?/g)].map(m => Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(a => [a[1], a[2]])));
}
async function mouseNode(label, name) {
  const xml = await snapshot(`${name}-before`);
  const node = nodes(xml).find(n => (n.text === label || n['content-desc'] === label || n['content-desc']?.startsWith(`${label}&#10;`)));
  if (!node) throw new Error(`Missing visible semantic label ${label}; inspect ${name}-before.png`);
  const bounds = [...node.bounds.matchAll(/\d+/g)].map(n => Number(n[0]));
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
  const process = spawn('adb', ['shell', 'screenrecord', '--time-limit', '15', path]);
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
adb('shell', 'am', 'force-stop', 'org.localsend.localsend_app');
adb('shell', 'am', 'start', '-n', 'org.localsend.localsend_app/.MainActivity');
await pause(2500);
await mouseNode('Send', 'open-send');
await mouseNode('Media', 'open-media');
await pause(3000);
const media = await snapshot('media-initial');
const photo = nodes(media).find(n => /^Image\d+,/.test(n['content-desc'] ?? ''));
if (!photo) throw new Error('First seeded photo is absent; inspect media-initial.png');
const photoLabel = photo['content-desc'].split(',')[0] + ',';
const bounds = [...photo.bounds.matchAll(/\d+/g)].map(n => Number(n[0]));
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
const selectedPhoto = nodes(selected).find(n => n['content-desc']?.startsWith(photoLabel));
if (selectedPhoto?.selected !== 'true') throw new Error('Mouse control did not select the first photo');
await mousePhoto();
await snapshot('media-reset-before-dpad');
await record('media-dpad-original', async () => {
  await remote(20); await remote(20); await remote(22); await remote(23);
});
const after = await snapshot('media-after-dpad');
fs.writeFileSync(`${out}/outcome.json`, JSON.stringify({
  mouseSelected: true,
  selectedPhotosAfterDpad: nodes(after).filter(n => n['content-desc']?.startsWith('Image') && n.selected === 'true'),
  focusedNodesAfterDpad: nodes(after).filter(n => n.focused === 'true'),
  boundary: 'Original 1.15.4 APK, supplementary compatible emulator; not physical Sony Android TV 10',
}, null, 2));
await fetch(`http://127.0.0.1:4723/session/${session}`, { method: 'DELETE' });
