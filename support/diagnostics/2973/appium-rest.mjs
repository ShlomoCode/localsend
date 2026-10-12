// Diagnostic cloud UI transport. Prepared only; do not execute before root reviews the plan.
// Uses Node's built-in fetch. No application source or device setting is substituted.
import { readFile, writeFile, appendFile, mkdir, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { runExtremes, restoreExtremes } from './native-extremes.mjs';

const [mode, evidenceArgument, ...args] = process.argv.slice(2);
if (process.env.GITHUB_ACTIONS !== 'true') throw new Error('This diagnostic transport may execute only in fork GitHub Actions');
if (!mode || !evidenceArgument) throw new Error('Usage: node appium-rest.mjs MODE EVIDENCE_DIR [ARGS]');
const evidence = resolve(evidenceArgument);
await mkdir(evidence, { recursive: true });
const username = process.env.BROWSERSTACK_USERNAME;
const accessKey = process.env.BROWSERSTACK_ACCESS_KEY;
if (!username || !accessKey) throw new Error('BrowserStack credential variables are missing');
const authorization = `Basic ${Buffer.from(`${username}:${accessKey}`).toString('base64')}`;
const endpoint = 'https://hub-cloud.browserstack.com/wd/hub';

function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) =>
      [key, /password|access.?key|token|authorization|browserstack.user|browserstack.key/i.test(key) ? '<REDACTED>' : redact(item)]));
  }
  if (typeof value === 'string') {
    const safe = value.replaceAll(username, '<REDACTED>').replaceAll(accessKey, '<REDACTED>');
    return /[?&](?:auth_token|token|X-Amz-Signature|X-Amz-Credential)=/i.test(safe) ? safe.split('?')[0] + '?<REDACTED>' : safe;
  }
  return value;
}

async function request(method, path, body) {
  const started = new Date().toISOString();
  const remaining = Number(process.env.DIAGNOSTIC_PHASE_DEADLINE_MS ?? Infinity) - Date.now();
  if (remaining <= 0) throw new Error('Diagnostic phase deadline reached before remote input/read');
  const response = await fetch(endpoint + path, {
    method,
    headers: { Authorization: authorization, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(Math.min(45000, remaining)),
  });
  const responseText = await response.text();
  if (method === 'POST' && path === '/session') {
    await writeFile(resolve(evidence, 'create-response-text.txt'), redact(responseText));
  }
  const result = JSON.parse(responseText);
  if (method === 'POST' && path === '/session') {
    await writeFile(resolve(evidence, 'create-response.json'), JSON.stringify(redact(result), null, 2));
  }
  await appendFile(resolve(evidence, 'input-events.jsonl'), JSON.stringify({
    started, finished: new Date().toISOString(), method, path, body: redact(body), status: response.status,
    error: redact(result.value?.error ?? null),
  }) + '\n');
  if (!response.ok || result.value?.error) throw new Error(`Remote command failed (${response.status}): ${JSON.stringify(redact(result))}`);
  return result;
}

if (mode === 'create') {
  const capabilities = JSON.parse(await readFile(args[0], 'utf8'));
  if (JSON.stringify(capabilities).includes('REPLACE_')) throw new Error('An exact uploaded official app ID is required');
  const existing = await readFile(resolve(evidence, 'session-attempt.json'), 'utf8').catch(error => {
    if (error.code !== 'ENOENT') throw error;
    return null;
  });
  if (existing) throw new Error('A session attempt already exists; reconcile its unique cloud build before another creation');
  await writeFile(resolve(evidence, 'session-attempt.json'), JSON.stringify({
    attemptedAt: new Date().toISOString(), capabilities: redact(capabilities), outcome: 'pending',
  }, null, 2));
  const result = await request('POST', '/session', capabilities);
  const sessionId = result.value?.sessionId ?? result.sessionId;
  if (!sessionId) throw new Error('Session response has no session ID; retain the response and inspect cloud state before retrying');
  await writeFile(resolve(evidence, 'owned-session.json'), JSON.stringify({ sessionId, createdAt: new Date().toISOString(), response: redact(result) }, null, 2));
  console.log(`Owned session recorded in ${evidence}`);
} else {
  const { sessionId } = JSON.parse(await readFile(resolve(evidence, 'owned-session.json'), 'utf8'));
  const prefix = `/session/${encodeURIComponent(sessionId)}`;
  if (mode === 'observe') {
    if (!['control', 'settings', 'extremes', 'restore-extremes'].includes(args[0])) throw new Error('Observe requires an explicit reviewed scope');
    const events = JSON.parse(await readFile(resolve(evidence, 'observation-native-targets.json'), 'utf8').catch(() => '[]'));
    let serial = Math.max(-1, ...(await readdir(evidence)).map(name => /^observe-(\d+)-/.exec(name)).filter(Boolean).map(match => Number(match[1]))) + 1;
    let captureGroup = '';
    const decode = text => text.replace(/&#10;/g, '\n').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    async function capture(label) {
      label = captureGroup ? `${captureGroup}-${label}` : label;
      const source = await request('GET', prefix + '/source');
      const image = await request('GET', prefix + '/screenshot');
      await writeFile(resolve(evidence, `observe-${serial++}-${label}.xml`), source.value);
      await writeFile(resolve(evidence, `observe-${serial - 1}-${label}.png`), Buffer.from(image.value, 'base64'));
      const nodes = [], stack = [];
      for (const token of source.value.matchAll(/<(\/?)([a-zA-Z0-9_.]+)\b([^>]*?)(\/?)>/g)) {
        if (token[1]) { stack.pop(); continue; }
        const attrs = Object.fromEntries([...token[3].matchAll(/([a-zA-Z0-9_-]+)="([^"]*)"/g)].map(item => [item[1], decode(item[2])]));
        const node = { ...attrs, parentIndex: stack.at(-1) ?? null };
        nodes.push(node);
        if (!token[4]) stack.push(nodes.length - 1);
      }
      return { source: source.value, nodes, snapshotLabel: `observe-${serial - 1}-${label}` };
    }
    async function touch(node, label) {
      if (node.clickable !== 'true' || node.enabled !== 'true' || node.displayed !== 'true') throw new Error(`Observed ${label} is not a visible enabled touch target`);
      const bounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds ?? '');
      if (!bounds) throw new Error(`Observed ${label} has no native bounds`);
      const [x1, y1, x2, y2] = bounds.slice(1).map(Number);
      if (x2 <= x1 || y2 <= y1) throw new Error(`Observed ${label} has empty bounds`);
      const { value: viewport } = await request('GET', prefix + '/window/rect');
      if (!Number.isFinite(viewport.width) || !Number.isFinite(viewport.height) || x1 < 0 || y1 < 0 || x2 > viewport.width || y2 > viewport.height) {
        throw new Error(`Observed ${label} is not fully inside the current touch viewport; no offscreen input`);
      }
      const x = Math.floor((x1 + x2) / 2), y = Math.floor((y1 + y2) / 2);
      events.push({ label, nativeNode: node, x, y, at: new Date().toISOString() });
      await writeFile(resolve(evidence, 'observation-native-targets.json'), JSON.stringify(events, null, 2));
      await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
        { type: 'pointerMove', duration: 0, x, y }, { type: 'pointerDown', button: 0 }, { type: 'pause', duration: 100 }, { type: 'pointerUp', button: 0 },
      ] }] });
    }
    async function byLabel(label, snapshotLabel) {
      for (let attempt = 0; attempt < 3; attempt++) {
      const screen = await capture(`${snapshotLabel}-${attempt}`);
      const matches = screen.nodes.filter(node => node.package === 'org.localsend.localsend_app' &&
        (node.text === label || node['content-desc'] === label || node['content-desc']?.split('\n')[0] === label));
      const targets = [...new Set(matches.map(node => {
        let target = node;
        while (target.clickable !== 'true' && target.parentIndex !== null) target = screen.nodes[target.parentIndex];
        return target;
      }).filter(node => node.package === 'org.localsend.localsend_app' && node.clickable === 'true' && node.enabled === 'true' && node.displayed === 'true'))];
      if (targets.length > 1) throw new Error(`Native LocalSend label ${label} is ambiguous`);
      if (targets.length === 1) { await touch(targets[0], label); return; }
      }
      throw new Error(`Native LocalSend label ${label} unavailable after bounded readiness; retained screen requires inspection`);
    }
    async function back() { await request('POST', prefix + '/appium/device/press_keycode', { keycode: 4 }); }
    async function activate(packageName) {
      if (!['org.localsend.localsend_app', 'com.android.settings'].includes(packageName)) throw new Error('Unreviewed application activation');
      await request('POST', prefix + '/execute/sync', { script: 'mobile: activateApp', args: [{ appId: packageName }] });
      if (packageName === 'org.localsend.localsend_app') {
        for (let attempt = 0; attempt < 3; attempt++) {
          const screen = await capture(`activate-localsend-ready-${attempt}`);
          if (screen.nodes.some(node => node.package === packageName && node.displayed === 'true')) return;
        }
        throw new Error('LocalSend package not observed after bounded activation readiness');
      }
    }
    async function openApps(label) {
      for (let attempt = 0; attempt < 3; attempt++) {
        const screen = await capture(`${label}-${attempt}`);
        const apps = screen.nodes.filter(node => node.clickable === 'true' && node.displayed === 'true' && (node['content-desc'] === 'App' || node.text === 'App'));
        if (apps.length === 1) { await touch(apps[0], 'Observed original App picker'); return; }
        if (apps.length > 1) throw new Error('Apps touch identity ambiguous');
        if (attempt === 2) break; // The final capture observes the previous swipe; never leave an unobserved final swipe.
        const bars = screen.nodes.filter(node => node.class === 'android.widget.HorizontalScrollView' && node.scrollable === 'true' && node.displayed === 'true' && node.enabled === 'true');
        if (bars.length !== 1) throw new Error('Actual empty Selection horizontal picker bar is not unique');
        const bounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(bars[0].bounds ?? '');
        if (!bounds) throw new Error('Observed picker bar has no live bounds');
        const [x1,y1,x2,y2] = bounds.slice(1).map(Number);
        const { value: viewport } = await request('GET', prefix + '/window/rect');
        if (!Number.isFinite(viewport.width) || !Number.isFinite(viewport.height) || x2 <= x1 || y2 <= y1 || x1 < 0 || y1 < 0 || x2 > viewport.width || y2 > viewport.height) throw new Error('Native picker bar is not fully inside the current viewport');
        const x = Math.floor(x1 + (x2 - x1) * 0.8), endX = Math.floor(x1 + (x2 - x1) * 0.2), y = Math.floor((y1+y2)/2);
        events.push({ label: 'Scroll actual horizontal picker bar toward Apps', nativeNode: bars[0], x, y, endX, at: new Date().toISOString() });
        await writeFile(resolve(evidence, 'observation-native-targets.json'), JSON.stringify(events, null, 2));
        await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
          { type: 'pointerMove', duration: 0, x, y }, { type: 'pointerDown', button: 0 }, { type: 'pointerMove', duration: 600, x: endX, y }, { type: 'pointerUp', button: 0 },
        ] }] });
      }
      throw new Error('Apps remains unavailable after bounded actual picker-bar navigation');
    }
    async function pickerControl(condition = 'default-control') {
    const previousGroup = captureGroup;
    captureGroup = condition;
    try {
    await byLabel('Send', 'receive');
    const initialSend = await capture('initial-send-selection');
    const sourceBars = initialSend.nodes.filter(node => node.package === 'org.localsend.localsend_app' && node.class === 'android.widget.HorizontalScrollView' && node.displayed === 'true' && node.enabled === 'true');
    const sourceBarIndex = sourceBars.length === 1 ? initialSend.nodes.indexOf(sourceBars[0]) : -1;
    const sourceButtons = initialSend.nodes.filter(node => node.package === 'org.localsend.localsend_app' && node.class === 'android.widget.Button' &&
      node.clickable === 'true' && node.enabled === 'true' && node.displayed === 'true' && ['File','Media','Paste','Text','Folder','App'].includes(node['content-desc'])).filter(node => {
        let ancestor = node;
        while (ancestor.parentIndex !== null) {
          if (ancestor.parentIndex === sourceBarIndex) return true;
          ancestor = initialSend.nodes[ancestor.parentIndex];
        }
        return false;
      });
    if (sourceBars.length !== 1 || !sourceButtons.length || initialSend.nodes.some(node => node['content-desc']?.startsWith('Selection\nFiles: '))) throw new Error('Initial empty Selection/native source bar is not uniquely observed; preserve it and stop');
    await openApps('send-picker-bar');
    await capture('apps-original-no-input');
    const keyboard = await request('GET', prefix + '/appium/device/is_keyboard_shown');
    await writeFile(resolve(evidence, 'picker-original-keyboard-state.json'), JSON.stringify({ shown: keyboard.value }, null, 2));
    if (typeof keyboard.value !== 'boolean') throw new Error('Actual keyboard visibility unavailable; no blind Back input');
    if (keyboard.value) await back();
    const picker = await capture('apps-original-keyboard-dismissed');
    const switches = picker.nodes.filter(node => node.class === 'android.widget.Switch' && node.clickable === 'true' && node.displayed === 'true');
    if (switches.length !== 1 || switches[0].checked !== 'false') throw new Error('Initial picker switch is not uniquely observed off; no control mutation');
    await writeFile(resolve(evidence, 'observation-state.json'), JSON.stringify({ originalSendSelection: 'empty-observed', originalMultipleSwitch: false, mutationMayHaveOccurred: true, restorationVerified: false }, null, 2));
    await touch(switches[0], 'Select Multiple Apps visible switch');
    const enabledPicker = await capture('apps-multiple-enabled');
    if (!enabledPicker.nodes.some(node => node.class === 'android.widget.Switch' && node.checked === 'true')) throw new Error('Visible switch input did not enable multiple selection');
    const appRows = enabledPicker.nodes.filter(node => node.clickable === 'true' && node.displayed === 'true' &&
      /(?:^|\n)[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+){2,}(?:$|\n)/.test(node['content-desc'] ?? ''));
    if (appRows.length < 2) throw new Error('Two actual installed app row identities are not observable; retained picker needs inspection');
    const chosen = appRows.slice(0, 2).map(node => ({ label: node['content-desc'].split('\n')[0], package: node['content-desc'].split('\n').find(line => /^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+){2,}$/.test(line)) }));
    await writeFile(resolve(evidence, `${condition}-selected-app-identities.json`), JSON.stringify(chosen, null, 2));
    for (const app of chosen) {
      const fresh = await capture(`before-select-${app.package.replaceAll('.', '-')}`);
      const rows = fresh.nodes.filter(node => node.clickable === 'true' && node.displayed === 'true' && node['content-desc']?.split('\n').includes(app.package));
      if (rows.length !== 1) throw new Error('Actual app row identity changed before touch');
      await touch(rows[0], `Actual installed app ${app.label} (${app.package})`);
    }
    await byLabel('Add 2 Apps', 'two-apps-selected');
    const added = await capture('send-two-actual-apps-added');
    // Normal Send displays the count and app icons, not file-name semantics.
    const selection = added.nodes.filter(node => node['content-desc']?.startsWith('Selection\nFiles: 2\n') && node.displayed === 'true');
    if (selection.length !== 1) throw new Error('Send does not expose one observed two-file Selection card after Add');
    await writeFile(resolve(evidence, `${condition}-verdict.json`), JSON.stringify({ condition, multipleSwitchEnabledByVisibleTouch: true, actualApps: chosen, add2AppsCompleted: true, sendFileCount: 2, matchingIconsRequireOriginalScreenshotInspection: true }, null, 2));
    // The original screenshot establishes the X. Native ancestry identifies its
    // sole unlabeled Button inside the current, semantically identified card.
    const cardIndex = added.nodes.indexOf(selection[0]);
    const clearTargets = added.nodes.filter(node => node.parentIndex === cardIndex && node.class === 'android.widget.Button' && node.clickable === 'true' && node.displayed === 'true' && !node['content-desc'] && !node.text);
    if (clearTargets.length !== 1) throw new Error('Selection clear button not unique in current visible header');
    await touch(clearTargets[0], 'Observed Selection header clear X');
    const restoredSend = await capture('send-original-selection-restored');
    if (['File','Media','Paste','Text','Folder','App'].filter(label => restoredSend.nodes.some(node => node['content-desc'] === label && node.class === 'android.widget.Button' && node.clickable === 'true' && node.displayed === 'true')).length < 2) throw new Error('Original empty Send selection not restored');
    await openApps('send-before-picker-state-restore');
    const restoreKeyboard = await request('GET', prefix + '/appium/device/is_keyboard_shown');
    if (restoreKeyboard.value === true) await back();
    else if (restoreKeyboard.value !== false) throw new Error('Keyboard state unavailable before picker restoration');
    const restorePicker = await capture('picker-before-state-restore');
    const restoreSwitches = restorePicker.nodes.filter(node => node.class === 'android.widget.Switch' && node.clickable === 'true' && node.displayed === 'true');
    if (restoreSwitches.length !== 1 || !['true', 'false'].includes(restoreSwitches[0].checked)) throw new Error('Picker switch restoration identity uncertain');
    if (restoreSwitches[0].checked === 'true') await touch(restoreSwitches[0], 'Restore original multiple switch off');
    const restoredPicker = await capture('picker-original-off-restored');
    if (!restoredPicker.nodes.some(node => node.class === 'android.widget.Switch' && node.checked === 'false')) throw new Error('Original picker switch off not verified');
    await writeFile(resolve(evidence, 'observation-state.json'), JSON.stringify({ originalSendSelection: 'empty-observed', originalMultipleSwitch: false, mutationMayHaveOccurred: false, restorationVerified: true }, null, 2));
    await back();
      await writeFile(resolve(evidence, `${condition}-picker-restoration.json`), JSON.stringify({ originalSelectionAndSwitchRestorationVerified: true, productValidated: false }, null, 2));
    } finally { captureGroup = previousGroup; }
    }
    async function restorePicker() {
      const state = JSON.parse(await readFile(resolve(evidence, 'observation-state.json'), 'utf8').catch(() => 'null'));
      if (!state?.mutationMayHaveOccurred) return;
      if (state.originalSendSelection !== 'empty-observed') throw new Error('Original picker selection unknown; no cleanup clear');
      await activate('org.localsend.localsend_app');
      let screen = await capture('restore-picker-current');
      if (screen.nodes.some(node => node.package === 'org.localsend.localsend_app' && node['content-desc'] === 'Apps (APK)' && node.displayed === 'true')) {
        const keyboard = await request('GET', prefix + '/appium/device/is_keyboard_shown');
        if (keyboard.value === true) await back();
        else if (keyboard.value !== false) throw new Error('Picker keyboard identity unavailable during cleanup');
        await back();
      }
      await byLabel('Send', 'restore-picker-send');
      screen = await capture('restore-picker-selection');
      const cards = screen.nodes.filter(node => node['content-desc']?.startsWith('Selection\nFiles: ') && node.displayed === 'true');
      if (cards.length > 1) throw new Error('Picker cleanup selection card ambiguous');
      if (cards.length === 1) {
        const cardIndex = screen.nodes.indexOf(cards[0]);
        const clear = screen.nodes.filter(node => node.parentIndex === cardIndex && node.class === 'android.widget.Button' && node.clickable === 'true' && node.displayed === 'true' && !node['content-desc'] && !node.text);
        if (clear.length !== 1) throw new Error('Picker cleanup clear X unavailable');
        await touch(clear[0], 'Restore original empty Selection X');
      }
      const empty = await capture('restore-picker-empty-send');
      if (['File','Media','Paste','Text','Folder','App'].filter(label => empty.nodes.some(node => node['content-desc'] === label && node.class === 'android.widget.Button' && node.clickable === 'true' && node.displayed === 'true')).length < 2) throw new Error('Empty Send cleanup unverified');
      await openApps('restore-picker-open-app');
      const keyboard = await request('GET', prefix + '/appium/device/is_keyboard_shown');
      if (keyboard.value === true) await back();
      else if (keyboard.value !== false) throw new Error('Picker restoration keyboard unknown');
      const restored = await capture('restore-picker-off');
      if (!restored.nodes.some(node => node.class === 'android.widget.Switch' && node.checked === 'false')) throw new Error('Picker off cleanup unverified');
      await writeFile(resolve(evidence, 'observation-state.json'), JSON.stringify({ ...state, mutationMayHaveOccurred: false, restorationVerified: true }, null, 2));
      await back();
    }
    if (args[0] === 'control') {
      await pickerControl();
    } else {
    if (args[0] !== 'restore-extremes') {
    await byLabel('Settings', 'send-after-apps');
    let versionFound = false;
    for (let attempt = 0; attempt < 4; attempt++) {
      const settings = await capture(`app-settings-${attempt}`);
      const version = settings.nodes.filter(node => node.package === 'org.localsend.localsend_app' && node.displayed === 'true' &&
        (node['content-desc'] === 'Version: 1.17.0 (583)' || node.text === 'Version: 1.17.0 (583)'));
      if (version.length === 1 && settings.nodes.some(node => node.package === 'org.localsend.localsend_app' && node.displayed === 'true' &&
        (node['content-desc'] === 'LocalSend' || node.text === 'LocalSend'))) {
        await writeFile(resolve(evidence, 'original-visible-version.json'), JSON.stringify({ versionLabel: version[0], originalSettingsSnapshot: `observe-${serial - 1}-app-settings-${attempt}`, identityVerified: true }, null, 2));
        versionFound = true;
        break;
      }
      if (attempt === 3) break;
      const { value: rect } = await request('GET', prefix + '/window/rect');
      if (!Number.isFinite(rect.width) || !Number.isFinite(rect.height)) throw new Error('Live bounds absent for Settings scroll');
      await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
        { type: 'pointerMove', duration: 0, x: Math.floor(rect.width / 2), y: Math.floor(rect.height * 0.75) }, { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 600, x: Math.floor(rect.width / 2), y: Math.floor(rect.height * 0.3) }, { type: 'pointerUp', button: 0 },
      ] }] });
    }
    if (!versionFound) throw new Error('Original visible version not exposed after bounded native Settings observation');
    // Real notification shade gestures use the live window dimensions, not stored coordinates.
    const { value: size } = await request('GET', prefix + '/window/rect');
    if (!Number.isFinite(size.width) || !Number.isFinite(size.height) || size.width <= 0 || size.height <= 0) throw new Error('Live window dimensions unavailable');
    const x = Math.floor(size.width * 0.85), startY = 1, endY = Math.floor(size.height * 0.8);
    for (let attempt = 0; attempt < 2; attempt++) {
      await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
        { type: 'pointerMove', duration: 0, x, y: startY }, { type: 'pointerDown', button: 0 }, { type: 'pointerMove', duration: 600, x, y: endY }, { type: 'pointerUp', button: 0 },
      ] }] });
      const shade = await capture(`notification-shade-${attempt}`);
      const gears = shade.nodes.filter(node => node.package === 'com.android.systemui' && node.clickable === 'true' && node.enabled === 'true' && node.displayed === 'true' &&
        (node['resource-id']?.endsWith(':id/settings_button') || node['content-desc'] === 'Settings'));
      if (gears.length === 1) { await touch(gears[0], 'native Settings gear'); break; }
      if (attempt === 1) throw new Error('Native Settings gear not observable; no guessed input');
    }
    }
    async function openNativePreference(label, snapshotLabel, parentHeading) {
      let swipes = 0;
      for (let attempt = 0; attempt < 4; attempt++) {
        const screen = await capture(`${snapshotLabel}-${attempt}`);
        // A real navigation can complete between source and screenshot. Retain and recapture stale source without input.
        if (!screen.nodes.some(node => node.package === 'com.android.settings' && node.displayed === 'true')) continue;
        if (!describeOriginalSettingsScreen(screen, parentHeading).subpageIdentityVerified) continue;
        const matches = screen.nodes.filter(node => node.package === 'com.android.settings' && node.displayed === 'true' &&
          (node.text === label || node['content-desc'] === label));
        const targets = [...new Set(matches.map(node => {
          let target = node;
          while (target.clickable !== 'true' && target.parentIndex !== null) target = screen.nodes[target.parentIndex];
          return target;
        }).filter(node => node.package === 'com.android.settings' && node.clickable === 'true' && node.enabled === 'true' && node.displayed === 'true'))];
        if (targets.length === 1) { await touch(targets[0], `Native Settings ${label}`); return; }
        if (targets.length > 1) throw new Error(`Native Settings ${label} identity ambiguous`);
        if (attempt === 3 || swipes === 2) break;
        const lists = screen.nodes.filter(node => node.package === 'com.android.settings' && node.scrollable === 'true' && node.enabled === 'true' &&
          node.displayed === 'true' && node.class === 'androidx.recyclerview.widget.RecyclerView' && node['resource-id'] === 'com.android.settings:id/recycler_view');
        if (lists.length !== 1) throw new Error(`Native Settings ${label} list not uniquely observable; no guessed swipe`);
        const bounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(lists[0].bounds ?? '');
        if (!bounds) throw new Error('Observed native Settings list has no bounds');
        const [x1, y1, x2, y2] = bounds.slice(1).map(Number);
        const { value: viewport } = await request('GET', prefix + '/window/rect');
        if (!Number.isFinite(viewport.width) || !Number.isFinite(viewport.height) || x2 <= x1 || y2 <= y1 || x1 < 0 || y1 < 0 || x2 > viewport.width || y2 > viewport.height) throw new Error('Native Settings list is not fully inside current viewport');
        const y = Math.floor(y1 + (y2 - y1) * 0.8), endY = Math.floor(y1 + (y2 - y1) * 0.3);
        const controls = screen.nodes.filter(node => node.package === 'com.android.settings' && node.displayed === 'true' &&
          (/SeekBar|Slider|Switch|CheckBox|RadioButton/.test(node.class ?? '') || node.checkable === 'true'));
        let corridors = [[x1 + 10, x2 - 10]];
        for (const control of controls) {
          const controlBounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(control.bounds ?? '');
          if (!controlBounds) throw new Error('Visible native setting control bounds unavailable; no list swipe');
          const [left, top, right, bottom] = controlBounds.slice(1).map(Number);
          if (right <= left || bottom <= top) throw new Error('Visible native setting control bounds invalid; no list swipe');
          if (bottom + 10 < endY || top - 10 > y) continue;
          corridors = corridors.flatMap(([start, end]) => {
            if (right + 10 <= start || left - 10 >= end) return [[start, end]];
            return [[start, Math.min(end, left - 10)], [Math.max(start, right + 10), end]].filter(([a, b]) => b - a >= 40);
          });
        }
        corridors = corridors.filter(([start, end]) => end - start >= 40).sort((a, b) => (b[1] - b[0]) - (a[1] - a[0]));
        if (!corridors.length) throw new Error('No observed native list swipe corridor clear of setting controls');
        const x = Math.floor((corridors[0][0] + corridors[0][1]) / 2);
        events.push({ label: `Scroll observed native Settings list toward ${label}`, nativeNode: lists[0], avoidedNativeControls: controls, safeHorizontalCorridor: corridors[0], x, y, endY, at: new Date().toISOString() });
        await writeFile(resolve(evidence, 'observation-native-targets.json'), JSON.stringify(events, null, 2));
        await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
          { type: 'pointerMove', duration: 0, x, y }, { type: 'pointerDown', button: 0 }, { type: 'pointerMove', duration: 600, x, y: endY }, { type: 'pointerUp', button: 0 },
        ] }] });
        swipes++;
      }
      throw new Error(`Native Settings ${label} unavailable after bounded package readiness and observed list navigation`);
    }
    function describeOriginalSettingsScreen(screen, heading) {
      const headings = screen.nodes.filter(node => node.package === 'com.android.settings' && node.displayed === 'true' && (node.text === heading || node['content-desc'] === heading));
      const headerHeadings = headings.filter(node => {
        let ancestor = node;
        for (let depth = 0; depth < 30 && ancestor.parentIndex !== null; depth++) {
          ancestor = screen.nodes[ancestor.parentIndex];
          if (/Toolbar/.test(ancestor.class ?? '') && ancestor.package === 'com.android.settings') return true;
          if (ancestor.package === 'com.android.settings' && ancestor['resource-id'] === 'com.android.settings:id/action_bar') return true;
          if (node['resource-id'] === 'com.android.settings:id/collapsing_appbar_extended_title' && ancestor.package === 'com.android.settings' &&
            ancestor['resource-id'] === 'com.android.settings:id/collapsing_app_bar') return true;
        }
        return false;
      });
      return {
        subpageIdentityVerified: headerHeadings.length > 0 && screen.nodes.some(node => node.package === 'com.android.settings' && node.displayed === 'true'),
        expectedHeading: heading, nativeHeadingCandidates: headings, observedNativeHeaderHeadings: headerHeadings,
        nativeControls: screen.nodes.filter(node => node.package === 'com.android.settings' && node.displayed === 'true' && /SeekBar|Slider/.test(node.class ?? '')),
        nativeLabels: screen.nodes.filter(node => node.text || node['content-desc']),
        rangeEstablished: false, screenshotInspectionRequired: true,
      };
    }
    const adapter = { evidence, capture, touch, back, activate, openNativePreference, describeOriginalSettingsScreen, pickerControl, restorePicker };
    if (args[0] === 'restore-extremes') {
      await restoreExtremes(adapter);
    } else {
    await openNativePreference('Display', 'android-settings', 'Settings');
    await capture('display-original');
    await openNativePreference('Screen zoom', 'display-before-zoom', 'Display');
    const zoom = await capture('screen-zoom-original');
    const originalControls = { screenZoom: describeOriginalSettingsScreen(zoom, 'Screen zoom') };
    await writeFile(resolve(evidence, 'original-native-settings-controls.json'), JSON.stringify(originalControls, null, 2));
    await back();
    await openNativePreference('Font size and style', 'display-before-font', 'Display');
    const font = await capture('font-size-original');
    originalControls.fontSize = describeOriginalSettingsScreen(font, 'Font size and style');
    await writeFile(resolve(evidence, 'original-native-settings-controls.json'), JSON.stringify(originalControls, null, 2));
    const identitiesVerified = originalControls.screenZoom.subpageIdentityVerified && originalControls.fontSize.subpageIdentityVerified;
    await writeFile(resolve(evidence, 'observation-verdict.json'), JSON.stringify({ scope: 'original-native-capture-before-any-calibration', settingsChanged: false, productValidated: false, originalNativeSnapshotsCaptured: true, originalNativeSubpageIdentitiesVerified: identitiesVerified, rangesEstablished: false }, null, 2));
    if (!identitiesVerified) throw new Error('Native target subpage identity requires original screenshot inspection; matrix remains blocked');
    if (args[0] === 'extremes') await runExtremes(adapter);
    }
    }
  } else if (mode === 'snapshot') {
    const label = args[0];
    if (!label || !/^[a-zA-Z0-9_-]+$/.test(label)) throw new Error('Snapshot label must contain letters, digits, underscores or hyphens');
    const source = await request('GET', prefix + '/source');
    await writeFile(resolve(evidence, `${label}.xml`), source.value);
    const screenshot = await request('GET', prefix + '/screenshot');
    await writeFile(resolve(evidence, `${label}.png`), Buffer.from(screenshot.value, 'base64'));
  } else if (mode === 'tap' || mode === 'swipe') {
    const coordinates = args.map(Number);
    if (coordinates.some(value => !Number.isFinite(value) || value < 0)) throw new Error('Nonnegative numeric coordinates are required');
    const [x, y, endX, endY, duration = 500] = coordinates;
    if (coordinates.length !== (mode === 'tap' ? 2 : 5)) throw new Error('tap expects X Y; swipe expects X Y END_X END_Y DURATION_MS');
    const actions = [
      { type: 'pointerMove', duration: 0, x, y },
      { type: 'pointerDown', button: 0 },
      mode === 'tap' ? { type: 'pause', duration: 100 } : { type: 'pointerMove', duration, x: endX, y: endY },
      { type: 'pointerUp', button: 0 },
    ];
    await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions }] });
  } else if (mode === 'quit') {
    await request('DELETE', prefix);
    await writeFile(resolve(evidence, 'ended-session.json'), JSON.stringify({ sessionId, endedAt: new Date().toISOString() }, null, 2));
  } else {
    throw new Error('Supported modes: create, snapshot, tap, swipe, quit');
  }
}
