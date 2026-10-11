import {spawn, execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync, writeFileSync, appendFileSync, mkdirSync, copyFileSync} from 'node:fs';
import {randomBytes, createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {relay} from './reused/relay.mjs';

const exec = promisify(execFile), root = 'support/diagnostics/issue1591-realpair';
mkdirSync('evidence', {recursive:true});
const token = randomBytes(24).toString('hex');
console.log('::add-mask::' + token);
const auth = 'Basic ' + Buffer.from(process.env.BROWSERSTACK_USERNAME + ':' + process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const secrets = [token, auth, process.env.BROWSERSTACK_USERNAME, process.env.BROWSERSTACK_ACCESS_KEY].filter(Boolean);
const redact = text => secrets.reduce((value, secret) => value.replaceAll(secret, '[redacted]'), String(text));
const save = (name, value) => writeFileSync('evidence/' + name, redact(value instanceof Error ? String(value) : typeof value === 'string' ? value : JSON.stringify(value, null, 2)));
const pause = ms => new Promise(ok => setTimeout(ok, ms));
const appId = 'org.localsend.localsendApp', proxyId = 'org.shlomocode.diagnostics.issue1591.byteproxy';
let session, local, r, failure, stage = 'configuration', previousFinished = false;
const results = [], cleanup = [], backgroundWindows = [];
const eid = element => element['element-6066-11e4-a52e-4f735466cecf'];
const prefix = () => '/session/' + session;

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
async function elements(using, value) { return wd('POST', prefix() + '/elements', {using, value}); }
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
async function powershell(script, args = []) {
  const started = Date.now();
  try {
    const output = await exec('pwsh', ['-NoProfile', '-File', root + '/reused/' + script, ...args], {timeout:180000, maxBuffer:4*1024*1024});
    save(`windows-${started}.txt`, output.stdout + output.stderr);
  } catch (error) { save(`windows-${started}-error.txt`, [error.message, error.stdout, error.stderr].join('\n')); throw error; }
}
async function gallery(desired, label) {
  stage = label + '-settings';
  await click('Settings'); await capture(label + '-settings-entry');
  const locator = '//XCUIElementTypeSwitch[contains(@name,"Save media to gallery") or contains(@label,"Save media to gallery")]';
  let matches;
  for (let attempt = 0; attempt < 5; attempt++) {
    matches = await elements('xpath', locator);
    if (matches.length) break;
    await wd('POST', prefix() + '/execute/sync', {script:'mobile: swipe', args:[{direction:'up'}]});
    await capture(label + '-settings-scroll-' + attempt);
  }
  if (matches.length !== 1) throw new Error('Gallery switch is absent or ambiguous; inspect retained native source before adjusting locators');
  const id = eid(matches[0]), getValue = () => wd('GET', prefix() + '/element/' + id + '/attribute/value');
  const before = await getValue();
  if (!['0','1',0,1,true,false].includes(before)) throw new Error('Gallery switch value is not an observed boolean');
  if ((before === '1' || before === 1 || before === true) !== desired) await wd('POST', prefix() + '/element/' + id + '/click', {});
  const after = await getValue();
  if ((after === '1' || after === 1 || after === true) !== desired) throw new Error('Gallery setting did not change');
  save(label + '-gallery.json', {desired, before, after, selectionTiming:'Global Settings before real transfer'});
  await capture(label + '-settings-selected');
  await click('Receive'); await capture(label + '-receive-ready');
}
async function configureProxy(label) {
  stage = label + '-proxy-start';
  await activate(proxyId);
  // Supply secrets through element values rather than retained session capabilities.
  for (const [name, value] of [['relayURL','http://bs-local.com:8080'], ['relayToken',token]]) {
    const element = await unique('accessibility id', name);
    await wd('POST', prefix() + '/element/' + eid(element) + '/clear', {});
    await wd('POST', prefix() + '/element/' + eid(element) + '/value', {text:value});
  }
  await click('startProxy');
  const started = Date.now(), deadline = started + 20000;
  let consentedLocalNetwork = false;
  while (!r.status().pollPending && Date.now() < deadline) {
    const source = await wd('GET', prefix() + '/source');
    if (!consentedLocalNetwork && /local network/i.test(source) && (await elements('accessibility id','Allow')).length === 1) {
      save(label + '-proxy-local-network-prompt.xml', source);
      writeFileSync('evidence/' + label + '-proxy-local-network-prompt.png', Buffer.from(await wd('GET', prefix() + '/screenshot'), 'base64'));
      await click('Allow'); consentedLocalNetwork = true;
    }
    await pause(250);
  }
  if (!r.status().pollPending) throw new Error('Proxy never opened an authenticated relay poll');
  save(label + '-proxy-start.xml', await wd('GET', prefix() + '/source'));
  const window = {case:label, proxyStartedUtc:new Date(started).toISOString(), switchUtc:new Date().toISOString(),
    expiryAuthority:'Swift NSLog backgroundTimeRemaining/lifecycle/expiry records in device-logs.txt', consentedLocalNetwork, statusBeforeSwitch:r.status()};
  backgroundWindows.push(window);
  await activate(appId); return window;
}
async function transfer({label, extension, desired, verifyDocuments}) {
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
  const window = await configureProxy(label);
  stage = label + '-windows-send';
  await powershell('windows3393-ui.ps1', ['-Action','click','-X','246','-Y','266','-Label',label+'-favorites','-RequireForeground','-UseControlSequence']);
  await powershell('windows3393-ui.ps1', ['-Action','click','-X','145','-Y','225','-Label',label+'-send','-RequireForeground','-UseControlSequence']);
  stage = label + '-receiver-approval';
  await capture(label + '-pending');
  await click('Accept', 12000); await capture(label + '-accepted');
  stage = label + '-receiver-save';
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const xml = await wd('GET', prefix() + '/source'); save(label + '-latest.xml', xml);
    // Only consent to a prompt that explicitly requests adding photos. Never
    // request read/write library access or dismiss a broader permission prompt.
    if (/Allow Full Access|Select Photos|access your photo library/i.test(xml)) throw new Error('Broader Photos access prompt is outside the add-only scenario');
    if (/add(?: to)? (?:your )?photos/i.test(xml) && (await elements('accessibility id', 'Allow Access')).length === 1) await click('Allow Access');
    if ((await elements('accessibility id', 'Done')).length === 1) break;
    if (/500|Internal Server Error/.test(xml)) {
      await capture(label + '-reported-error');
      results.push({case:label, stage, source:identity, outcome:'observed-500', transport:r.status()});
      throw new Error('Observed HTTP 500 in real receiver transfer; retain exact source and device log to classify');
    }
    await pause(250);
  }
  await unique('accessibility id', 'Done', 1000); await capture(label + '-completed');
  await powershell('windows3393-ui.ps1', ['-Action','snapshot','-Label',label+'-sender-end']);
  save(label + '-sender-status.json', {authority:'Original Windows sender-end screenshot and native HWND/PID records; review image for Finished, per-file result and error details', autoTextStatus:'not exposed by this reused Flutter HWND backend'});
  const completeSource = await wd('GET', prefix() + '/source');
  const observedSuccess = completeSource.includes(filename) && /(?:name|label)="Finished"/.test(completeSource) && !/Finished with error|(?:name|label)="Error"|Internal Server Error/.test(completeSource);
  save(label + '-completion-status.json', {filename, doneVisible:true, finishedLabelObserved:/(?:name|label)="Finished"/.test(completeSource), fileObserved:completeSource.includes(filename), observedSuccess});
  if (!observedSuccess) throw new Error('Done appeared without an observed successful Finished/file result; inspect both endpoints');
  window.completedUtc = new Date().toISOString(); window.transport = r.status();
  const result = {case:label, source:identity, gallery:desired, outcome:'real-app-completed', transport:r.status(), byteExact:false};
  results.push(result);
  if (verifyDocuments) {
    stage = label + '-saved-file-verification';
    const path = `@${appId}:documents/${filename}`;
    const encoded = await wd('POST', prefix() + '/appium/device/pull_file', {path});
    const saved = Buffer.from(encoded, 'base64');
    writeFileSync('evidence/' + label + '-saved.' + extension, saved);
    const hash = createHash('sha256').update(saved).digest('hex');
    Object.assign(result, {path, savedBytes:saved.length, savedSha256:hash, byteExact:hash === identity.sha256 && saved.length === identity.bytes});
    if (!result.byteExact) throw new Error('Exact saved-file hash or size differs from real sender fixture');
  } else {
    result.verificationLimit = 'Gallery completion is UI evidence only. Documents pull cannot establish Photos library bytes; no read/write Photos authorization was granted.';
  }
  save('scenario-results.json', {results, backgroundWindows});
  await click('Done'); previousFinished = true;
  await activate(proxyId); await click('stopProxy');
  save(label + '-proxy-after-stop.xml', await wd('GET', prefix() + '/source'));
  // The helper's normal stop cancels its NWConnections without assuming that a
  // final HTTP push can run. Close owned sender keep-alive sockets server-side.
  await r.stop(); save(label + '-relay-trace.json', r.trace);
  r = relay({token}); await r.start();
  await activate(appId);
}
async function collectMetadata() {
  try {
    const response = await fetch(`https://api-cloud.browserstack.com/app-automate/sessions/${session}.json`, {headers:{authorization:auth}, signal:AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error('Session metadata HTTP ' + response.status);
    const detail = (await response.json()).automation_session;
    save('browserstack-session.json', detail);
    for (const [key, file] of [['device_logs_url','device-logs.txt'], ['appium_logs_url','appium-logs.txt'], ['video_url','original-browserstack-video.mp4']]) {
      if (!detail[key]) { save(file + '-error.txt', 'Session metadata omitted ' + key); continue; }
      const url = new URL(detail[key]);
      if (url.protocol !== 'https:' || !(url.hostname === 'browserstack.com' || url.hostname.endsWith('.browserstack.com'))) throw new Error('Unexpected BrowserStack evidence host');
      let log;
      for (let attempt = 0; attempt < 4; attempt++) {
        log = await fetch(url, {headers:{authorization:auth}, signal:AbortSignal.timeout(30000)});
        if (log.status !== 404) break;
        await log.text(); await pause(5000);
      }
      if (!log.ok) { save(file + '-error.txt', 'Evidence HTTP ' + log.status); continue; }
      if (key === 'video_url') writeFileSync('evidence/' + file, Buffer.from(await log.arrayBuffer()));
      else save(file, await log.text());
    }
  } catch (error) { save('metadata-error.txt', error); }
}
try {
  for (const name of ['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','PROXY_APP','RECEIVER_APP','RECEIVER_IDENTITY','BS_LOCAL_ID']) if (!process.env[name]) throw new Error('Missing required input ' + name);
  for (const name of ['PROXY_APP','RECEIVER_APP']) if (!/^bs:\/\/[a-f0-9]{40}$/i.test(process.env[name])) throw new Error('Expected immutable BrowserStack app hash for ' + name);
  save('identity.json', {receiver:process.env.RECEIVER_APP, receiverIdentity:process.env.RECEIVER_IDENTITY, proxy:process.env.PROXY_APP,
    proxyId, appId, run:process.env.GITHUB_RUN_ID, revision:process.env.GITHUB_SHA, device:'iPad 9th', os:'18', sender:'unchanged Windows 1.17.0 x64 release', comparison:process.env.COMPARISON});
  stage = 'windows-startup';
  await powershell('windows2311-desktop.ps1');
  await powershell('windows_release_ui_probe.ps1', ['-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-2022','-FixtureTimestampUtc','2025-02-13T14:11:00Z','-FixtureFileName','startup-control.txt','-DiagnosticPeerPort','53318','-InitializeOnly']);
  stage = 'browserstack-local';
  local = spawn('C:/tmp/bs-local-bin/BrowserStackLocal.exe', ['--key',process.env.BROWSERSTACK_ACCESS_KEY,'--local-identifier',process.env.BS_LOCAL_ID,'--force-local','--only-automate'], {windowsHide:true});
  let output = '', localError;
  for (const [stream, name] of [[local.stdout,'local.stdout.txt'],[local.stderr,'local.stderr.txt']]) createInterface({input:stream}).on('line', line => {const text = redact(line) + '\n'; appendFileSync('evidence/' + name, text); output = (output + text).slice(-20000);});
  local.on('error', error => {localError = error;});
  const localDeadline = Date.now() + 120000;
  while (!/You can now access your local|Local Testing successfully connected/i.test(output) && Date.now() < localDeadline && !localError && local.exitCode === null) await pause(200);
  if (localError || local.exitCode !== null || !/You can now access your local|Local Testing successfully connected/i.test(output)) throw new Error('Owned BrowserStack Local did not become ready');
  r = relay({token}); await r.start();
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
      sessionName:'Windows 1.17 real selection to unchanged iPad receiver', idleTimeout:120, debug:true, video:true, networkLogs:false}};
  save('requested-capabilities.json', caps);
  const created = await wd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}},120000);
  session = created.sessionId; if (!session) throw new Error('Session ID missing in W3C response');
  save('owned-session.json', {session, capabilities:created.capabilities, createdUtc:new Date().toISOString()});
  stage = 'receiver-startup'; await capture('receiver-startup');
  // Normal local-network permission is unrelated to Photos authorization.
  const source = await wd('GET', prefix() + '/source');
  if (/local network/i.test(source) && (await elements('accessibility id','Allow')).length === 1) await click('Allow');
  await click('Receive');
  await transfer({label:'mkv-gallery-off-control',extension:'mkv',desired:false,verifyDocuments:true});
  if (process.env.COMPARISON === 'mp4-off') await transfer({label:'mp4-gallery-off',extension:'mp4',desired:false,verifyDocuments:true});
  if (process.env.COMPARISON === 'gallery-on') {
    await transfer({label:'mp4-gallery-on-control',extension:'mp4',desired:true,verifyDocuments:false});
    await transfer({label:'mkv-gallery-on',extension:'mkv',desired:true,verifyDocuments:true});
  }
} catch (error) {
  failure = redact(error); save('failure.json', {stage, error:failure, classification:'Classify using actual UI, device lifecycle and transport logs. Infrastructure errors are not a reproduction.'});
  if (session) await capture('failure').catch(error => save('failure-capture-error.txt', error));
  if (stage.includes('receiver') || stage.includes('saved-file')) {
    await powershell('windows3393-ui.ps1', ['-Action','snapshot','-Label','sender-failure']).catch(error => save('sender-failure-capture-error.txt', error));
    // This is the same Windows 1.17 error-details control used in the reliable
    // release harness. Retain the preceding image so its actual presence can
    // be reviewed; the clicked image alone is not proof of an HTTP error.
    await powershell('windows3393-ui.ps1', ['-Action','click','-X','127','-Y','258','-Label','sender-failure-error-detail','-RequireForeground','-UseControlSequence']).catch(error => save('sender-error-detail-capture-error.txt', error));
  }
} finally {
  save('scenario-results.json', {results, backgroundWindows, failure, lastStage:stage, transport:r?.status()});
  if (session) {
    stage = 'owned-session-cleanup';
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
  save('cleanup.json', cleanup);
}
if (failure) { console.error(failure); process.exitCode = 1; }
