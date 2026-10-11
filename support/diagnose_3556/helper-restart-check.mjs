import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { mkdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { relay } from '../cloud_transport/relay.mjs';

// Runner-only component evidence; no application or Android service is started.
assert.equal(process.env.GITHUB_ACTIONS, 'true');
assert.equal(process.env.GITHUB_REPOSITORY, 'ShlomoCode/localsend');
assert(process.env.NEGATIVE_RELAY_SOURCE, 'The immutable old relay source is required');
const old = await import(pathToFileURL(process.env.NEGATIVE_RELAY_SOURCE).href);
const evidence = { componentOnly: true, negativeHead: 'a3c81bb623aaa1e4906b2788863c4298780da5ce', cases: [] };
const requests = new Set();
function saveEvidence() {
  mkdirSync('evidence', { recursive: true });
  writeFileSync('evidence/helper-restart-check.json', JSON.stringify(evidence, null, 2));
}
const watchdog = setTimeout(() => {
  evidence.error = 'Component restart check exceeded its 20-second hard deadline';
  saveEvidence();
  process.exit(1);
}, 20000);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) {
  const end = Date.now() + 3000;
  while (!predicate()) { assert(Date.now() < end, 'State observation deadline'); await delay(10); }
}
function pull(port, token) {
  let ended = false;
  const promise = new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/pull', headers: { authorization: `Bearer ${token}` } }, res => {
      const chunks = [];
      res.on('data', data => chunks.push(data));
      res.on('error', reject);
      res.on('end', () => { ended = true; resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }); });
    });
    requests.add(req);
    req.on('close', () => requests.delete(req));
    req.on('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('Bounded poll deadline')));
  });
  promise.catch(() => {});
  return { promise, ended: () => ended };
}
async function check(factory, port, candidate) {
  const r = factory({ httpPort: port, tcpPort: port + 1, transport: 'coalesced' });
  let socket;
  try {
    await r.start();
    // No Android disconnect reaches the relay: the tunnel still holds the old HTTP request.
    const first = pull(port, r.token);
    await delay(100);
    assert.equal(first.ended(), false);
    if (candidate) assert.equal(r.status().pendingPull, true);
    r.closePeers('Observed retired helper');
    r.setPeerLimit(90 * 60000);
    if (!candidate) {
      const rejected = await pull(port, r.token).promise;
      assert.equal(rejected.status, 409);
      assert.equal(first.ended(), false);
      evidence.cases.push({ name: 'old restart rejects fresh pull while tunnel retains retired request', status: rejected.status });
      return;
    }
    r.retireStoppedHelper('Observed stopped helper and empty owned peers');
    const fresh = pull(port, r.token);
    assert.deepEqual(await first.promise, { status: 200, body: '[]' });
    await until(() => r.status().pendingPull);
    // Old response cleanup must not clear the fresh waiter, and ordinary concurrent pulls remain rejected.
    const concurrent = await pull(port, r.token).promise;
    assert.equal(concurrent.status, 409);
    assert.equal(fresh.ended(), false);
    r.retireStoppedHelper('Component fresh helper stopped');
    assert.deepEqual(await fresh.promise, { status: 200, body: '[]' });
    socket = net.connect(port + 1, '127.0.0.1');
    await until(() => r.status().peers === 1);
    assert.throws(() => r.retireStoppedHelper('Invalid live helper reset'), /empty owned peers/);
    socket.destroy();
    await until(() => r.status().peers === 0);
    r.retireStoppedHelper('Component cleanup');
    assert.equal(r.status().queued, 0);
    assert.equal(r.status().pendingPull, false);
    evidence.cases.push({ name: 'candidate releases retired poll, admits fresh poll and preserves concurrent/live-peer guards', passed: true, trace: r.trace });
  } finally { socket?.destroy(); await r.stop(); }
}
try {
  await check(old.relay, 18086, false);
  await check(relay, 18088, true);
  evidence.success = true;
} finally {
  clearTimeout(watchdog);
  for (const req of requests) req.destroy();
  saveEvidence();
}
console.log('Helper restart pending-poll negative control and candidate passed (component evidence only).');
