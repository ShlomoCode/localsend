// Diagnostic only. Run on the Actions runner connected to the issue1864 TV AVD.
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
const out = 'evidence-cloud';
const adb = (...args) => execFileSync('adb', args, { encoding: 'utf8', timeout: 30000 });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = data => fs.appendFileSync(`${out}/input-timings.jsonl`, JSON.stringify({ time: Date.now(), ...data }) + '\n');
async function snapshot(name) {
  adb('shell', 'uiautomator', 'dump', '/sdcard/ui.xml');
  adb('pull', '/sdcard/ui.xml', `${out}/${name}.xml`);
  fs.writeFileSync(`${out}/${name}.png`, execFileSync('adb', ['exec-out', 'screencap', '-p']));
  fs.writeFileSync(`${out}/${name}-window.txt`, adb('shell', 'dumpsys', 'window', 'windows'));
  return fs.readFileSync(`${out}/${name}.xml`, 'utf8');
}
function nodes(xml) {
  return [...xml.matchAll(/<node\s+([^>]+)>?/g)].map(m => Object.fromEntries([...m[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(a => [a[1], a[2]])));
}
async function mouseNode(label, name) {
  const xml = await snapshot(`${name}-before`);
  const node = nodes(xml).find(n => (n.text === label || n['content-desc'] === label));
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
  const process = spawn('adb', ['shell', 'screenrecord', '--time-limit', '15', `/sdcard/${name}.mp4`]);
  log({ type: 'recording', action: 'start', name });
  await pause(900);
  await action();
  await pause(1200);
  adb('shell', 'pkill', '-INT', 'screenrecord');
  await new Promise(resolve => process.on('exit', resolve));
  adb('pull', `/sdcard/${name}.mp4`, `${out}/${name}.mp4`);
  log({ type: 'recording', action: 'end', name });
}
adb('shell', 'settings', 'put', 'system', 'show_touches', '1');
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
await snapshot('media-initial');
// Inspect this screenshot before choosing a photo's actual mouse target.
// The D-pad experiment follows only after successful mouse selection control.
fs.writeFileSync(`${out}/pending-control.txt`, 'Review media-initial.png; mouse photo selection control is still pending.\n');
