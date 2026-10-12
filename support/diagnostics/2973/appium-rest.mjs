// Diagnostic cloud UI transport. Prepared only; do not execute before root reviews the plan.
// Uses Node's built-in fetch. No application source or device setting is substituted.
import { readFile, writeFile, appendFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

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
  const response = await fetch(endpoint + path, {
    method,
    headers: { Authorization: authorization, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(45000),
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
    // This stage exercises the real picker and reads Android settings without slider inputs.
    const events = [];
    let serial = 0;
    const decode = text => text.replace(/&#10;/g, '\n').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    async function capture(label) {
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
      return { source: source.value, nodes };
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
      const screen = await capture(snapshotLabel);
      const matches = screen.nodes.filter(node => node.text === label || node['content-desc'] === label || node['content-desc']?.split('\n')[0] === label);
      const targets = [...new Set(matches.map(node => {
        let target = node;
        while (target.clickable !== 'true' && target.parentIndex !== null) target = screen.nodes[target.parentIndex];
        return target;
      }).filter(node => node.clickable === 'true' && node.enabled === 'true' && node.displayed === 'true'))];
      if (targets.length !== 1) throw new Error(`Native label ${label} has ${targets.length} visible targets; retained screen requires inspection`);
      await touch(targets[0], label);
    }
    async function back() { await request('POST', prefix + '/appium/device/press_keycode', { keycode: 4 }); }
    await byLabel('Send', 'receive');
    const initialSend = await capture('initial-send-selection');
    if (!initialSend.nodes.some(node => (node['content-desc'] ?? node.text) === 'Apps')) throw new Error('Initial Send selection is not observed empty; preserve it and stop');
    await byLabel('Apps', 'send');
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
    await writeFile(resolve(evidence, 'control-selected-app-identities.json'), JSON.stringify(chosen, null, 2));
    for (const app of chosen) {
      const fresh = await capture(`before-select-${app.package.replaceAll('.', '-')}`);
      const rows = fresh.nodes.filter(node => node.clickable === 'true' && node.displayed === 'true' && node['content-desc']?.split('\n').includes(app.package));
      if (rows.length !== 1) throw new Error('Actual app row identity changed before touch');
      await touch(rows[0], `Actual installed app ${app.label} (${app.package})`);
    }
    await byLabel('Add 2 Apps', 'two-apps-selected');
    const added = await capture('send-two-actual-apps-added');
    if (chosen.some(app => !added.source.includes(app.label))) throw new Error('Send does not expose both chosen actual app labels after Add');
    await writeFile(resolve(evidence, 'default-control-verdict.json'), JSON.stringify({ multipleSwitchEnabledByVisibleTouch: true, actualApps: chosen, add2AppsCompleted: true, sendLabelsObserved: true }, null, 2));
    // The X is unlabeled in this released app. Locate it only in the live Selection header,
    // retaining the full original screenshot/source and exact native bounds for review.
    const selection = added.nodes.filter(node => (node['content-desc'] ?? node.text) === 'Selection');
    if (selection.length !== 1) throw new Error('Selection header not uniquely observable; no guessed clear input');
    const headerBounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(selection[0].bounds ?? '');
    if (!headerBounds) throw new Error('Selection header bounds absent');
    const [hx1, hy1, hx2, hy2] = headerBounds.slice(1).map(Number);
    const clearTargets = added.nodes.filter(node => {
      const bounds = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds ?? '');
      if (!bounds || node.class !== 'android.widget.Button' || node.clickable !== 'true' || node.displayed !== 'true') return false;
      const [x1,y1,x2,y2] = bounds.slice(1).map(Number);
      return x1 > hx2 && y1 < hy2 && y2 > hy1;
    });
    if (clearTargets.length !== 1) throw new Error('Selection clear button not unique in current visible header');
    await touch(clearTargets[0], 'Observed Selection header clear X');
    const restoredSend = await capture('send-original-selection-restored');
    if (!restoredSend.nodes.some(node => (node['content-desc'] ?? node.text) === 'Apps')) throw new Error('Original empty Send selection not restored');
    await byLabel('Apps', 'send-before-picker-state-restore');
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
    if (args[0] === 'control') {
      await writeFile(resolve(evidence, 'observation-verdict.json'), JSON.stringify({ scope: 'default-picker-control-only', originalSelectionAndSwitchRestorationVerified: true, androidSettingsChanged: false, aboutAndNativeSettingsObserved: false, enlargementProductFailureValidated: false }, null, 2));
    } else {
    await byLabel('Settings', 'send-after-apps');
    let aboutFound = false;
    for (let attempt = 0; attempt < 4; attempt++) {
      const settings = await capture(`app-settings-${attempt}`);
      if (settings.nodes.some(node => node['content-desc'] === 'About' || node.text === 'About')) {
        await byLabel('About', 'app-settings-before-about');
        const about = await capture('about-original-version');
        if (!about.source.includes('1.17.0')) throw new Error('About screen does not expose uploaded original version 1.17.0');
        await back();
        aboutFound = true;
        break;
      }
      const { value: rect } = await request('GET', prefix + '/window/rect');
      if (!Number.isFinite(rect.width) || !Number.isFinite(rect.height)) throw new Error('Live bounds absent for Settings scroll');
      await request('POST', prefix + '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
        { type: 'pointerMove', duration: 0, x: Math.floor(rect.width / 2), y: Math.floor(rect.height * 0.75) }, { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 600, x: Math.floor(rect.width / 2), y: Math.floor(rect.height * 0.3) }, { type: 'pointerUp', button: 0 },
      ] }] });
    }
    if (!aboutFound) throw new Error('About label not exposed after bounded native Settings observation');
    // Real notification shade gestures use the live window dimensions, not stored coordinates.
    const { value: size } = await request('GET', prefix + '/window/rect');
    if (!Number.isFinite(size.width) || !Number.isFinite(size.height) || size.width <= 0 || size.height <= 0) throw new Error('Live window dimensions unavailable');
    const x = Math.floor(size.width / 2), startY = 1, endY = Math.floor(size.height * 0.8);
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
    await byLabel('Display', 'android-settings');
    await capture('display-original');
    await byLabel('Screen zoom', 'display-before-zoom');
    const zoom = await capture('screen-zoom-original');
    const originalControls = { screenZoom: { nativeControls: zoom.nodes.filter(node => /SeekBar|Slider/.test(node.class ?? '')), nativeLabels: zoom.nodes.filter(node => node.text || node['content-desc']), rangeEstablished: false, screenshotInspectionRequired: true } };
    await writeFile(resolve(evidence, 'original-native-settings-controls.json'), JSON.stringify(originalControls, null, 2));
    await back();
    await byLabel('Font size and style', 'display-before-font');
    const font = await capture('font-size-original');
    originalControls.fontSize = { nativeControls: font.nodes.filter(node => /SeekBar|Slider/.test(node.class ?? '')), nativeLabels: font.nodes.filter(node => node.text || node['content-desc']), rangeEstablished: false, screenshotInspectionRequired: true };
    await writeFile(resolve(evidence, 'original-native-settings-controls.json'), JSON.stringify(originalControls, null, 2));
    await writeFile(resolve(evidence, 'observation-verdict.json'), JSON.stringify({ settingsChanged: false, productValidated: false, originalNativeScreensCaptured: true }, null, 2));
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
