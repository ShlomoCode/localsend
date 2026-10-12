import {spawn, execFile} from 'node:child_process';
import {promisify, isDeepStrictEqual} from 'node:util';
import {readFileSync, writeFileSync, appendFileSync, mkdirSync, copyFileSync, existsSync} from 'node:fs';
import {randomBytes, createHash} from 'node:crypto';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
import {relay} from './reused/relay.mjs';
import {runWebSocketQualification} from './ws-qualification.mjs';

const exec = promisify(execFile), root = dirname(fileURLToPath(import.meta.url));
mkdirSync('evidence', {recursive:true});
const comparisonRoot = process.cwd(), nodelayComparison = process.env.COMPARISON === 'nodelay-first-mkv-off';
let arm = 'default', senderNoDelay = false, firstHelper, senderReport, senderSettings;
const armReceipts = [];
function enterArm(name) {
  arm = name;
  const directory = resolve(comparisonRoot, 'evidence/nodelay-' + name);
  mkdirSync(directory + '/evidence', {recursive:true});
  const source = resolve(comparisonRoot, 'evidence');
  const fixtures = JSON.parse(readFileSync(source + '/fixture-index.json', 'utf8').replace(/^\uFEFF/, ''));
  for (const file of ['fixture-index.json', ...Object.values(fixtures).flatMap(file => [file, file + '.identity.json'])]) copyFileSync(source + '/' + file, directory + '/evidence/' + file);
  process.chdir(directory);
  const hashes = Object.fromEntries(Object.values(fixtures).map(file => [file, createHash('sha256').update(readFileSync('evidence/' + file)).digest('hex')]));
  writeFileSync('evidence/arm-fixture-hashes.json', JSON.stringify(hashes,null,2));
}
if (nodelayComparison) enterArm('default');
const token = randomBytes(24).toString('hex');
console.log('::add-mask::' + token);
const auth = 'Basic ' + Buffer.from(process.env.BROWSERSTACK_USERNAME + ':' + process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const secrets = [token, auth, process.env.BROWSERSTACK_USERNAME, process.env.BROWSERSTACK_ACCESS_KEY].filter(Boolean);
const redact = text => secrets.reduce((value, secret) => value.replaceAll(secret, '[redacted]'), String(text));
const save = (name, value) => writeFileSync('evidence/' + name, redact(value instanceof Error ? String(value) : typeof value === 'string' ? value : JSON.stringify(value, null, 2)));
const pause = ms => new Promise(ok => setTimeout(ok, ms));
const appId = 'org.localsend.localsendApp', proxyId = 'org.shlomocode.diagnostics.issue1591.byteproxy';
let session, local, r, failure, stage = 'configuration', previousFinished = false;
let monitoredWindow, healthMonitor;
let helperStartAttempted = false;
let windowsUI, windowsReady, windowsSeq = 0;
let windowsUIAmbiguous = false;
const windowsRequests = new Map();
const healthMaxAgeMs = 5000;
const results = [], cleanup = [], backgroundWindows = [];
const basicReceiveCardName = 'Receive Quick Save Quick Save for "Favorites" Require PIN Save media to gallery Auto Finish Save to history';
const advancedReceiveCardName = basicReceiveCardName + ' Verify checksums when receiving files';
const receiveCard = '//XCUIElementTypeOther[normalize-space(@name)=\'' + basicReceiveCardName + '\' or normalize-space(@name)=\'' + advancedReceiveCardName + '\']';
let initialReceiveChecksum;
const receiveChecksumObservations = [];
const eid = element => element['element-6066-11e4-a52e-4f735466cecf'];
const prefix = () => '/session/' + session;

function healthIssue(window, {background = true, afterSwitch = false, requirePeer = false} = {}) {
  if (r.status().faults.length) return 'relay transport fault: ' + r.status().faults[0].kind;
  const state = r.health(), sample = state.lastHealth, payload = sample?.payload;
  if (!sample || !Number.isFinite(state.healthAgeMs) || state.healthAgeMs > healthMaxAgeMs) return 'missing or stale health';
  if (!payload.running) return 'helper is not running';
  if (window.generation && (payload.generation !== window.generation || payload.pid !== window.pid)) return 'helper generation or PID changed';
  if (background) {
    if (payload.applicationState !== 'background') return 'helper is not observed in background';
    if (afterSwitch && Date.parse(sample.receivedUtc) < Date.parse(window.switchUtc)) return 'health sample predates switch';
    if (payload.budgetState !== 'finite' || !Number.isFinite(payload.remainingBudgetSeconds) || payload.remainingBudgetSeconds - state.healthAgeMs / 1000 <= 0) return 'finite background budget expired or unavailable';
  } else if (payload.applicationState !== 'active') return 'helper is not observed active before switching';
  if (requirePeer && !r.healthSamples.some(entry => entry.payload.generation === window.generation && entry.payload.pid === window.pid && entry.payload.peers.some(peer => peer.ready && peer.toLocalSendBytes > 0 && peer.fromLocalSendBytes > 0))) return 'no ready bidirectional LocalSend peer observed';
  return null;
}
async function checkpoint(window, milestone, {awaitBackground = false, requirePeer = false, minimumObservedBudgetSeconds = 0} = {}) {
  if (window.healthFault) throw new Error('Transport infrastructure health failed: ' + window.healthFault.issue);
  const invokedUtc = new Date().toISOString();
  const foregroundState = await wd('POST', prefix() + '/execute/sync', {script:'mobile: queryAppState', args:[{bundleId:appId}]}, 10000);
  const deadline = Date.now() + (awaitBackground ? healthMaxAgeMs : 0);
  let issue;
  do {
    issue = healthIssue(window, {afterSwitch:true, requirePeer});
    if (!issue || Date.now() >= deadline) break;
    await pause(100);
  } while (Date.now() <= deadline);
  const observation = {milestone, invokedUtc, checkedUtc:new Date().toISOString(), foregroundAppId:appId, foregroundState,
    healthMaxAgeMs, minimumObservedBudgetSeconds,
    budgetInterpretation:'Latest finite allowance minus monotonic server sample age; network sampling latency is not bounded and this is an admission margin, not guaranteed remaining time', health:r.health(), issue};
  observation.observedAdjustedBudgetSeconds = observation.health.lastHealth?.payload.remainingBudgetSeconds - observation.health.healthAgeMs / 1000;
  if (!issue && (!Number.isFinite(observation.observedAdjustedBudgetSeconds) || observation.observedAdjustedBudgetSeconds < minimumObservedBudgetSeconds)) issue = 'observed background allowance is below the conservative admission margin';
  observation.issue = issue;
  window.checkpoints.push(observation);
  save(window.case + '-health-checkpoints.json', window);
  save(window.case + '-health-samples.json', r.healthSamples);
  if (foregroundState !== 4) throw new Error('Transport infrastructure: LocalSend is not observed foreground (state 4) at ' + milestone);
  if (issue) throw new Error('Transport infrastructure at ' + milestone + ': ' + issue);
  if (window.healthFault) throw new Error('Transport infrastructure health failed: ' + window.healthFault.issue);
}
async function auditTransportDrain(window) {
  const started = Date.now(), deadline = started + 5000, observations = [];
  let drained = false;
  do {
    const state = r.status(), issue = window.healthFault?.issue || healthIssue(window, {afterSwitch:true,requirePeer:true});
    const peerAudit = Object.entries(state.peerBytes).map(([id,bytes]) => ({id,...bytes,acknowledged:bytes.acknowledgedToDevice === bytes.fromSender}));
    drained = state.pendingAckSeq === null && state.queued === 0 && peerAudit.every(peer => peer.acknowledged);
    observations.push({utc:new Date().toISOString(),elapsedMs:Date.now()-started,pendingAckSeq:state.pendingAckSeq,queued:state.queued,peerAudit,health:r.health(),issue,drained});
    save(window.case + '-transport-drain-audit.json',{timeoutMs:5000,elapsedMs:Date.now()-started,drained,observations});
    if (issue) throw new Error('Transport infrastructure before drain admission: ' + issue);
    if (drained) break;
    await pause(Math.min(100,Math.max(0,deadline-Date.now())));
  } while (Date.now() < deadline);
  if (!drained) throw new Error('Transport infrastructure: pending ACK or unacknowledged sender bytes at case end');
}
function monitorHealth(window) {
  monitoredWindow = window;
  healthMonitor ||= setInterval(() => {
    if (!monitoredWindow || monitoredWindow.healthFault) return;
    const issue = healthIssue(monitoredWindow, {afterSwitch:true});
    if (issue) {
      monitoredWindow.healthFault = {utc:new Date().toISOString(), stage, issue, health:r.health()};
      save(monitoredWindow.case + '-health-fault.json', monitoredWindow.healthFault);
    }
    save(monitoredWindow.case + '-health-samples.json', r.healthSamples);
  }, 500);
}

async function wd(method, path, body, timeoutMs = 30000) {
  const started = Date.now(); let response, error;
  try {
    response = await fetch('https://hub-cloud.browserstack.com/wd/hub' + path, {
      method, headers:{authorization:auth, 'content-type':'application/json'},
      body:body === undefined ? undefined : JSON.stringify(body), signal:AbortSignal.timeout(timeoutMs),
    });
    const json = await response.json();
    if (!response.ok || json.value?.error) {
      save(`w3c-error-${started}.json`, {method, path, status:response.status, response:json});
      throw new Error(`W3C ${response.status} ${json.value?.error || ''} ${json.value?.message || ''}`);
    }
    return json.value;
  } catch (caught) { error = redact(caught); throw new Error(error); }
  finally {
    appendFileSync('evidence/w3c-boundaries.jsonl', JSON.stringify({utc:new Date(started).toISOString(), elapsedMs:Date.now()-started,
      stage, method, path:path.replace(/\/session\/[^/]+/, '/session/owned'), status:response?.status, error}) + '\n');
  }
}
async function capture(label) {
  save(label + '.xml', await wd('GET', prefix() + '/source'));
  writeFileSync('evidence/' + label + '.png', Buffer.from(await wd('GET', prefix() + '/screenshot'), 'base64'));
  save(label + '-app-state.json', {utc:new Date().toISOString(), appId,
    state:await wd('POST', prefix() + '/execute/sync', {script:'mobile: queryAppState', args:[{bundleId:appId}]}),
    pidAuthority:'Process identity and lifecycle require the original BrowserStack device logs; app-state is not a PID.'});
}
function captureWindowsStreams(label) {
  const reportPath = 'evidence/release-ui-report.json';
  if (!existsSync(reportPath)) return;
  const report = JSON.parse(readFileSync(reportPath, 'utf8').replace(/^\uFEFF/, ''));
  const streams = ['stdout','stderr'].map(stream => {
    const path = 'evidence/windows-app.' + stream + '.txt';
    if (!existsSync(path)) return {stream,sourcePath:path,status:'capture-unavailable',reason:'redirected file absent'};
    const bytes = readFileSync(path);
    const snapshotName = 'windows-app-' + label + '.' + stream + '.txt';
    save(snapshotName, bytes.toString('utf8'));
    const retainedSnapshotPath = 'evidence/' + snapshotName, retained = readFileSync(retainedSnapshotPath);
    return {stream,sourcePath:path,sourceBytes:bytes.length,sourceSha256:createHash('sha256').update(bytes).digest('hex'),
      retainedSnapshotPath,retainedSnapshotBytes:retained.length,retainedSnapshotSha256:createHash('sha256').update(retained).digest('hex'),
      snapshotTransform:'UTF-8 decode plus configured text redaction; redirected source file remains retained separately',
      status:bytes.length ? 'bytes-retained' : 'capture-unavailable',limitation:'Empty streams do not establish absence of application errors; snapshots may precede later writes'};
  });
  save('windows-app-' + label + '-streams.json', {utc:new Date().toISOString(),launch:report.appStreamCapture,
    executable:report.executable,observedLaunchProcesses:report.processes,streams});
}
async function captureTransportErrorSnapshot(failedStage) {
  // One supplemental request after the fatal interval is frozen. The native
  // action qualifies fresh pixels and ownership before its single info click.
  const label = 'sender-transport-fault-dialog';
  const readJson = name => JSON.parse(readFileSync('evidence/' + name, 'utf8').replace(/^\uFEFF/, ''));
  const receipt = {utc:new Date().toISOString(),failedStage,attempted:false,status:'evidence-unavailable',
    outcome:'Supplemental readable ErrorDialog review only; original transport failure remains fatal'};
  try {
    const baseline = readJson('windows-ui-prewarmed-action.json');
    if (!windowsReady || windowsUI?.exitCode !== null || !Number.isInteger(baseline.appPid) || baseline.appPid <= 0 || !Number.isInteger(baseline.window) || baseline.window <= 0) {
      throw new Error('Owned prewarmed Windows RPC or baseline PID/HWND unavailable');
    }
    receipt.appPid = baseline.appPid; receipt.window = baseline.window;
    receipt.attempted = 'indeterminate'; receipt.status = 'dispatch-indeterminate';
    await powershell('windows3393-ui.ps1', ['-Action','favorites-error','-Label',label,'-ExpectedPid',String(baseline.appPid),'-ExpectedWindow',String(baseline.window)]);
    receipt.rpcCompleted = true; receipt.status = 'rpc-completed-awaiting-native-receipt';
  } catch (error) {
    receipt.error = redact(error); throw error;
  } finally {
    // A timed-out request may still post input. Never dispatch a replacement.
    // Keep a native receipt separately even if the controller lost its reply.
    const nativePath = 'evidence/' + label + '-receipt.json';
    try {
      if (existsSync(nativePath)) {
        const native = readJson(label + '-receipt.json');
        if (native.action !== 'favorites-error' || native.expectedPid !== receipt.appPid || native.expectedWindow !== receipt.window ||
            !Number.isFinite(Date.parse(native.utc)) || Date.parse(native.utc) < Date.parse(receipt.utc)) {
          throw new Error('Native details receipt does not belong to this request');
        }
        receipt.native = native;
        receipt.attempted = native.attempted; receipt.status = native.status;
      }
    } catch (error) {receipt.nativeReceiptError = redact(error);}
    save(label + '-controller-receipt.json', receipt);
  }
}
async function elements(using, value, timeoutMs = 30000) { return wd('POST', prefix() + '/elements', {using, value}, timeoutMs); }
async function unique(using, value, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const matches = await elements(using, value);
    if (matches.length > 1) throw new Error('Ambiguous UI control: ' + value);
    if (matches.length === 1 && await wd('GET', prefix() + '/element/' + eid(matches[0]) + '/displayed')) return matches[0];
    await pause(250);
  }
  throw new Error('UI control absent: ' + value);
}
async function click(label, timeout) {
  const element = await unique('xpath', `//*[@name="${label}" or @label="${label}" or starts-with(@name,"${label}\nTab ")]`, timeout);
  await wd('POST', prefix() + '/element/' + eid(element) + '/click', {});
}
async function activate(bundleId) { await wd('POST', prefix() + '/appium/device/activate_app', {appId:bundleId}); }
async function powershell(script, args = [], {timeoutMs = 30000} = {}) {
  if (script === 'windows3393-ui.ps1' && windowsReady) {
    if (windowsUIAmbiguous) throw new Error('Owned Windows observer RPC is indeterminate; no subsequent native request allowed');
    const value = name => {const index=args.indexOf(name);return index < 0 ? undefined : args[index + 1];};
    const id = ++windowsSeq;
    return new Promise((ok, reject) => {
      const timer = setTimeout(() => {windowsRequests.delete(id);windowsUIAmbiguous = true;reject(new Error('Prewarmed Windows UI deadline exceeded'));}, timeoutMs);
      windowsRequests.set(id, {ok, reject, timer});
      windowsUI.stdin.write(JSON.stringify({id,action:value('-Action'),x:Number(value('-X') || 0),y:Number(value('-Y') || 0),label:value('-Label'),
        foreground:args.includes('-RequireForeground'),sequence:args.includes('-UseControlSequence'),
        expectedPid:Number(value('-ExpectedPid') || 0),expectedWindow:Number(value('-ExpectedWindow') || 0),expectedFilename:value('-ExpectedFilename') || '',allowInfo:args.includes('-AllowInfo')}) + '\n');
    });
  }
  const started = Date.now();
  try {
    const output = await exec('pwsh', ['-NoProfile', '-File', root + '/reused/' + script, ...args], {timeout:180000, maxBuffer:4*1024*1024});
    save(`windows-${started}.txt`, output.stdout + output.stderr);
  } catch (error) { save(`windows-${started}-error.txt`, [error.message, error.stdout, error.stderr].join('\n')); throw error; }
}
const senderOutcomeRequests = new Set();
async function observeSenderOutcome(label, filename, window, {allowInfo = false, trigger} = {}) {
  if (senderOutcomeRequests.has(label)) throw new Error('Sender outcome observer already dispatched; no replacement allowed');
  senderOutcomeRequests.add(label);
  const receipt = {utc:new Date().toISOString(),label,filename,timeoutMs:5000,status:'dispatch-indeterminate',senderVerified:false,
    trigger,allowInfo,
    authority:'Owned original before/after Windows pixels and any actual UIA result; opaque provider requires parent visual review'};
  let nativeDispatched = false;
  try {
    const baseline = JSON.parse(readFileSync('evidence/windows-ui-prewarmed-action.json','utf8').replace(/^\uFEFF/,''));
    receipt.appPid = baseline.appPid; receipt.window = baseline.window;
    if (!windowsReady || windowsUI?.exitCode !== null || !Number.isInteger(baseline.appPid) || baseline.appPid <= 0 || !Number.isInteger(baseline.window) || baseline.window <= 0) throw new Error('Owned sender identity/RPC unavailable');
    nativeDispatched = true;
    await powershell('windows3393-ui.ps1',['-Action','sending-outcome','-Label',label,'-ExpectedPid',String(baseline.appPid),'-ExpectedWindow',String(baseline.window),'-ExpectedFilename',filename,...(allowInfo ? ['-AllowInfo'] : [])],{timeoutMs:5000});
    const native = JSON.parse(readFileSync('evidence/' + label + '-receipt.json','utf8').replace(/^\uFEFF/,''));
    if (native.action !== 'sending-outcome' || native.expectedPid !== baseline.appPid || native.expectedWindow !== baseline.window || native.filename !== filename || !Number.isFinite(Date.parse(native.utc)) || Date.parse(native.utc) < Date.parse(receipt.utc)) throw new Error('Sender outcome native receipt identity differs');
    receipt.native = native; receipt.status = native.status;
    if (native.attempted === true && ['UIA-deadline-indeterminate','invocation-indeterminate'].includes(native.status)) {
      windowsUIAmbiguous = true;
      receipt.ambiguity = 'Native info invocation may still complete; no subsequent native request or second arm is admitted';
    }
  } catch (error) {
    receipt.error = redact(error);
    if (allowInfo && nativeDispatched) {
      windowsUIAmbiguous = true;
      receipt.ambiguity = 'Terminal native request lacks a qualified completion receipt; possible input is not replaced';
    }
  }
  finally {receipt.completedUtc = new Date().toISOString();receipt.health = r?.health();save(label + '-controller-receipt.json',receipt);window.senderOutcome = receipt;}
  if (windowsUIAmbiguous) throw new Error('Sender observer completion or input is indeterminate; pair stopped without a replacement or second arm');
  return receipt;
}
async function prepareWindowsUI() {
  windowsUI = spawn('pwsh',['-NoProfile','-File',root + '/windows-ui-server.ps1']);
  windowsUIAmbiguous = false;
  const pendingReady = new Promise((ok, reject) => {
    const timer = setTimeout(() => reject(new Error('Windows native helper did not prewarm')), 60000);
    const stop = error => {clearTimeout(timer);reject(error);for(const pending of windowsRequests.values()){clearTimeout(pending.timer);pending.reject(error);}windowsRequests.clear();};
    windowsUI.on('error', stop); windowsUI.on('exit', code => stop(new Error('Owned Windows UI process exited ' + code)));
    createInterface({input:windowsUI.stdout}).on('line', line => {
      if (!line.startsWith('ISSUE1591_RPC:')) {appendFileSync('evidence/windows-ui-server.stdout.txt',redact(line) + '\n');return;}
      try {
        const result = JSON.parse(line.slice('ISSUE1591_RPC:'.length));
        if (result.ready) {windowsReady = true;save('windows-ui-server.json',result);clearTimeout(timer);ok();return;}
        const pending = windowsRequests.get(result.id);
        if (!pending) return;
        clearTimeout(pending.timer);windowsRequests.delete(result.id);
        if (result.ok) pending.ok(result);else pending.reject(new Error(result.error));
      } catch (error) {stop(error);}
    });
    createInterface({input:windowsUI.stderr}).on('line', line => appendFileSync('evidence/windows-ui-server.stderr.txt',redact(line) + '\n'));
  });
  await pendingReady;
}
async function receiveInventory() {
  const cards = await elements('xpath', receiveCard);
  if (cards.length !== 1) throw new Error('Exact basic/advanced Receive card is absent or ambiguous');
  const cardName = (await wd('GET', prefix() + '/element/' + eid(cards[0]) + '/attribute/name')).replace(/\s+/g, ' ').trim();
  const count = cardName === basicReceiveCardName ? 6 : cardName === advancedReceiveCardName ? 7 : 0;
  const switches = await elements('xpath', receiveCard + '/following-sibling::XCUIElementTypeSwitch');
  if (!count || switches.length !== count) throw new Error('Receive card switch inventory does not match its full exact labels');
  return {cardName, count, switches};
}
async function observeReceiveChecksum(label, milestone) {
  // Advanced adds this seventh Receive control without changing its value.
  const locator = receiveCard + '/following-sibling::XCUIElementTypeSwitch[7]';
  let inventory = await receiveInventory();
  if (inventory.count !== 7) throw new Error('Advanced Receive checksum control is unavailable');
  const visible = async () => await wd('GET', prefix() + '/element/' + eid(inventory.switches[6]) + '/displayed') &&
    await wd('GET', prefix() + '/element/' + eid(inventory.switches[3]) + '/displayed');
  if (!await visible()) {
    for (let attempt = 0; attempt < 6; attempt++) await wd('POST', prefix() + '/execute/sync', {script:'mobile: swipe', args:[{direction:'down'}]});
    await capture(label + '-checksum-' + milestone + '-top-reset');
    for (let attempt = 0; attempt < 5; attempt++) {
      inventory = await receiveInventory();
      if (inventory.count !== 7) throw new Error('Advanced Receive inventory changed during checksum observation');
      if (await visible()) break;
      await wd('POST', prefix() + '/execute/sync', {script:'mobile: swipe', args:[{direction:'up'}]});
    }
  }
  const checksum = await unique('xpath', locator);
  inventory = await receiveInventory();
  if (inventory.count !== 7 || !await visible()) throw new Error('Gallery/checksum controls are not visibly observed together');
  const value = await wd('GET', prefix() + '/element/' + eid(checksum) + '/attribute/value');
  const observation = {case:label, milestone, value, initialValue:initialReceiveChecksum, locator, cardName:inventory.cardName,
    visible:true, mutations:'none; checksum control is read only', baselineAuthority:'First visible advanced Receive checksum observation in this owned session'};
  await capture(label + '-checksum-' + milestone);
  receiveChecksumObservations.push(observation);
  save('receive-checksum-observations.json', receiveChecksumObservations);
  if (!['0','1'].includes(value)) throw new Error('Receive checksum value is not an observed boolean');
  if (initialReceiveChecksum === undefined) {
    initialReceiveChecksum = value;
    observation.initialValue = value;
    save('receive-checksum-observations.json', receiveChecksumObservations);
  } else if (value !== initialReceiveChecksum) throw new Error('Receive checksum setting changed from its first observed value');
}
async function gallery(desired, label) {
  stage = label + '-settings';
  await click('Settings'); await capture(label + '-settings-entry');
  // The unchanged iPad app exposes the Receive card's labels as one native
  // element and six/seven unnamed sibling switches. Original 38179175479
  // basic XML and 38185385547 advanced XML identify gallery as the fourth.
  const card = receiveCard;
  const locator = card + '/following-sibling::XCUIElementTypeSwitch[4]';
  let matches = await elements('xpath', locator);
  if (matches.length > 1) throw new Error('Gallery switch is ambiguous');
  if (matches.length !== 1 || !await wd('GET', prefix() + '/element/' + eid(matches[0]) + '/displayed')) {
    // Network observations can leave Settings below Receive on later cases.
    // Normalize toward the top, then discover downward using visible controls.
    for (let attempt = 0; attempt < 6; attempt++) {
      await wd('POST', prefix() + '/execute/sync', {script:'mobile: swipe', args:[{direction:'down'}]});
    }
    await capture(label + '-settings-top-reset');
    for (let attempt = 0; attempt < 5; attempt++) {
      matches = await elements('xpath', locator);
      if (matches.length > 1) throw new Error('Gallery switch is ambiguous');
      if (matches.length === 1 && await wd('GET', prefix() + '/element/' + eid(matches[0]) + '/displayed')) break;
      await wd('POST', prefix() + '/execute/sync', {script:'mobile: swipe', args:[{direction:'up'}]});
      await capture(label + '-settings-scroll-' + attempt);
    }
  }
  matches = await elements('xpath', locator);
  if (matches.length !== 1) throw new Error('Gallery switch is absent or ambiguous; inspect retained native source before adjusting locators');
  const inventory = await receiveInventory(), cardName = inventory.cardName;
  if (inventory.count === 7) await observeReceiveChecksum(label, 'before-gallery');
  const id = eid(await unique('xpath', locator));
  if (!await wd('GET', prefix() + '/element/' + id + '/displayed')) throw new Error('Gallery switch is not visibly observed before selection');
  await capture(label + '-gallery-before');
  const getValue = () => wd('GET', prefix() + '/element/' + id + '/attribute/value');
  const before = await getValue();
  if (!['0','1',0,1,true,false].includes(before)) throw new Error('Gallery switch value is not an observed boolean');
  if ((before === '1' || before === 1 || before === true) !== desired) await wd('POST', prefix() + '/element/' + id + '/click', {});
  const refreshed = await unique('xpath', locator);
  const afterInventory = await receiveInventory();
  if (afterInventory.cardName !== cardName || afterInventory.count !== inventory.count) throw new Error('Receive card inventory changed after gallery selection');
  const after = await wd('GET', prefix() + '/element/' + eid(refreshed) + '/attribute/value');
  if (!['0','1',0,1,true,false].includes(after)) throw new Error('Gallery switch after-value is not an observed boolean');
  if ((after === '1' || after === 1 || after === true) !== desired) throw new Error('Gallery setting did not change');
  save(label + '-gallery.json', {desired, before, after, locator, cardName, switchCount:inventory.count, visiblyObservedBefore:true, visiblyObservedAfter:true, nativeLayoutAuthority:'Original 38179175479 basic six-switch XML/image and 38185385547 exact advanced seven-switch XML: gallery fourth', selectionTiming:'Global Settings before real transfer'});
  await capture(label + '-settings-selected');
  if (afterInventory.count === 7) await observeReceiveChecksum(label, 'after-gallery');
  await receiverNetworkSettings(label);
  await click('Receive'); await capture(label + '-receive-ready');
}
async function receiverNetworkSettings(label) {
  stage = label + '-receiver-network-settings';
  // Retained scroll-4 XML from run 38179175479 exposes one footer StaticText
  // followed immediately by its unnamed checkbox, represented as Switch.
  const footer = '//XCUIElementTypeStaticText[@name="Advanced settings"]';
  const toggle = footer + '/following-sibling::*[1][self::XCUIElementTypeSwitch]';
  let found;
  for (let attempt=0;attempt<6;attempt++) {
    found=await elements('xpath',toggle);
    if(found.length>1)throw new Error('Advanced settings footer is ambiguous');
    if(found.length===1&&await wd('GET',prefix()+'/element/'+eid(found[0])+'/displayed'))break;
    await wd('POST',prefix()+'/execute/sync',{script:'mobile: swipe',args:[{direction:'up'}]});
    await capture(label+'-advanced-footer-scroll-'+attempt);
  }
  const checkbox=await unique('xpath',toggle);
  if((await elements('xpath',footer)).length!==1)throw new Error('Advanced settings label is ambiguous');
  const before=await wd('GET',prefix()+'/element/'+eid(checkbox)+'/attribute/value');
  if(!['0','1'].includes(before))throw new Error('Advanced settings checkbox value is not an observed boolean');
  await capture(label+'-advanced-before');
  if(before==='0')await wd('POST',prefix()+'/element/'+eid(checkbox)+'/click',{});
  // Expanding settings moves this already-observed footer offscreen (run
  // 38181832948). Read its unique refreshed value without a visibility gate;
  // the actual Network port/Encryption controls still must be visible below.
  const current=await elements('xpath',toggle);
  if(current.length!==1||(await elements('xpath',footer)).length!==1)throw new Error('Advanced settings readback is absent or ambiguous');
  const after=await wd('GET',prefix()+'/element/'+eid(current[0])+'/attribute/value');
  if(after!=='1')throw new Error('Advanced settings did not reveal its controls');
  save(label+'-advanced-toggle.json',{before,after,footer,toggle,visibilityPolicy:'Leave Advanced on in this isolated diagnostic session; no restore action',nativeAuthority:'Original 38179175479 scroll-4 XML: unique Advanced settings StaticText, immediate sibling Switch; source LabeledCheckbox labelFirst=true'});
  await capture(label+'-advanced-revealed');
  // The app source orders Network plain TextFieldTv controls as Device model,
  // Port, Discovery Timeout, Multicast address; alias uses a separate button.
  // Encryption is this card's only BooleanEntry. Require the observed native
  // inventory to match before reading values; never mutate these controls.
  const card='//XCUIElementTypeOther[starts-with(normalize-space(@name),"Network ") and contains(@name,"Device name") and contains(@name,"Device model") and contains(@name,"Port") and contains(@name,"Discovery Timeout") and contains(@name,"Encryption") and contains(@name,"Multicast address")]';
  const encryption=card+'/following-sibling::XCUIElementTypeSwitch';
  const fields=card+'/following-sibling::XCUIElementTypeTextField';
  for(let attempt=0;attempt<6;attempt++){
    const switches=await elements('xpath',encryption),inputs=await elements('xpath',fields);
    if(switches.length>1||inputs.length>4)throw new Error('Network control inventory is ambiguous');
    if(switches.length===1&&inputs.length===4&&await wd('GET',prefix()+'/element/'+eid(switches[0])+'/displayed')&&await wd('GET',prefix()+'/element/'+eid(inputs[1])+'/displayed'))break;
    await wd('POST',prefix()+'/execute/sync',{script:'mobile: swipe',args:[{direction:'down'}]});
    await capture(label+'-network-scroll-'+attempt);
  }
  const cards=await elements('xpath',card),switches=await elements('xpath',encryption),inputs=await elements('xpath',fields);
  await capture(label+'-network-settings');
  if(cards.length!==1||switches.length!==1||inputs.length!==4)throw new Error('Network labels/control order do not match source; actual encryption/port proof unavailable');
  if(!await wd('GET',prefix()+'/element/'+eid(switches[0])+'/displayed')||!await wd('GET',prefix()+'/element/'+eid(inputs[1])+'/displayed'))throw new Error('Network encryption/port controls are not visibly observed');
  const observed=[];
  for(const element of inputs)observed.push({name:await wd('GET',prefix()+'/element/'+eid(element)+'/attribute/name'),value:await wd('GET',prefix()+'/element/'+eid(element)+'/attribute/value'),rect:await wd('GET',prefix()+'/element/'+eid(element)+'/rect')});
  const encryptionValue=await wd('GET',prefix()+'/element/'+eid(switches[0])+'/attribute/value');
  const portValue=observed[1].value;
  const cardName=await wd('GET',prefix()+'/element/'+eid(cards[0])+'/attribute/name');
  save(label+'-network-settings.json',{cardName,card,fieldOrder:['Device model','Port','Discovery Timeout','Multicast address'],observed,portValue,encryptionValue,
    sourceAuthority:'Current unchanged settings_tab.dart: advanced plain TextFieldTv order; Encryption sole Network BooleanEntry',mutations:'Only Advanced settings visibility checkbox; port/encryption controls read without edits'});
  if(encryptionValue!=='1'||portValue!=='53317')throw new Error('Actual receiver settings do not admit the expected encrypted port 53317 control');
  if(/Offline|Restart the server to apply the settings/i.test(cardName))throw new Error('Receiver Network UI does not establish an active server with applied settings');
  // Keep Advanced visible in this isolated session; no restore tap is needed.
  // First basic case acquires its checksum baseline here, after Network proof.
  await observeReceiveChecksum(label, 'after-network');
}
async function configureProxy(label) {
  stage = label + '-proxy-start';
  if (nodelayComparison) {
    await wd('POST', prefix() + '/appium/device/terminate_app', {bundleId:proxyId});
    const stopped = await wd('POST', prefix() + '/execute/sync', {script:'mobile: queryAppState', args:[{bundleId:proxyId}]});
    save('helper-before-start.json', {arm, state:stopped, policy:'Fresh helper process only; receiver process/server retained'});
    if (stopped !== 1) throw new Error('Fresh helper admission requires observed not-running state 1');
  }
  await activate(proxyId);
  // Supply secrets through element values rather than retained session capabilities.
  for (const [name, value] of [['relayURL','http://bs-local.com:8080'], ['relayToken',token]]) {
    const element = await unique('accessibility id', name);
    await wd('POST', prefix() + '/element/' + eid(element) + '/clear', {});
    await wd('POST', prefix() + '/element/' + eid(element) + '/value', {text:value});
  }
  helperStartAttempted = true;
  await click('startProxy');
  const started = Date.now(), deadline = started + 20000;
  let consentedLocalNetwork = false;
  while ((!r.status().pollPending || healthIssue({}, {background:false})) && Date.now() < deadline) {
    const source = await wd('GET', prefix() + '/source');
    if (!consentedLocalNetwork && /local network/i.test(source) && (await elements('accessibility id','Allow')).length === 1) {
      save(label + '-proxy-local-network-prompt.xml', source);
      writeFileSync('evidence/' + label + '-proxy-local-network-prompt.png', Buffer.from(await wd('GET', prefix() + '/screenshot'), 'base64'));
      await click('Allow'); consentedLocalNetwork = true;
    }
    await pause(250);
  }
  if (!r.status().pollPending || healthIssue({}, {background:false})) throw new Error('Proxy never established both an authenticated relay poll and fresh active/running health');
  save(label + '-proxy-start.xml', await wd('GET', prefix() + '/source'));
  const window = {case:label, proxyStartedUtc:new Date(started).toISOString(), switchUtc:new Date().toISOString(),
    expiryAuthority:'Authenticated live health plus Swift lifecycle/expiry device logs', consentedLocalNetwork,
    generation:r.health().lastHealth.payload.generation, pid:r.health().lastHealth.payload.pid, checkpoints:[], statusBeforeSwitch:r.status()};
  if (nodelayComparison) {
    if (firstHelper && (window.pid === firstHelper.pid || window.generation === firstHelper.generation)) throw new Error('Second arm did not establish a distinct helper PID and generation');
    firstHelper ||= {pid:window.pid,generation:window.generation};
    save('helper-identity.json', {arm,pid:window.pid,generation:window.generation,firstHelper});
  }
  backgroundWindows.push(window);
  await activate(appId);
  await checkpoint(window, 'after-app-switch', {awaitBackground:true}); monitorHealth(window);
  return window;
}
async function transfer({label, extension, desired, verifyDocuments, galleryOracle = false}) {
  const filename = `issue1591-${process.env.GITHUB_RUN_ID}-${label}.${extension}`;
  const fixtureIndex = JSON.parse(readFileSync('evidence/fixture-index.json', 'utf8').replace(/^\uFEFF/, ''));
  const sourceFilename = fixtureIndex[extension];
  if (!sourceFilename || sourceFilename.includes('/') || sourceFilename.includes('\\')) throw new Error('Invalid source fixture index');
  const identity = JSON.parse(readFileSync('evidence/' + sourceFilename + '.identity.json', 'utf8').replace(/^\uFEFF/, ''));
  copyFileSync('evidence/' + sourceFilename, 'evidence/' + filename);
  identity.selectedFilename = filename; identity.sourceArtifactFilename = sourceFilename;
  await gallery(desired, label);
  // Prepare Explorer and Windows app state while the proxy remains foreground-capable.
  // No transfer is triggered until configureProxy has begun its background budget.
  stage = label + '-windows-file-selection';
  await powershell('windows2311-context.ps1', ['-Case',label, '-FixturePath',resolve('evidence/' + filename), '-SelectOnly', ...(previousFinished ? ['-CompletePrevious'] : [])]);
  captureWindowsStreams(label + '-selected');
  const window = await configureProxy(label);
  stage = label + '-windows-send';
  // These admission margins exceed the one-second media duration. They are
  // observed allowances, not RPC latency bounds or guaranteed iOS lifetime.
  await checkpoint(window, 'before-windows-send', {minimumObservedBudgetSeconds:20});
  await powershell('windows3393-ui.ps1', ['-Action','click','-X','246','-Y','266','-Label',label+'-favorites','-RequireForeground','-UseControlSequence']);
  await checkpoint(window, 'before-windows-send-action', {minimumObservedBudgetSeconds:20});
  await powershell('windows3393-ui.ps1', ['-Action','click','-X','145','-Y','225','-Label',label+'-send','-RequireForeground','-UseControlSequence']);
  window.senderSendUtc = new Date().toISOString(); await checkpoint(window, 'after-windows-send');
  stage = label + '-receiver-approval';
  await capture(label + '-pending');
  await unique('accessibility id', 'Accept', 12000);
  await checkpoint(window, 'before-Accept', {requirePeer:true,minimumObservedBudgetSeconds:15});
  window.acceptInvokedUtc = new Date().toISOString(); await click('Accept', 1000);
  window.acceptReturnedUtc = new Date().toISOString();
  // Observe the actual sender before a receiver wait can exhaust the finite budget.
  // This is one bounded request; an ambiguous RPC never gets a replacement.
  if (process.env.COMPARISON === 'mkv-gallery-pair') {
    await observeSenderOutcome(label + '-sender-early', filename, window,{trigger:'Immediately after actual receiver Accept RPC return; upload completion is not assumed'});
    await checkpoint(window, 'after-early-sender-observation', {requirePeer:true});
  }
  await checkpoint(window, 'after-Accept', {requirePeer:true});
  await capture(label + '-accepted');
  stage = label + '-receiver-save';
  const galleryPair = process.env.COMPARISON === 'mkv-gallery-pair';
  const deadline = Date.now() + (galleryPair ? 10000 : 30000);
  let terminalSenderObserved = false;
  while (Date.now() < deadline) {
    if (window.healthFault) throw new Error('Transport infrastructure while waiting for save: ' + window.healthFault.issue);
    const xml = await wd('GET', prefix() + '/source',undefined,galleryPair?3000:30000); save(label + '-latest.xml', xml);
    const receiverDone = (await elements('accessibility id', 'Done',galleryPair?2000:30000)).length === 1;
    const receiverError = /(?:name|label|value)="[^"\n]*(?:HTTP(?: status)?[: ]+500|Internal Server Error)[^"\n]*"/i.test(xml);
    if (process.env.COMPARISON === 'mkv-gallery-pair' && !terminalSenderObserved &&
        (receiverDone || receiverError || Date.now() - Date.parse(window.acceptReturnedUtc) >= 5000)) {
      terminalSenderObserved = true;
      // Only the terminal observation may invoke info. A timed-out early read
      // cannot send input, and a terminal timeout never receives a replacement.
      await observeSenderOutcome(label + '-sender-terminal',filename,window,{allowInfo:true,
        trigger:receiverDone?'receiver-Done-observed':receiverError?'receiver-error-observed':'five-second-post-Accept-boundary-not-completion-proof'});
      await checkpoint(window,'after-terminal-sender-observation',{requirePeer:true});
    }
    // Only consent to a prompt that explicitly requests adding photos. Never
    // request read/write library access or dismiss a broader permission prompt.
    if (/Allow Full Access|Select Photos|access your photo library/i.test(xml)) throw new Error('Broader Photos access prompt is outside the add-only scenario');
    if (/add(?: to)? (?:your )?photos/i.test(xml) && (await elements('accessibility id', 'Allow Access')).length === 1) await click('Allow Access');
    if (receiverDone) break;
    if (receiverError) {
      await checkpoint(window, 'observed-error-health', {requirePeer:true});
      await capture(label + '-reported-error');
      results.push({case:label, stage, source:identity, outcome:'observed-500', transport:r.status()});
      throw new Error('Observed HTTP 500 in real receiver transfer; retain exact source and device log to classify');
    }
    await pause(250);
  }
  await unique('accessibility id', 'Done', 1000);
  await checkpoint(window, 'receiver-save-completion', {requirePeer:true}); await capture(label + '-completed');
  await powershell('windows3393-ui.ps1', ['-Action','snapshot','-Label',label+'-sender-end']);
  save(label + '-sender-status.json', {authority:'Original Windows sender-end screenshot and native HWND/PID records; review image for Finished, per-file result and error details', autoTextStatus:'not exposed by this reused Flutter HWND backend'});
  const completeSource = await wd('GET', prefix() + '/source');
  const observedSuccess = completeSource.includes(filename) && /(?:name|label)="Finished"/.test(completeSource) && !/Finished with error|(?:name|label)="Error"|Internal Server Error/.test(completeSource);
  save(label + '-completion-status.json', {filename, doneVisible:true, finishedLabelObserved:/(?:name|label)="Finished"/.test(completeSource), fileObserved:completeSource.includes(filename), observedSuccess});
  if (!observedSuccess) throw new Error('Done appeared without an observed successful Finished/file result; inspect both endpoints');
  window.completedUtc = new Date().toISOString(); window.transport = r.status();
  const result = {case:label, source:identity, gallery:desired, outcome:'receiver-completed-sender-review-required',
    senderVerified:false, transport:r.status(), byteExact:false, evidenceAdmission:'Requires parent raw sender image/PID review and original device logs before both-endpoint success'};
  results.push(result);
  const photosObserved = galleryOracle && /(?:name|label)="Saved in Photos"/.test(completeSource);
  result.photosLabelObserved = photosObserved;
  if (verifyDocuments && !photosObserved) {
    stage = label + '-saved-file-verification';
    const path = `@${appId}:documents/${filename}`;
    await checkpoint(window, 'before-documents-pull', {requirePeer:true});
    let encoded;
    try {encoded = await wd('POST', prefix() + '/appium/device/pull_file', {path});}
    catch (error) {
      if (galleryOracle) {
        Object.assign(result,{path,outcome:'save-destination-oracle-unavailable',verificationLimit:'No Saved in Photos label and Documents pull failed. This does not establish a save defect or absence from Photos.',pullError:redact(error)});
        save('scenario-results.json',{results,backgroundWindows});
        throw new Error('Gallery destination verification blocked; inspect original receiver/sender UI and device log');
      }
      throw error;
    }
    await checkpoint(window, 'after-documents-pull', {requirePeer:true});
    const saved = Buffer.from(encoded, 'base64');
    writeFileSync('evidence/' + label + '-saved.' + extension, saved);
    const hash = createHash('sha256').update(saved).digest('hex');
    Object.assign(result, {path, savedBytes:saved.length, savedSha256:hash, byteExact:hash === identity.sha256 && saved.length === identity.bytes});
    if (!result.byteExact) throw new Error('Exact saved-file hash or size differs from real sender fixture');
  } else {
    result.verificationLimit = galleryOracle ?
      'Gallery completion and Saved in Photos label are UI evidence only. Documents pull cannot establish Photos library bytes; no read/write Photos authorization was granted.' :
      'Gallery completion is UI evidence only. Documents pull cannot establish Photos library bytes; no read/write Photos authorization was granted.';
  }
  save('scenario-results.json', {results, backgroundWindows});
  await checkpoint(window, 'verified-case-end', {requirePeer:true});
  await auditTransportDrain(window);
  monitoredWindow = null;
  await click('Done'); previousFinished = true;
  await activate(proxyId); await click('stopProxy');
  save(label + '-proxy-after-stop.xml', await wd('GET', prefix() + '/source'));
  // The helper's normal stop cancels its NWConnections without assuming that a
  // final HTTP push can run. Close owned sender keep-alive sockets server-side.
  if (!nodelayComparison) await r.stop();
  save(label + '-relay-trace.json', r.trace);
  captureWindowsStreams(label + '-completed');
  if (!nodelayComparison) {r = relay({token}); await r.start();}
  await activate(appId);
}
async function retainFailure(error) {
  const failedWindow = nodelayComparison && backgroundWindows.findLast(window => window.case === arm+'-mkv-gallery-off-control');
  const unadmittedFirstRequest = failedWindow && !failedWindow.acceptInvokedUtc &&
    (stage.endsWith('-windows-send') || stage.endsWith('-receiver-approval'));
  const captureSenderError = unadmittedFirstRequest || (stage.endsWith('-windows-send') && r?.status().faults.length);
  failure ||= redact(error); save('failure.json', {stage, error:redact(error), overallFailure:failure, classification:'Classify using actual UI, device lifecycle and transport logs. Infrastructure errors are not a reproduction.'});
  if (r && (r.status().faults.length || unadmittedFirstRequest)) {
    save('failed-interval-transport.json', {utc:new Date().toISOString(),stage,failure,transport:r.status(),trace:r.trace,backgroundWindows});
    monitoredWindow = null;
  }
  if (session) await capture('failure').catch(error => save('failure-capture-error.txt', error));
  if (captureSenderError) {
    await captureTransportErrorSnapshot(stage).catch(error => save('sender-transport-fault-dialog-capture-error.txt', error));
  }
  if (!captureSenderError && (stage.includes('receiver') || stage.includes('saved-file'))) {
    await powershell('windows3393-ui.ps1', ['-Action','snapshot','-Label','sender-failure']).catch(error => save('sender-failure-capture-error.txt', error));
    save('sender-error-detail-unavailable.json', {stage,attempted:false,status:'evidence-unavailable',
      reason:'Original sender snapshot retained; no semantically qualified Error information control is exposed by this backend, so no coordinate input is sent'});
  }
}
async function collectMetadata() {
  try {
    const response = await fetch(`https://api-cloud.browserstack.com/app-automate/sessions/${session}.json`, {headers:{authorization:auth}, signal:AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error('Session metadata HTTP ' + response.status);
    const detail = (await response.json()).automation_session;
    save('browserstack-session.json', detail);
    for (const [key, file] of [['device_logs_url','device-logs.txt'], ['appium_logs_url','appium-logs.txt'], ['video_url','original-browserstack-video.mp4']]) {
      if (!detail[key]) { save(file + '-error.txt', 'Session metadata omitted ' + key); failure ||= 'Required original evidence omitted: ' + key; continue; }
      const url = new URL(detail[key]);
      if (url.protocol !== 'https:' || !(url.hostname === 'browserstack.com' || url.hostname.endsWith('.browserstack.com'))) throw new Error('Unexpected BrowserStack evidence host');
      let log;
      for (let attempt = 0; attempt < 4; attempt++) {
        log = await fetch(url, {headers:{authorization:auth}, signal:AbortSignal.timeout(30000)});
        if (log.status !== 404) break;
        await log.text(); await pause(5000);
      }
      if (!log.ok) { save(file + '-error.txt', 'Evidence HTTP ' + log.status); failure ||= 'Required original evidence HTTP ' + log.status + ': ' + key; continue; }
      if (key === 'video_url') writeFileSync('evidence/' + file, Buffer.from(await log.arrayBuffer()));
      else {
        const raw = await log.text();save(file, raw);
        if (!raw.trim()) failure ||= 'Required original evidence is empty: ' + key;
        if (key === 'device_logs_url' && (!raw.includes('loopback-ready') || !raw.includes('did-enter-background'))) failure ||= 'Device logs omitted helper loopback/lifecycle proof';
        if (key === 'device_logs_url') {
          let ownedStopped = false;
          const events = [], fatal = [];
          const pattern = /started destination=127\.0\.0\.1:53317|stopping reason=user-stop|background-expired|background-task-unavailable|relay-(?:poll|push|health)-failed/g;
          for (const match of raw.matchAll(pattern)) {
            if (match[0].startsWith('started destination=')) ownedStopped = false;
            if (match[0] === 'stopping reason=user-stop') ownedStopped = true;
            const entry = {event:match[0],offset:match.index,ownedStopped,rawContext:raw.slice(Math.max(0,match.index-220),match.index+220)};
            events.push(entry);
            if (!ownedStopped && !match[0].startsWith('started destination=')) fatal.push(entry);
          }
          save('native-proxy-fatal-audit.json',{orderingAuthority:'Original device log text order; normal owned stop is stopping reason=user-stop, new helper start opens the next interval',events,fatal});
          if (fatal.length) failure ||= 'Native helper expiry or transport failure before owned stop';
        }
      }
    }
  } catch (error) { save('metadata-error.txt', error); failure ||= 'Required original BrowserStack evidence retrieval failed'; }
}
if (process.env.COMPARISON === 'ws-qualification') {
  await runWebSocketQualification({wd,save,redact,auth,token,appId,proxyId,root,
    setSession:value=>{session=value;},setStage:value=>{stage=value;}});
} else {
try {
  for (const name of ['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','PROXY_APP','RECEIVER_APP','RECEIVER_IDENTITY','BS_LOCAL_ID']) if (!process.env[name]) throw new Error('Missing required input ' + name);
  for (const name of ['PROXY_APP','RECEIVER_APP']) if (!/^bs:\/\/[a-f0-9]{40}$/i.test(process.env[name])) throw new Error('Expected immutable BrowserStack app hash for ' + name);
  save('identity.json', {receiver:process.env.RECEIVER_APP, receiverIdentity:process.env.RECEIVER_IDENTITY, proxy:process.env.PROXY_APP,
    proxyId, appId, run:process.env.GITHUB_RUN_ID, revision:process.env.GITHUB_SHA, device:'iPad 9th', os:'18', sender:'unchanged Windows 1.17.0 x64 release', comparison:process.env.COMPARISON});
  if (nodelayComparison) writeFileSync(resolve(comparisonRoot,'evidence/nodelay-source-identity.json'),redact(JSON.stringify({
    revision:process.env.GITHUB_SHA,node:process.version,armOrder:['default','nodelay'],receiver:process.env.RECEIVER_APP,
    receiverIdentity:process.env.RECEIVER_IDENTITY,helper:process.env.PROXY_APP,
    sourceHashes:Object.fromEntries(['run.mjs','reused/relay.mjs','.github/workflows/issue1591-realpair.yml'].map(file => {
      const path = file.startsWith('.github/') ? resolve(comparisonRoot,file) : resolve(root,file);
      return [file,createHash('sha256').update(readFileSync(path)).digest('hex')];
    }))},null,2)));
  stage = 'windows-startup';

  await powershell('windows2311-desktop.ps1');
  await powershell('windows_release_ui_probe.ps1', ['-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-2022','-FixtureTimestampUtc','2025-02-13T14:11:00Z','-FixtureFileName','startup-control.txt','-DiagnosticPeerPort','53318','-InitializeOnly']);
  captureWindowsStreams('launch');
  await prepareWindowsUI();
  stage = 'browserstack-local';
  local = spawn('C:/tmp/bs-local-bin/BrowserStackLocal.exe', ['--key',process.env.BROWSERSTACK_ACCESS_KEY,'--local-identifier',process.env.BS_LOCAL_ID,'--force-local','--only-automate'], {windowsHide:true});
  let output = '', localError;
  for (const [stream, name] of [[local.stdout,'local.stdout.txt'],[local.stderr,'local.stderr.txt']]) createInterface({input:stream}).on('line', line => {const text = redact(line) + '\n'; appendFileSync('evidence/' + name, text); output = (output + text).slice(-20000);});
  local.on('error', error => {localError = error;});
  const localDeadline = Date.now() + 120000;
  while (!/You can now access your local|Local Testing successfully connected/i.test(output) && Date.now() < localDeadline && !localError && local.exitCode === null) await pause(200);
  if (localError || local.exitCode !== null || !/You can now access your local|Local Testing successfully connected/i.test(output)) throw new Error('Owned BrowserStack Local did not become ready');
  r = relay({token,senderNoDelay}); await r.start();
  stage = 'capacity-admission';
  const response = await fetch('https://api-cloud.browserstack.com/app-automate/plan.json', {headers:{authorization:auth}, signal:AbortSignal.timeout(30000)});
  if (!response.ok) throw new Error('Fresh global capacity check HTTP ' + response.status);
  const plan = await response.json(); save('capacity-before-session.json', {checkedUtc:new Date().toISOString(), plan});
  const running = plan.parallel_sessions_running == null ? NaN : Number(plan.parallel_sessions_running);
  const queued = plan.queued_sessions == null ? NaN : Number(plan.queued_sessions);
  const planLimits = [plan.parallel_sessions_max_allowed,plan.team_parallel_sessions_max_allowed].filter(value => value !== undefined && value !== null).map(Number);
  const limit = Math.min(5, ...planLimits);
  const teamRunning = Number(plan.team_parallel_sessions_running);
  if (!Number.isFinite(running) || !Number.isFinite(queued) || !Number.isFinite(limit) || running >= limit || queued > 0 || (Number.isFinite(teamRunning) && teamRunning >= limit)) throw new Error('BrowserStack global capacity unavailable or occupied; no session admitted');
  stage = 'owned-session-creation';
  const caps = {platformName:'iOS', 'appium:deviceName':'iPad 9th', 'appium:platformVersion':'18', 'appium:automationName':'XCUITest',
    'appium:app':process.env.RECEIVER_APP, 'appium:otherApps':[process.env.PROXY_APP], 'appium:autoAcceptAlerts':false,
    'bstack:options':{local:true, localIdentifier:process.env.BS_LOCAL_ID, projectName:'LocalSend diagnostic', buildName:'issue1591-'+process.env.GITHUB_RUN_ID,
      // The second arm's bounded host-only preparation can exceed 120 seconds.
      // Provider session retention adds no device input or product timeout change.
      sessionName:'Windows 1.17 real selection to unchanged iPad receiver', idleTimeout:nodelayComparison ? 300 : 120, debug:true, video:true, networkLogs:false}};
  save('requested-capabilities.json', caps);
  const created = await wd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}},120000);
  session = created.sessionId; if (!session) throw new Error('Session ID missing in W3C response');
  save('owned-session.json', {session, capabilities:created.capabilities, createdUtc:new Date().toISOString()});
  stage = 'receiver-startup'; await capture('receiver-startup');
  // Normal local-network permission is unrelated to Photos authorization.
  const source = await wd('GET', prefix() + '/source');
  if (/local network/i.test(source) && (await elements('accessibility id','Allow')).length === 1) await click('Allow');
  await click('Receive');
  if (nodelayComparison) {
    for (const name of ['default','nodelay']) {
      let armFailure;
      try {
        if (name === 'nodelay') {
          enterArm(name); senderNoDelay = true; previousFinished = false;
          await powershell('windows_release_ui_probe.ps1', ['-OutputDirectory','evidence','-ExecutablePath',senderReport.executable.path,
            '-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-2022','-InitializeOnly']);
          await prepareWindowsUI();
          r = relay({token,senderNoDelay}); await r.start();
        }
        senderReport = JSON.parse(readFileSync('evidence/release-ui-report.json','utf8').replace(/^\uFEFF/,''));
        const ownedSender = JSON.parse(readFileSync('evidence/windows-ui-prewarmed-action.json','utf8').replace(/^\uFEFF/,''));
        if (armReceipts.length && ownedSender.appPid === armReceipts[0].senderPid) throw new Error('Second arm sender PID is not fresh');
        const settings = readFileSync(resolve(dirname(senderReport.executable.path),'settings.json'));
        const config = JSON.parse(settings.toString('utf8').replace(/^\uFEFF/,''));
        const settingsHash = createHash('sha256').update(settings).digest('hex');
        copyFileSync(resolve(dirname(senderReport.executable.path),'settings.json'),'evidence/sender-settings-before.json');
        save('arm-identity.json',{arm,senderNoDelay,node:process.version,nodeVersions:process.versions,
          sourceHashes:Object.fromEntries(['run.mjs','reused/relay.mjs','reused/windows_release_ui_probe.ps1'].map(file => [file,createHash('sha256').update(readFileSync(resolve(root,file))).digest('hex')])),
          sender:senderReport,settingsSha256:settingsHash,settingsText:settings.toString('utf8'),discoveryTimeoutMs:500,
          timeoutAuthority:'No persisted timeout override; Windows v1.17 tag 7f21d1f9082a43803e05c37f021912e012145aa5 common/lib/constants.dart defaults to 500 ms. Not a runtime measured internal deadline.',
          armOrder:['default','nodelay'],poolContext:'Fresh Windows sender process, relay and helper for each first MKV Gallery OFF request; unlike earlier same-process multi-case history',
          receiverPolicy:'Same owned session and receiver/server; no restart or settings reset between arms',
          selectedFilename:`issue1591-${process.env.GITHUB_RUN_ID}-${arm}-mkv-gallery-off-control.mkv`,
          filenamePolicy:'Arm-specific basename prevents destination collision on retained receiver; source fixture bytes are identical'});
        if (Object.keys(config).some(key => /timeout/i.test(key))) throw new Error('Sender timeout override is outside the preserved 500 ms default comparator');
        if (senderSettings && !isDeepStrictEqual(senderSettings,config)) throw new Error('Sender full persisted configuration changed between arms');
        senderSettings ||= config;
        await transfer({label:arm+'-mkv-gallery-off-control',extension:'mkv',desired:false,verifyDocuments:true});
      } catch (error) {
        armFailure = redact(error); await retainFailure(error);
      } finally {
        monitoredWindow = null;
        const receipt = {arm, failure:armFailure,cleanup:[]};
        const clean = async (operation, action) => {
          try {await action();receipt.cleanup.push({operation,ok:true});}
          catch (error) {receipt.cleanup.push({operation,ok:false,error:redact(error)});failure ||= 'Arm cleanup failed: ' + operation;}
        };
        await clean('helper owned stop and terminate', async () => {
          await activate(proxyId);
          const stops = await elements('accessibility id','stopProxy');
          if (stops.length === 1) await click('stopProxy');
          await wd('POST',prefix()+'/appium/device/terminate_app',{bundleId:proxyId});
          const state = await wd('POST',prefix()+'/execute/sync',{script:'mobile: queryAppState',args:[{bundleId:proxyId}]});
          receipt.helperStoppedState=state;
          if (state !== 1) throw new Error('Helper not observed stopped');
        });
        if (r) {
          save('arm-relay-trace.json',r.trace);save('arm-helper-health.json',r.healthSamples);
          await clean('relay stop',async()=>{
            let timer;
            try {await Promise.race([r.stop(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Relay stop exceeded 10 seconds')),10000);})]);}
            finally {clearTimeout(timer);}
          });
          save('arm-relay-trace.json',r.trace);
          r=null;
        }
        await clean('Windows final stream capture',async()=>captureWindowsStreams('arm-final'));
        if (windowsUI) await clean('owned Windows UI stop',async()=>{if(windowsUI.exitCode===null)await exec('taskkill',['/PID',String(windowsUI.pid),'/T','/F'],{timeout:30000});});
        windowsUI=null;windowsReady=false;
        await clean('owned sender stop',async()=>{
          const owned = JSON.parse(readFileSync('evidence/windows-ui-prewarmed-action.json','utf8').replace(/^\uFEFF/,''));
          if (!Number.isInteger(owned.appPid) || owned.appPid <= 0) throw new Error('Owned sender PID unavailable');
          receipt.senderPid=owned.appPid;receipt.senderWindow=owned.window;
          const report = JSON.parse(readFileSync('evidence/release-ui-report.json','utf8').replace(/^\uFEFF/,''));
          const executablePath = report.executable?.path;
          if (!executablePath || !report.processes.some(process => process.pid === owned.appPid &&
              process.executablePath?.toLowerCase() === executablePath.toLowerCase())) throw new Error('Sender native PID is not linked to the exact release executable report');
          if (!Number.isInteger(owned.window) || owned.window <= 0) throw new Error('Sender native window unavailable');
          const expected = Buffer.from(JSON.stringify({pid:owned.appPid,window:owned.window,path:executablePath})).toString('base64');
          const stopped = await exec('pwsh',['-NoProfile','-Command',`
$ErrorActionPreference='Stop'
$expected=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${expected}'))|ConvertFrom-Json
$live=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$expected.pid)
if(-not $live -or $live.ExecutablePath -ine $expected.path){throw 'Live sender PID/executable identity changed; no termination'}
$window=(Get-Process -Id $expected.pid -ErrorAction Stop).MainWindowHandle.ToInt64()
if($window -ne $expected.window){throw 'Live sender main HWND ownership changed; no termination'}
$receipt=@{pid=$expected.pid;window=$window;executablePath=$live.ExecutablePath;creationDate=$live.CreationDate;qualifiedUtc=[DateTime]::UtcNow.ToString('o')}
& taskkill /PID $expected.pid /T /F | Out-Null
if($LASTEXITCODE -ne 0){throw 'Qualified sender taskkill failed'}
$stopDeadline=[DateTime]::UtcNow.AddSeconds(5)
while((Get-CimInstance Win32_Process -Filter ('ProcessId = '+$expected.pid)) -and [DateTime]::UtcNow -lt $stopDeadline){Start-Sleep -Milliseconds 100}
if(Get-CimInstance Win32_Process -Filter ('ProcessId = '+$expected.pid)){throw 'Sender PID still present after taskkill'}
$receipt.stopped=$true;$receipt|ConvertTo-Json -Compress
`],{timeout:30000});
          receipt.senderStopQualification=JSON.parse(stopped.stdout.trim());
          save('sender-owned-stop.json',receipt.senderStopQualification);
        });
        receipt.cleanupSucceeded = receipt.cleanup.every(entry=>entry.ok);
        armReceipts.push(receipt);save('arm-receipt.json',receipt);
        writeFileSync(resolve(comparisonRoot,'evidence/nodelay-comparison.json'),redact(JSON.stringify({armOrder:['default','nodelay'],armReceipts,failure},null,2)));
        if (!receipt.cleanupSucceeded) throw new Error('Bounded owned cleanup failed; second arm is not admitted');
        await activate(appId);
      }
    }
  } else {
    await transfer({label:'mkv-gallery-off-control',extension:'mkv',desired:false,verifyDocuments:true});
  }
  if (process.env.COMPARISON === 'mp4-off') await transfer({label:'mp4-gallery-off',extension:'mp4',desired:false,verifyDocuments:true});
  if (process.env.COMPARISON === 'mkv-gallery-pair') await transfer({label:'mkv-gallery-on-direct',extension:'mkv',desired:true,verifyDocuments:true,galleryOracle:true});
  if (process.env.COMPARISON === 'gallery-on') {
    await transfer({label:'mp4-gallery-on-control',extension:'mp4',desired:true,verifyDocuments:false});
    await transfer({label:'mkv-gallery-on',extension:'mkv',desired:true,verifyDocuments:true});
  }
} catch (error) {
  if (nodelayComparison && existsSync('evidence/failure.json')) {failure ||= redact(error);save('comparison-abort.json',{stage,error:redact(error),failure});}
  else await retainFailure(error);
} finally {
  monitoredWindow = null; if (healthMonitor) clearInterval(healthMonitor);
  try {captureWindowsStreams('final');} catch (error) {save('windows-app-final-stream-capture-error.txt', error);}
  if (r) save('final-helper-health-samples.json', r.healthSamples);
  save('scenario-results.json', {results, backgroundWindows, failure, lastStage:stage, transport:r?.status()});
  if (session) {
    stage = 'owned-session-cleanup';
    if (!nodelayComparison && failure && helperStartAttempted) {
      // Freeze the failed interval first, then request the existing stop/dump.
      // Each command shares one deadline; an ambiguous reply gets no retry.
      const receipt = {operation:'helper owned failure stop for timing retention',startedUtc:new Date().toISOString(),ok:false};
      const deadline = Date.now() + 15000;
      const remaining = () => {
        const ms = deadline - Date.now();
        if (ms <= 0) throw new Error('Helper failure stop exceeded 15 seconds');
        return ms;
      };
      try {
        await wd('POST',prefix()+'/appium/device/activate_app',{appId:proxyId},remaining());
        const stops = await wd('POST',prefix()+'/elements',{using:'accessibility id',value:'stopProxy'},remaining());
        if (stops.length !== 1) throw new Error('Owned helper stop control absent or ambiguous');
        receipt.clickAttemptedUtc = new Date().toISOString();
        await wd('POST',prefix()+'/element/'+eid(stops[0])+'/click',{},remaining());
        receipt.ok = true;
        receipt.authority = 'Stop click completed; native timing summary is required to establish dump retention';
      } catch (error) {
        receipt.error = redact(error);
        failure ||= 'Helper failure timing retention cleanup failed';
      }
      receipt.finishedUtc = new Date().toISOString();
      cleanup.push(receipt);save('helper-failure-stop.json',receipt);
    }
    try { await wd('DELETE', '/session/' + session, undefined, 30000); cleanup.push({operation:'DELETE owned session without trailing slash',ok:true}); }
    catch (error) { cleanup.push({operation:'DELETE owned session',ok:false,error:redact(error)}); failure ||= 'Owned session cleanup failed'; }
    await collectMetadata();
  }
  if (r) { try { await r.stop(); cleanup.push({operation:'relay stop',ok:true}); } catch (error) { cleanup.push({operation:'relay stop',ok:false,error:redact(error)}); failure ||= 'Relay cleanup failed'; } save('relay-trace.json', r.trace); }
  if (local) {
    // Only terminate the process tree started by this run, never another user's tunnel.
    try { if (local.exitCode === null) await exec('taskkill',['/PID',String(local.pid),'/T','/F']); cleanup.push({operation:'owned Local process tree stop',ok:true}); }
    catch (error) { cleanup.push({operation:'owned Local stop',ok:false,error:redact(error)}); failure ||= 'Owned Local cleanup failed'; }
  }
  if (windowsUI && windowsUI.exitCode === null) {
    try {await exec('taskkill',['/PID',String(windowsUI.pid),'/T','/F']);cleanup.push({operation:'owned prewarmed Windows UI process stop',ok:true});}
    catch(error){cleanup.push({operation:'owned Windows UI stop',ok:false,error:redact(error)});failure ||= 'Owned Windows UI cleanup failed';}
  }
  save('cleanup.json', cleanup);
  save('evidence-admission.json', {failure, senderVerified:false, admission:'Requires parent inspection of both endpoint results, exact saved bytes, native health/lifecycle and original video/logs. A successful controller exit alone does not establish app-to-app success.'});
}
if (failure) { console.error(failure); process.exitCode = 1; }
}
