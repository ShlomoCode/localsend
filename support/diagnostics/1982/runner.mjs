import assert from 'node:assert/strict';
import net from 'node:net';
import {randomBytes, createHash} from 'node:crypto';
import {readFileSync, writeFileSync} from 'node:fs';
import {relay} from './reused/cloud_transport/relay.mjs';

const expectedSource = 'c1ce322fb3acf08e44f329b8b7208b8b0d91e244';
const expectedApk = '4e83fb49ae093995d11987948a2ac9f9c5b8b368cc98a49851de472a4067aaef';
const expectedSigner = 'f88aa73f86bf2a235abc0ffe6ee56179bed520e48be843386c10368283df24ea';
const provenance = JSON.parse(readFileSync('source-pair/baseline/provenance.json', 'utf8'));
assert.equal(provenance.source_sha, expectedSource);
assert.equal(provenance.apk_sha256, expectedApk);
assert.equal(provenance.tracked_source_unchanged, true);
assert.equal(provenance.post_build_source_or_bytecode_modification, false);
assert.equal(createHash('sha256').update(readFileSync('source-pair/baseline/app-arm64-v8a-release.apk')).digest('hex'), expectedApk);
assert.equal(readFileSync('current-reuse/provenance/source-sha.txt', 'utf8').trim(), expectedSource);
assert.equal(createHash('sha256').update(readFileSync('current-reuse/source-bundle.tar.gz')).digest('hex'), '98f6e749c0eb470b7d2bb4a365f704328ae7dc4bbc6d78ddf2d574dfb63cc20b');
const token = process.env.RELAY_TOKEN;
assert(token && /^[0-9a-f]{48}$/.test(token));
assert(/^bs:\/\/[0-9a-f]{40}$/.test(process.env.HELPER_APP || ''));
assert.equal(provenance.browserstack_app_url, 'bs://6b6263a47e4923fd6caa200636a98f0184e7f928');
const jobStart = Number(process.env.ISSUE1982_JOB_STARTED_MS);
assert(Number.isFinite(jobStart) && jobStart > 0);
const cleanupBoundary = jobStart + 35 * 60_000;
assert(Date.now() < jobStart + 10 * 60_000, 'Setup exceeded ten minutes; do not allocate a device');
const auth = 'Basic ' + Buffer.from(process.env.BROWSERSTACK_USERNAME + ':' + process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const senderPort = 53318;
const r = relay({token, tcpPort:senderPort});
const audit = [];
let session;
let allocation;
let scenarioStarted;
let indeterminateInput = false;
const helperLocators = new Map();
let knownPackage = 'org.localsend.cloudtransport';
const allowedHelperControls = new Set(['Start socket control', 'Stop helper', 'Relay to LocalSend', 'Inspect LocalSend APK']);
function safe(value) {
  if (typeof value === 'string') {
    for (const secret of [process.env.BROWSERSTACK_USERNAME, process.env.BROWSERSTACK_ACCESS_KEY, token]) if (secret) value = value.replaceAll(secret, '[redacted]');
    return value;
  }
  if (Array.isArray(value)) return value.map(safe);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, safe(item)]));
  return value;
}
function persist() {
  writeFileSync('evidence/webdriver-audit.json', JSON.stringify(audit, null, 2));
  writeFileSync('evidence/relay-trace.json', JSON.stringify(r.trace, null, 2));
}
const evidenceTimer = setInterval(persist, 1000);
evidenceTimer.unref();
async function wd(method, path, body, options = {}) {
  const cleanup = options.cleanup === true;
  const isInput = method === 'POST' && (/\/(?:click|actions|back|activate_app)$/.test(path));
  if (!cleanup) {
    assert(!indeterminateInput, 'Previous input had an indeterminate result; no further input or scenario RPC');
    assert(Date.now() < cleanupBoundary, 'Cleanup reserve reached');
    if (scenarioStarted) assert(Date.now() < scenarioStarted + 25 * 60_000, 'Product-stage budget reached');
  }
  const clickId = path.match(/\/element\/([^/]+)\/click$/)?.[1];
  const locator = clickId ? helperLocators.get(clickId) : null;
  if (isInput && knownPackage === 'org.localsend.cloudtransport') {
    assert(clickId && locator?.using === 'accessibility id' && allowedHelperControls.has(locator.value), 'Only verified transport or public package-inspection controls may be used in the helper');
  }
  const entry = {startedUtc:new Date().toISOString(), method, path, body:safe(body), input:isInput, knownPackage};
  audit.push(entry);
  try {
    const timeout = path === '/session' ? 240_000 : cleanup ? 15_000 : options.timeoutMs ?? 15_000;
    const remaining = cleanup ? timeout : Math.min(timeout, cleanupBoundary - Date.now(), scenarioStarted ? scenarioStarted + 25 * 60_000 - Date.now() : timeout);
    const response = await fetch('https://hub-cloud.browserstack.com/wd/hub' + path, {
      method, headers:{authorization:auth, 'content-type':'application/json'},
      body:body ? JSON.stringify(body) : undefined, signal:AbortSignal.timeout(Math.max(1, remaining)),
    });
    const json = await response.json();
    entry.status = response.status;
    if (!response.ok || json.value?.error) {
      if (path === '/session' && allocation) {
        allocation.failureResponse = {status:response.status, error:safe(String(json.value?.error || ''))};
        writeFileSync('evidence/allocation-intent.json', JSON.stringify(allocation, null, 2));
      }
      throw new Error('WebDriver ' + response.status + ' ' + safe(String(json.value?.error || '')) + ' ' + safe(String(json.value?.message || '')).slice(0, 1500));
    }
    if (method === 'POST' && /\/elements?$/.test(path)) for (const element of Array.isArray(json.value) ? json.value : [json.value]) {
      if (element?.['element-6066-11e4-a52e-4f735466cecf']) helperLocators.set(element['element-6066-11e4-a52e-4f735466cecf'], body);
    }
    if (method === 'POST' && path.endsWith('/activate_app')) knownPackage = body.appId;
    if (method === 'GET' && path.endsWith('/current_package')) knownPackage = json.value;
    entry.completedUtc = new Date().toISOString();
    persist();
    return json.value;
  } catch (error) {
    entry.error = safe(String(error));
    entry.completedUtc = new Date().toISOString();
    // An aborted input response does not establish whether the device performed it.
    if (isInput && !entry.status) indeterminateInput = true;
    persist();
    throw error;
  }
}
async function helperClick(name) {
  assert(allowedHelperControls.has(name));
  const element = await wd('POST', `/session/${session}/element`, {using:'accessibility id', value:name});
  const id = element['element-6066-11e4-a52e-4f735466cecf'];
  assert(await wd('GET', `/session/${session}/element/${id}/enabled`));
  assert(await wd('GET', `/session/${session}/element/${id}/displayed`));
  await wd('POST', `/session/${session}/element/${id}/click`, {});
}
const controls = [];
try {
  await r.start();
  const planResponse = await fetch('https://api-cloud.browserstack.com/app-automate/plan.json', {headers:{authorization:auth}, signal:AbortSignal.timeout(30_000)});
  assert(planResponse.ok, 'Capacity query failed');
  const plan = await planResponse.json();
  writeFileSync('evidence/fresh-capacity.json', JSON.stringify({checkedUtc:new Date().toISOString(), running:plan.parallel_sessions_running, maximum:plan.parallel_sessions_max_allowed, queued:plan.queued_sessions, heldManualSlots:2}, null, 2));
  assert(Number(plan.parallel_sessions_max_allowed) >= 5 && Number(plan.parallel_sessions_running) < 3 && Number(plan.queued_sessions) === 0, 'Conservative five-slot capacity gate failed; do not queue');
  const caps = {platformName:'Android', 'appium:deviceName':'Samsung Galaxy S21', 'appium:platformVersion':'11.0', 'appium:automationName':'UiAutomator2', 'appium:app':process.env.HELPER_APP,
    'appium:otherApps':[provenance.browserstack_app_url], 'appium:autoGrantPermissions':false,
    'bstack:options':{local:true, localIdentifier:process.env.BS_LOCAL_ID, projectName:'LocalSend issue 1982', buildName:'issue1982-' + process.env.GITHUB_RUN_ID, sessionName:'unchanged-c1ce-approval-picker', debug:true, networkLogs:false, video:true, appiumVersion:'2.15.0', resignApp:false}};
  writeFileSync('evidence/session-capabilities.json', JSON.stringify(caps, null, 2));
  allocation = {requestedUtc:new Date().toISOString(), run:process.env.GITHUB_RUN_ID, project:caps['bstack:options'].projectName, build:caps['bstack:options'].buildName, name:caps['bstack:options'].sessionName, localIdentifier:process.env.BS_LOCAL_ID, requestedDevice:caps['appium:deviceName'], requestedOs:caps['appium:platformVersion']};
  writeFileSync('evidence/allocation-intent.json', JSON.stringify(allocation, null, 2));
  const created = await wd('POST', '/session', {capabilities:{alwaysMatch:caps, firstMatch:[{}]}});
  session = created.sessionId;
  assert(session, 'Session ID missing');
  allocation.session = session;
  allocation.returnedUtc = new Date().toISOString();
  writeFileSync('evidence/allocation-intent.json', JSON.stringify(allocation, null, 2));
  writeFileSync('evidence/browserstack-session.json', JSON.stringify({session, device:'Samsung Galaxy S21', os:'Android 11.0', source:expectedSource}, null, 2));
  await helperClick('Inspect LocalSend APK');
  let inspection;
  const inspectionDeadline = Date.now() + 30_000;
  do {
    const source = await wd('GET', `/session/${session}/source`);
    writeFileSync('evidence/package-inspection-ui.xml', source);
    if (source.includes('APK inspection complete')) {
      const encoded = await wd('POST', `/session/${session}/appium/device/pull_file`, {path:'/sdcard/Android/data/org.localsend.cloudtransport/files/localsend-apk-inspection.json'});
      inspection = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
      break;
    }
    assert(!source.includes('APK inspection failed') && !source.includes('report write failed'), 'Public installed APK inspection failed');
    await new Promise(resolve => setTimeout(resolve, 300));
  } while (Date.now() < inspectionDeadline);
  writeFileSync('evidence/installed-apk-inspection.json', JSON.stringify(inspection ?? {unavailable:true}, null, 2));
  assert(inspection?.successful && inspection.baseApk.stableWhileRead, 'Installed APK identity unavailable');
  assert.equal(inspection.baseApk.sha256, expectedApk);
  assert.deepEqual(inspection.signingCertificateSha256, [expectedSigner]);
  assert.equal(inspection.splitApks.length, 0);
  await helperClick('Start socket control');
  for (const size of [0, 1, 65537, 8 * 1024 * 1024]) {
    const data = randomBytes(size);
    const socket = net.connect({host:'127.0.0.1', port:senderPort, allowHalfOpen:true});
    socket.setTimeout(90_000, () => socket.destroy(new Error('Physical opaque relay control timed out')));
    socket.end(data);
    const chunks = [];
    for await (const chunk of socket) chunks.push(chunk);
    const reply = JSON.parse(Buffer.concat(chunks));
    assert.equal(reply.count, size);
    assert.equal(reply.sha256, createHash('sha256').update(data).digest('hex'));
    controls.push({bytes:size, byteExact:true, replyAfterHalfClose:true});
  }
  writeFileSync('evidence/physical-controls.json', JSON.stringify({controls, metrics:r.status()}, null, 2));
  await helperClick('Stop helper');
  await new Promise(resolve => setTimeout(resolve, 16_000));
  const drain = Date.now() + 15_000;
  while (r.status().pollPending && Date.now() < drain) await new Promise(resolve => setTimeout(resolve, 100));
  assert(!r.status().pollPending, 'Prior helper long poll did not drain');
  r.record('helper-old-poll-drained');
  await helperClick('Relay to LocalSend');
  knownPackage = 'transition';
  await wd('POST', `/session/${session}/appium/device/activate_app`, {appId:'org.localsend.localsend_app'});
  scenarioStarted = Date.now();
  writeFileSync('evidence/budget.json', JSON.stringify({jobStart, cleanupBoundary, scenarioStarted, productDeadline:Math.min(cleanupBoundary, scenarioStarted + 25 * 60_000), targetApprovalMs:20_000, pickerReturnMs:15_000}, null, 2));
  const scenario = await import('./scenario.mjs');
  await scenario.default({session, wd, senderHost:'127.0.0.1', senderPort, transportStatus:r.status, relayRecord:r.record, relayTrace:r.trace,
    budgetDeadline:Math.min(cleanupBoundary, scenarioStarted + 25 * 60_000)});
} catch (error) {
  writeFileSync('evidence/runner-error.txt', safe(String(error)));
  throw error;
} finally {
  const cleanup = {startedUtc:new Date().toISOString(), session, unknownAllocation:Boolean(allocation && !session), indeterminateInput, errors:[]};
  if (session) {
    try { writeFileSync('evidence/android-logcat.json', JSON.stringify(safe(await wd('POST', `/session/${session}/log`, {type:'logcat'}, {cleanup:true})), null, 2)); }
    catch (error) { cleanup.errors.push({operation:'logcat', error:safe(String(error))}); }
    try { await wd('DELETE', `/session/${session}`, undefined, {cleanup:true}); cleanup.deleteResponseUtc = new Date().toISOString(); }
    catch (error) { cleanup.errors.push({operation:'delete-owned-session', error:safe(String(error))}); }
  }
  try { await r.stop(); } catch (error) { cleanup.errors.push({operation:'relay-stop', error:safe(String(error))}); }
  cleanup.finalMetrics = r.status();
  cleanup.completedUtc = new Date().toISOString();
  writeFileSync('evidence/cleanup.json', JSON.stringify(cleanup, null, 2));
  persist();
  clearInterval(evidenceTimer);
}
