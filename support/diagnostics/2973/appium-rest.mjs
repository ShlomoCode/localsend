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
  if (mode === 'snapshot') {
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
    await request('DELETE', prefix + '/actions');
  } else if (mode === 'quit') {
    await request('DELETE', prefix);
    await writeFile(resolve(evidence, 'ended-session.json'), JSON.stringify({ sessionId, endedAt: new Date().toISOString() }, null, 2));
  } else {
    throw new Error('Supported modes: create, snapshot, tap, swipe, quit');
  }
}
