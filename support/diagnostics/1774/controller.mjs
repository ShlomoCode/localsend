// Source-only preparation. Run only after root selects the frozen stage and
// the coordinator issues admission for this exact fork Actions attempt.
import { readFile, writeFile, appendFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { createUi, APP } from './ui.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const APK_HASH = '82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3';
const FIXTURE_HASH = 'fd9566b940419a8916c484f2279320ba6a2c416a6909283cb705c0bac36d741c';
const restoreOnly = process.argv.slice(2).includes('--restore');
const evidence = resolve(process.env.EVIDENCE_DIR ?? 'evidence/issue1774');
const output = evidence;
const username = process.env.BROWSERSTACK_USERNAME, key = process.env.BROWSERSTACK_ACCESS_KEY;
const app = process.env.BASELINE_APP;
const runId = process.env.GITHUB_RUN_ID, runAttempt = process.env.GITHUB_RUN_ATTEMPT;
let session = null, deadline = Infinity, deviceHardDeadline = Infinity, productDeadline = Infinity, stage = 'preflight', cleanupPhase = false;
let ownership = null;
function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) =>
    [name, /password|access.?key|token|authorization|app_url|appReference|baseline_app|^data$/i.test(name) ? '<REDACTED>' : redact(item)]));
  if (typeof value === 'string') {
    let result = value;
    for (const secret of [username, key, app].filter(Boolean)) result = result.replaceAll(secret, '<REDACTED>');
    return result.replace(/bs:\/\/[a-zA-Z0-9_-]+/g, '<REDACTED_APP_REFERENCE>');
  }
  return value;
}
async function save(name, value) { await writeFile(resolve(evidence, name), JSON.stringify(redact(value), null, 2)); }
function checkDeadline() {
  if (Date.now() >= (cleanupPhase ? deadline : productDeadline)) throw new Error(cleanupPhase ? '12-minute device deadline reached' : '9-minute product-action deadline reached');
}
async function request(method, path, body, provider = false) {
  checkDeadline();
  const at = new Date().toISOString();
  const host = provider ? 'https://api-cloud.browserstack.com' : 'https://hub-cloud.browserstack.com/wd/hub';
  const remaining = (cleanupPhase ? deadline : productDeadline) - Date.now();
  const response = await fetch(host + path, { method, headers: { Authorization: `Basic ${Buffer.from(`${username}:${key}`).toString('base64')}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(Math.min(30000, remaining)) });
  const text = await response.text();
  let result;
  try { result = JSON.parse(text); } catch { result = { parseError: true, responseText: text }; }
  // Persist a returned handle before processing status or making another request.
  if (method === 'POST' && path === '/session') {
    const returned = result.value?.sessionId ?? result.sessionId;
    if (typeof returned === 'string' && /^[a-zA-Z0-9_-]+$/.test(returned)) {
      session = returned;
      ownership.session = session;
      ownership.sessionCreatedAt = new Date().toISOString();
      ownership.deviceDeadlineUtc = new Date(deviceHardDeadline).toISOString();
      ownership.nativeDeadlineUtc = new Date(deadline).toISOString();
      await writeFile(resolve(output, 'ownership.json'), JSON.stringify(ownership, null, 2));
      await writeFile(resolve(output, 'session.json'), JSON.stringify(ownership, null, 2));
      await save('owned-session.json', ownership);
    }
    await save('create-response.json', result);
  }
  await appendFile(resolve(evidence, 'events.jsonl'), JSON.stringify(redact({ at, completedAt: new Date().toISOString(), stage, method, path, body, status: response.status, error: result.value?.error })) + '\n');
  if (!response.ok || result.value?.error || result.parseError) throw Object.assign(new Error(`Remote ${method} ${path} failed with status ${response.status}: ${result.value?.error ?? 'response unavailable'}`), { definitiveResponse: !response.ok || Boolean(result.value?.error) });
  return result;
}
const command = (method, path, body) => {
  if (!session) throw new Error('No owned session');
  return request(method, `/session/${encodeURIComponent(session)}${path}`, body);
};
async function readJson(file) { return JSON.parse(await readFile(file, 'utf8')); }
async function preflight() {
  if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend') throw new Error('Only selected fork GitHub Actions may execute this controller');
  if (!username || !key || !runId || !runAttempt) throw new Error('Actions identity or provider credentials unavailable');
  if (!app || !/^bs:\/\/[a-zA-Z0-9_-]+$/.test(app)) throw new Error('Existing provenance-bound BASELINE_APP unavailable');
  const receipt = await readJson(process.env.BASELINE_RECEIPT ?? 'support/diagnostics/1774/original-apk-binding.json');
  // The retained receipt must identify these unchanged bytes and the exact
  // private existing upload reference. No upload occurs in this controller.
  if (receipt.sha256 !== APK_HASH || receipt.bytes !== 46558706 || receipt.uploadReferenceSha256 !== hash(app)) throw new Error('Official APK receipt does not bind BASELINE_APP to the frozen artifact');
  await save('original-apk-binding.json', receipt);
  const admission = await readJson(process.env.COORDINATOR_ADMISSION_FILE ?? 'support/diagnostics/1774/admission.json');
  const now = Date.now(), admitted = Date.parse(admission.admittedAt), expires = Date.parse(admission.expiresAt);
  if (admission.issue !== 1774 || admission.rootSelected !== true || admission.maxSessions !== 1 || admission.unknownManualHolds !== 2 ||
      admission.sourceHead !== process.env.GITHUB_SHA || typeof admission.reservationId !== 'string' || !admission.reservationId.trim() ||
      admission.stage !== 'issue1774-native-display-size-original' || String(admission.runAttempt) !== '1' || runAttempt !== '1' || admission.maxJobs !== 1 ||
      !Number.isFinite(admitted) || !Number.isFinite(expires) || admitted > now || now - admitted > 300000 || expires <= now ||
      !Number.isInteger(admission.totalPotentialBefore1774) || admission.totalPotentialBefore1774 + 1 > 5) throw new Error('Fresh exact one-session coordinator admission unavailable');
  await save('coordinator-admission.json', admission);
  const plan = await request('GET', '/app-automate/plan.json', undefined, true);
  await save('provider-plan.json', { observedAt: new Date().toISOString(), plan });
  const running = plan.parallel_sessions_running, queued = plan.queued_sessions, capacity = plan.parallel_sessions_max_allowed;
  if (![running, queued, capacity].every(value => Number.isInteger(value) && value >= 0) || running + queued + 2 + 1 > 5 || running + queued + 1 > capacity) throw new Error('Fresh provider plan capacity gate failed or counts unavailable');
  const fixture = await readFile(process.env.FIXTURE_PATH ?? 'support/diagnostics/1774/fixture.png');
  if (fixture.length !== 184874 || hash(fixture) !== FIXTURE_HASH) throw new Error('Frozen ordinary PNG fixture hash/length mismatch');
  await save('fixture-input.json', { bytes: fixture.length, sha256: hash(fixture) });
  return fixture;
}
await mkdir(evidence, { recursive: true });
await mkdir(output, { recursive: true });
const ui = createUi({ command, save, evidence, checkDeadline });
try {
  if (restoreOnly) {
    if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend' || !username || !key) throw new Error('Fork Actions credentials required for restore');
    ownership = await readJson(resolve(output, 'ownership.json'));
    if (String(ownership.runId) !== runId || String(ownership.runAttempt) !== runAttempt || !ownership.session || !/^[a-zA-Z0-9_-]+$/.test(ownership.session)) throw new Error('Exact Actions-owned session unavailable for restore');
    session = ownership.session;
    deviceHardDeadline = Date.parse(ownership.deviceDeadlineUtc);
    deadline = Date.parse(ownership.nativeDeadlineUtc);
    if (!Number.isFinite(deadline) || !Number.isFinite(deviceHardDeadline) || deadline >= deviceHardDeadline) throw new Error('Original device/native deadlines unavailable');
    cleanupPhase = true; stage = 'independent-native-restore';
    await save('independent-native-restoration.json', await ui.restore());
  } else {
    const start = Date.now(), jobDeadline = Date.parse(process.env.ISSUE1774_JOB_DEADLINE_UTC);
    if (!Number.isFinite(jobDeadline)) throw new Error("Actual 20-minute job deadline unavailable");
    deviceHardDeadline = Math.min(start + 12 * 60000, jobDeadline - 8 * 60000);
    deadline = deviceHardDeadline - 30000; productDeadline = Math.min(start + 9 * 60000, deadline - 150000);
    if (productDeadline - start < 5 * 60000) throw new Error("Insufficient actual job reserve before device creation");
    await save("actual-budget.json", { jobDeadlineUtc: new Date(jobDeadline).toISOString(), productDeadlineUtc: new Date(productDeadline).toISOString(), nativeDeadlineUtc: new Date(deadline).toISOString(), deviceHardDeadlineUtc: new Date(deviceHardDeadline).toISOString(), deviceMaximumMs: deviceHardDeadline-start, cleanupRetentionUploadReserveMinutes: 8 });
    const fixture = await preflight();
    if (productDeadline - Date.now() < 5 * 60000) throw new Error("Actual product reserve exhausted before creation");
    const creationAdmission = await readJson(process.env.COORDINATOR_ADMISSION_FILE);
    if (Date.parse(creationAdmission.expiresAt) <= Date.now() || Date.now() - Date.parse(creationAdmission.admittedAt) > 300000) throw new Error("Coordinator admission expired before creation");
    // Exclusive marker prevents re-creating after any uncertain POST response.
    ownership = { runId, runAttempt, buildName: `issue1774-${runId}-attempt-${runAttempt}`, creationAttempted: true,
      attemptedAt: new Date().toISOString(), deviceDeadlineUtc: new Date(deviceHardDeadline).toISOString(),
      nativeDeadlineUtc: new Date(deadline).toISOString(), session: null };
    await writeFile(resolve(output, 'ownership.json'), JSON.stringify(ownership, null, 2), { flag: 'wx' });
    await save('session-attempt.json', ownership);
    stage = 'session-create';
    await request('POST', '/session', { capabilities: { alwaysMatch: { platformName: 'Android', 'appium:automationName': 'UiAutomator2',
      'appium:deviceName': 'Samsung Galaxy S23', 'appium:platformVersion': '13.0', 'appium:app': app,
      'bstack:options': { projectName: 'LocalSend issue1774 frozen short round', buildName: ownership.buildName,
        sessionName: 'unchanged-1.18.2-original-max-restored', debug: true, video: true, networkLogs: false, idleTimeout: 60 } } } });
    if (!session) throw new Error('Creation result has no owned handle; do not POST again; reconcile unique build');
    stage = 'observed-provider-device-identity';
    const providerSession = await request('GET', `/app-automate/sessions/${encodeURIComponent(session)}.json`, undefined, true);
    await save('observed-provider-session.json', providerSession);
    const actual = providerSession.automation_session;
    if (actual?.hashed_id !== session || actual.device !== 'Samsung Galaxy S23' || actual.os?.toLowerCase() !== 'android' ||
        !['13', '13.0'].includes(String(actual.os_version))) throw new Error('Observed provider session/device/Android13 identity mismatch or unavailable');
    stage = 'supported-ordinary-png-push-pull';
    const filename = `issue1774-${runId}-${runAttempt}.png`, devicePath = `/sdcard/Download/${filename}`;
    await command('POST', '/appium/device/push_file', { path: devicePath, data: fixture.toString('base64') });
    const pulled = Buffer.from((await command('POST', '/appium/device/pull_file', { path: devicePath })).value, 'base64');
    await save('fixture-roundtrip.json', { devicePath, pushedBytes: fixture.length, pulledBytes: pulled.length, sha256: hash(pulled) });
    if (pulled.length !== fixture.length || hash(pulled) !== FIXTURE_HASH) throw new Error('Supported fixture roundtrip hash mismatch');
    stage = 'native-original-font-zoom'; const nativeOriginal = await ui.originals();
    const conditionObservations = [{ label: 'original', nativeZoomValue: nativeOriginal.originalZoom, defaultPositionUnknown: true }];
    stage = 'actual-localsend-file-picker'; await ui.selectFixture(filename, fixture.length);
    stage = 'original-scale-working-control'; let original, originalStructuralError;
    try { original = await ui.monitor('original'); }
    catch (error) {
      if (error.monitorBeforeInput !== true || !error.actualUrl) throw error;
      originalStructuralError = error;
      original = { url: error.actualUrl, opened: false, actualMonitorActivationAttempted: false };
      await save('original-structural-observation.json', { error: error.message, actualUrl: error.actualUrl, snapshot: error.snapshot,
        actualMonitorActivationAttempted: false, productVerdict: null, pixelVerdict: 'pending-pixel-inspection' });
    }
    stage = 'native-maximum-zoom-font-unchanged'; let endpoint = await ui.maximum(); await ui.verifyFont('maximum-font-unchanged');
    if (Number(nativeOriginal.originalZoom) === Number(endpoint.value)) {
      stage = 'observed-distinct-nonmax-control';
      const lower = await ui.nonmaxControl(); await ui.verifyFont('nonmax-control-font-unchanged');
      const lowerControl = await ui.monitor('observed-nonmax-control', original.url);
      conditionObservations.push({ label: 'observed-nonmax-control', nativeZoomValue: lower, defaultPositionUnknown: true, monitorOpened: lowerControl.opened });
      if (!lowerControl.opened) throw new Error('Observed distinct nonmax monitor working control unmet');
      stage = 'return-to-qualified-maximum'; endpoint = await ui.maximum(); await ui.verifyFont('returned-maximum-font-unchanged');
    } else if (originalStructuralError) throw originalStructuralError;
    else if (!original.opened) throw new Error('Original nonmax monitor did not open actual ZoomDialog; harness control unmet');
    stage = 'maximum-scale-monitor'; const maximum = await ui.monitor('maximum', original.url);
    // A repeat is one bounded identical observation, not a recovery or a
    // candidate replay. Preserve both outcomes and require pixel inspection.
    conditionObservations.push({ label: 'maximum', nativeZoomValue: endpoint.value, monitorOpened: maximum.opened });
    if (productDeadline - Date.now() > 90000) {
      stage = 'maximum-scale-identical-repeat'; const repeated = await ui.monitor('maximum-repeat', original.url);
      await save('maximum-identical-repeat.json', { nativeZoomValue: endpoint.value, sameCondition: true, monitorOpened: repeated.opened, pixelVerdict: 'pending-pixel-inspection' });
    }
    stage = 'restore-exact-original'; cleanupPhase = true; await ui.restore(); cleanupPhase = false;
    const restoredObservation = { label: 'restored', nativeZoomValue: nativeOriginal.originalZoom, exactNativeRestorationVerified: true };
    conditionObservations.push(restoredObservation);
    if (productDeadline - Date.now() > 60000) {
      stage = 'restored-working-control'; const restored = await ui.monitor('restored', original.url);
      restoredObservation.monitorOpened = restored.opened;
      if (original.opened && !restored.opened) throw new Error('Previously working original monitor failed after exact restoration');
    }
    await save('result.json', { status: 'pending-pixel-inspection', failureStage: null, productVerdict: null, originalMonitorOpened: original.opened,
      originalMonitorActivationAttempted: original.actualMonitorActivationAttempted ?? true, originalStructuralObservation: originalStructuralError?.message ?? null,
      maximumMonitorOpened: maximum.opened, testedRelease: 'official unchanged 1.18.2', device: 'Samsung Galaxy S23', android: '13.0',
      reportedReleaseAndDeviceUnknown: true, conditionObservations,
      roundConditions: [...new Set(conditionObservations.map(item => Number(item.nativeZoomValue)))], distinctNativePositionCount: new Set(conditionObservations.map(item => Number(item.nativeZoomValue))).size });
  }
} catch (error) {
  await save(restoreOnly ? 'independent-restore-failure.json' : 'failure.json', { at: new Date().toISOString(), stage, error: String(error.message),
    status: 'gate-or-observation-failure', productVerdict: null, originalPixelsRequireInspection: true });
  process.exitCode = 1;
} finally {
  if (session && !restoreOnly) {
    cleanupPhase = true;
    try { stage = 'finally-native-restoration'; await save('finally-native-restoration.json', await ui.restore()); }
    catch (error) { await save('native-restoration-failure.json', { stage, error: String(error.message), restored: false }); process.exitCode = 1; }
    // Exact-session DELETE remains required if the action deadline expired.
    // This does not authorize any further device input after that deadline.
    try {
      stage = 'exact-session-delete';
      const response = await fetch(`https://hub-cloud.browserstack.com/wd/hub/session/${encodeURIComponent(session)}`, { method: 'DELETE',
        headers: { Authorization: `Basic ${Buffer.from(`${username}:${key}`).toString('base64')}` },
        signal: AbortSignal.timeout(Math.max(1, Math.min(15000, deviceHardDeadline - Date.now()))) });
      await save('exact-session-delete.json', { at: new Date().toISOString(), session, status: response.status, deleted: response.ok });
      if (!response.ok) process.exitCode = 1;
    } catch (error) { await save('exact-session-delete-failure.json', { session, error: String(error.message) }); process.exitCode = 1; }
  }
}
