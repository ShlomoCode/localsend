import { mkdir, writeFile, readFile, appendFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createWriteStream } from 'node:fs';
import path from 'node:path';

// Diagnostic only. Run on the fork Actions runner, never on the management Mac.
const out = path.resolve(process.env.EVIDENCE_DIR || 'evidence301');
await mkdir(out, { recursive: true, mode: 0o700 });
const user = process.env.BS_SPRINT_USERNAME;
const key = process.env.BS_SPRINT_ACCESS_KEY;
if (!user || !key) throw new Error('Missing BrowserStack credentials');
const auth = `Basic ${Buffer.from(`${user}:${key}`).toString('base64')}`;
const hub = 'https://hub-cloud.browserstack.com/wd/hub';
const api = 'https://api-cloud.browserstack.com/app-automate';
const app = 'bs://4750eafebb15101bf6a61e9d8fc6632a43b20735';
const identity = { app, source: 'c1ce322fb3acf08e44f329b8b7208b8b0d91e244', version: '1.18.2', ipaSha256: 'abe84652465ce8add78f25a50e5c3bcceeac87d4e4f084c53d73d0b21cc06c27', buildRun: '38135768528', artifactId: '11701275665', resigning: 'normal BrowserStack resigning' };
const ownName = `issue301-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}`;
const save = (name, obj) => writeFile(path.join(out, name), JSON.stringify(obj, null, 2), { mode: 0o600 });
const log = (event, data = {}) => appendFile(path.join(out, 'input-timestamps.jsonl'), `${JSON.stringify({ at: new Date().toISOString(), event, ...data })}\n`, { mode: 0o600 });
const errorReceipt = error => ({ error: error.name, status: error.remoteStatus ?? null, remoteError: error.remoteError ?? null, route: error.remoteRoute ?? null,
  message: String(error.message).replaceAll(user, '<redacted>').replaceAll(key, '<redacted>').replace(/https?:\/\/\S+/g, '<url-redacted>') });
let sid;
let mutationsStopped = false;
let deadline;
async function request(url, method = 'GET', body, ms = 8000) {
  const res = await fetch(url, { method, headers: { Authorization: auth, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(ms) });
  const json = await res.json();
  if (!res.ok || json.value?.error) {
    const message = String(json.value?.message || json.message || '').replaceAll(user, '<redacted>').replaceAll(key, '<redacted>')
      .replace(/https?:\/\/\S+/g, '<url-redacted>').replace(/(?:authorization|userName|accessKey)\s*[:=]\s*\S+/gi, '<credential-redacted>');
    await log('remote-error', { route: new URL(url).pathname, method, status: res.status, error: json.value?.error || 'HTTP', message: message.slice(0, 1500) });
    throw Object.assign(new Error(`Remote command failed (${res.status}, ${json.value?.error || 'HTTP'}): ${message.slice(0, 1500)}`), {
      remoteStatus: res.status, remoteError: json.value?.error || 'HTTP', remoteRoute: new URL(url).pathname,
    });
  }
  return json;
}
async function wd(route, method = 'GET', body, ms = 8000) {
  if (method !== 'GET' && (mutationsStopped || Date.now() >= deadline)) throw new Error('Product mutations stopped');
  await log('command-start', { method, route, body });
  try {
    const response = await request(`${hub}/session/${sid}${route}`, method, body, ms);
    await log('command-end', { method, route });
    return response.value;
  } catch (error) {
    mutationsStopped = true;
    await log('command-failed-stop-mutations', { method, route });
    throw error;
  }
}
async function elements(predicate) {
  return wd('/elements', 'POST', { using: '-ios predicate string', value: predicate });
}
const eid = e => e['element-6066-11e4-a52e-4f735466cecf'] || e.ELEMENT;
async function single(predicate) {
  const found = await elements(predicate);
  if (found.length !== 1) throw new Error(`Expected exactly one native control; got ${found.length}`);
  return eid(found[0]);
}
const button = label => single(`type == 'XCUIElementTypeButton' AND (label == '${label}' OR name == '${label}') AND visible == 1`);
const click = id => wd(`/element/${id}/click`, 'POST', {});
const editable = () => single(`(type == 'XCUIElementTypeTextView' OR type == 'XCUIElementTypeTextField') AND enabled == 1 AND visible == 1`);
async function capture(name) {
  const source = await wd('/source'); // WDA can take >3 s; retain the explicit 8 s bound.
  await writeFile(path.join(out, `${name}.xml`), source, { mode: 0o600 });
  const screenshot = await wd('/screenshot');
  await writeFile(path.join(out, `${name}.png`), Buffer.from(screenshot, 'base64'), { mode: 0o600 });
  await log('capture', { name });
  return source;
}
function keyboardBounds(source) {
  const tag = source.match(/<XCUIElementTypeKeyboard\b[^>]*>/)?.[0];
  if (!tag || !/visible="true"/.test(tag)) throw new Error('Visible native keyboard not confirmed');
  const n = attribute => Number(tag.match(new RegExp(`${attribute}="([^"]+)"`))?.[1]);
  const bounds = { x: n('x'), y: n('y'), width: n('width'), height: n('height') };
  if (!Object.values(bounds).every(Number.isFinite) || bounds.height <= 0) throw new Error('Keyboard bounds unavailable');
  return bounds;
}
async function integrity(id, text, condition) {
  const value = await wd(`/element/${id}/attribute/value`);
  await save(`${condition}-integrity.json`, { exact: value === text, expectedSha256: createHash('sha256').update(text).digest('hex'), actualSha256: createHash('sha256').update(String(value)).digest('hex'), semanticValueIsNotVisualEndpointProof: true });
  if (value !== text) throw new Error('Native editor readback differs from fixture');
}
async function swipe(id, direction, name) {
  const source = await wd('/source');
  const keyboard = keyboardBounds(source);
  const r = await wd(`/element/${id}/rect`);
  const screen = await wd('/window/rect');
  const left = Math.max(0, r.x) + 12;
  const right = Math.min(screen.width, r.x + r.width) - 12;
  const top = Math.max(0, r.y) + 12;
  const bottom = Math.min(screen.height, keyboard.y, r.y + r.height) - 12;
  if (![left, right, top, bottom].every(Number.isFinite) || right - left < 20 || bottom - top < 60) throw new Error('No safe inside-field gesture region');
  const x = Math.round((left + right) / 2);
  const startY = Math.round(direction === 'toward-top' ? top : bottom);
  const endY = Math.round(direction === 'toward-top' ? bottom : top);
  await log('inside-field-swipe', { direction, bounds: r, keyboard, x, startY, endY });
  await wd('/actions', 'POST', { actions: [{ type: 'pointer', id: 'owned-finger', parameters: { pointerType: 'touch' }, actions: [
    { type: 'pointerMove', duration: 0, x, y: startY, origin: 'viewport' },
    { type: 'pointerDown', button: 0 }, { type: 'pause', duration: 120 },
    { type: 'pointerMove', duration: 550, x, y: endY, origin: 'viewport' },
    { type: 'pointerUp', button: 0 },
  ] }] }, 12000);
  await capture(name);
}
async function cleanup() {
  const cleanupDeadline = Date.now() + 55000;
  const cleanupRequest = (url, method = 'GET', body, ms = 8000) => {
    const remaining = cleanupDeadline - Date.now();
    if (remaining < 500) throw new Error('Cleanup budget exhausted; coordinator reconciliation required');
    return request(url, method, body, Math.min(ms, remaining));
  };
  let record;
  try { record = JSON.parse(await readFile(path.join(out, 'session.private.json'), 'utf8')); } catch {}
  let intent;
  try { intent = JSON.parse(await readFile(path.join(out, 'intent.json'), 'utf8')); } catch { return; }
  if (intent.name !== ownName) throw new Error('Cleanup ownership mismatch');
  let ids = record?.id ? [record.id] : [];
  if (!ids.length) {
    const builds = await cleanupRequest(`${api}/builds.json?limit=20`);
    const matching = builds.filter(b => b.automation_build?.name === ownName);
    if (matching.length > 1) throw new Error('Ambiguous cleanup build ownership');
    if (matching.length === 1) {
      const sessions = await cleanupRequest(`${api}/builds/${matching[0].automation_build.hashed_id}/sessions.json`);
      ids = sessions.filter(s => s.automation_session?.name === ownName).map(s => s.automation_session.hashed_id);
    }
  }
  if (ids.length > 1) throw new Error('One-session invariant violated; coordinator reconciliation required');
  for (const id of ids) {
    let metadata = await cleanupRequest(`${api}/sessions/${id}.json`);
    if (metadata.automation_session?.name !== ownName) throw new Error('Provider session ownership mismatch');
    await save('provider-before-cleanup.private.json', metadata);
    if (!['done', 'passed', 'failed', 'error', 'timeout'].includes(metadata.automation_session?.status)) {
      const deleted = await cleanupRequest(`${hub}/session/${id}`, 'DELETE', undefined, 15000);
      await save('cleanup-delete.json', { id, at: new Date().toISOString(), response: deleted });
    }
    for (let i = 0; i < 4; i++) {
      metadata = await cleanupRequest(`${api}/sessions/${id}.json`);
      await save('provider-terminal.private.json', metadata);
      const status = metadata.automation_session?.status;
      const terminal = ['done', 'passed', 'failed', 'error', 'timeout'].includes(status);
      await save('cleanup-verification.json', { id, status, terminal });
      const video = metadata.automation_session?.video_url;
      if (terminal && video) {
        const remaining = cleanupDeadline - Date.now();
        if (remaining < 500) throw new Error('Terminal session confirmed; original video retention needs follow-up');
        const response = await fetch(video, { signal: AbortSignal.timeout(Math.min(20000, remaining)) });
        if (!response.ok) throw new Error('Original provider video download failed');
        await pipeline(Readable.fromWeb(response.body), createWriteStream(path.join(out, 'original-provider-video.mp4'), { mode: 0o600 }));
        await save('video-retention.json', { retainedOriginal: true, providerSession: id });
        break;
      }
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
    const status = metadata.automation_session?.status;
    await save('cleanup-verification.json', { id, status, terminal: ['done', 'passed', 'failed', 'error', 'timeout'].includes(status) });
    if (!['done', 'passed', 'failed', 'error', 'timeout'].includes(status)) throw new Error('Provider terminal state not confirmed');
  }
  if (!ids.length) await save('cleanup-unresolved.json', { noSessionFound: true, reconcileBeforeNextAttempt: true });
}
if (process.argv.includes('--cleanup')) {
  try { await cleanup(); } catch (error) {
    await save('cleanup-failure.json', { ...errorReceipt(error), coordinatorReconciliationRequired: true });
    process.exitCode = 1;
  }
} else {
  await save('identity.json', identity);
  await save('intent.json', { name: ownName, at: new Date().toISOString(), maximumSessions: 1, deviceDeadlineSeconds: 720 });
  let failure;
  try {
    const apps = await request(`${api}/recent_apps?limit=100`);
    const selected = apps.filter(a => a.app_url === app);
    if (selected.length !== 1 || selected[0].app_version !== identity.version || selected[0].app_name !== 'localsend-c1ce-unsigned-device.ipa') throw new Error('Fixed app metadata mismatch');
    await save('selected-app.private.json', selected[0]);
    const inventory = await request(`${api}/devices.json`);
    if (!inventory.some(d => d.device === 'iPhone 16' && d.os === 'ios' && d.os_version === '18')) throw new Error('Selected device unavailable in inventory');
    await save('selected-device.json', { device: 'iPhone 16', os: 'ios', os_version: '18' });
    deadline = Date.now() + 720000;
    const created = await request(`${hub}/session`, 'POST', { capabilities: { alwaysMatch: {
      platformName: 'iOS', 'appium:automationName': 'XCUITest', 'appium:deviceName': 'iPhone 16', 'appium:platformVersion': '18',
      'appium:app': app, 'appium:newCommandTimeout': 45,
      'bstack:options': { userName: user, accessKey: key, projectName: 'LocalSend sprint diagnostics', buildName: ownName, sessionName: ownName, idleTimeout: 45, video: true, debug: true },
    }, firstMatch: [{}] } }, 90000);
    sid = created.value?.sessionId || created.sessionId;
    if (!sid) throw new Error('Session creation outcome unknown');
    const caps = created.value?.capabilities || created.value || {};
    const safeCaps = Object.fromEntries(Object.entries(caps).filter(([k]) => /^(appium:)?(deviceName|platformVersion|automationName|platformName|app|bundleId|udid)$/.test(k)));
    await save('session.private.json', { id: sid, name: ownName, capabilities: safeCaps, deadline: new Date(deadline).toISOString() });
    let source = await capture('startup');
    if (/XCUIElementTypeAlert\b/.test(source)) {
      if (!source.includes('LocalSend') || !source.includes('devices on your local network')) throw new Error('Unexpected startup alert');
      await click(await button('Allow'));
      source = await capture('startup-local-network-allowed');
    }
    const application = source.match(/<XCUIElementTypeApplication\b[^>]*>/)?.[0];
    if (!application || !/bundleId="org\.localsend\.localsendApp"/.test(application) || !/(?:name|label)="LocalSend"/.test(application)) throw new Error('Owned LocalSend application not confirmed');
    if (await wd('/orientation') !== 'PORTRAIT') throw new Error('Portrait prerequisite not met');
    await click(await single(`label BEGINSWITH 'Send' AND label CONTAINS 'Tab 2 of 3' AND accessible == 1 AND visible == 1`));
    await click(await button('Text'));
    let field = await editable();
    const short = 'CONTROL 301 first\nCONTROL 301 last';
    await click(field);
    await wd(`/element/${field}/value`, 'POST', { text: short }, 20000);
    await integrity(field, short, 'short-control');
    keyboardBounds(await capture('short-control'));
    await save('short-control-observation.json', { exactValue: true, visualReviewRequired: true });
    await click(await button('Cancel'));
    await capture('short-control-cancelled');
    await click(await button('Text'));
    field = await editable();
    const long = Array.from({ length: 30 }, (_, i) => `LINE ${String(i + 1).padStart(2, '0')} 301 unique text`).join('\n');
    await writeFile(path.join(out, 'long-fixture.txt'), long, { mode: 0o600 });
    await click(field);
    await wd(`/element/${field}/value`, 'POST', { text: long }, 30000);
    await integrity(field, long, 'long-portrait-before');
    keyboardBounds(await capture('long-portrait-before'));
    for (const direction of ['toward-top', 'toward-bottom']) {
      for (let n = 1; n <= 6; n++) await swipe(field, direction, `long-portrait-${direction}-${n}`);
    }
    await integrity(field, long, 'long-portrait-after');
    await click(await button('Cancel'));
    await capture('long-portrait-cancelled');
    await save('result.json', { stage: 'observations-retained', productConditions: ['short-control', 'long-portrait-keyboard-visible'], fixtureIntegrity: true, firstAndLastLineReachability: 'requires-original-visual-review', reproduced: null, transferAttempted: false });
  } catch (error) {
    failure = error;
    await save('failure.json', { stage: 'qualification-or-capture', ...errorReceipt(error), replayAllowed: false });
  } finally {
    try { await cleanup(); } catch (error) { await save('cleanup-failure.json', { ...errorReceipt(error), coordinatorReconciliationRequired: true }); failure ||= error; }
  }
  if (failure) process.exitCode = 1;
}
