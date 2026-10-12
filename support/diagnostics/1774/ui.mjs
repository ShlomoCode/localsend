// Prepared source only. Every touch uses a newly captured native target.
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

export const APP = 'org.localsend.localsend_app';
const SETTINGS = 'com.android.settings';
const decode = text => text.replace(/&#10;/g, '\n').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
const visible = node => node.displayed === 'true';
const named = (node, label) => node.text === label || node['content-desc'] === label;
export function bounds(node) {
  const match = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds ?? '');
  if (!match) throw new Error('Native bounds unavailable');
  const [left, top, right, bottom] = match.slice(1).map(Number);
  if (right <= left || bottom <= top) throw new Error('Empty native bounds');
  return { left, top, right, bottom };
}
function parse(xml) {
  const nodes = [], stack = [];
  for (const token of xml.matchAll(/<(\/?)([a-zA-Z0-9_.]+)\b([^>]*?)(\/?)>/g)) {
    if (token[1]) { stack.pop(); continue; }
    const attrs = Object.fromEntries([...token[3].matchAll(/([a-zA-Z0-9_-]+)="([^"]*)"/g)].map(item => [item[1], decode(item[2])]));
    nodes.push({ ...attrs, parentIndex: stack.at(-1) ?? null });
    if (!token[4]) stack.push(nodes.length - 1);
  }
  return nodes;
}
function descendant(screen, node, parent) {
  let current = node;
  while (current.parentIndex !== null) {
    current = screen.nodes[current.parentIndex];
    if (current === parent) return true;
  }
  return false;
}
function unique(items, name) {
  if (items.length !== 1) throw new Error(`${name} unavailable or ambiguous (${items.length}); inspect retained PNG/XML`);
  return items[0];
}
function target(screen, node) {
  let current = node;
  while (current.clickable !== 'true' && current.parentIndex !== null) current = screen.nodes[current.parentIndex];
  if (current.clickable !== 'true' || current.enabled !== 'true' || !visible(current)) throw new Error('Semantic target is not an enabled visible control');
  return current;
}
export function createUi({ command, save, evidence, checkDeadline }) {
  let serial = 0;
  const statePath = resolve(evidence, 'native-state.json');
  let state = null;
  async function persist() { await save('native-state.json', state); }
  async function capture(label) {
    checkDeadline();
    const at = new Date().toISOString();
    const source = (await command('GET', '/source')).value;
    const png = Buffer.from((await command('GET', '/screenshot')).value, 'base64');
    if (png.length < 24 || png.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') throw new Error('Original PNG unavailable');
    const metadata = { at, currentPackage: (await command('GET', '/appium/device/current_package')).value,
      orientation: (await command('GET', '/orientation')).value, windowRect: (await command('GET', '/window/rect')).value,
      imageWidth: png.readUInt32BE(16), imageHeight: png.readUInt32BE(20),
      sourceRotation: Number(/<hierarchy\b[^>]*\brotation="([0-3])"/.exec(source)?.[1] ?? NaN) };
    const snapshot = `${Date.now()}-${serial++}-${label.replace(/[^a-zA-Z0-9_-]/g, '-')}`;
    await writeFile(resolve(evidence, snapshot + '.xml'), source);
    await writeFile(resolve(evidence, snapshot + '.png'), png);
    await save(snapshot + '.metadata.json', metadata);
    return { nodes: parse(source), metadata, snapshot };
  }
  async function gesture(screen, node, label, end) {
    const b = bounds(node), rect = screen.metadata.windowRect;
    if (!['x', 'y', 'width', 'height'].every(key => Number.isFinite(rect?.[key])) || b.left < rect.x || b.top < rect.y || b.right > rect.x + rect.width || b.bottom > rect.y + rect.height) throw new Error('Target is outside live viewport');
    const x = Math.floor((b.left + b.right) / 2), y = Math.floor((b.top + b.bottom) / 2);
    await save(`${screen.snapshot}-input.json`, { at: new Date().toISOString(), label, nativeNode: node, x, y, end, snapshot: screen.snapshot });
    await command('POST', '/actions', { actions: [{ type: 'pointer', id: 'touch', parameters: { pointerType: 'touch' }, actions: [
      { type: 'pointerMove', duration: 0, x, y }, { type: 'pointerDown', button: 0 },
      end ? { type: 'pointerMove', duration: 600, ...end } : { type: 'pause', duration: 100 }, { type: 'pointerUp', button: 0 },
    ] }] });
  }
  async function touch(screen, node, label) {
    if (node.clickable !== 'true' || node.enabled !== 'true' || !visible(node)) throw new Error('Touch target is not enabled/visible');
    await gesture(screen, node, label);
  }
  async function click(label, pkg = APP) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const screen = await capture(`before-${label}-${attempt}`);
      const matches = screen.nodes.filter(node => node.package === pkg && visible(node) && named(node, label));
      const targets = [...new Set(matches.map(node => target(screen, node)))];
      if (targets.length > 1) throw new Error(`Semantic ${label} target ambiguous`);
      if (targets.length === 1) { await touch(screen, targets[0], label); return; }
    }
    throw new Error(`Semantic ${label} control not observed`);
  }
  const back = () => command('POST', '/appium/device/press_keycode', { keycode: 4 });
  async function activate(pkg) {
    if (![APP, SETTINGS].includes(pkg)) throw new Error('Unapproved native activation');
    try { await command('POST', '/appium/device/activate_app', { appId: pkg }); }
    catch (error) {
      // A timeout leaves activation uncertain. Only a returned rejection and
      // observed unchanged app foreground permit ordinary shade navigation.
      if (pkg !== SETTINGS || !error.definitiveResponse) throw error;
      const rejected = await capture('settings-activation-rejected');
      if (rejected.metadata.currentPackage !== APP) throw error;
      for (let step = 0; step < 2; step++) {
        const fresh = await capture(`native-settings-shade-before-${step}`), rect = fresh.metadata.windowRect;
        if (![APP, 'com.android.systemui'].includes(fresh.metadata.currentPackage)) throw new Error('Native shade foreground changed');
        if (!['x', 'y', 'width', 'height'].every(key => Number.isFinite(rect?.[key])) || rect.width < 10 || rect.height < 10) throw new Error('Native shade live geometry unavailable');
        const x = Math.floor(rect.x + rect.width * .85), y = Math.floor(rect.y + 2);
        await gesture(fresh, { bounds: `[${x - 1},${y - 1}][${x + 1},${y + 1}]` }, 'Ordinary native notification shade', { x, y: Math.floor(rect.y + rect.height * .8) });
        const shade = await capture(`native-settings-shade-${step}`);
        const gears = shade.nodes.filter(node => node.package === 'com.android.systemui' && visible(node) && node.clickable === 'true' && node.enabled === 'true' &&
          (node['resource-id']?.endsWith(':id/settings_button') || node['content-desc'] === 'Settings'));
        if (gears.length > 1) throw new Error('Native Settings shade gear ambiguous');
        if (gears.length === 1) { await touch(shade, gears[0], 'Native Settings gear'); break; }
        if (step === 1) throw new Error('Native Settings shade gear unavailable');
      }
    }
    for (let attempt = 0; attempt < 3; attempt++) {
      const screen = await capture(`activated-${pkg}-${attempt}`);
      if (screen.metadata.currentPackage === pkg && screen.nodes.some(node => node.package === pkg && visible(node))) return screen;
    }
    throw new Error('Native activation readiness unavailable; no input retry');
  }
  function heading(screen, text) {
    if (screen.metadata.currentPackage !== SETTINGS) return false;
    return screen.nodes.some(node => node.package === SETTINGS && visible(node) && named(node, text) && screen.nodes.some(parent =>
      parent.package === SETTINGS && (/Toolbar/.test(parent.class ?? '') || parent['resource-id'] === `${SETTINGS}:id/action_bar` ||
      parent['resource-id'] === `${SETTINGS}:id/collapsing_app_bar`) && descendant(screen, node, parent)));
  }
  async function preference(label, parentHeading) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const screen = await capture(`native-${parentHeading}-${label}-${attempt}`);
      if (!heading(screen, parentHeading)) throw new Error('Native Settings header gate failed');
      const matches = [...new Set(screen.nodes.filter(node => node.package === SETTINGS && visible(node) && named(node, label)).map(node => target(screen, node)))];
      if (matches.length > 1) throw new Error('Native preference ambiguous');
      if (matches.length === 1) { await touch(screen, matches[0], label); return; }
      if (attempt === 2) break;
      const list = unique(screen.nodes.filter(node => node.package === SETTINGS && visible(node) && node.enabled === 'true' && node.scrollable === 'true' && node['resource-id'] === `${SETTINGS}:id/recycler_view`), 'Native Settings list');
      const b = bounds(list), y = Math.floor(b.top + (b.bottom - b.top) * .8), endY = Math.floor(b.top + (b.bottom - b.top) * .3);
      let corridors = [[b.left + 10, b.right - 10]];
      for (const control of screen.nodes.filter(node => node.package === SETTINGS && visible(node) && (/SeekBar|Slider|Switch|CheckBox|RadioButton/.test(node.class ?? '') || node.checkable === 'true'))) {
        const c = bounds(control);
        if (c.bottom + 10 < endY || c.top - 10 > y) continue;
        corridors = corridors.flatMap(([a, z]) => c.right + 10 <= a || c.left - 10 >= z ? [[a, z]] : [[a, Math.min(z, c.left - 10)], [Math.max(a, c.right + 10), z]].filter(([a, z]) => z - a >= 40));
      }
      const corridor = corridors.sort((a, b) => (b[1] - b[0]) - (a[1] - a[0]))[0];
      if (!corridor || corridor[1] - corridor[0] < 40) throw new Error('No native swipe corridor clear of setting controls');
      const x = Math.floor((corridor[0] + corridor[1]) / 2);
      await gesture(screen, { ...list, bounds: `[${x - 1},${y - 1}][${x + 1},${y + 1}]` }, `Scroll Settings list toward ${label}`, { x, y: endY });
    }
    throw new Error(`Native ${label} preference unavailable after bounded navigation`);
  }
  async function settingsPage(name) {
    await activate(SETTINGS);
    for (let step = 0; step < 4; step++) {
      const screen = await capture(`settings-page-${name}-${step}`);
      const observed = ['Settings', 'Display', 'Screen zoom', 'Font size and style'].filter(text => heading(screen, text));
      const current = unique(observed, 'Native Settings heading');
      if (current === name) return;
      if (['Screen zoom', 'Font size and style'].includes(current)) await back();
      else if (current === 'Settings') await preference('Display', 'Settings');
      else await preference(name, 'Display');
    }
    throw new Error('Native Settings navigation limit reached');
  }
  async function setting(axis, label) {
    const font = axis === 'font', title = font ? 'Font size and style' : 'Screen zoom';
    const ids = font ? ['font_size_seek_bar', 'font_size_seek_bar_larger_button', 'font_size_seek_bar_smaller_button'] : ['seek_bar', 'larger', 'smaller'];
    const screen = await capture(label);
    if (!heading(screen, title)) throw new Error('Native setting heading unavailable');
    const m = screen.metadata, rect = m.windowRect;
    if (m.orientation !== 'PORTRAIT' || m.sourceRotation !== 0 || m.imageWidth >= m.imageHeight ||
        !['x', 'y', 'width', 'height'].every(key => Number.isFinite(rect?.[key])) || rect.width <= 0 || rect.height <= rect.width) throw new Error('Original native portrait geometry unavailable');
    const [slider, up, down] = ids.map(id => unique(screen.nodes.filter(node => node.package === SETTINGS && visible(node) && node['resource-id'] === `${SETTINGS}:id/${id}`), id));
    if (slider.class !== 'android.widget.SeekBar' || slider.enabled !== 'true' || !slider.text?.trim() || !Number.isFinite(Number(slider.text))) throw new Error('Native slider value unavailable');
    if (up['content-desc'] !== (font ? 'Increase font size' : 'Increase size') || down['content-desc'] !== (font ? 'Decrease font size' : 'Decrease size')) throw new Error('Native setting buttons not identified');
    if (![up, down].every(node => ['true', 'false'].includes(node.enabled))) throw new Error('Native button state unavailable');
    for (const node of [slider, up, down]) bounds(node);
    if (state && screen.metadata.orientation !== state.orientation) throw new Error('Original orientation changed');
    return { value: slider.text, slider, up, down, screen };
  }
  function signature(sample) { return JSON.stringify({ value: sample.value, slider: sample.slider.bounds, up: sample.up.bounds, down: sample.down.bounds,
    upEnabled: sample.up.enabled, downEnabled: sample.down.enabled, metadata: { ...sample.screen.metadata, at: undefined } }); }
  async function stable(axis, label, expected) {
    const first = await setting(axis, label + '-first'), second = await setting(axis, label + '-second');
    if (signature(first) !== signature(second) || expected !== undefined && second.value !== expected) throw new Error('Native setting is not stable/exact');
    return second;
  }
  async function originals() {
    if (state) throw new Error('Original setting state already exists');
    await settingsPage('Font size and style');
    const font = await stable('font', 'original-font');
    await settingsPage('Screen zoom');
    const zoom = await stable('zoom', 'original-zoom');
    if (zoom.screen.metadata.orientation !== font.screen.metadata.orientation || zoom.screen.metadata.orientation !== 'PORTRAIT') throw new Error('Reported portrait Settings geometry not qualified');
    state = { version: 1, originalFont: font.value, originalZoom: zoom.value, orientation: zoom.screen.metadata.orientation,
      originals: { font, zoom }, trajectory: [zoom.value], pending: null, restored: true, inputs: 0 };
    await persist();
    return state;
  }
  async function adjust(direction, expected, label, reverse = false) {
    if (state.pending) throw new Error('Uncertain native mutation must be reconciled before input');
    const before = await stable('zoom', label + '-before', state.trajectory.at(-1));
    const node = direction === 'increase' ? before.up : before.down;
    state.pending = { direction, from: before.value, expected, reverse, at: new Date().toISOString() }; state.restored = false;
    await persist();
    await touch(before.screen, node, label);
    const after = await stable('zoom', label + '-after', expected);
    if (direction === 'increase' ? Number(after.value) < Number(before.value) : Number(after.value) > Number(before.value)) throw new Error('Native adjustment moved against observed direction');
    if (reverse) {
      if (after.value !== state.trajectory.at(-2)) throw new Error('Native adjustment missed saved reverse trajectory');
      state.trajectory.pop();
    } else if (after.value !== before.value) state.trajectory.push(after.value);
    state.history ??= []; state.history.push({ direction, before, after, label }); state.pending = null;
    await persist();
    return after;
  }
  async function maximum() {
    await settingsPage('Screen zoom');
    let current = await stable('zoom', 'maximum-start', state.trajectory.at(-1));
    state.restored = false; await persist();
    while (true) {
      if (current.up.enabled === 'false') {
        const endpoint = await stable('zoom', 'maximum-disabled-increase', current.value);
        if (endpoint.up.enabled !== 'false' || endpoint.down.enabled !== 'true') throw new Error('Native maximum disabled-Increase proof unavailable');
        state.endpoint = { type: 'disabledIncrease', value: current.value }; await persist(); return state.endpoint;
      }
      if (state.inputs >= 8) throw new Error('Native maximum not established within eight Increase inputs');
      const from = current.value; state.inputs++; await persist();
      current = await adjust('increase', undefined, 'maximum-increase');
      if (current.up.enabled === 'false') continue;
      if (current.value !== from) continue;
      if (state.inputs + 2 > 8) throw new Error('Insufficient remaining Increase budget for operational upper clamp');
      const high = current.value, savedLower = state.trajectory.at(-2), geometry = signature(current);
      const decreased = await adjust('decrease', savedLower, 'clamp-positive-decrease');
      if (Number(decreased.value) >= Number(high)) throw new Error('Native clamp bounce did not reach a strictly lower observed position');
      state.inputs++; await persist(); await adjust('increase', high, 'clamp-positive-increase');
      state.inputs++; await persist(); const repeated = await adjust('increase', high, 'clamp-repeated-no-growth');
      if (signature(repeated) !== geometry) throw new Error('Upper clamp geometry/control states changed');
      state.endpoint = { type: 'operationalUpperClamp', value: high, originalPixelsRequireReview: true }; await persist(); return state.endpoint;
    }
  }
  async function nonmaxControl() {
    await settingsPage('Screen zoom');
    const before = await stable('zoom', 'nonmax-control-before', state.endpoint?.value);
    if (!state.endpoint || before.down.enabled !== 'true') throw new Error('Qualified maximum/Decrease control unavailable');
    const after = await adjust('decrease', undefined, 'one-native-decrease-for-distinct-control');
    if (Number(after.value) >= Number(before.value)) throw new Error('Single native Decrease did not expose a distinct lower position');
    await save('observed-nonmax-control-position.json', { before, after, nativePositionIsLower: true, isDefaultUnknown: true });
    return after.value;
  }
  async function verifyFont(label) {
    await settingsPage('Font size and style');
    const observed = await stable('font', label, state.originalFont);
    await save(label + '.json', { observed, fontUnchanged: true });
  }
  async function restore() {
    state ??= JSON.parse(await readFile(statePath, 'utf8').catch(error => { if (error.code === 'ENOENT') return 'null'; throw error; }));
    if (!state) return { mutationRecorded: false };
    if (state.version !== 1 || !Array.isArray(state.trajectory) || state.trajectory[0] !== state.originalZoom) throw new Error('Durable native state invalid');
    if (state.restored && !state.pending && state.restoredAt) return { ...state, exactRestorationPreviouslyVerified: true };
    await settingsPage('Screen zoom');
    let current = await stable('zoom', 'restore-observe');
    if (state.pending) {
      const pending = state.pending;
      if (current.value !== pending.from) {
        const movedInDirection = pending.direction === 'increase' ? Number(current.value) > Number(pending.from) : Number(current.value) < Number(pending.from);
        if (!movedInDirection || pending.expected !== undefined && current.value !== pending.expected) throw new Error('Uncertain setting mutation cannot be reconciled; no repeat input');
        if (pending.reverse) {
          if (current.value !== state.trajectory.at(-2)) throw new Error('Uncertain restoration missed saved reverse trajectory');
          state.trajectory.pop();
        } else state.trajectory.push(current.value);
      }
      state.pending = null; await persist();
    }
    if (current.value !== state.trajectory.at(-1)) throw new Error('Current zoom differs from durable trajectory');
    while (state.trajectory.length > 1) {
      const expected = state.trajectory.at(-2);
      if (Number(expected) === Number(current.value)) throw new Error('Saved reverse trajectory has ambiguous equal numeric positions');
      current = await adjust(Number(expected) > Number(current.value) ? 'increase' : 'decrease', expected, 'restore-exact-original-step', true);
    }
    await stable('zoom', 'restored-original-zoom', state.originalZoom);
    await verifyFont('restored-original-font');
    state.restored = true; state.restoredAt = new Date().toISOString(); await persist();
    return state;
  }
  async function selectFixture(filename, size) {
    await activate(APP); await click('Send'); await click('File');
    const picker = await capture('native-file-picker');
    const pkg = picker.metadata.currentPackage;
    if (!['com.google.android.documentsui', 'com.android.documentsui'].includes(pkg)) throw new Error('Native DocumentsUI picker unavailable');
    let screen = picker;
    if (!screen.nodes.some(node => visible(node) && named(node, 'Downloads'))) {
      await click('Show roots', pkg); screen = await capture('native-downloads-navigation');
    }
    await click('Downloads', pkg); await click(filename, pkg);
    const selected = await capture('actual-localsend-file-selection');
    const names = selected.nodes.filter(node => node.package === APP && visible(node) && ((node.text ?? '').includes(filename) || (node['content-desc'] ?? '').includes(filename)));
    const selection = selected.nodes.filter(node => node.package === APP && visible(node) && /Selection\nFiles: 1\n/.test(node['content-desc'] ?? ''));
    if (!names.length || selection.length !== 1 || !/Size: [1-9]/.test(selection[0]['content-desc'])) throw new Error('Selected real filename/single-file/nonzero-size not exposed; preserve picker and stop');
    await save('selected-fixture.json', { filename, pushedBytes: size, names, selection, snapshot: selected.snapshot, exactByteIdentityFromPullHash: true });
    await click('Send mode'); await click('Share via link');
  }
  async function clearFixture() {
    await activate(APP);
    const share = await capture('before-clear-actual-share-page');
    if (share.metadata.currentPackage !== APP || !share.nodes.some(node => node.package === APP && visible(node) && named(node, 'Share via link')) ||
        share.nodes.some(node => node.package === APP && visible(node) && named(node, 'Close'))) throw new Error('Actual Share via link page not qualified for ordinary Back');
    await back();
    let send;
    for (let attempt = 0; attempt < 3; attempt++) {
      const screen = await capture(`clear-fixture-send-ready-${attempt}`);
      const selected = screen.nodes.filter(node => node.package === APP && visible(node) && /Selection\nFiles: 1\n/.test(node['content-desc'] ?? ''));
      if (selected.length > 1) throw new Error('Actual single-file Selection composite ambiguous');
      if (selected.length === 1 && screen.metadata.currentPackage === APP) { send = { screen, selected: selected[0] }; break; }
    }
    if (!send) throw new Error('Actual single-file Selection composite unavailable after ordinary Back');
    await touch(send.screen, send.selected, 'Actual one-file Selection composite');
    const page = await capture('clear-fixture-actual-selection-page');
    if (page.metadata.currentPackage !== APP || !page.nodes.some(node => node.package === APP && visible(node) && named(node, 'Selection')) ||
        !page.nodes.some(node => node.package === APP && visible(node) && named(node, 'Delete all'))) throw new Error('Actual Selection page and Delete all not observed');
    await click('Delete all');
    for (let attempt = 0; attempt < 3; attempt++) {
      const empty = await capture(`clear-fixture-empty-send-${attempt}`);
      if (empty.metadata.currentPackage === APP && empty.nodes.some(node => node.package === APP && visible(node) && named(node, 'Selection')) &&
          empty.nodes.some(node => node.package === APP && visible(node) && named(node, 'File') && node.clickable === 'true' && node.enabled === 'true') &&
          !empty.nodes.some(node => node.package === APP && visible(node) && /Selection\nFiles: [1-9]/.test(node['content-desc'] ?? '')) &&
          !empty.nodes.some(node => node.package === APP && visible(node) && named(node, 'Delete all'))) {
        await save('fixture-selection-cleared.json', { snapshot: empty.snapshot, emptySendSelectionObserved: true,
          ordinaryUiSequence: ['Back from Share via link', 'one-file Selection', 'Delete all'], diskFixtureDeletionRequested: false });
        return;
      }
    }
    throw new Error('Empty Send selection not observed after Delete all; no reselection');
  }
  async function monitor(condition, expectedUrl) {
    await activate(APP);
    const screen = await capture(condition + '-link-card-before-monitor');
    if (screen.metadata.orientation !== state.orientation) throw new Error('Original orientation changed on product page');
    const urls = screen.nodes.filter(node => node.package === APP && visible(node) && /^https?:\/\/\S+$/.test(node.text || node['content-desc'] || ''));
    await save(condition + '-all-native-url-rows.json', { urls, snapshot: screen.snapshot });
    const candidates = expectedUrl ? urls.filter(node => (node.text || node['content-desc']) === expectedUrl) : urls;
    if (!candidates.length) throw new Error('Actual URL row unavailable');
    candidates.sort((a, b) => bounds(a).top - bounds(b).top || bounds(a).left - bounds(b).left);
    const url = expectedUrl ? unique(candidates, 'Same actual URL row') : candidates[0];
    if (!expectedUrl && candidates.length > 1 && bounds(candidates[0]).top === bounds(candidates[1]).top) throw new Error('First actual URL row ambiguous');
    const value = url.text || url['content-desc'];
    if (expectedUrl && expectedUrl !== value) throw new Error('Real URL changed between display conditions');
    const ub = bounds(url);
    // Source Row order is URL, copy InkWell, QR InkWell, monitor InkWell.
    // Require the native row association and three distinct ordered controls.
    let row = url, actions = [];
    for (let depth = 0; depth < 4 && row.parentIndex !== null; depth++) {
      row = screen.nodes[row.parentIndex];
      actions = screen.nodes.filter(node => node.package === APP && visible(node) && node.clickable === 'true' && node.enabled === 'true' && node !== url && descendant(screen, node, row) && !node.text && !node['content-desc'])
        .filter(node => { const b = bounds(node); return b.left >= ub.right && b.top < ub.bottom && b.bottom > ub.top; });
      if (actions.length >= 3) break;
    }
    const beforeInputError = message => Object.assign(new Error(message), { monitorBeforeInput: true, actualUrl: value, snapshot: screen.snapshot });
    if (actions.length !== 3) throw beforeInputError('Actual URL-associated three-action monitor identity gate unmet');
    actions.sort((a, b) => bounds(a).left - bounds(b).left);
    if (actions.some((node, index) => index && bounds(actions[index - 1]).right > bounds(node).left)) throw beforeInputError('Actual link actions overlap or ancestry ambiguous');
    const monitorTarget = actions[2];
    await save(condition + '-monitor-target.json', { at: new Date().toISOString(), url: value, urlLength: value.length,
      ipFamily: value.includes('[') ? 'IPv6' : 'IPv4-or-hostname', row, urlNode: url, actions, monitorTarget, snapshot: screen.snapshot,
      originalPixelsRequireInspection: true, verdict: 'pending-pixel-inspection' });
    const mb = bounds(monitorTarget), rect = screen.metadata.windowRect;
    if (!['x', 'y', 'width', 'height'].every(key => Number.isFinite(rect?.[key])) || mb.left < rect.x || mb.top < rect.y ||
        mb.right > rect.x + rect.width || mb.bottom > rect.y + rect.height) throw beforeInputError('Actual monitor target is outside live viewport or viewport unavailable');
    await touch(screen, monitorTarget, 'Actual third URL-row InkWell (monitor)');
    let opened = false, outcome;
    for (let attempt = 0; attempt < 3; attempt++) {
      outcome = await capture(condition + '-monitor-outcome-' + attempt);
      if (outcome.nodes.some(node => node.package === APP && visible(node) && named(node, 'URL')) &&
          outcome.nodes.some(node => node.package === APP && visible(node) && named(node, value)) &&
          outcome.nodes.some(node => node.package === APP && visible(node) && named(node, 'Close'))) { opened = true; break; }
    }
    await save(condition + '-outcome.json', { actualMonitorActivationAttempted: true, zoomDialogOpened: opened,
      snapshot: outcome.snapshot, verdict: 'pending-pixel-inspection', productVerdict: null });
    if (opened) await click('Close');
    return { url: value, opened };
  }
  return { capture, originals, maximum, nonmaxControl, verifyFont, restore, selectFixture, clearFixture, monitor, activate };
}
