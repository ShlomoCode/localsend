// Unexecuted source-only diagnostic. Copied to isolated diagnostic branch before dispatch.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend') {
  throw new Error('Only the authorized fork Actions runner may execute this controller');
}
const root = dirname(fileURLToPath(import.meta.url));
const evidence = resolve('diagnostic-2973-evidence');
await mkdir(evidence, { recursive: true });
const user = process.env.BROWSERSTACK_USERNAME;
const key = process.env.BROWSERSTACK_ACCESS_KEY;
if (!user || !key) throw new Error('BrowserStack credentials unavailable');
const auth = `Basic ${Buffer.from(`${user}:${key}`).toString('base64')}`;
const buildName = `2973-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}`;
function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) =>
    [name, /password|access.?key|token|authorization|browserstack.user|browserstack.key/i.test(name) ? '<REDACTED>' : redact(item)]));
  if (typeof value === 'string') {
    const safe = value.replaceAll(user, '<REDACTED>').replaceAll(key, '<REDACTED>');
    return /[?&](?:auth_token|token|X-Amz-Signature|X-Amz-Credential)=/i.test(safe) ? safe.split('?')[0] + '?<REDACTED>' : safe;
  }
  return value;
}
const capabilities = JSON.parse(await readFile(resolve(root, 'appium-capabilities.template.json'), 'utf8'));
capabilities.capabilities.alwaysMatch['appium:app'] = process.env.APK_APP_URL;
capabilities.capabilities.alwaysMatch['bstack:options'].buildName = buildName;
capabilities.capabilities.alwaysMatch['bstack:options'].sessionName = `${buildName}-original`;
if (!/^bs:\/\/[a-zA-Z0-9_-]+$/.test(process.env.APK_APP_URL ?? '')) throw new Error('A verified original APK upload identity is required');
const planFile = process.env.PICKER_PLAN === 'preflight' ? 'preflight.json' : process.env.PICKER_PLAN === 'observation' ? 'observation.json' : 'matrix.json';
if (!['preflight', 'observation', 'matrix'].includes(process.env.PICKER_PLAN)) throw new Error('Unknown reviewed plan');
const plan = JSON.parse(await readFile(resolve(root, planFile), 'utf8'));
if (JSON.stringify(plan).includes('REPLACE_')) throw new Error('Observed native controls and restoration values are not filled in; no session allocated');
const matrix = process.env.PICKER_PLAN === 'matrix';
if (matrix && (!plan.restore?.length || !plan.originalSettingsIdentity || !plan.restore.some(step => step.expectedSourceIncludes?.length))) {
  throw new Error('Settings changes require observed original values and explicit restore input sequence');
}
await writeFile(resolve(evidence, 'capabilities.json'), JSON.stringify(capabilities, null, 2));
await writeFile(resolve(evidence, 'plan.json'), JSON.stringify(plan, null, 2));

async function transport(mode, ...args) {
  await new Promise((resolvePromise, reject) => {
    const remaining = (cleaning ? cleanupDeadline : deadline) - Date.now();
    if (remaining <= 0) return reject(new Error('Controller phase deadline reached'));
    const child = spawn(process.execPath, [resolve(root, 'appium-rest.mjs'), mode, evidence, ...args.map(String)], { stdio: 'inherit', timeout: Math.min(mode === 'observe' ? 300000 : 100000, remaining) });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolvePromise() : reject(new Error(`Transport ${mode} failed with code ${code}`)));
  });
}

async function api(path) {
  const remaining = (cleaning ? cleanupDeadline : deadline) - Date.now();
  if (remaining <= 0) throw new Error('Controller management phase deadline reached');
  const response = await fetch(`https://api-cloud.browserstack.com${path}`, { headers: { Authorization: auth }, signal: AbortSignal.timeout(Math.min(20000, remaining)) });
  if (!response.ok) throw new Error(`BrowserStack management read failed: ${response.status}`);
  return response.json();
}
async function inventory(path) {
  const result = [];
  for (let offset = 0; offset < 1000; offset += 100) {
    const page = await api(`${path}?limit=100&offset=${offset}`);
    if (!Array.isArray(page)) throw new Error('Malformed ownership inventory page');
    result.push(...page);
    if (page.length < 100) return result;
  }
  throw new Error('Ownership inventory exceeds bounded pagination; root reconciliation required before allocation');
}
async function enforcePriorAttemptHold() {
  if (process.env.GITHUB_RUN_ATTEMPT !== '1') throw new Error('Rerun attempts require explicit prior-attempt reconciliation; no allocation');
  const token = process.env.GH_API_TOKEN;
  if (!token) throw new Error('Read-only Actions attempt ledger token unavailable');
  const response = await fetch('https://api.github.com/repos/ShlomoCode/localsend/actions/workflows/build_android_apk.yml/runs?per_page=100&branch=codex%2Fbug-2973-intake', {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' },
    signal: AbortSignal.timeout(Math.min(20000, Math.max(1, deadline - Date.now()))),
  });
  if (!response.ok) throw new Error('Prior Actions attempt ledger unavailable; no allocation');
  const ledger = await response.json();
  if (!Array.isArray(ledger.workflow_runs) || !Number.isFinite(ledger.total_count) || ledger.total_count > 100) {
    throw new Error('Prior Actions attempt ledger incomplete; root reconciliation required');
  }
  const prior = ledger.workflow_runs.filter(run => String(run.id) !== process.env.GITHUB_RUN_ID);
  await writeFile(resolve(evidence, 'prior-action-attempts.json'), JSON.stringify(prior.map(run => ({ id: run.id, status: run.status, conclusion: run.conclusion })), null, 2));
  const reconciled = JSON.parse(await readFile(resolve(root, 'reconciled-attempts.json'), 'utf8'));
  for (const run of prior) {
    if (run.status === 'completed' && run.conclusion === 'success') continue;
    const resolution = reconciled.find(item => String(item.runId) === String(run.id) && item.headSha === run.head_sha && ['harness-before-picker', 'harness-after-add'].includes(item.classification) && item.terminalStatus === 'done');
    if (!resolution || run.status !== 'completed' || run.conclusion !== 'failure') throw new Error('Prior 2973 Actions attempt is unresolved or unsuccessful; hold allocation until root reconciles its cleanup');
    const terminal = await api(`/app-automate/sessions/${encodeURIComponent(resolution.sessionId)}.json`);
    if (terminal.automation_session?.status !== resolution.terminalStatus) throw new Error('Reconciled prior session no longer has its verified terminal status');
    await writeFile(resolve(evidence, `prior-reconciled-${run.id}.json`), JSON.stringify(resolution, null, 2));
  }
}

let settingChanged = false;
let failure;
let owned;
let cleaning = false;
let cleanupDeadline;
const deadline = Date.now() + 5 * 60000;
async function verifyCapturedSource(step) {
  if (!step.expectedSourceIncludes?.length) return;
  if (step.mode !== 'snapshot') throw new Error('Source assertions must refer to a named captured screenshot/source');
  const source = await readFile(resolve(evidence, `${step.args[0]}.xml`), 'utf8');
  if (step.expectedSourceIncludes.some(text => !source.includes(text))) throw new Error('Original Settings values were not verified in native source');
}
async function recoverOwnedSession() {
  const recorded = await readFile(resolve(evidence, 'create-response.json'), 'utf8').catch(() => null);
  if (recorded) {
    const response = JSON.parse(recorded);
    const sessionId = response.value?.sessionId ?? response.sessionId;
    if (sessionId) return { sessionId, recoveredFrom: 'saved-create-response' };
  }
  const attempt = await readFile(resolve(evidence, 'session-attempt.json'), 'utf8').catch(() => null);
  if (!attempt) return null;
  for (let pass = 0; pass < 3; pass++) {
    const builds = await api('/app-automate/builds.json?limit=100');
    const matches = builds.map(item => item.automation_build).filter(item => item?.name === buildName);
    if (matches.length > 1) throw new Error('Owned build recovery is ambiguous; unrelated sessions untouched');
    if (matches.length === 1) {
      const sessions = await api(`/app-automate/builds/${encodeURIComponent(matches[0].hashed_id)}/sessions.json?limit=100`);
      const exact = sessions.map(item => item.automation_session).filter(item =>
        item?.name === `${buildName}-original` && item.build_name === buildName && item.project_name === 'LocalSend bug sprint');
      if (exact.length > 1) throw new Error('Owned session recovery is ambiguous; unrelated sessions untouched');
      if (exact.length === 1) return { sessionId: exact[0].hashed_id, recoveredFrom: 'unique-build-session-identity', status: exact[0].status };
    }
    const remaining = cleanupDeadline - Date.now();
    if (pass < 2 && remaining > 0) await new Promise(resolvePromise => setTimeout(resolvePromise, Math.min(10000, remaining)));
  }
  return null;
}
try {
  await enforcePriorAttemptHold();
  const capacity = await api('/app-automate/plan.json');
  await writeFile(resolve(evidence, 'capacity-before.json'), JSON.stringify(capacity, null, 2));
  const fields = ['parallel_sessions_running', 'parallel_sessions_max_allowed', 'queued_sessions'];
  if (fields.some(field => !Number.isFinite(capacity[field]) || capacity[field] < 0) || capacity.parallel_sessions_max_allowed < 1) {
    throw new Error('Capacity response fields are missing or malformed; no allocation');
  }
  if (capacity.parallel_sessions_running >= Math.min(capacity.parallel_sessions_max_allowed, 5) || capacity.queued_sessions > 0) {
    throw new Error('Capacity is unavailable or queued; no device allocation');
  }
  const buildsBefore = await inventory('/app-automate/builds.json');
  for (const item of buildsBefore) {
    const build = item.automation_build;
    if (!/^2973-\d+-\d+$/.test(build?.name ?? '')) continue;
    const sessions = await inventory(`/app-automate/builds/${encodeURIComponent(build.hashed_id)}/sessions.json`);
    if (sessions.some(item => !['done', 'failed', 'timeout'].includes(item.automation_session?.status))) throw new Error('Prior 2973 session is nonterminal or unknown; reconcile before allocating another');
  }
  await writeFile(resolve(evidence, 'prior-ownership.json'), JSON.stringify({ prior2973RunningSessions: 0, recentBuildInventoryRead: true }));
  await transport('create', resolve(evidence, 'capabilities.json'));
  owned = JSON.parse(await readFile(resolve(evidence, 'owned-session.json'), 'utf8'));
  const actual = await api(`/app-automate/sessions/${encodeURIComponent(owned.sessionId)}.json`);
  await writeFile(resolve(evidence, 'actual-session-identity.json'), JSON.stringify(redact(actual), null, 2));
  const info = actual.automation_session ?? actual;
  const expected = capabilities.capabilities.alwaysMatch['bstack:options'];
  if (info.device !== expected.deviceName || String(info.os_version) !== expected.osVersion) throw new Error('Actual allocated model/OS differs from reviewed substitute');
  await transport('snapshot', '00-original-app-start');
  if (process.env.PICKER_PLAN === 'observation') await transport('observe', 'control');
  for (const [index, step] of plan.steps.entries()) {
    if (Date.now() > deadline) throw new Error('Bounded cloud scenario deadline reached');
    if (!['tap', 'swipe', 'snapshot'].includes(step.mode)) throw new Error('Unsupported UI plan operation');
    await transport('snapshot', `step-${index}-before`);
    // Mark before request: an uncertain touch may already have changed the setting.
    if (matrix) settingChanged = true;
    await transport(step.mode, ...step.args);
    await verifyCapturedSource(step);
    await transport('snapshot', `step-${index}-after`);
  }
  await writeFile(resolve(evidence, 'execution-verdict.json'), JSON.stringify({ classification: 'captured-ui-sequence-awaiting-raw-inspection', productValidated: false }, null, 2));
} catch (error) {
  failure = error;
  await writeFile(resolve(evidence, 'failure.txt'), `${error.message}\n`);
} finally {
  cleaning = true;
  cleanupDeadline = Date.now() + 2 * 60000;
  if (!owned) owned = JSON.parse(await readFile(resolve(evidence, 'owned-session.json'), 'utf8').catch(() => 'null'));
  if (!owned) {
    try {
      owned = await recoverOwnedSession();
      if (owned) await writeFile(resolve(evidence, 'owned-session.json'), JSON.stringify(owned, null, 2));
    } catch (error) {
      failure ??= error;
      await writeFile(resolve(evidence, 'session-recovery-failure.txt'), `${error.message}\n`);
    }
  }
  if (owned) {
    if (process.env.PICKER_PLAN === 'observation') {
      const state = JSON.parse(await readFile(resolve(evidence, 'observation-state.json'), 'utf8').catch(() => 'null'));
      if (state?.mutationMayHaveOccurred || (state && !state.restorationVerified)) {
        failure ??= new Error('Original app selection/switch restoration unverified after partial observation');
        await writeFile(resolve(evidence, 'observation-restoration-unverified.json'), JSON.stringify({ state, productValidated: false, terminationDoesNotProveStateRestoration: true }, null, 2));
      }
    }
    if (settingChanged) {
      try {
        for (const step of plan.restore) {
          await transport(step.mode, ...step.args);
          await verifyCapturedSource(step);
        }
        await writeFile(resolve(evidence, 'restoration-verdict.json'), JSON.stringify({ inputsCompleted: true, originalNativeValuesVerified: true, imagesRequireRootInspection: true }));
      } catch (error) {
        failure ??= error;
        await writeFile(resolve(evidence, 'restoration-failure.txt'), `${error.message}\n`);
      }
    }
    try { await transport('quit'); } catch (error) {
      failure ??= error;
      await writeFile(resolve(evidence, 'cleanup-failure.txt'), `${error.message}\n`);
    }
  } else {
    // Never retry an uncertain create POST. Root reconciles this unique build's sessions.
    await writeFile(resolve(evidence, 'unresolved-create.json'), JSON.stringify({ buildName, automaticRetry: false, recoveryRequired: true }, null, 2));
  }
}
if (failure) throw failure;
