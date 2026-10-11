import {readFileSync, writeFileSync} from 'node:fs';
import {waitForNativeControl} from './native-readiness.mjs';

const appPackage = 'org.localsend.localsend_app';
const settingsPackage = 'com.android.settings';
const powerPackage = 'com.samsung.android.lool';
const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
const policies = Object.freeze(['Unrestricted', 'Optimised', 'Restricted']);
const appName = `//*[@package="${settingsPackage}" and @resource-id="${settingsPackage}:id/entity_header_title" and @text="LocalSend"]`;
const heading = text => `//*[@package="${settingsPackage}" and @class="android.widget.TextView" and @text="${text}" and @displayed="true"]`;
const appIdentity = `count(${heading('App info')})=1 and count(${appName})=1`;
// The Battery screen has not been captured. Require its identity and all three
// labelled radio controls before borrowing the policy; do not infer a fallback.
const policyIdentity = `count(${heading('Battery')})=1 and count(//*[@package="${settingsPackage}" and @text="LocalSend" and @displayed="true"])=1`;
const radios = `//*[@package="${settingsPackage}" and @class="android.widget.RadioButton" and @checkable="true" and @displayed="true"]`;
const labelNode = policy => `//*[@package="${settingsPackage}" and @text="${policy}" and @displayed="true"]`;
const policyRow = policy => `${labelNode(policy)}/ancestor-or-self::*[@package="${settingsPackage}" and count(.//android.widget.RadioButton[@checkable="true" and @displayed="true"])=1][1]`;
const policyRadio = policy => `${policyRow(policy)}//android.widget.RadioButton[@package="${settingsPackage}" and @checkable="true" and @displayed="true"]`;
const policyGuard = `${policyIdentity} and count(${radios})=3 and count(${radios}[@checked="true"])=1 and count(${radios}[@checked="false"])=2 and ${policies.map(policy => `count(${labelNode(policy)})=1 and count(${policyRadio(policy)})=1`).join(' and ')}`;
const target = value => ({using: 'xpath', value});
let contextSequence = 0;

function context({session, wd}, phase) {
  if (!session || typeof wd !== 'function') throw new Error('Samsung policy requires a session and WebDriver client');
  // A failed preparation may restore internally and again in the scenario's
  // finally. Keep both attempts, including ambiguous failures, independently.
  phase = `${phase}-${contextSequence++}`;
  const prefix = `/session/${session}`;
  const stem = `evidence/samsung-policy-${phase}`;
  let sequence = 0;
  const events = [];
  const event = (name, values = {}) => {
    events.push({name, utc: new Date().toISOString(), ...values});
    writeFileSync(`${stem}.json`, JSON.stringify({events}, null, 2));
  };
  const call = (method, path, body) => wd(method, path, body, {timeoutMs: 10000});
  const ready = (name, choices, options = {}) => waitForNativeControl({wd, prefix, label: `samsung-${phase}-${sequence++}-${name}`, choices, timeoutMs: 12000, ...options});
  async function capture(name, sourceFile) {
    const file = `${stem}-${sequence++}-${name}`;
    const xml = sourceFile ? readFileSync(sourceFile, 'utf8') : await call('GET', `${prefix}/source`);
    writeFileSync(`${file}.xml`, xml);
    event(name, {xml: `${file}.xml`});
    writeFileSync(`${file}.png`, Buffer.from(await call('GET', `${prefix}/screenshot`), 'base64'));
  }
  async function failure(error) {
    event('failed', {error: String(error)});
    try { await capture('failure'); } catch (captureError) { event('failure-capture-failed', {error: String(captureError)}); }
  }
  async function intent(action, uri) {
    await capture('before-intent');
    await call('POST', `${prefix}/execute/sync`, {script: 'mobile: startActivity', args: [{action, ...(uri ? {uri} : {}), wait: true, stop: false}]});
    await capture('after-intent');
  }
  async function returnApp() {
    await capture('before-return-app');
    await call('POST', `${prefix}/appium/device/activate_app`, {appId: appPackage});
    const app = await ready('returned-app', [target(`//*[@package="${appPackage}"][1]`)], {requireClickable: false});
    await capture('after-return-app', app.readiness.sourceFile);
  }
  async function openPolicy() {
    await intent('android.settings.APPLICATION_DETAILS_SETTINGS', `package:${appPackage}`);
    // The intent may resume the app's policy page. Both outcomes need identity.
    const outcome = await ready('app-info-or-policy', [target(`${appName}[${appIdentity}]`), target(`${policyRadio('Unrestricted')}[${policyGuard}]`)], {requireClickable: false});
    await capture('app-info-or-policy', outcome.readiness.sourceFile);
    if (outcome.readiness.choice === 1) return;
    const batteryTitle = `//*[@package="${settingsPackage}" and @text="Battery" and @displayed="true"]`;
    const batteryTarget = target(`${batteryTitle}/ancestor-or-self::*[@package="${settingsPackage}" and @clickable="true"][1][${appIdentity} and count(${batteryTitle})=1]`);
    const containerTarget = target(`//*[@package="${settingsPackage}" and @resource-id="${settingsPackage}:id/recycler_view" and @scrollable="true" and @displayed="true"][${appIdentity}]`);
    for (let attempt = 0; attempt <= 5; attempt++) {
      const control = await ready(`battery-or-scroll-${attempt}`, [batteryTarget, containerTarget], {requireClickable: false});
      await capture(`battery-or-scroll-${attempt}`, control.readiness.sourceFile);
      if (control.readiness.choice === 0) {
        const button = await ready('battery-click', [batteryTarget]);
        await capture('before-battery-click', button.readiness.sourceFile);
        await call('POST', `${prefix}/element/${button[elementKey]}/click`, {});
        await capture('after-battery-click');
        await ready('policy-screen', [target(`${policyRadio('Unrestricted')}[${policyGuard}]`)], {requireClickable: false});
        return;
      }
      if (attempt === 5) throw new Error('Battery row was not observed within five guarded Samsung App info scrolls');
      const {x, y, width, height} = control.readiness.rect;
      // Derive the gesture from the observed native container rectangle.
      const centerX = Math.round(x + width / 2);
      const startY = Math.round(y + height * 0.8);
      const endY = Math.round(y + height * 0.3);
      await capture('before-scroll');
      try {
        await call('POST', `${prefix}/actions`, {actions: [{type: 'pointer', id: 'samsung-policy-scroll', parameters: {pointerType: 'touch'}, actions: [
          {type: 'pointerMove', duration: 0, origin: 'viewport', x: centerX, y: startY},
          {type: 'pointerDown', button: 0}, {type: 'pause', duration: 150},
          {type: 'pointerMove', duration: 500, origin: 'viewport', x: centerX, y: endY}, {type: 'pointerUp', button: 0},
        ]}]});
      } finally { await call('DELETE', `${prefix}/actions`); }
      await capture('after-scroll');
      await ready('app-info-after-scroll', [target(`${heading('App info')}[${appIdentity}]`)], {requireClickable: false});
    }
  }
  async function observePolicy(name) {
    const selected = await ready(name, policies.map(policy => target(`${policyRadio(policy)}[@checked="true"][${policyGuard}]`)), {requireClickable: false});
    const checked = await call('GET', `${prefix}/element/${selected[elementKey]}/attribute/checked`);
    if (checked !== true && checked !== 'true') throw new Error('Samsung selected policy changed during observation');
    await capture(name, selected.readiness.sourceFile);
    const policy = policies[selected.readiness.choice];
    event('policy-observed', {policy, readiness: selected.readiness});
    return policy;
  }
  async function setPolicy(policy, beforeClick) {
    const current = await observePolicy('policy-before-change');
    if (current === policy) return;
    const button = await ready(`select-${policy}`, [target(`${policyRow(policy)}[@clickable="true" and count(.//android.widget.RadioButton[@checked="false"])=1][${policyGuard}]`)]);
    await capture('before-policy-click', button.readiness.sourceFile);
    if (beforeClick) await beforeClick();
    event('policy-mutation-attempt', {from: current, to: policy});
    await call('POST', `${prefix}/element/${button[elementKey]}/click`, {});
    await capture('after-policy-click');
    const verified = await observePolicy('policy-after-change');
    if (verified !== policy) throw new Error(`Samsung policy remained ${verified}; expected ${policy}`);
  }
  async function verifyPowerOff() {
    await intent('android.settings.BATTERY_SAVER_SETTINGS');
    const container = `//*[@package="${powerPackage}" and @resource-id="${powerPackage}:id/sesl_switchbar_container" and @text="Power saving"]`;
    const topSwitch = `${container}/android.widget.Switch[@package="${powerPackage}" and @resource-id="${powerPackage}:id/sesl_switchbar_switch" and @checked="false" and @checkable="true"]`;
    const offText = `${container}/android.widget.TextView[@package="${powerPackage}" and @resource-id="${powerPackage}:id/sesl_switchbar_text" and @text="Off"]`;
    const identity = `count(//*[@package="${powerPackage}" and @class="android.widget.TextView" and @text="Power saving"])=1 and count(${container})=1 and count(${topSwitch})=1 and count(${offText})=1`;
    const control = await ready('power-saving-off', [target(`${topSwitch}[${identity}]`)], {requireClickable: false});
    const checked = await call('GET', `${prefix}/element/${control[elementKey]}/attribute/checked`);
    if (checked !== false && checked !== 'false') throw new Error('Samsung global Power saving changed during verification');
    await capture('power-saving-off', control.readiness.sourceFile);
    event('power-saving-verified', {enabled: false});
  }
  return {event, capture, failure, openPolicy, observePolicy, setPolicy, verifyPowerOff, returnApp};
}

export async function prepare({session, wd, onMutationAttempt}) {
  if (onMutationAttempt !== undefined && typeof onMutationAttempt !== 'function') throw new Error('onMutationAttempt must be a function');
  const ctx = context({session, wd}, 'prepare');
  let state;
  let mutationAttempted = false;
  try {
    // Check global policy before borrowing LocalSend's policy. Never toggle it.
    await ctx.verifyPowerOff();
    await ctx.openPolicy();
    state = Object.freeze({originalPolicy: await ctx.observePolicy('original-policy'), desiredPolicy: 'Unrestricted', appPackage, session});
    ctx.event('original-policy-recorded', {state});
    await ctx.setPolicy('Unrestricted', async () => {
      if (onMutationAttempt) await onMutationAttempt(state);
      mutationAttempted = true;
    });
    await ctx.verifyPowerOff();
    await ctx.returnApp();
    return state;
  } catch (error) {
    await ctx.failure(error);
    if (mutationAttempted) {
      try { await restore({session, wd, state}); ctx.event('prepare-failure-restored', {originalPolicy: state.originalPolicy}); }
      catch (restoreError) {
        ctx.event('prepare-failure-restore-failed', {error: String(restoreError)});
        throw new AggregateError([error, restoreError], 'Samsung preparation failed and original policy restoration failed');
      }
    } else {
      try { await ctx.returnApp(); } catch (returnError) { throw new AggregateError([error, returnError], 'Samsung preparation failed and LocalSend could not be resumed'); }
    }
    throw error;
  }
}

export async function restore({session, wd, state}) {
  if (!state || !Object.isFrozen(state) || state.session !== session || state.appPackage !== appPackage || !policies.includes(state.originalPolicy)) {
    throw new Error('Restore requires the immutable original Samsung policy from the same session');
  }
  const ctx = context({session, wd}, 'restore');
  let failure;
  try {
    await ctx.openPolicy();
    await ctx.setPolicy(state.originalPolicy);
    const actual = await ctx.observePolicy('restored-policy');
    if (actual !== state.originalPolicy) throw new Error('Original Samsung policy was not restored');
    ctx.event('original-policy-restored', {originalPolicy: actual});
  } catch (error) { failure = error; await ctx.failure(error); }
  finally {
    try { await ctx.returnApp(); }
    catch (error) { failure = failure ? new AggregateError([failure, error], 'Samsung restoration and app return failed') : error; }
  }
  if (failure) throw failure;
}
