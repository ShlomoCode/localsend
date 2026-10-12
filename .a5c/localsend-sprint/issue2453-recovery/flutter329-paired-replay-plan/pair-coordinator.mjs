// Proposed cloud executor only. No local execution or dispatch is admitted.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFile, spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';

const exec = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(process.env.LS2453_OUTPUT_DIR || 'paired-evidence');
fs.mkdirSync(out, {recursive: true});
const authUser = process.env.BROWSERSTACK_USERNAME;
const authKey = process.env.BROWSERSTACK_ACCESS_KEY;
if (!authUser || !authKey || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend' || process.env.GITHUB_ACTIONS !== 'true') {
  throw new Error('Authorized fork cloud runner and existing BrowserStack secrets required');
}
const started = Number(process.env.LS2453_STARTED_MS);
if (!Number.isFinite(started) || started <= 0 || started > Date.now()) throw new Error('Finite job-start timestamp from the first workflow step required');
const scenarioDeadline = started + 20 * 60 * 1000;
const overallDeadline = started + 25 * 60 * 1000;
// Leave the last minute of the five-minute final reserve for artifact upload.
// GitHub's hard cancellation can still interrupt cleanup; root must reconcile
// ownership whenever DELETE/final stopped receipts are absent.
const cleanupDeadline = overallDeadline - 60000;
const bundle = 'org.localsend.localsendApp';
const inputs = {
  default: {run: '38185684847', artifact: '11719532258', archive: '287f6442bd70cd7eb2e8ed9f1e301a17b4cf7da9da4fca87d44ec3414ad221ee', ipa: 'cc980b30402309c9461d3885f3d262bd2c77d135a0dfaaf41b45813bd7cd0411'},
  candidate: {run: '38191446249', artifact: '11720814570', archive: '83ea5195796cbf4749c12817ea54c8de9aa6b559a12baf6bb67b92ff0bbb2d1a', ipa: '5b11c2cd7a4eebf1b971063e6d9f82b710eca8b63b453dea9ed5dce880e90f32'},
};
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const scrub = text => [authUser, authKey, Buffer.from(`${authUser}:${authKey}`).toString('base64')].reduce((s, secret) => s.split(secret).join('[REDACTED]'), text).replace(/https?:\/\/[^\s"']+\?[^\s"']+/g, url => `${url.split('?')[0]}?[REDACTED]`);
const save = (name, value) => fs.writeFileSync(path.join(out, name), scrub(typeof value === 'string' ? value : JSON.stringify(value, null, 2)));
const event = value => fs.appendFileSync(path.join(out, 'coordinator.ndjson'), `${scrub(JSON.stringify({...value, utc: new Date().toISOString()}))}\n`);
let session;
let nativeSettlement = 'settled';
let lastIdentity;
let candidateInstalled = false;
let creationAttempted = false;
let deleted = false;
let stopped = false;

function admission() {
  const record = JSON.parse(fs.readFileSync(process.env.LS2453_ADMISSION_FILE, 'utf8'));
  const age = Date.now() - Date.parse(record.issuedAt);
  if (record.repository !== 'ShlomoCode/localsend' || record.issue !== 2453 || record.rootAuthorized !== true || record.sibling1591Released !== true || record.issue2453OwnedDevices !== 0 || record.issue2453OwnedJobs !== 1 || record.globalDeviceCeiling !== 5 || record.maxNewDevices !== 1 || record.allowUploads !== true || record.allowSingleSession !== true || !process.env.LS2453_DISPATCH_NONCE || record.dispatchNonce !== process.env.LS2453_DISPATCH_NONCE || record.sourceSha !== process.env.GITHUB_SHA || record.sourceRef !== process.env.GITHUB_REF || !Number.isFinite(age) || age < 0 || age > 5 * 60 * 1000 || !Number.isFinite(Date.parse(record.expiresAt)) || Date.parse(record.expiresAt) <= Date.now()) {
    throw new Error('Fresh run-bound root/sibling admission is missing or incompatible');
  }
  // This receipt is supplied by the root after live coordination, not inferred
  // from an old inventory or from a provider capacity response.
  save('admission.json', record);
}

async function http(method, url, label, {body, multipart, native = false, cleanup = false, binary = false} = {}) {
  const deadline = cleanup ? cleanupDeadline : scenarioDeadline;
  const allowance = native ? 300000 : 60000;
  if (Date.now() + allowance > deadline) throw new Error(`${label}: insufficient deadline allowance`);
  if (native && nativeSettlement !== 'settled') throw new Error(`${label}: previous native settlement unresolved`);
  const responseFile = path.join(out, `.${label}.response`);
  const args = ['--silent', '--show-error', '--max-time', String(allowance / 1000), '--request', method, '--user', `${authUser}:${authKey}`, '--output', responseFile, '--write-out', '%{http_code}'];
  let inputFile;
  if (body !== undefined) {
    save(`${label}-request.json`, body);
    inputFile = path.join(out, `.${label}.request`);
    fs.writeFileSync(inputFile, JSON.stringify(body), {mode: 0o600});
    args.push('--header', 'Content-Type: application/json', '--data-binary', `@${inputFile}`);
  }
  if (multipart) args.push('--form', `file=@${multipart}`);
  args.push(url);
  if (native) nativeSettlement = 'unresolved';
  event({phase: 'start', method, label, session, native, cleanup});
  let status;
  try {
    let reply = await exec('curl', args, {timeout: allowance + 1000, maxBuffer: 1024 * 1024});
    status = Number(reply.stdout);
    // Only an explicit non-native 418 is retried. A native/proxy timeout may
    // leave work running; never replay it or queue the installation transition.
    if (status === 418 && !native) {
      event({phase: 'http418-proxy-retry', label});
      reply = await exec('curl', ['--proxy', 'socks5h://100.108.223.54:38471', ...args], {timeout: Math.min(allowance + 1000, deadline - Date.now()), maxBuffer: 1024 * 1024});
      status = Number(reply.stdout);
    }
    if (binary && status >= 200 && status < 300) {
      fs.renameSync(responseFile, path.join(out, `${label}.mp4`));
      event({phase: 'end', label, status});
      return;
    }
    const raw = fs.readFileSync(responseFile, 'utf8');
    save(`${label}.json`, raw);
    const parsed = JSON.parse(raw);
    if (status < 200 || status >= 300 || parsed.value?.error || parsed.state === 'error' || (typeof parsed.status === 'number' && parsed.status !== 0) || (native && !Object.hasOwn(parsed, 'value'))) throw new Error(`${label}: provider HTTP/protocol failure; retained response`);
    if (native) nativeSettlement = 'settled';
    event({phase: 'end', label, status, nativeSettlement});
    return parsed;
  } catch (error) {
    event({phase: 'error', label, status, nativeSettlement, message: scrub(error.message)});
    throw new Error(`${label}: provider operation did not settle successfully`);
  } finally {
    if (inputFile) fs.rmSync(inputFile, {force: true});
    fs.rmSync(responseFile, {force: true});
  }
}

const request = async (method, route, label, body) => (await http(method, `https://hub-cloud.browserstack.com/wd/hub/session/${session}/${route}`, label, {body, native: true})).value;
const execute = (label, script, args) => request('POST', 'execute/sync', label, {script, args: [args]});
async function source(label) {
  const xml = await request('GET', 'source', label);
  if (typeof xml !== 'string') { nativeSettlement = 'unresolved'; throw new Error('Malformed native source'); }
  save(`${label}.xml`, xml);
  return xml;
}
function nodes(xml, type, name) {
  return [...xml.matchAll(/<XCUIElementType\w+[^>]*>/g)].map(m => m[0]).filter(n => n.includes(`type="${type}"`) && n.includes(`name="${name}`) && n.includes('visible="true"'));
}
function point(node) {
  const number = name => { const m = node.match(new RegExp(` ${name}="([0-9.]+)"`)); if (!m) throw new Error('Missing observed bounds'); return Number(m[1]); };
  return {x: number('x') + number('width') / 2, y: number('y') + number('height') / 2};
}
async function click(label, using, value) {
  const found = await request('POST', 'element', `${label}-find`, {using, value});
  const id = found?.['element-6066-11e4-a52e-4f735466cecf'];
  if (!id) { nativeSettlement = 'unresolved'; throw new Error(`${label}: missing observed control ID`); }
  await request('POST', `element/${id}/click`, label, {});
  return id;
}
async function screenshot(label, element) {
  const data = await request('GET', element ? `element/${element}/screenshot` : 'screenshot', label);
  if (typeof data !== 'string') { nativeSettlement = 'unresolved'; throw new Error('Malformed screenshot'); }
  const bytes = Buffer.from(data, 'base64');
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (bytes.length < 1000 || !bytes.subarray(0, 8).equals(signature) || bytes.toString('ascii', 12, 16) !== 'IHDR') throw new Error('Non-PNG/invalid screenshot; rendered equivalence unknown');
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  const expectedRatio = element ? 1 : 402 / 874;
  if (width < 40 || width > 4000 || height < 40 || height > 8000 || Math.abs(width / height - expectedRatio) > 0.02) throw new Error('Screenshot dimensions do not match observed sample/device; equivalence unknown');
  // A valid PNG can still be a compositor placeholder. Equal screenshot hashes
  // are rendered representation parity only, subject to retained video review.
  fs.writeFileSync(path.join(out, `${label}.png`), bytes);
  return crypto.createHash('sha256').update(bytes).digest('hex');
}
async function verifyIdentity(label) {
  const reply = await http('GET', `https://api-cloud.browserstack.com/app-automate/sessions/${session}.json`, label);
  const info = reply.automation_session;
  if (!info || info.device !== 'iPhone 16 Pro' || info.os !== 'ios' || info.os_version !== '18.6') throw new Error('Actual device/OS identity unavailable or mismatched');
  const identity = {session, device: info.device, os: info.os, osVersion: info.os_version};
  if (lastIdentity && JSON.stringify(identity) !== JSON.stringify(lastIdentity)) throw new Error('Session/device identity changed');
  lastIdentity = identity;
  return info;
}

async function settings(arm) {
  // The app's Settings/Send tabs were observed in sdk329-original/ready.xml.
  // This shared setup addition does not navigate invented iOS Settings paths.
  await click(`${arm}-app-settings`, '-ios predicate string', 'type == "XCUIElementTypeStaticText" AND name BEGINSWITH "Settings"');
  const xml = await source(`${arm}-app-settings-page`);
  await screenshot(`${arm}-app-settings`);
  const stable = [...xml.matchAll(/<XCUIElementType\w+[^>]*>/g)].map(m => m[0]).filter(n => n.includes('visible="true"') && n.includes('accessible="true"')).map(n => {
    const attr = key => n.match(new RegExp(` ${key}="([^"]*)"`))?.[1] || '';
    return {type: attr('type'), name: attr('name'), value: attr('value'), enabled: attr('enabled'), selected: attr('selected') || (attr('traits').includes('Selected') ? 'true' : '')};
  }).filter(n => n.name && !/^\d{1,2}:\d{2}$/.test(n.name));
  if (!stable.length) throw new Error('App Settings values unavailable');
  save(`${arm}-app-settings-stable.json`, stable);
  await click(`${arm}-settings-return-send`, '-ios predicate string', 'type == "XCUIElementTypeStaticText" AND name BEGINSWITH "Send"');
  const returned = await source(`${arm}-settings-send-returned`);
  if (!returned.includes('name="Media"')) throw new Error('Settings return did not reach Send');
  return stable;
}

async function setup(arm) {
  await request('POST', 'orientation', `${arm}-setup-portrait`, {orientation: 'PORTRAIT'});
  let xml = await source(`${arm}-launch`);
  if (/<XCUIElementTypeAlert[^>]*name="Allow “LocalSend” to find devices on local networks\?"[^>]*visible="true"/.test(xml) && /<XCUIElementTypeButton[^>]*name="Allow"[^>]*visible="true"/.test(xml)) {
    await execute(`${arm}-allow-network`, 'mobile: alert', {action: 'accept', buttonLabel: 'Allow'});
    xml = await source(`${arm}-after-network`);
  }
  if (!xml.includes('name="Media"')) {
    await click(`${arm}-send`, '-ios predicate string', 'type == "XCUIElementTypeStaticText" AND name BEGINSWITH "Send"');
    xml = await source(`${arm}-send-ready`);
  }
  if (!xml.includes('name="Media"')) throw new Error('Ordinary Send setup failed');
  // Baseline completion may persist Files1 through upgrade. No undocumented
  // clear/reset action is allowed: this mismatch stops the pair explicitly.
  if (/ (?:name|value)="Files: [1-9]/.test(xml)) throw new Error('Retained Send files differ from fresh baseline; no reviewed clear action');
  const appSettings = await settings(arm);
  await click(`${arm}-media`, 'accessibility id', 'Media');
  xml = await source(`${arm}-photo-entry`);
  if (arm === 'default') {
    if (!xml.includes('Limit Access')) throw new Error('Fresh baseline lacks expected limited-photo prompt');
    await execute(`${arm}-limit-access`, 'mobile: alert', {action: 'accept', buttonLabel: 'Limit Access…'});
    xml = await source(`${arm}-limited-chooser`);
    const sample = nodes(xml, 'XCUIElementTypeImage', 'PXGGridLayout-Info').filter(n => n.includes('label="Photo,'));
    if (!sample.length) throw new Error('No ordinary preloaded visible photo');
    save('chosen-sample-node.txt', sample[0]);
    await execute(`${arm}-choose-one`, 'mobile: tap', point(sample[0]));
    await source(`${arm}-chosen-one`);
    await click(`${arm}-limited-update`, 'accessibility id', 'Update');
    xml = await source(`${arm}-limited-gate`);
  } else if (xml.includes('Limit Access')) throw new Error('Candidate permission state did not carry over');
  const limitedGateObserved = xml.includes('Continue with limited access');
  if (limitedGateObserved) {
    if (!xml.includes('width="402" height="874"')) throw new Error('Limited gate geometry differs');
    await execute(`${arm}-continue-limited`, 'mobile: tap', {x: 201, y: 830});
    xml = await source(`${arm}-grid`);
  }
  if (!xml.includes('name="Accessible files"') || !xml.includes('width="402" height="874"') || !/name="Confirm"[^>]*enabled="false"/.test(xml) || [...xml.matchAll(/<XCUIElementTypeImage[^>]*name="Image[0-9][^>]*visible="true"[^>]*>/g)].length !== 1) throw new Error('Arm did not reach identical unselected one-photo portrait setup');
  const found = await request('POST', 'element', `${arm}-sample-evidence-find`, {using: '-ios predicate string', value: 'type == "XCUIElementTypeImage" AND name BEGINSWITH "Image1"'});
  const sampleId = found?.['element-6066-11e4-a52e-4f735466cecf'];
  if (!sampleId) { nativeSettlement = 'unresolved'; throw new Error('Sample evidence element ID missing'); }
  const sampleRenderSha = await screenshot(`${arm}-sample-render`, sampleId);
  const fingerprint = {sampleRenderSha, appSettings, limitedGateObserved, photos: 'Limited gate plus one visible photo; iOS Settings not queried', geometry: '402x874', selected: false, sendFiles: 0};
  save(`${arm}-setup-equivalence.json`, fingerprint);
  return fingerprint;
}

async function capacity(label) {
  const reply = await http('GET', 'https://api-cloud.browserstack.com/app-automate/plan.json', label);
  const running = reply.parallel_sessions_running;
  const queued = reply.queued_sessions;
  const maximum = reply.parallel_sessions_max_allowed;
  if (![running, queued, maximum].every(Number.isInteger) || running < 0 || queued !== 0 || maximum < 1 || running >= Math.min(5, maximum)) throw new Error('Immediate running/queued capacity unknown or unavailable');
}
function findIpas(dir) { return fs.readdirSync(dir, {withFileTypes: true}).flatMap(e => e.isDirectory() ? findIpas(path.join(dir, e.name)) : e.name.endsWith('.ipa') ? [path.join(dir, e.name)] : []); }
async function upload(arm) {
  const input = inputs[arm];
  const archive = path.resolve(process.env.LS2453_INPUT_DIR, `${arm}.zip`);
  if (hash(archive) !== input.archive) throw new Error(`${arm}: exact retained archive hash mismatch`);
  const unpack = path.join(out, `.input-${arm}`);
  await exec('unzip', ['-q', archive, '-d', unpack], {timeout: 60000});
  const ipas = findIpas(unpack);
  if (ipas.length !== 1 || hash(ipas[0]) !== input.ipa) throw new Error(`${arm}: retained original IPA missing/hash mismatch`);
  const receipt = await http('POST', 'https://api-cloud.browserstack.com/app-automate/upload', `${arm}-upload`, {multipart: ipas[0]});
  if (!/^bs:\/\/[a-zA-Z0-9]+$/.test(receipt.app_url || '')) throw new Error('Missing exact immutable upload app URL');
  save(`${arm}-artifact-binding.json`, {...input, appUrl: receipt.app_url, requestedIdentityOnly: true});
  fs.rmSync(unpack, {recursive: true, force: true});
  return receipt.app_url;
}
async function sequence(arm) {
  nativeSettlement = 'unresolved';
  const child = spawn(process.execPath, [path.join(here, 'pair-sequence.mjs')], {env: {...process.env, LS2453_ARM: arm, LS2453_SESSION_ID: session, LS2453_OUTPUT_DIR: out, LS2453_SCENARIO_DEADLINE_MS: String(scenarioDeadline)}, stdio: ['ignore', 'ignore', 'ignore']});
  const timer = setTimeout(() => child.kill('SIGTERM'), Math.max(1, scenarioDeadline - Date.now()));
  const result = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', (code, signal) => resolve({code, signal})); });
  clearTimeout(timer);
  if (result.signal) { nativeSettlement = 'unresolved'; throw new Error('Scenario process deadline/termination leaves native settlement unknown'); }
  const outcome = JSON.parse(fs.readFileSync(path.join(out, arm, 'outcome.json'), 'utf8'));
  if (outcome.session !== session || outcome.arm !== arm) throw new Error('Scenario outcome identity mismatch');
  nativeSettlement = outcome.nativeSettlement;
  if (nativeSettlement !== 'settled' || !outcome.triggerReached || !(outcome.status === 'scripted-gates-passed' || outcome.transitionEligible === true)) throw new Error('Scenario is not eligible for an installation transition');
  return outcome;
}

async function cleanup() {
  if (!session) {
    save('ownership.json', {ownedDevices: creationAttempted ? 'unknown' : 0, reason: creationAttempted ? 'Create response did not disclose session ID; root must reconcile provider inventory' : 'No session creation attempted'});
    return;
  }
  // Canonical DELETE is allowed even when native work is unresolved. No other
  // native command is queued in this state. A DELETE acknowledgment alone does
  // not establish provider device release.
  try {
    await http('DELETE', `https://hub-cloud.browserstack.com/wd/hub/session/${session}`, 'canonical-delete', {cleanup: true});
    deleted = true;
    let info;
    for (let attempt = 0; attempt < 3 && !stopped; attempt++) {
      const final = await http('GET', `https://api-cloud.browserstack.com/app-automate/sessions/${session}.json`, `final-session-${attempt}`, {cleanup: true});
      info = final.automation_session;
      stopped = Boolean(info && info.status === 'done' && info.reason === 'CLIENT_STOPPED_SESSION' && info.duration !== undefined);
      if (!stopped && attempt < 2) await new Promise(resolve => setTimeout(resolve, 1000));
    }
    if (!stopped) throw new Error('Final stopped provider receipt absent');
    // Preserve raw provider evidence through its supplied read-only URLs.
    for (const [key, label, binary] of [['video_url', 'continuous-video', true], ['device_logs_url', 'device-logs', false], ['appium_logs_url', 'appium-logs', false]]) {
      if (!info[key]) { event({phase: 'evidence-gap', label}); continue; }
      try {
        if (binary) await http('GET', info[key], label, {cleanup: true, binary: true});
        else {
          // Log bodies may be text, not JSON. Fetch separately and redact secrets.
          const file = path.join(out, `.${label}.raw`);
          try {
            if (Date.now() + 31000 > cleanupDeadline) throw new Error('Evidence retrieval would consume artifact preservation reserve');
            await exec('curl', ['--silent', '--show-error', '--fail', '--max-time', '30', '--user', `${authUser}:${authKey}`, '--output', file, info[key]], {timeout: 31000});
            save(`${label}.txt`, fs.readFileSync(file, 'utf8'));
          } finally { fs.rmSync(file, {force: true}); }
        }
      } catch { event({phase: 'evidence-gap', label, reason: 'retrieval failed'}); }
    }
  } catch (error) { event({phase: 'cleanup-error', message: error.message}); }
  save('ownership.json', {session, canonicalDeleteAcknowledged: deleted, finalStoppedReceipt: stopped, ownedDevices: deleted && stopped ? 0 : 'unknown', rootReconciliationRequired: !(deleted && stopped)});
}

try {
  admission();
  await capacity('capacity-before-uploads');
  const defaultUrl = await upload('default');
  const candidateUrl = await upload('candidate');
  if (defaultUrl === candidateUrl) throw new Error('Uploads did not yield distinct artifact references');
  admission();
  await capacity('capacity-immediately-before-session');
  const template = JSON.parse(fs.readFileSync(path.join(here, 'session-request.template.json'), 'utf8'));
  template.capabilities.alwaysMatch['appium:app'] = defaultUrl;
  template.capabilities.alwaysMatch['bstack:options'].midSessionInstallApps = [candidateUrl];
  save('session-request.json', template);
  creationAttempted = true;
  const created = await http('POST', 'https://hub-cloud.browserstack.com/wd/hub/session', 'session-create', {body: template, native: true});
  session = created.value?.sessionId;
  if (!session) { nativeSettlement = 'unresolved'; throw new Error('Session create identity absent'); }
  save('ownership.json', {session, ownedDevices: 1, scenarioDeadline, overallDeadline});
  await verifyIdentity('default-identity');
  const baselineSetup = await setup('default');
  const baseline = await sequence('default');
  save('baseline-transition-admission.json', baseline);
  await execute('terminate-default', 'mobile: terminateApp', {bundleId: bundle});
  const state = await execute('query-default-not-running', 'mobile: queryAppState', {bundleId: bundle});
  if (![0, 1].includes(state)) throw new Error('Old target not confirmed stopped');
  // BrowserStack's documented iOS driver.installApp maps to this endpoint;
  // no version-comparison option is sent for the equal-build-number artifacts.
  await request('POST', 'appium/device/install_app', 'install-candidate-exact-url', {appPath: candidateUrl});
  candidateInstalled = true;
  await execute('activate-candidate', 'mobile: activateApp', {bundleId: bundle});
  await verifyIdentity('candidate-identity');
  const candidateSetup = await setup('candidate');
  if (JSON.stringify(candidateSetup) !== JSON.stringify(baselineSetup)) throw new Error('Settings/sample render/setup differ; no valid paired condition');
  await sequence('candidate');
  save('pair-status.json', {status: 'scripted-gates-completed', candidateInstallAcknowledged: candidateInstalled, candidateSelection: 'provisional pending provider Appium log review for exact URL and non-skipped same-version installation', artifactIdentity: 'original IPA hashes bound to exact upload and acknowledged installation URLs; on-device bytes unverified', verdict: 'requires original video and provider-log review; installation acknowledgment alone is insufficient'});
} catch (error) {
  save('pair-status.json', {status: 'incomplete', candidateInstallAcknowledged: candidateInstalled, candidateSelection: 'unverified pending exact-URL/non-skipped provider installation log review', nativeSettlement, message: error.message, interpretation: 'No automatic product freeze or remediation verdict'});
  process.exitCode = 1;
} finally {
  await cleanup();
}
