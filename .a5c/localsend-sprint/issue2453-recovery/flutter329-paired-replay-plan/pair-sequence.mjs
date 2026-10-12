// Source-only proposal. Execute only in an explicitly authorized fork cloud run.
import fs from 'node:fs';
import path from 'node:path';

const arm = process.env.LS2453_ARM;
if (!['default', 'candidate'].includes(arm)) throw new Error('An explicit paired arm is required');
const session = process.env.LS2453_SESSION_ID;
if (!session) throw new Error('An existing admitted session is required');
const deadline = Number(process.env.LS2453_SCENARIO_DEADLINE_MS);
if (!Number.isFinite(deadline) || deadline <= Date.now()) throw new Error('An explicit future scenario deadline is required');
const out = path.join(process.env.LS2453_OUTPUT_DIR, arm);
fs.mkdirSync(out, {recursive: true});
const auth = Buffer.from(`${process.env.BROWSERSTACK_USERNAME}:${process.env.BROWSERSTACK_ACCESS_KEY}`).toString('base64');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const record = event => fs.appendFileSync(path.join(out, 'commands.ndjson'), `${JSON.stringify(event)}\n`);
let nativeSettlement = 'settled';
let triggerReached = false;

async function request(method, route, label, body) {
  if (Date.now() + 300000 > deadline) {
    const error = new Error(`${label}: insufficient remaining time for a full provider timeout; preserve cleanup reserve`);
    error.deadlineFailure = true;
    throw error;
  }
  const started = new Date().toISOString();
  record({phase: 'start', arm, session, label, method, route, started});
  nativeSettlement = 'unresolved';
  try {
    // Longer than the previously observed 240s provider proxy timeout; do not queue
    // another command after an unresolved request or treat a client abort as idle.
    const response = await fetch(`https://hub-cloud.browserstack.com/wd/hub/session/${session}/${route}`, {
      method, headers: {Authorization: `Basic ${auth}`, 'Content-Type': 'application/json'},
      ...(body !== undefined ? {body: JSON.stringify(body)} : {}),
      signal: AbortSignal.timeout(300000),
    });
    const raw = await response.text();
    fs.writeFileSync(path.join(out, `${label}.json`), raw);
    const value = JSON.parse(raw);
    record({phase: 'end', arm, session, label, started, ended: new Date().toISOString(), httpStatus: response.status, error: value.value?.error});
    if (!response.ok || value.value?.error) throw new Error(`${label}: provider command failed; see retained response`);
    nativeSettlement = 'settled';
    return value.value;
  } catch (error) {
    record({phase: 'error', arm, session, label, started, ended: new Date().toISOString(), message: error.message});
    throw error;
  }
}

async function source(label) {
  const xml = await request('GET', 'source', label);
  if (typeof xml !== 'string') {
    nativeSettlement = 'unresolved';
    throw new Error(`${label}: no native XML string`);
  }
  fs.writeFileSync(path.join(out, `${label}.xml`), xml);
  return xml;
}
const tap = (label, point) => request('POST', 'execute/sync', label, {script: 'mobile: tap', args: [point]});
function visibleName(xml, name) {
  return [...xml.matchAll(/<XCUIElementType\w+[^>]*>/g)].some(match => match[0].includes(`name="${name}"`) && match[0].includes('visible="true"'));
}
function visibleFileCount(xml, pattern) {
  return [...xml.matchAll(/<XCUIElementType\w+[^>]*>/g)].some(match => match[0].includes('visible="true"') && pattern.test(match[0]));
}
async function click(label, using, value) {
  const found = await request('POST', 'element', `${label}-find`, {using, value});
  const id = found?.['element-6066-11e4-a52e-4f735466cecf'];
  if (typeof id !== 'string' || !id) {
    nativeSettlement = 'unresolved';
    throw new Error(`${label}: no element ID`);
  }
  await request('POST', `element/${id}/click`, label, {});
}
function center(xml, type, namePrefix) {
  const nodes = [...xml.matchAll(/<XCUIElementType\w+[^>]*>/g)].map(match => match[0])
    .filter(node => node.includes(`type="${type}"`) && node.includes(`name="${namePrefix}`) && node.includes('visible="true"'));
  if (nodes.length !== 1) throw new Error(`Expected one visible control: ${namePrefix}`);
  const attr = name => {
    const match = nodes[0].match(new RegExp(` ${name}="([0-9.]+)"`));
    if (!match) throw new Error(`Missing native bound ${name}`);
    return Number(match[1]);
  };
  return {x: attr('x') + attr('width') / 2, y: attr('y') + attr('height') / 2};
}
function picker(xml, selected) {
  if (!xml.includes('name="Accessible files"') || !xml.includes('width="402" height="874"')) throw new Error('Expected observed portrait picker geometry');
  const images = [...xml.matchAll(/<XCUIElementTypeImage[^>]*name="Image[0-9][^>]*visible="true"[^>]*>/g)];
  if (images.length !== 1) throw new Error('Expected limited access to exactly one visible sample');
  const confirm = selected ? /name="Confirm \(1\/999\)"[^>]*enabled="true"/ : /name="Confirm"[^>]*enabled="false"/;
  if (!confirm.test(xml)) throw new Error(`Expected picker selected=${selected}`);
  return {image: center(xml, 'XCUIElementTypeImage', 'Image1'), close: center(xml, 'XCUIElementTypeButton', 'Close')};
}
async function reopen(label) {
  await click(`${label}-media`, 'accessibility id', 'Media');
  let xml = await source(`${label}-gate`);
  if (xml.includes('Continue with limited access')) {
    // This control was independently observed in the existing exact-device setup.
    // Stop on any geometry change rather than widen permissions or invent a target.
    if (!xml.includes('width="402" height="874"')) throw new Error('Limited gate geometry changed');
    await tap(`${label}-continue`, {x: 201, y: 830});
    xml = await source(`${label}-grid`);
  }
  return xml;
}

// Coordinator must first launch the exact arm and complete the existing ordinary
// limited-one-photo setup. This script does not install, admit or reset devices.
async function runSequence() {
const initial = picker(await source('control-before'), false);
await tap('control-select', initial.image);
picker(await source('control-selected'), true);
await tap('control-close', initial.close);
const controlSend = await source('control-send');
if (!visibleName(controlSend, 'Media')) throw new Error('Working portrait Close control failed');
if (visibleFileCount(controlSend, / (?:name|value)="Files: [1-9]/)) throw new Error('Arm setup has retained Send files; starting states do not match');
const pretrigger = picker(await reopen('control-reopen'), false);
fs.writeFileSync(path.join(out, 'pretrigger-centers.json'), JSON.stringify(pretrigger, null, 2));
record({phase: 'trigger', arm, session, time: new Date().toISOString(), selected: false});
triggerReached = true;

// Exact reported input order: Media unselected -> landscape -> portrait.
// No postrotation source/screenshot query precedes the two raw input attempts.
await request('POST', 'orientation', 'landscape', {orientation: 'LANDSCAPE'});
await pause(2000);
await request('POST', 'orientation', 'portrait-return', {orientation: 'PORTRAIT'});
await pause(2000);
await tap('raw-return-select', pretrigger.image);
await pause(1000);
await tap('raw-return-close', pretrigger.close);
await pause(1000);
const after = await source('after-raw-close');
if (!visibleName(after, 'Media')) throw new Error('Raw Close did not yield visible Send/Media; classify with retained video/geometry before interpreting');

// Completion verifies real app behavior after this one rotation, without a
// second trigger. Raw returned selection itself requires the continuous video.
const completion = picker(await reopen('completion'), false);
await tap('completion-select', completion.image);
picker(await source('completion-selected'), true);
await click('completion-confirm', '-ios predicate string', 'type == "XCUIElementTypeButton" AND name BEGINSWITH "Confirm"');
const completed = await source('completion-send');
if (!visibleName(completed, 'Media') || !visibleFileCount(completed, / (?:name|value)="Files: 1(?:[^0-9]|"|$)/)) throw new Error('Confirm did not yield visible Send Files1');
fs.writeFileSync(path.join(out, 'outcome.json'), JSON.stringify({arm, session, status: 'scripted-gates-passed', nativeSettlement, triggerReached, portraitControl: true, rotationCount: 1, rawCloseToSend: true, confirmedSendFiles1: true, rawReturnedSelection: 'requires independent video inspection'}, null, 2));
}

await runSequence().catch(error => {
  record({phase: 'scenario-error', arm, session, time: new Date().toISOString(), message: error.message});
  fs.writeFileSync(path.join(out, 'outcome.json'), JSON.stringify({arm, session, status: 'incomplete', error: error.message, nativeSettlement, triggerReached, transitionEligible: nativeSettlement === 'settled' && triggerReached && !error.deadlineFailure, interpretation: 'inspect executed phases and retained evidence; not an automatic app-freeze verdict'}, null, 2));
  process.exitCode = 1;
});
