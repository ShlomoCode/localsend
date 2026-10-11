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
let monitoredWindow, healthMonitor;
let windowsUI, windowsReady, windowsSeq = 0;
const windowsRequests = new Map();
const healthMaxAgeMs = 5000;
const results = [], cleanup = [], backgroundWindows = [];
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
  if (script === 'windows3393-ui.ps1' && windowsReady) {
    const value = name => {const index=args.indexOf(name);return index < 0 ? undefined : args[index + 1];};
    const id = ++windowsSeq;
    return new Promise((ok, reject) => {
      const timer = setTimeout(() => {windowsRequests.delete(id);reject(new Error('Prewarmed Windows UI deadline exceeded'));}, 30000);
      windowsRequests.set(id, {ok, reject, timer});
      windowsUI.stdin.write(JSON.stringify({id,action:value('-Action'),x:Number(value('-X') || 0),y:Number(value('-Y') || 0),label:value('-Label'),
        foreground:args.includes('-RequireForeground'),sequence:args.includes('-UseControlSequence')}) + '\n');
    });
  }
  const started = Date.now();
  try {
    const output = await exec('pwsh', ['-NoProfile', '-File', root + '/reused/' + script, ...args], {timeout:180000, maxBuffer:4*1024*1024});
    save(`windows-${started}.txt`, output.stdout + output.stderr);
  } catch (error) { save(`windows-${started}-error.txt`, [error.message, error.stdout, error.stderr].join('\n')); throw error; }
}
async function prepareWindowsUI() {
  windowsUI = spawn('pwsh',['-NoProfile','-File',root + '/windows-ui-server.ps1']);
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
async function gallery(desired, label) {
  stage = label + '-settings';
  await click('Settings'); await capture(label + '-settings-entry');
  // The unchanged iPad app exposes the Receive card's labels as one native
  // element and six unnamed sibling switches. Retained XML and the original
  // image from run 38179175479 identify gallery as the fourth switch.
  const cardName = 'Receive Quick Save Quick Save for "Favorites" Require PIN Save media to gallery Auto Finish Save to history';
  const card = '//XCUIElementTypeOther[normalize-space(@name)=\'' + cardName + '\']';
  const locator = card + '/following-sibling::XCUIElementTypeSwitch[4]';
  let matches;
  for (let attempt = 0; attempt < 5; attempt++) {
    matches = await elements('xpath', locator);
    if (matches.length) break;
    await wd('POST', prefix() + '/execute/sync', {script:'mobile: swipe', args:[{direction:'up'}]});
    await capture(label + '-settings-scroll-' + attempt);
  }
  if (matches.length !== 1) throw new Error('Gallery switch is absent or ambiguous; inspect retained native source before adjusting locators');
  if ((await elements('xpath', card + '/following-sibling::XCUIElementTypeSwitch')).length !== 6) throw new Error('Receive card switch order differs from retained native UI; no gallery action admitted');
  const id = eid(matches[0]), getValue = () => wd('GET', prefix() + '/element/' + id + '/attribute/value');
  const before = await getValue();
  if (!['0','1',0,1,true,false].includes(before)) throw new Error('Gallery switch value is not an observed boolean');
  if ((before === '1' || before === 1 || before === true) !== desired) await wd('POST', prefix() + '/element/' + id + '/click', {});
  const after = await getValue();
  if (!['0','1',0,1,true,false].includes(after)) throw new Error('Gallery switch after-value is not an observed boolean');
  if ((after === '1' || after === 1 || after === true) !== desired) throw new Error('Gallery setting did not change');
  save(label + '-gallery.json', {desired, before, after, locator, cardName, nativeLayoutAuthority:'Original run 38179175479 settings-entry XML and image: six Receive switches, gallery fourth', selectionTiming:'Global Settings before real transfer'});
  await capture(label + '-settings-selected');
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
  const current=await unique('xpath',toggle);
  const after=await wd('GET',prefix()+'/element/'+eid(current)+'/attribute/value');
  if(after!=='1')throw new Error('Advanced settings did not reveal its controls');
  save(label+'-advanced-toggle.json',{before,after,footer,toggle,nativeAuthority:'Original 38179175479 scroll-4 XML: unique Advanced settings StaticText, immediate sibling Switch; source LabeledCheckbox labelFirst=true'});
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
  if(before==='0'){
    for(let attempt=0;attempt<6;attempt++){
      const choices=await elements('xpath',toggle);
      if(choices.length===1&&await wd('GET',prefix()+'/element/'+eid(choices[0])+'/displayed'))break;
      await wd('POST',prefix()+'/execute/sync',{script:'mobile: swipe',args:[{direction:'up'}]});
    }
    const restore=await unique('xpath',toggle);
    if(await wd('GET',prefix()+'/element/'+eid(restore)+'/attribute/value')!=='1')throw new Error('Advanced visibility checkbox changed unexpectedly');
    await wd('POST',prefix()+'/element/'+eid(restore)+'/click',{});
    const restored=await unique('xpath',toggle);
    if(await wd('GET',prefix()+'/element/'+eid(restored)+'/attribute/value')!=='0')throw new Error('Advanced visibility did not restore its prior state');
    await capture(label+'-advanced-restored');
  }
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
  backgroundWindows.push(window);
  await activate(appId);
  await checkpoint(window, 'after-app-switch', {awaitBackground:true}); monitorHealth(window);
  return window;
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
  window.acceptReturnedUtc = new Date().toISOString(); await checkpoint(window, 'after-Accept', {requirePeer:true});
  await capture(label + '-accepted');
  stage = label + '-receiver-save';
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (window.healthFault) throw new Error('Transport infrastructure while waiting for save: ' + window.healthFault.issue);
    const xml = await wd('GET', prefix() + '/source'); save(label + '-latest.xml', xml);
    // Only consent to a prompt that explicitly requests adding photos. Never
    // request read/write library access or dismiss a broader permission prompt.
    if (/Allow Full Access|Select Photos|access your photo library/i.test(xml)) throw new Error('Broader Photos access prompt is outside the add-only scenario');
    if (/add(?: to)? (?:your )?photos/i.test(xml) && (await elements('accessibility id', 'Allow Access')).length === 1) await click('Allow Access');
    if ((await elements('accessibility id', 'Done')).length === 1) break;
    if (/(?:name|label|value)="[^"\n]*(?:HTTP(?: status)?[: ]+500|Internal Server Error)[^"\n]*"/i.test(xml)) {
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
  if (verifyDocuments) {
    stage = label + '-saved-file-verification';
    const path = `@${appId}:documents/${filename}`;
    await checkpoint(window, 'before-documents-pull', {requirePeer:true});
    const encoded = await wd('POST', prefix() + '/appium/device/pull_file', {path});
    await checkpoint(window, 'after-documents-pull', {requirePeer:true});
    const saved = Buffer.from(encoded, 'base64');
    writeFileSync('evidence/' + label + '-saved.' + extension, saved);
    const hash = createHash('sha256').update(saved).digest('hex');
    Object.assign(result, {path, savedBytes:saved.length, savedSha256:hash, byteExact:hash === identity.sha256 && saved.length === identity.bytes});
    if (!result.byteExact) throw new Error('Exact saved-file hash or size differs from real sender fixture');
  } else {
    result.verificationLimit = 'Gallery completion is UI evidence only. Documents pull cannot establish Photos library bytes; no read/write Photos authorization was granted.';
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
try {
  for (const name of ['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','PROXY_APP','RECEIVER_APP','RECEIVER_IDENTITY','BS_LOCAL_ID']) if (!process.env[name]) throw new Error('Missing required input ' + name);
  for (const name of ['PROXY_APP','RECEIVER_APP']) if (!/^bs:\/\/[a-f0-9]{40}$/i.test(process.env[name])) throw new Error('Expected immutable BrowserStack app hash for ' + name);
  save('identity.json', {receiver:process.env.RECEIVER_APP, receiverIdentity:process.env.RECEIVER_IDENTITY, proxy:process.env.PROXY_APP,
    proxyId, appId, run:process.env.GITHUB_RUN_ID, revision:process.env.GITHUB_SHA, device:'iPad 9th', os:'18', sender:'unchanged Windows 1.17.0 x64 release', comparison:process.env.COMPARISON});
  stage = 'windows-startup';
  await powershell('windows2311-desktop.ps1');
  await powershell('windows_release_ui_probe.ps1', ['-OutputDirectory','evidence','-ReleaseVersion','1.17.0','-AssetArchitecture','x86-64','-RunnerLabel','windows-2022','-FixtureTimestampUtc','2025-02-13T14:11:00Z','-FixtureFileName','startup-control.txt','-DiagnosticPeerPort','53318','-InitializeOnly']);
  await prepareWindowsUI();
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
  monitoredWindow = null; if (healthMonitor) clearInterval(healthMonitor);
  if (r) save('final-helper-health-samples.json', r.healthSamples);
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
  if (windowsUI && windowsUI.exitCode === null) {
    try {await exec('taskkill',['/PID',String(windowsUI.pid),'/T','/F']);cleanup.push({operation:'owned prewarmed Windows UI process stop',ok:true});}
    catch(error){cleanup.push({operation:'owned Windows UI stop',ok:false,error:redact(error)});failure ||= 'Owned Windows UI cleanup failed';}
  }
  save('cleanup.json', cleanup);
  save('evidence-admission.json', {failure, senderVerified:false, admission:'Requires parent inspection of both endpoint results, exact saved bytes, native health/lifecycle and original video/logs. A successful controller exit alone does not establish app-to-app success.'});
}
if (failure) { console.error(failure); process.exitCode = 1; }
