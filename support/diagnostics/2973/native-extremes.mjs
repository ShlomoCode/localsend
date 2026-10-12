// Source-only native setting trials. The caller owns the session and deadlines.
import { readFile, writeFile, rename } from 'node:fs/promises';
import { resolve, isAbsolute } from 'node:path';

const axes = {
  font: { heading: 'Font size and style', slider: 'font_size_seek_bar', up: 'font_size_seek_bar_larger_button', down: 'font_size_seek_bar_smaller_button', upLabel: 'Increase font size', downLabel: 'Decrease font size' },
  zoom: { heading: 'Screen zoom', slider: 'seek_bar', up: 'larger', down: 'smaller', upLabel: 'Increase size', downLabel: 'Decrease size' },
};
const pkg = 'com.android.settings';

async function context(adapter) {
  if (!isAbsolute(adapter.evidence)) throw new Error('Absolute evidence directory required');
  const file = resolve(adapter.evidence, 'extremes-state.json');
  let state;
  try { state = JSON.parse(await readFile(file, 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    state = { version: 1, settingScaleFactorUnknown: true, activeAxis: null, axes: Object.fromEntries(Object.keys(axes).map(axis => [axis, { original: '2.0', trajectory: ['2.0'], pending: null, restored: true, trialStarted: false }])) };
  }
  if (state.version !== 1 || ![null, 'font', 'zoom'].includes(state.activeAxis)) throw new Error('Unsupported durable extremes state');
  for (const axis of Object.keys(axes)) {
    const record = state.axes[axis];
    if (record.original !== '2.0' || record.trajectory[0] !== '2.0' || !record.trajectory.every(value => Number.isFinite(Number(value)))) throw new Error('Invalid saved native trajectory');
    if (axis !== state.activeAxis && (!record.restored || record.pending)) throw new Error('Multiple unresolved native axes');
  }
  async function save() {
    state.updatedAt = new Date().toISOString();
    await writeFile(file + '.tmp', JSON.stringify(state, null, 2));
    await rename(file + '.tmp', file);
  }
  async function evidence(name, value) { await writeFile(resolve(adapter.evidence, name + '.json'), JSON.stringify(value, null, 2)); }
  return { adapter, state, save, evidence };
}

function control(screen, id) {
  const matches = screen.nodes.filter(node => node.package === pkg && node.displayed === 'true' && node['resource-id'] === `${pkg}:id/${id}`);
  if (matches.length !== 1) throw new Error(`Native control ${id} is not unique`);
  return matches[0];
}

async function read(ctx, axis, label) {
  const spec = axes[axis];
  for (let attempt = 0; attempt < 3; attempt++) {
    const screen = await ctx.adapter.capture(`${label}-${attempt}`);
    if (!ctx.adapter.describeOriginalSettingsScreen(screen, spec.heading).subpageIdentityVerified) continue;
    const slider = control(screen, spec.slider), up = control(screen, spec.up), down = control(screen, spec.down);
    if (slider.class !== 'android.widget.SeekBar' || slider.enabled !== 'true' || !Number.isFinite(Number(slider.text)) || !slider.text?.trim()) throw new Error('Native enabled SeekBar value unavailable');
    if (up['content-desc'] !== spec.upLabel || down['content-desc'] !== spec.downLabel) throw new Error('Native adjustment button identity changed');
    if (!['true', 'false'].includes(up.enabled) || !['true', 'false'].includes(down.enabled)) throw new Error('Native button enabled state unavailable');
    return { value: slider.text, slider, up, down, snapshot: screen.snapshotLabel ?? `${label}-${attempt}` };
  }
  throw new Error(`Native ${axis} page not ready after three captures`);
}

async function recover(ctx, axis) {
  await ctx.adapter.activate(pkg);
  for (let step = 0; step < 4; step++) {
    let heading;
    for (let attempt = 0; attempt < 3; attempt++) {
      const screen = await ctx.adapter.capture(`recover-${axis}-${step}-${attempt}`);
      const observed = ['Font size and style', 'Screen zoom', 'Display', 'Settings'].filter(name => ctx.adapter.describeOriginalSettingsScreen(screen, name).subpageIdentityVerified);
      if (observed.length === 1) { heading = observed[0]; break; }
    }
    if (!heading) throw new Error('Native Settings recovery heading unavailable or ambiguous');
    if (heading === axes[axis].heading) return;
    if (heading === 'Font size and style' || heading === 'Screen zoom') await ctx.adapter.back();
    else if (heading === 'Display') await ctx.adapter.openNativePreference(axes[axis].heading, `recover-open-${axis}`, 'Display');
    else await ctx.adapter.openNativePreference('Display', `recover-display-${axis}`, 'Settings');
  }
  throw new Error('Native page recovery exceeded bounded navigation');
}

async function stable(ctx, axis, label, expected, endpoint = false) {
  const first = await read(ctx, axis, `${label}-first`), second = await read(ctx, axis, `${label}-second`);
  if (first.value !== second.value || (expected !== undefined && second.value !== expected)) throw new Error('Native value is not stable/exact');
  if (endpoint && (first.up.enabled !== 'false' || second.up.enabled !== 'false' || first.down.enabled !== 'true' || second.down.enabled !== 'true')) throw new Error('Native maximum requires disabled Increase and enabled Decrease in both captures');
  await ctx.evidence(label, { axis, value: second.value, first, second, nativeValueVerified: true, pixelsRequireOriginalInspection: true, settingScaleFactorUnknown: true });
  return second;
}

async function reconcile(ctx, axis) {
  const record = ctx.state.axes[axis], pending = record.pending;
  if (!pending) return;
  const current = await stable(ctx, axis, `reconcile-${axis}-${pending.direction}`);
  if (pending.direction === 'increase') {
    if (Number(current.value) > Number(pending.from)) {
      record.trajectory.push(current.value);
      record.observedTrajectory = [...record.trajectory];
    }
    else if (current.value !== pending.from) throw new Error('Uncertain increase cannot be reconciled monotonically');
  } else {
    if (current.value === pending.expected) record.trajectory.pop();
    else if (current.value !== pending.from) throw new Error('Uncertain decrease cannot be reconciled to saved trajectory');
  }
  record.pending = null;
  await ctx.save();
}

async function restoreAxis(ctx, axis) {
  await recover(ctx, axis);
  const record = ctx.state.axes[axis];
  let current = await read(ctx, axis, `restore-${axis}-current`);
  if (current.value === record.original) {
    await stable(ctx, axis, `${axis}-exact-baseline-restored`, record.original);
    record.trajectory = [record.original]; record.pending = null; record.restored = true;
    ctx.state.activeAxis = null;
    await ctx.save();
    return;
  }
  await reconcile(ctx, axis);
  current = await read(ctx, axis, `restore-${axis}-reconciled`);
  if (current.value !== record.trajectory.at(-1)) throw new Error('Current native value differs from durable trajectory');
  while (record.trajectory.length > 1) {
    const expected = record.trajectory.at(-2);
    if (current.down.enabled !== 'true') throw new Error('Native Decrease unavailable during restoration');
    record.pending = { direction: 'decrease', from: current.value, expected };
    await ctx.save();
    await ctx.adapter.touch(current.down, axes[axis].downLabel);
    current = await read(ctx, axis, `restore-${axis}-step-${record.trajectory.length}`);
    if (current.value !== expected) throw new Error('Native Decrease did not reach exact saved value');
    record.trajectory.pop(); record.pending = null;
    await ctx.save();
  }
  await stable(ctx, axis, `${axis}-exact-baseline-restored`, record.original);
  record.restored = true; ctx.state.activeAxis = null;
  await ctx.save();
}

export async function restoreExtremes(adapter) {
  if (!isAbsolute(adapter.evidence)) throw new Error('Absolute evidence directory required');
  try { await readFile(resolve(adapter.evidence, 'extremes-state.json'), 'utf8'); }
  catch (error) {
    if (error.code === 'ENOENT') return { mutationRecorded: false, cleanupNavigationRequired: false };
    throw error;
  }
  const ctx = await context(adapter);
  if (ctx.state.activeAxis) await restoreAxis(ctx, ctx.state.activeAxis);
  for (const axis of Object.keys(axes)) {
    await recover(ctx, axis);
    await stable(ctx, axis, `${axis}-final-baseline`, '2.0');
  }
  await adapter.restorePicker();
  ctx.state.finalBaselineAndPickerRestored = true;
  await ctx.save();
  return ctx.state;
}

export async function runExtremes(adapter) {
  const ctx = await context(adapter);
  if (ctx.state.activeAxis) throw new Error('Unresolved setting mutation; restoreExtremes required before another trial');
  // Original observation captured both baselines; verify the current font page
  // around the activation smoke check before any setting mutation.
  await recover(ctx, 'font');
  await stable(ctx, 'font', 'activation-before-font-baseline', '2.0');
  await adapter.activate('org.localsend.localsend_app');
  let appReady = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    const screen = await adapter.capture(`activation-roundtrip-localsend-${attempt}`);
    if (screen.nodes.some(node => node.package === 'org.localsend.localsend_app' && node.displayed === 'true')) { appReady = true; break; }
  }
  if (!appReady) throw new Error('LocalSend activation not observed before setting mutation');
  await adapter.activate(pkg);
  await recover(ctx, 'font');
  await stable(ctx, 'font', 'activation-roundtrip-font-baseline', '2.0');
  for (const axis of Object.keys(axes)) {
    const record = ctx.state.axes[axis];
    if (record.trialStarted) continue; // Never repeat a condition after interrupted or completed execution.
    for (const baseline of Object.keys(axes)) {
      await recover(ctx, baseline);
      await stable(ctx, baseline, `${axis}-before-trial-${baseline}-baseline`, '2.0');
    }
    await recover(ctx, axis);
    let current = await read(ctx, axis, `${axis}-before-increase`);
    record.trialStarted = true; record.restored = false; ctx.state.activeAxis = axis;
    ctx.state.finalBaselineAndPickerRestored = false;
    await ctx.save();
    let endpointEstablished = false;
    let calibrationError;
    try {
      for (let advances = 0; current.up.enabled === 'true'; advances++) {
        if (advances >= 8) throw new Error('Native maximum not reached within eight observed advances');
        record.pending = { direction: 'increase', from: current.value };
        await ctx.save();
        await adapter.touch(current.up, axes[axis].upLabel);
        const next = await read(ctx, axis, `${axis}-increase-${advances + 1}`);
        if (Number(next.value) <= Number(current.value)) throw new Error('Native increase did not strictly grow numeric value');
        record.trajectory.push(next.value); record.observedTrajectory = [...record.trajectory]; record.pending = null;
        await ctx.save(); current = next;
      }
      const endpoint = await stable(ctx, axis, `${axis}-observed-maximum`, current.value, true);
      record.maximum = endpoint.value; record.maximumTrajectory = [...record.trajectory];
      await ctx.save();
      endpointEstablished = true;
      await adapter.activate('org.localsend.localsend_app');
      const trial = await adapter.pickerControl(axis === 'font' ? 'font-maximum-zoom-baseline' : 'zoom-maximum-font-baseline');
      record.result = { outcome: 'observed', evidence: trial ?? null, productValidated: false, settingScaleFactorUnknown: true };
    } catch (error) {
      record.result = { outcome: endpointEstablished ? 'picker-control-failure-or-candidate' : 'endpoint-calibration-failure', error: String(error.message ?? error), productValidated: false, settingScaleFactorUnknown: true };
      if (!endpointEstablished) calibrationError = error;
    } finally {
      await ctx.save();
      await ctx.evidence(`${axis}-condition-result`, record);
      await restoreAxis(ctx, axis);
      await adapter.restorePicker();
      record.pickerBaselineRestored = true;
      await ctx.save();
    }
    if (calibrationError) throw calibrationError;
  }
  return restoreExtremes(adapter);
}
