import assert from 'node:assert/strict';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
const pidFile = 'evidence/local-parent-pid.txt';
if (!existsSync(pidFile)) process.exit(0);
const parent = Number(readFileSync(pidFile, 'utf8').trim());
const expected = readFileSync('evidence/local-parent-start-ticks.txt', 'utf8').trim();
assert(Number.isInteger(parent) && parent > 1);
function identity(pid) {
  try {
    const raw = readFileSync(`/proc/${pid}/stat`, 'utf8');
    const fields = raw.slice(raw.lastIndexOf(')') + 2).trim().split(/\s+/);
    return {pid, name:raw.slice(raw.indexOf('(') + 1, raw.lastIndexOf(')')), state:fields[0], parent:Number(fields[1]), startTicks:fields[19]};
  } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
const observed = identity(parent);
assert(!observed || observed.startTicks === expected, 'Local tunnel parent PID was reused; refuse signaling');
const owned = [];
function descendants(pid) {
  const item = identity(pid);
  if (!item) return;
  owned.push(item);
  let children;
  try { children = readFileSync(`/proc/${pid}/task/${pid}/children`, 'utf8').trim(); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (children) for (const child of children.split(/\s+/)) {
    const current = identity(Number(child));
    if (current?.parent === pid) descendants(Number(child));
  }
}
descendants(parent);
const receiptPath = 'evidence/local-owned-process-receipt.json';
if (process.argv[2] === 'record') {
  assert(observed, 'Owned Local parent exited before descendant ownership could be recorded');
  writeFileSync(receiptPath, JSON.stringify({parent, expectedStartTicks:expected, recordedUtc:new Date().toISOString(), owned}, null, 2));
  process.exit(0);
}
if (!existsSync(receiptPath)) {
  writeFileSync('evidence/local-process-cleanup.json', JSON.stringify({parent, qualified:false, reason:'Missing readiness descendant receipts; orphaned child termination cannot be established'}, null, 2));
  throw new Error('Owned Local descendant cleanup is unqualified; preserve evidence');
}
const receipt = JSON.parse(readFileSync(receiptPath, 'utf8'));
assert.equal(receipt.parent, parent);
assert.equal(receipt.expectedStartTicks, expected);
for (const item of receipt.owned) if (!owned.some(current => current.pid === item.pid && current.startTicks === item.startTicks)) owned.push(item);
const report = {startedUtc:new Date().toISOString(), parent, expectedStartTicks:expected, ownedBeforeStop:owned, signals:[], final:[]};
const save = () => writeFileSync('evidence/local-process-cleanup.json', JSON.stringify(report, null, 2));
function alive(item) {
  const current = identity(item.pid);
  return current && current.state !== 'Z' && current.state !== 'X';
}
function signal(item, name) {
  const current = identity(item.pid);
  if (!current || current.state === 'Z' || current.state === 'X') return;
  assert.equal(current.startTicks, item.startTicks, 'Owned tunnel PID identity changed; refuse signaling');
  process.kill(item.pid, name);
  report.signals.push({pid:item.pid, signal:name, utc:new Date().toISOString()});
  save();
}
save();
if (observed) signal(observed, 'SIGTERM');
const grace = Date.now() + 10_000;
while (owned.some(alive) && Date.now() < grace) await new Promise(resolve => setTimeout(resolve, 200));
for (const item of owned.slice().reverse()) if (alive(item)) signal(item, 'SIGTERM');
await new Promise(resolve => setTimeout(resolve, 1000));
for (const item of owned.slice().reverse()) if (alive(item)) signal(item, 'SIGKILL');
await new Promise(resolve => setTimeout(resolve, 300));
report.final = owned.map(item => ({owned:item, current:identity(item.pid), stillAlive:Boolean(alive(item))}));
report.completedUtc = new Date().toISOString();
save();
assert(report.final.every(item => !item.stillAlive), 'Owned tunnel cleanup did not reach a terminal process state');
