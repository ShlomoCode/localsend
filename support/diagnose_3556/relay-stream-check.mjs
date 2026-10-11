import http from 'node:http';
import net from 'node:net';
import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { relay } from '../cloud_transport/relay.mjs';

// Synthetic loopback transport checks only; this runner never starts LocalSend.
if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend') {
  throw new Error('This check runs only in the owned ShlomoCode/localsend Actions job');
}
const started = Date.now();
const evidence = { synthetic: true, cases: [], configuredLimits: {}, memory: {}, durationMs: null, success: false };
const memoryStart = process.memoryUsage();
evidence.memory = { startRss: memoryStart.rss, peakRss: memoryStart.rss, startHeapUsed: memoryStart.heapUsed, peakHeapUsed: memoryStart.heapUsed };
const sample = setInterval(() => {
  const m = process.memoryUsage();
  evidence.memory.peakRss = Math.max(evidence.memory.peakRss, m.rss);
  evidence.memory.peakHeapUsed = Math.max(evidence.memory.peakHeapUsed, m.heapUsed);
}, 500);
const delayTimers = new Set();
const requests = new Set(), targetSockets = new Set(), targets = new Map(), expectedOpens = [];
const clientStates = [];
const relays = [], pulls = [];
let stopping = false, watchdog;
const delay = ms => new Promise(resolve => {
  const pending = { resolve, timer: null };
  pending.timer = setTimeout(() => { delayTimers.delete(pending); resolve(); }, ms);
  delayTimers.add(pending);
});
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function assert(value, message) { if (!value) throw new Error(message); }
function check(name, details = {}) { evidence.cases.push({ name, passed: true, ...details }); console.log(`relay synthetic check: ${name}`); }
async function bounded(promise, ms, label) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms); })]); }
  finally { clearTimeout(timer); }
}
async function until(predicate, label) {
  const deadline = Date.now() + 15000;
  while (!predicate()) { assert(!stopping, "Check stopped"); assert(Date.now() < deadline, `${label} timed out`); await delay(20); }
}
const target = net.createServer({ allowHalfOpen: true }, socket => {
  targetSockets.add(socket);
  const id = expectedOpens.shift();
  if (!id) { socket.destroy(); return; }
  const t = { socket, bytes: 0, hash: createHash('sha256'), eof: deferred(), closed: deferred(), digest: null, challenge: randomBytes(24), challengeSent: false };
  targets.set(id, t);
  socket.on('data', data => {
    t.bytes += data.length; t.hash.update(data);
    if (!t.challengeSent) { t.challengeSent = true; socket.write(t.challenge); }
  });
  socket.on('end', () => { t.digest = t.hash.digest('hex'); t.eof.resolve(); socket.end(); });
  socket.on('error', () => {});
  socket.on('close', () => { targetSockets.delete(socket); t.closed.resolve(); });
});
function request(port, token, path, { method = 'GET', body, headers = {}, open = false } = {}) {
  let resolve, reject;
  const state = { port, path, method, startedElapsedMs: performance.now(), responseStatus: null, responseEnded: false, closed: false, error: null };
  const response = new Promise((a, b) => { resolve = a; reject = b; });
  // Aborted requests deliberately reject; attach a handler before any destruction.
  response.catch(() => {});
  const req = http.request({ host: '127.0.0.1', port, method, path, headers: { authorization: `Bearer ${token}`, ...headers } }, res => {
    state.responseStatus = res.statusCode;
    const chunks = [];
    res.on('data', chunk => chunks.push(chunk));
    res.on('error', error => { state.error = error.message; reject(error); });
    res.on('end', () => { state.responseEnded = true; resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }); });
  });
  clientStates.push({ state, req });
  requests.add(req);
  req.on('error', error => { state.error = error.message; reject(error); });
  req.on('close', () => { state.closed = true; requests.delete(req); });
  if (!open) req.end(body);
  return { req, response };
}
async function call(r, path, body, token = r.token) {
  return bounded(request(r.port, token, path, body === undefined ? {} : { method: 'POST', body: JSON.stringify(body), headers: { 'content-type': 'application/json' } }).response, 20000, 'HTTP control');
}
async function openPeer(r, id) {
  expectedOpens.push(id);
  assert((await call(r, '/push', { id, kind: 'open' })).status === 200, 'Owned target open failed');
  assert(targets.has(id), 'Target connection was not captured');
  return targets.get(id);
}
const reverse = new Map();
async function pull(r) {
  while (!stopping) {
    const response = await call(r, '/pull');
    if (stopping) return;
    assert(response.status === 200, 'Reverse pull failed');
    for (const event of JSON.parse(response.body)) {
      if (event.kind === 'data') {
        const key = `${r.port}/${event.id}`;
        reverse.set(key, Buffer.concat([reverse.get(key) ?? Buffer.alloc(0), Buffer.from(event.data, 'base64')]));
      }
    }
  }
}
function upload(r, id, length) {
  return request(r.port, r.token, `/${r.mode === 'stream' ? 'upload' : 'binary'}/${id}`, {
    method: 'POST', open: true,
    headers: { 'content-type': 'application/octet-stream', ...(length === undefined ? {} : { 'content-length': length }) },
  });
}
async function finishAndCheck(r, id, u, bytes, digest) {
  u.req.end();
  const response = await bounded(u.response, 15000, 'Upload completion');
  assert(response.status === 200, 'Upload completion failed');
  const t = targets.get(id);
  if (r.mode === 'coalesced') {
    assert(!t.digest, 'Coalesced batch EOF incorrectly ended target');
    assert((await call(r, '/push', { id, kind: 'eof' })).status === 200, 'Coalesced true EOF failed');
  }
  await bounded(t.eof.promise, 15000, 'Real target readable EOF');
  assert(t.bytes === bytes && t.digest === digest, 'Target byte count or SHA-256 mismatch');
  return { bytes: t.bytes, sha256: t.digest, readableEof: true };
}
async function coalescedBatch(r) {
  const id = "coalesced_batch", t = await openPeer(r, id), payload = randomBytes(8192);
  const u = upload(r, id, payload.length);
  u.req.write(payload.subarray(0, 4096));
  await until(() => t.bytes === 4096, "Coalesced prefix delivery");
  assert(!t.digest, "Partial coalesced request ended target");
  u.req.write(payload.subarray(4096));
  check("coalesced-bounded-batch-and-explicit-tcp-eof", await finishAndCheck(r, id, u, payload.length, createHash("sha256").update(payload).digest("hex")));
}
async function sparse(r) {
  const id = "sparse_stream", t = await openPeer(r, id);
  const chunks = Array.from({ length: 14 }, () => randomBytes(1024));
  const bytes = chunks.reduce((n, chunk) => n + chunk.length, 0);
  const digest = createHash('sha256').update(Buffer.concat(chunks)).digest('hex');
  const u = upload(r, id);
  const begin = performance.now();
  evidence.sparse = { requiredOpenDurationMs: 310000, clock: 'performance.now', checkpointLimit: 600, checkpointsDropped: 0, checkpoints: [] };
  const checkpoint = phase => {
    const state = { phase, openDurationMs: performance.now() - begin, stopping, requestDestroyed: u.req.destroyed,
      requestWritableEnded: u.req.writableEnded, targetBytes: t.bytes, targetReadableEof: t.digest !== null,
      upload: r.owned.status().uploads[id] ?? null };
    if (evidence.sparse.checkpoints.length >= evidence.sparse.checkpointLimit) {
      evidence.sparse.checkpoints.shift(); evidence.sparse.checkpointsDropped++;
    }
    evidence.sparse.checkpoints.push(state);
    return state;
  };
  const waitDeadline = async deadline => {
    const timeout = deadline + 15000;
    while (performance.now() < deadline) {
      const state = checkpoint('waiting-for-deadline');
      assert(!state.stopping, 'Sparse deadline wait stopped');
      assert(!state.requestDestroyed, 'Sparse upload ended during deadline wait');
      assert(performance.now() < timeout, 'Sparse deadline wait exceeded finite allowance');
      await delay(Math.max(1, Math.min(1000, deadline - performance.now())));
    }
    checkpoint('deadline-reached');
    assert(performance.now() < timeout, 'Sparse deadline exceeded finite allowance');
  };
  for (let index = 0; index < chunks.length - 1; index++) {
    await waitDeadline(begin + index * 25000);
    const state = checkpoint('before-sparse-chunk');
    assert(!state.stopping, 'Sparse upload stopped before request EOF');
    assert(!state.requestDestroyed, 'Sparse upload ended before request EOF');
    u.req.write(chunks[index]);
    await until(() => t.bytes >= (index + 1) * 1024, 'Sparse chunk delivery');
    if (index % 2 === 0) console.log(`relay synthetic progress: ${r.mode} ${Math.floor((performance.now() - begin) / 1000)}s`);
  }
  await waitDeadline(begin + 310000);
  const state = checkpoint('before-final-chunk');
  const openDurationMs = state.openDurationMs;
  assert(!state.stopping, 'Sparse check stopped before final chunk');
  assert(openDurationMs >= 310000, 'Request did not remain open beyond Node default 300 seconds');
  assert(!state.requestDestroyed, 'Sparse request destroyed before final chunk');
  assert(!state.requestWritableEnded, 'Sparse client request ended before final chunk');
  assert(state.upload !== null, 'Sparse relay upload state missing before final chunk');
  assert(!state.upload.requestEof, 'Sparse request EOF arrived before the final chunk');
  assert(!state.targetReadableEof, 'Sparse target reached readable EOF before final chunk');
  u.req.write(chunks.at(-1));
  await until(() => t.bytes === bytes, 'Sparse final chunk delivery');
  const received = await finishAndCheck(r, id, u, bytes, digest);
  check("sparse-stream-over-300-seconds", { openDurationMs, chunkIntervalMs: 25000, ...received });
}
async function run() {
  await new Promise((resolve, reject) => { target.once('error', reject); target.listen(15317, '127.0.0.1', resolve); });
  for (const [mode, port] of [['stream', 18080], ['coalesced', 18081]]) {
    const owned = relay({ httpPort: port, reverseTargetPort: 15317, token: randomBytes(24).toString('hex'), transport: mode });
    const r = { owned, port, mode, token: owned.token };
    relays.push(r); await owned.start();
    evidence.configuredLimits[mode] = owned.status().uploadLimits;
    assert(owned.status().uploadLimits.absoluteTimeoutMs === 900000, 'Unexpected absolute upload limit');
    pulls.push(pull(r)); pulls.at(-1).catch(() => {});
  }
  const r = relays[0];
  assert((await call(r, '/status', undefined, 'incorrect')).status === 401, 'Authentication was not enforced');
  const unowned = upload(r, 'unowned'); unowned.req.end();
  assert((await bounded(unowned.response, 15000, 'Unowned peer')).status === 410, 'Unowned upload was not rejected');
  check('auth-401-and-unowned-peer-410');
  const healthy = await openPeer(r, 'healthy');
  const u = upload(r, 'healthy');
  const payload = randomBytes(4096);
  u.req.write(payload.subarray(0, 1024));
  await until(() => healthy.bytes === 1024, 'Streaming prefix before request EOF');
  await until(() => reverse.get(`${r.port}/healthy`)?.equals(healthy.challenge), 'Duplex challenge before request EOF');
  assert(!u.req.writableEnded && !healthy.digest, 'Prefix or challenge waited for request EOF');
  check('stream-prefix-and-duplex-before-http-eof');
  const duplicate = upload(r, 'healthy'); duplicate.req.end(randomBytes(8));
  assert((await bounded(duplicate.response, 15000, 'Duplicate upload')).status === 409, 'Duplicate peer upload was not rejected');
  check('duplicate-peer-409');
  for (const action of ['abort', 'cancel']) {
    const id = `owned_${action}`, t = await openPeer(r, id), disposable = upload(r, id);
    disposable.req.write(randomBytes(128));
    await until(() => t.bytes === 128, 'Disposable upload prefix');
    if (action === 'abort') disposable.req.destroy();
    else assert((await call(r, '/push', { id, kind: 'error' })).status === 200, 'Owned cancellation failed');
    await bounded(t.closed.promise, 15000, 'Owned peer cleanup');
    assert(!healthy.socket.destroyed && !u.req.destroyed, 'Disposing another peer damaged healthy upload');
    check(`${action}-owns-only-its-peer`);
  }
  u.req.write(payload.subarray(1024));
  check('second-peer-healthy-hash', await finishAndCheck(r, 'healthy', u, payload.length, createHash('sha256').update(payload).digest('hex')));
  await coalescedBatch(relays[1]);
  await sparse(relays[0]);
}
let failure;
try {
  await Promise.race([run(), new Promise((_, reject) => { watchdog = setTimeout(() => reject(new Error('Finite 360-second watchdog exceeded')), 360000); })]);
  evidence.success = true;
} catch (error) { failure = error; evidence.error = error.message; }
finally {
  // Snapshot before cleanup destroys requests or alters relay state, on success and failure.
  evidence.stateBeforeCleanup = { stopping, elapsedMs: Date.now() - started,
    clients: clientStates.map(({ state, req }) => ({ ...state, destroyed: req.destroyed, writableEnded: req.writableEnded,
      writableFinished: req.writableFinished, writableLength: req.writableLength })),
    targets: Object.fromEntries([...targets].map(([id, t]) => [id, { bytes: t.bytes, sha256: t.digest,
      destroyed: t.socket.destroyed, readableEnded: t.socket.readableEnded, writableEnded: t.socket.writableEnded }])) };
  evidence.relayStateBeforeCleanup = Object.fromEntries(relays.map(r => [r.mode, r.owned.status()]));
  evidence.uploads = Object.fromEntries(relays.map(r => [r.mode, evidence.relayStateBeforeCleanup[r.mode].uploads]));
  evidence.relayTraceBeforeCleanup = Object.fromEntries(relays.map(r => [r.mode, structuredClone(r.owned.trace)]));
  clearTimeout(watchdog); clearInterval(sample); stopping = true;
  for (const pending of delayTimers) { clearTimeout(pending.timer); pending.resolve(); }
  delayTimers.clear();
  try {
    await bounded((async () => {
      for (const req of requests) req.destroy();
      await Promise.all(relays.map(r => r.owned.stop()));
      for (const socket of targetSockets) socket.destroy();
      if (target.listening) await new Promise(resolve => target.close(resolve));
      await Promise.allSettled(pulls);
    })(), 5000, 'Owned server cleanup');
  } catch (error) { failure ??= error; evidence.success = false; evidence.cleanupError = error.message; }
  evidence.durationMs = Date.now() - started;
  mkdirSync('evidence/windows-transfer', { recursive: true });
  writeFileSync('evidence/windows-transfer/relay-stream-check.json', JSON.stringify(evidence, null, 2));
}
if (failure) { console.error(`relay synthetic check failed: ${failure.message}`); process.exitCode = 1; }
