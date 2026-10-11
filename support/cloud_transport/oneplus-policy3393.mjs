import {readFileSync, writeFileSync} from 'node:fs';
import {waitForNativeControl} from './native-readiness.mjs';

const appPackage = 'org.localsend.localsend_app';
const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
const now = () => new Date().toISOString();

// Change only the observed LocalSend switch. A failed click may have taken effect.
export async function setOnePlusBackground({session, wd, enabled, requireInitial = false, label, onMutationAttempt}) {
  if (typeof enabled !== 'boolean' || typeof wd !== 'function' || !session || !/^[a-zA-Z0-9_-]+$/.test(label || '')) {
    throw new Error('A session, WebDriver client, Boolean state, and safe evidence label are required');
  }
  if (onMutationAttempt !== undefined && typeof onMutationAttempt !== 'function') throw new Error('onMutationAttempt must be a function');

  const prefix = `/session/${session}`;
  const evidence = `evidence/${label}-oneplus-background`;
  const record = {label, desired: enabled, requireInitial, started: now(), initial: null, state: null, changed: false, mutationAttempted: false, events: []};
  const save = () => writeFileSync(`${evidence}.json`, JSON.stringify(record, null, 2));
  const event = (name, values = {}) => { record.events.push({name, utc: now(), ...values}); save(); };
  const call = (method, path, body) => wd(method, path, body, {timeoutMs: 10000});
  const ready = (name, choices, options = {}) => waitForNativeControl({
    wd, prefix, label: `${label}-oneplus-${name}`, choices, timeoutMs: 12000, ...options,
  });
  const appInfoIdentity = 'count(//*[@package="com.android.settings" and @resource-id="com.android.settings:id/app_name" and @text="LocalSend"])=1 and count(//*[@package="com.android.settings" and @resource-id="com.android.settings:id/toolbar"]/android.widget.TextView[@package="com.android.settings" and @text="App info"])=1';
  const batteryTitle = '//*[@package="com.android.settings" and @resource-id="android:id/title" and @text="Battery usage"]';
  const batteryRow = `${batteryTitle}/ancestor::*[@package="com.android.settings" and @clickable="true"][1]`;
  const policyIdentity = 'count(//*[@package="com.oplus.battery" and @resource-id="com.oplus.battery:id/custom_toolbar"]/android.widget.TextView[@package="com.oplus.battery" and @text="LocalSend"])=1 and count(//*[@package="com.oplus.battery" and @resource-id="android:id/title" and @text="Power consumption controls"])=1';
  // These identifiers and strings come from the captured physical OnePlus dialog.
  const enableDialogTitle = `//*[@package="com.oplus.battery" and @resource-id="com.oplus.battery:id/alertTitle" and @text='Allow all background activity for "LocalSend"?']`;
  const enableDialogMessage = '//*[@package="com.oplus.battery" and @resource-id="android:id/message" and @text="Allow all background activity for this app. Power consumption will increase."]';
  const dialogButton = (id, text) => `//*[@package="com.oplus.battery" and @resource-id="android:id/${id}" and @text="${text}"]`;
  const allowButton = dialogButton('button1', 'Allow');
  const cancelButton = dialogButton('button2', 'Cancel');
  const enableDialogIdentity = `count(${enableDialogTitle})=1 and count(${enableDialogMessage})=1 and count(${allowButton})=1 and count(${cancelButton})=1`;
  const enableDialogTarget = action => ({using: 'xpath', value: `${action === 'allow' ? allowButton : cancelButton}[${enableDialogIdentity}]`, sourceIncludes: ['resource-id="com.oplus.battery:id/alertTitle"', 'resource-id="android:id/message"']});
  const batteryTarget = {using: 'xpath', value: `${batteryRow}[${appInfoIdentity} and count(${batteryTitle})=1 and count(//*[@package="com.oplus.battery" and @resource-id="com.oplus.battery:id/alertTitle"])=0]`, sourceIncludes: ['text="App info"', 'text="LocalSend"', 'text="Battery usage"']};
  const policyTitle = 'android.widget.TextView[@package="com.oplus.battery" and @resource-id="android:id/title" and @text="Allow background activity"]';
  const policyRow = `//${policyTitle}/ancestor::*[@package="com.oplus.battery" and @clickable="true" and .//android.widget.Switch[@package="com.oplus.battery" and @resource-id="android:id/switch_widget"]][1]`;
  const switchFor = state => {
    const checked = String(state);
    const text = state ? 'On' : 'Off';
    return `android.widget.Switch[@package="com.oplus.battery" and @resource-id="android:id/switch_widget" and @checked="${checked}" and @text="${text}" and @clickable="false" and @enabled="true"]`;
  };
  const stateTarget = (state, kind) => {
    const row = `${policyRow}[count(.//${policyTitle})=1 and count(.//${switchFor(state)})=1]`;
    const path = kind === 'row' ? row : `${row}//${switchFor(state)}`;
    return {using: 'xpath', value: `${path}[${policyIdentity} and count(${policyRow})=1 and count(//*[@package="com.oplus.battery" and @resource-id="com.oplus.battery:id/alertTitle"])=0]`, sourceIncludes: ['text="Allow background activity"', 'resource-id="android:id/switch_widget"']};
  };
  const stateChoices = kind => [stateTarget(false, kind), stateTarget(true, kind)];
  const observedState = async (element, expected) => {
    const checked = await call('GET', `${prefix}/element/${element[elementKey]}/attribute/checked`);
    if (checked !== expected && checked !== String(expected)) throw new Error('The observed switch state changed during the readiness check');
    return expected;
  };
  const snapshot = async (name, sourceFile) => {
    writeFileSync(`${evidence}-${name}.xml`, readFileSync(sourceFile));
    const png = await call('GET', `${prefix}/screenshot`);
    writeFileSync(`${evidence}-${name}.png`, Buffer.from(png, 'base64'));
    event(`${name}-captured`, {xml: `${evidence}-${name}.xml`, png: `${evidence}-${name}.png`});
  };
  const failureSnapshot = async () => {
    try { writeFileSync(`${evidence}-failure.xml`, await call('GET', `${prefix}/source`)); } catch { /* Keep the original failure. */ }
    try { writeFileSync(`${evidence}-failure.png`, Buffer.from(await call('GET', `${prefix}/screenshot`), 'base64')); } catch { /* Keep the original failure. */ }
  };
  const clickDialogOnce = async action => {
    const before = await ready(`${action}-dialog-before`, [enableDialogTarget(action)]);
    await snapshot(`${action}-dialog-before`, before.readiness.sourceFile);
    const button = await ready(`${action}-dialog-click`, [enableDialogTarget(action)]);
    if (onMutationAttempt) await onMutationAttempt({initial: record.initial, desired: enabled, label});
    record.mutationAttempted = true;
    event(`${action}-dialog-click-started`, {readiness: button.readiness});
    try {
      await call('POST', `${prefix}/element/${button[elementKey]}/click`, {});
      event(`${action}-dialog-click-returned`);
    } catch (error) {
      event(`${action}-dialog-click-ambiguous`, {errorName: error?.name || 'Error'});
      throw error;
    }
    const after = await ready(`${action}-dialog-after`, [stateTarget(action === 'allow', 'switch')], {requireClickable: false});
    await observedState(after, action === 'allow');
    await snapshot(`${action}-dialog-after`, after.readiness.sourceFile);
    event(`${action}-dialog-state-verified`, {checked: action === 'allow', readiness: after.readiness});
  };

  let failure;
  try {
    const openAppInfo = async name => {
      event(name);
      await call('POST', `${prefix}/execute/sync`, {script: 'mobile: startActivity', args: [{action: 'android.settings.APPLICATION_DETAILS_SETTINGS', uri: `package:${appPackage}`, wait: true, stop: false}]});
    };
    await openAppInfo('open-app-info');
    let battery;
    if (!enabled) {
      // The observed App info intent can resume the OEM dialog or policy screen.
      event('inspect-pending-enable-dialog');
      const restoreChoices = [enableDialogTarget('cancel'), batteryTarget, ...stateChoices('switch')];
      let outcome = await ready('restore-app-info-outcome', restoreChoices, {requireClickable: false});
      if (outcome.readiness.choice === 0) {
        event('pending-enable-dialog-observed', {readiness: outcome.readiness});
        await clickDialogOnce('cancel');
        await openAppInfo('reopen-app-info-after-cancel');
        outcome = await ready('restore-after-cancel-outcome', restoreChoices, {requireClickable: false});
        if (outcome.readiness.choice === 0) throw new Error('The enable dialog remained after the single Cancel click');
      } else {
        event('pending-enable-dialog-not-observed');
      }
      if (outcome.readiness.choice === 1) {
        battery = await ready('battery-row', [batteryTarget]);
      } else {
        const checked = outcome.readiness.choice === 3;
        await observedState(outcome, checked);
        await snapshot('restore-policy-resumed', outcome.readiness.sourceFile);
        event('restore-policy-screen-observed', {checked, readiness: outcome.readiness});
      }
    } else {
      battery = await ready('battery-row', [batteryTarget]);
    }
    if (battery) {
      await snapshot('app-info-before', battery.readiness.sourceFile);
      event('open-battery-usage', {readiness: battery.readiness});
      await call('POST', `${prefix}/element/${battery[elementKey]}/click`, {});
    }

    const initialSwitch = await ready('initial-switch', stateChoices('switch'), {requireClickable: false, sourceIncludes: ['text="LocalSend"', 'text="Power consumption controls"']});
    const initial = initialSwitch.readiness.choice === 1;
    await observedState(initialSwitch, initial);
    record.initial = initial;
    event('initial-state', {checked: initial, readiness: initialSwitch.readiness});
    if (requireInitial && initial) throw new Error('Allow background activity was already On; the required Off baseline is absent');
    if (enabled && initial) throw new Error('Allow background activity was already On; an On trial requires an observed Off baseline');

    if (initial !== enabled) {
      const row = await ready('owning-row', [stateTarget(initial, 'row')], {sourceIncludes: ['text="LocalSend"', 'text="Power consumption controls"']});
      await snapshot('before', row.readiness.sourceFile);
      const clickRow = await ready('click-row', [stateTarget(initial, 'row')], {sourceIncludes: ['text="LocalSend"', 'text="Power consumption controls"']});
      if (onMutationAttempt) await onMutationAttempt({initial, desired: enabled, label});
      record.mutationAttempted = true;
      event('click-started', {from: initial, to: enabled, readiness: clickRow.readiness});
      try {
        await call('POST', `${prefix}/element/${clickRow[elementKey]}/click`, {});
        record.changed = true;
        event('click-returned');
      } catch (error) {
        event('click-ambiguous', {errorName: error?.name || 'Error'});
        throw error;
      }
      if (enabled) {
        const outcome = await ready('enable-outcome', [enableDialogTarget('allow'), stateTarget(true, 'switch')], {requireClickable: false});
        if (outcome.readiness.choice === 0) {
          event('enable-dialog-observed', {readiness: outcome.readiness});
          await clickDialogOnce('allow');
        } else {
          await observedState(outcome, true);
          event('enabled-without-dialog', {readiness: outcome.readiness});
        }
      }
    } else {
      await snapshot('before', initialSwitch.readiness.sourceFile);
      event('already-desired', {checked: initial});
    }

    const verified = await ready('verified-switch', [stateTarget(enabled, 'switch')], {requireClickable: false, sourceIncludes: ['text="LocalSend"', 'text="Power consumption controls"']});
    record.state = await observedState(verified, enabled);
    await snapshot('after', verified.readiness.sourceFile);
    event('verified-state', {checked: record.state, readiness: verified.readiness});
  } catch (error) {
    failure = error;
    event('failed', {errorName: error?.name || 'Error', phase: record.events.at(-1)?.name});
    await failureSnapshot();
  } finally {
    event('return-original-app-started');
    try {
      await call('POST', `${prefix}/appium/device/activate_app`, {appId: appPackage});
      await ready('returned-original-app', [{using: 'xpath', value: `//*[@package="${appPackage}"][1]`}], {requireClickable: false, sourceIncludes: [`package="${appPackage}"`]});
      event('return-original-app-verified');
    } catch (error) {
      event('return-original-app-failed', {errorName: error?.name || 'Error'});
      if (!failure) failure = error;
    }
    record.ended = now();
    save();
  }

  if (failure) throw failure;
  return {initial: record.initial, state: record.state, changed: record.changed};
}
