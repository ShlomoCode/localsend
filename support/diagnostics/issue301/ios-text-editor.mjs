import { mkdir, writeFile, readFile, appendFile, rename, copyFile, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
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
async function nativeLetter(condition, source) {
  keyboardBounds(source);
  const keyboard = await single(`type == 'XCUIElementTypeKeyboard' AND visible == 1`);
  const keys = await wd(`/element/${keyboard}/elements`, 'POST', { using: '-ios predicate string',
    value: `type == 'XCUIElementTypeKey' AND (label == 'q' OR label == 'Q') AND enabled == 1 AND visible == 1` });
  if (keys.length !== 1) throw new Error('Exactly one observed native q/Q key required');
  const id = eid(keys[0]);
  const letter = await wd(`/element/${id}/attribute/label`);
  if (!['q', 'Q'].includes(letter) || !source.includes(`label="${letter}"`)) throw new Error('Native letter case not qualified');
  await save(`${condition}-native-key.json`, { letter, keyId: id, keyboardId: keyboard, bounds: await wd(`/element/${id}/rect`), mutation: 'one native key click' });
  await click(id);
  return letter;
}
async function fullValue(field, condition) {
  const value = await wd(`/element/${field}/attribute/value`);
  if (typeof value !== 'string') throw new Error('Native full text unavailable');
  await writeFile(path.join(out, `${condition}-full-value.txt`), value, { mode: 0o600 });
  await save(`${condition}-full-value.json`, { value, length: value.length, fieldRect: await wd(`/element/${field}/rect`), caretEvidence: 'original native source and screenshot; no synthetic caret' });
  return value;
}
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
async function retainVideo(video, id, cleanupDeadline) {
  const file = path.join(out, 'original-provider-video.mp4');
  try {
    const receipt = JSON.parse(await readFile(path.join(out, 'video-retention.json'), 'utf8'));
    const probe = JSON.parse(await readFile(path.join(out, 'video-probe.json'), 'utf8'));
    const decode = JSON.parse(await readFile(path.join(out, 'video-decode.json'), 'utf8'));
    if (receipt.retainedOriginal && receipt.providerSession === id && probe.validVideo && decode.fullDecodePassed &&
      createHash('sha256').update(await readFile(file)).digest('hex') === receipt.sha256) return;
  } catch {}
  try {
    const failed = JSON.parse(await readFile(path.join(out, 'video-validation-failure.json'), 'utf8'));
    if (failed.providerSession === id) throw Object.assign(new Error('Owned video acquisition already failed; reviewed recovery required'), { priorVideoFailure: true });
  } catch (error) { if (error.priorVideoFailure) throw error; }
  const remaining = limit => {
    const ms = cleanupDeadline - Date.now();
    if (ms < 500) throw new Error('Terminal session confirmed; bounded video validation needs follow-up');
    return Math.min(limit, ms);
  };
  const candidate = path.join(out, 'provider-video-candidate.mp4');
  await save('video-retention.json', { retainedOriginal: false, providerSession: id, validationPending: true });
  try {
    if (!video) throw new Error('Terminal session confirmed but original provider video URL is missing; media retention incomplete');
    const normalized = video.replace(/\\u0026/g, '&'); // Provider metadata sometimes contains literal escaped separators.
    const response = await fetch(normalized, { signal: AbortSignal.timeout(remaining(12000)) });
    const mime = (response.headers.get('content-type') || '').split(';')[0].toLowerCase();
    await save('video-http.json', { status: response.status, contentType: mime, providerSession: id });
    await pipeline(Readable.fromWeb(response.body), createWriteStream(candidate, { mode: 0o600 }));
    const bytes = await readFile(candidate);
    if (!response.ok || !mime.startsWith('video/') || bytes.length < 12 || bytes.toString('ascii', 4, 8) !== 'ftyp') throw new Error('Provider response is not validated HTTP video/MP4');
    const run = promisify(execFile);
    const probe = await run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', candidate], { timeout: remaining(5000), killSignal: 'SIGKILL', maxBuffer: 1024 * 1024 });
    const parsed = JSON.parse(probe.stdout);
    if (!parsed.streams?.some(s => s.codec_type === 'video') || !(Number(parsed.format?.duration) > 0)) throw new Error('Provider video probe lacks a usable video stream');
    await save('video-probe.json', { validVideo: true, ...parsed });
    const decoded = await run('ffmpeg', ['-nostdin', '-v', 'error', '-xerror', '-i', candidate, '-map', '0:v:0', '-vsync', '0', '-c:v', 'rawvideo', '-f', 'rawvideo', '-y', '/dev/null'], { timeout: remaining(12000), killSignal: 'SIGKILL', maxBuffer: 1024 * 1024 });
    await save('video-decode.json', { fullDecodePassed: true, exitCode: 0, stderr: decoded.stderr });
    await copyFile(candidate, file, constants.COPYFILE_EXCL); // Never overwrite an existing original.
    await unlink(candidate);
    await save('video-retention.json', { retainedOriginal: true, providerSession: id, sha256: createHash('sha256').update(bytes).digest('hex'), validHttpVideoAndMp4: true, fullDecodePassed: true });
  } catch (error) {
    try { await rename(candidate, path.join(out, `provider-video-invalid-or-unvalidated-${Date.now()}.private.bin`)); } catch {}
    await save('video-validation-failure.json', { ...errorReceipt(error), retainedOriginal: false, providerSession: id });
    throw error;
  }
}
function qualifyAdmission() {
  const admission = JSON.parse(process.env.COORDINATOR_ADMISSION_JSON || 'null');
  const now = Date.now(), admitted = Date.parse(admission?.admittedAt), expires = Date.parse(admission?.expiresAt);
  const jobDeadline = Date.parse(process.env.ISSUE301_JOB_DEADLINE_UTC);
  const requiredRemainingMs = 720000 + 65000;
  if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend' ||
      admission?.issue !== 301 || admission.stage !== 'issue301-round2-native-first-line-edit' || admission.sourceHead !== process.env.GITHUB_SHA ||
      admission.rootSelected !== true || admission.maxJobs !== 1 || admission.maxSessions !== 1 || admission.runAttempt !== '1' || process.env.GITHUB_RUN_ATTEMPT !== '1' ||
      typeof admission.reservationId !== 'string' || !admission.reservationId.trim() || admission.unknownManualHolds !== 2 ||
      !Number.isInteger(admission.totalPotentialBefore301) || admission.totalPotentialBefore301 < 2 || admission.totalPotentialBefore301 + 1 > 5 ||
      !Number.isFinite(admitted) || admitted > now || now - admitted > 300000 || !Number.isFinite(expires) || expires - now < requiredRemainingMs ||
      !Number.isFinite(jobDeadline) || jobDeadline - now < requiredRemainingMs) throw new Error('Fresh exact admission or remaining lease/job budget unavailable before device intent');
  return admission;
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
    let mediaVerified = false;
    for (let i = 0; i < 4; i++) {
      metadata = await cleanupRequest(`${api}/sessions/${id}.json`);
      await save('provider-terminal.private.json', metadata);
      const status = metadata.automation_session?.status;
      const terminal = ['done', 'passed', 'failed', 'error', 'timeout'].includes(status);
      await save('cleanup-verification.json', { id, status, terminal });
      const video = metadata.automation_session?.video_url;
      if (terminal && video) {
        await retainVideo(video, id, cleanupDeadline);
        mediaVerified = true;
        break;
      }
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
    const status = metadata.automation_session?.status;
    await save('cleanup-verification.json', { id, status, terminal: ['done', 'passed', 'failed', 'error', 'timeout'].includes(status) });
    if (!['done', 'passed', 'failed', 'error', 'timeout'].includes(status)) throw new Error('Provider terminal state not confirmed');
    if (!mediaVerified) await retainVideo(undefined, id, cleanupDeadline); // Reuse verified same-session receipts or fail explicitly for missing media.
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
  let failure;
  try {
    await save('coordinator-admission-input.json', qualifyAdmission());
    const apps = await request(`${api}/recent_apps?limit=100`);
    const selected = apps.filter(a => a.app_url === app);
    if (selected.length !== 1 || selected[0].app_version !== identity.version || selected[0].app_name !== 'localsend-c1ce-unsigned-device.ipa') throw new Error('Fixed app metadata mismatch');
    await save('selected-app.private.json', selected[0]);
    const inventory = await request(`${api}/devices.json`);
    if (!inventory.some(d => d.device === 'iPhone 16' && d.os === 'ios' && d.os_version === '18')) throw new Error('Selected device unavailable in inventory');
    await save('selected-device.json', { device: 'iPhone 16', os: 'ios', os_version: '18' });
    const admission = qualifyAdmission();
    const plan = await request(`${api}/plan.json`);
    await save('provider-capacity-before-intent.json', { at: new Date().toISOString(), plan });
    const running = plan.parallel_sessions_running, queued = plan.queued_sessions, capacity = plan.parallel_sessions_max_allowed;
    if (![running, queued, capacity].every(n => Number.isInteger(n) && n >= 0) || running + queued + admission.totalPotentialBefore301 + 1 > 5 || running + queued + 1 > capacity) throw new Error('Fresh provider capacity not available before device intent');
    qualifyAdmission();
    deadline = Date.now() + 720000;
    await save('intent.json', { name: ownName, at: new Date().toISOString(), maximumSessions: 1, deviceDeadlineSeconds: 720, reservationId: admission.reservationId });
    qualifyAdmission();
    const created = await request(`${hub}/session`, 'POST', { capabilities: { alwaysMatch: {
      platformName: 'iOS', 'appium:automationName': 'XCUITest', 'appium:deviceName': 'iPhone 16', 'appium:platformVersion': '18',
      'appium:app': app, 'appium:newCommandTimeout': 45,
      'bstack:options': { userName: user, accessKey: key, appiumVersion: '1.21.0', projectName: 'LocalSend sprint diagnostics', buildName: ownName, sessionName: ownName, idleTimeout: 45, video: true, debug: true },
    }, firstMatch: [{}] } }, 90000);
    sid = created.value?.sessionId || created.sessionId;
    if (!sid) throw new Error('Session creation outcome unknown');
    const caps = created.value?.capabilities || created.value || {};
    const safeCaps = Object.fromEntries(Object.entries(caps).filter(([k]) => /^(appium:)?(deviceName|platformVersion|automationName|platformName|app|bundleId|udid)$/.test(k)));
    await save('session.private.json', { id: sid, name: ownName, capabilities: safeCaps, deadline: new Date(deadline).toISOString() });
    const provider = await request(`${api}/sessions/${sid}.json`);
    await save('provider-environment.private.json', provider);
    if (provider.automation_session?.name !== ownName || provider.automation_session?.device !== 'iPhone 16' || provider.automation_session?.os_version !== '18.5') throw new Error('Exact owned iPhone16/iOS18.5 environment not confirmed');
    await save('automation-pin.json', { requestedAppiumVersion: '1.21.0', nativeRoutes: 'existing W3C routes only' });
    let source = await capture('startup');
    if (/XCUIElementTypeAlert\b/.test(source)) {
      const title = 'Allow “LocalSend” to find devices on local networks?';
      const alerts = [...source.matchAll(/<XCUIElementTypeAlert\b[^>]*>[\s\S]*?<\/XCUIElementTypeAlert>/g)];
      const application = source.match(/<XCUIElementTypeApplication\b[^>]*>/)?.[0] || '';
      if (!/bundleId="com\.apple\.springboard"/.test(application) || alerts.length !== 1 ||
        !alerts[0][0].includes(`label="${title}"`) || !alerts[0][0].includes('The app uses the local network to find and connect to nearby devices.')) throw new Error('Unexpected startup alert');
      const alert = await single(`type == 'XCUIElementTypeAlert' AND label == '${title}' AND visible == 1`);
      const allow = await wd(`/element/${alert}/elements`, 'POST', {
        using: '-ios predicate string', value: `type == 'XCUIElementTypeButton' AND label == 'Allow' AND enabled == 1 AND visible == 1`,
      });
      if (allow.length !== 1) throw new Error('Expected exactly one Allow button inside the owned local-network alert');
      await click(eid(allow[0])); // One mutation only; subsequent readiness observations never replay it.
      for (let attempt = 1; attempt <= 3; attempt++) {
        source = await capture(`startup-local-network-allowed-${attempt}`);
        const root = source.match(/<XCUIElementTypeApplication\b[^>]*>/)?.[0] || '';
        if (!/XCUIElementTypeAlert\b/.test(source) && /bundleId="org\.localsend\.localsendApp"/.test(root) && /(?:name|label)="LocalSend"/.test(root)) break;
        if (/XCUIElementTypeAlert\b/.test(source) && !source.includes(`label="${title}"`)) throw new Error('Unexpected alert after local-network permission');
        if (attempt === 3) throw new Error('Local-network alert disappearance and owned app readiness not confirmed');
        await new Promise(resolve => setTimeout(resolve, 500));
      }
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
    const shortSource = await capture('short-control');
    const shortBefore = await fullValue(field, 'short-native-before');
    const shortLetter = await nativeLetter('short-native', shortSource);
    await capture('short-native-after-key');
    const shortAfter = await fullValue(field, 'short-native-after');
    await save('short-native-control.json', { exactAppend: shortAfter === shortBefore + shortLetter, letter: shortLetter });
    if (shortAfter !== shortBefore + shortLetter) throw new Error('Short native key append control not qualified');
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
    for (let n = 1; n <= 6; n++) await swipe(field, 'toward-top', `long-portrait-toward-top-${n}`);
    const beforeTap = await capture('long-first-line-before-tap');
    const fieldRect = await wd(`/element/${field}/rect`);
    const screen = await wd('/window/rect');
    const keyboard = keyboardBounds(beforeTap);
    const png = await readFile(path.join(out, 'long-first-line-before-tap.png'));
    const mapped = { sourceRun: '38280104322', sourceScreenshot: 'long-portrait-toward-top-6.png', x: 120, y: 167,
      field: { x: 80, y: 155, width: 233, height: 286 }, screen: { x: 0, y: 0, width: 393, height: 852 },
      keyboard: { x: 0, y: 561, width: 393, height: 233 }, screenshot: { width: 1178, height: 2556 }, visualAuditRequired: true };
    await save('first-line-mapping.json', { mapped, actualField: fieldRect, actualScreen: screen, actualKeyboard: keyboard });
    for (const [expected, actual] of [[mapped.field, fieldRect], [mapped.screen, screen], [mapped.keyboard, keyboard]]) {
      if (Object.entries(expected).some(([k, v]) => actual[k] !== v)) throw new Error('Original first-line geometry changed; tap is not qualified');
    }
    if (png.readUInt32BE(16) !== mapped.screenshot.width || png.readUInt32BE(20) !== mapped.screenshot.height) throw new Error('Original screenshot geometry changed; tap is not qualified');
    const longBefore = await fullValue(field, 'long-first-line-before');
    if (longBefore !== long) throw new Error('Long fixture changed before the mapped tap');
    await log('one-mapped-first-line-tap', { x: mapped.x, y: mapped.y });
    await wd('/actions', 'POST', { actions: [{ type: 'pointer', id: 'owned-finger', parameters: { pointerType: 'touch' }, actions: [
      { type: 'pointerMove', duration: 0, x: mapped.x, y: mapped.y, origin: 'viewport' }, { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: 100 }, { type: 'pointerUp', button: 0 },
    ] }] }, 12000);
    const afterTap = await capture('long-first-line-after-tap');
    if (await fullValue(field, 'long-first-line-after-tap') !== long) throw new Error('Mapped tap changed fixture; native key condition not qualified');
    const afterTapRect = await wd(`/element/${field}/rect`);
    const afterTapKeyboard = keyboardBounds(afterTap);
    if (Object.entries(mapped.field).some(([k, v]) => afterTapRect[k] !== v) || Object.entries(mapped.keyboard).some(([k, v]) => afterTapKeyboard[k] !== v)) throw new Error('Geometry changed after mapped tap; native key condition not qualified');
    const letter = await nativeLetter('long-first-line', afterTap);
    await capture('long-first-line-after-key');
    const longAfter = await fullValue(field, 'long-first-line-after-key');
    const first = long.split('\n')[0];
    const firstAfter = longAfter.split('\n')[0];
    const insertionOffsets = Array.from({ length: first.length + 1 }, (_, i) => i).filter(i => firstAfter === first.slice(0, i) + letter + first.slice(i));
    const restExact = longAfter.split('\n').slice(1).join('\n') === long.split('\n').slice(1).join('\n');
    const qualified = insertionOffsets.length > 0 && restExact && longAfter.length === long.length + 1;
    await save('long-native-insertion.json', { letter, insertionOffsets, rest29LinesExact: restExact, singleLetterFirstLineDelta: qualified, runtimeVisualAuditRequired: true, reproduced: null });
    if (!qualified) throw new Error('Native insertion location uncertain; no product bug classification');
    for (let n = 1; n <= 6; n++) await swipe(field, 'toward-bottom', `long-portrait-toward-bottom-${n}`);
    await integrity(field, longAfter, 'long-portrait-after');
    await fullValue(field, 'long-return-last-line');
    await click(await button('Cancel'));
    await capture('long-portrait-cancelled');
    await save('result.json', { stage: 'observations-retained', productConditions: ['short-native-keyboard-letter-control', 'long-first-line-tap-native-letter-return-last-line'], fixtureIntegrity: true, firstAndLastLineReachability: 'requires-original-visual-review', caretAndInsertionLocation: 'requires-original-visual-review', reproduced: null, transferAttempted: false });
  } catch (error) {
    failure = error;
    await save('failure.json', { stage: 'qualification-or-capture', ...errorReceipt(error), replayAllowed: false });
  } finally {
    try { await cleanup(); } catch (error) { await save('cleanup-failure.json', { ...errorReceipt(error), coordinatorReconciliationRequired: true }); failure ||= error; }
  }
  if (failure) process.exitCode = 1;
}
