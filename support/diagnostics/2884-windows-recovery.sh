#!/bin/bash
# Cloud-only, stopped-disk evidence collection. Never repairs or boots Windows.
set -uo pipefail
umask 077
work_dir=$1
evidence_dir=$2
raw_dir="$work_dir/offline-recovery-raw"
mkdir -p "$raw_dir" "$evidence_dir/offline-recovery"
# This directory receives sanitized outputs only; private input stays in work_dir.
chmod 0755 "$evidence_dir/offline-recovery"
if [ "${3:-}" != --worker ]; then
  # timeout creates its own process group; keep its PID for descendant cleanup.
  # 210+5 worker, <=5 group cleanup, <=6 publication: 14s remain before host TERM.
  /usr/bin/timeout --signal=TERM --kill-after=5s 210s bash "$0" "$work_dir" "$evidence_dir" --worker &
  recovery_pid=$!
  wait "$recovery_pid"
  recovery_status=$?
  kill -TERM -- "-$recovery_pid" 2>/dev/null || true
  for attempt in 1 2 3 4 5; do
    if ! kill -0 -- "-$recovery_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  kill -KILL -- "-$recovery_pid" 2>/dev/null || true
  # Publish only after the worker/appliance have stopped. Raw data stays private.
  /usr/bin/timeout --signal=TERM --kill-after=1s 5s node - "$work_dir" "$evidence_dir" "$recovery_status" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const [work, evidence, exitCode] = process.argv.slice(2);
const raw = path.join(work, 'offline-recovery-raw');
const out = path.join(evidence, 'offline-recovery');
const publish = (name, value) => {
  const filename = path.join(out, name);
  fs.writeFileSync(filename, value);
  fs.chmodSync(filename, 0o644);
};
const status = { status: 'UNAVAILABLE', workerExitCode: Number(exitCode), readOnly: true,
  diskRetained: false, dumpBytesRetained: false, wslCapabilityInferred: false };
// Fail closed: without both exact random secrets, retain no worker text.
try {
  const config = JSON.parse(fs.readFileSync(path.join(work, 'config.json'), 'utf8'));
  const secrets = [config.bearerToken, config.localPassword];
  if (secrets.some(s => typeof s !== 'string' || s.length < 20)) throw new Error('redaction unavailable');
  const redact = text => secrets.reduce((value, secret) => value.split(secret).join('[REDACTED]'), text);
  const bounded = (name, maximum) => {
    const filename = path.join(raw, name);
    if (!fs.existsSync(filename)) return null;
    const fd = fs.openSync(filename, 'r');
    try {
      const size = fs.fstatSync(fd).size;
      const buffer = Buffer.alloc(Math.min(size, maximum));
      const read = fs.readSync(fd, buffer, 0, buffer.length, 0);
      return { bytes: buffer.subarray(0, read), size, truncated: size > maximum };
    } finally { fs.closeSync(fd); }
  };
  const manifestFile = bounded('manifest.json', 65536);
  const manifest = manifestFile && !manifestFile.truncated ? JSON.parse(manifestFile.bytes.toString('utf8')) : null;
  const names = ['SrtTrail.txt', 'CBS.log', 'dism.log', 'ntbtlog.txt'];
  const entries = [];
  for (const name of names) {
    const sample = bounded(name, 262144);
    const metadata = manifest?.logs?.find(entry => entry.name === name);
    if (!sample || !metadata || metadata.status !== 'COLLECTED' || sample.size !== metadata.sampleBytes || sample.truncated) {
      entries.push({ name, status: 'UNAVAILABLE_OR_INCOMPLETE' });
      continue;
    }
    const bytes = sample.bytes;
    // Windows logs may be UTF-16LE. Preserve readable text, never binary bytes.
    const utf16 = (bytes[0] === 0xff && bytes[1] === 0xfe) ||
      (bytes.length > 4 && bytes[1] === 0 && bytes[3] === 0);
    const text = bytes.toString(utf16 ? 'utf16le' : 'utf8').replace(/^\uFEFF/, '');
    const sanitized = redact(text);
    const output = Buffer.from(sanitized, 'utf8');
    // UTF-8 conversion can expand invalid bytes; artifact remains <=256KiB.
    publish(name, output.subarray(0, 262144));
    entries.push({ ...metadata, encoding: utf16 ? 'utf16le' : 'utf8',
      publishedBytes: Math.min(output.length, 262144), publicationTruncated: output.length > 262144,
      fullOriginalHash: 'NOT_COMPUTED_TO_AVOID_UNBOUNDED_READ' });
  }
  const driver = bounded('driver.txt', 65536);
  if (driver) publish('driver.txt', redact(driver.bytes.toString('utf8')));
  status.logs = entries;
  status.worker = manifest;
  status.status = entries.some(entry => entry.status === 'COLLECTED') ? 'PARTIAL_EVIDENCE' : 'UNAVAILABLE';
  publish('status.json', redact(JSON.stringify(status, null, 2)));
} catch {
  status.reason = 'Worker evidence or exact-secret redaction unavailable; no raw text published';
  publish('status.json', JSON.stringify(status, null, 2));
}
JS
  publication_status=$?
  if [ "$publication_status" -ne 0 ]; then
    printf '{"status":"UNAVAILABLE","reason":"publication_failed","workerExitCode":%s,"wslCapabilityInferred":false}\n' "$recovery_status" > "$evidence_dir/offline-recovery/status.json"
    chmod 0644 "$evidence_dir/offline-recovery/status.json"
  fi
  rm -rf -- "$raw_dir" "$work_dir/guestfs-cache" "$work_dir/guestfs-tmp"
  printf '2884_OFFLINE_RECOVERY worker_rc=%s publication_rc=%s WSL_inference=false\n' "$recovery_status" "$publication_status"
  # Supplementary collection never replaces the host's primary failure code.
  exit 0
fi

export LIBGUESTFS_BACKEND=direct
export LIBGUESTFS_BACKEND_SETTINGS=force_kvm
export LIBGUESTFS_CACHEDIR="$work_dir/guestfs-cache"
export LIBGUESTFS_TMPDIR="$work_dir/guestfs-tmp"
mkdir -p "$LIBGUESTFS_CACHEDIR" "$LIBGUESTFS_TMPDIR"
node - "$work_dir" "$raw_dir" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const [work, raw] = process.argv.slice(2);
const manifest = { status: 'UNAVAILABLE', partition: '/dev/sda3', selection: 'owned_unattend_GPT_partition_3', logs: [] };
const driver = fs.openSync(path.join(raw, 'driver.txt'), 'w');
let diagnosticBytes = 0;
function diagnostic(value) {
  const bytes = Buffer.from(value);
  const bounded = bytes.subarray(0, Math.max(0, 65536 - diagnosticBytes));
  fs.writeSync(driver, bounded); diagnosticBytes += bounded.length;
}
const guest = spawn('guestfish', ['--ro', '--format=qcow2', '-a', path.join(work, 'windows.qcow2')],
  { stdio: ['pipe', 'pipe', 'pipe'] });
let pending;
let response = '';
let sequence = 0;
let closed = false;
guest.stderr.on('data', chunk => diagnostic(chunk));
guest.stdout.on('data', chunk => {
  response += chunk.toString('utf8');
  if (response.length > 65536) { pending?.reject(new Error('command output exceeded bound')); pending = null; guest.kill(); return; }
  const markerMatch = pending && response.match(new RegExp(`(?:^|\\n)${pending.marker}\\n`));
  if (pending && markerMatch) {
    const current = pending; pending = null;
    const output = response.slice(0, markerMatch.index).trim();
    response = ''; diagnostic(output + '\n'); current.resolve(output);
  }
});
guest.on('error', error => { closed = true; pending?.reject(error); pending = null; });
guest.on('close', code => { closed = true; pending?.reject(new Error(`guestfish exited ${code}`)); pending = null; });
guest.stdin.on('error', error => { pending?.reject(error); pending = null; });
function command(text, tolerateMissing = false) {
  if (closed) return Promise.reject(new Error('guestfish is closed'));
  const marker = `ISSUE2884_GUESTFISH_COMMAND_${++sequence}`;
  return new Promise((resolve, reject) => {
    pending = { marker, resolve, reject };
    // '-' is guestfish's documented continue-on-error prefix. Only probes use it.
    guest.stdin.write(`${tolerateMissing ? '-' : ''}${text}\necho ${marker}\n`);
  });
}
const quote = value => JSON.stringify(value);
(async () => {
  try {
    // Keep direct-backend QEMU and its recovery helper in our timeout group.
    await command('set-pgroup false');
    await command('run');
    manifest.filesystems = await command('list-filesystems');
    if (!/^\/dev\/sda3:\s+ntfs\s*$/m.test(manifest.filesystems)) throw new Error('owned partition is not NTFS');
    await command('mount-ro /dev/sda3 /');
    if (await command('is-dir /Windows') !== 'true') throw new Error('owned Windows directory unavailable');
    for (const [name, filename] of [
      ['SrtTrail.txt', '/Windows/System32/LogFiles/Srt/SrtTrail.txt'],
      ['CBS.log', '/Windows/Logs/CBS/CBS.log'],
      ['dism.log', '/Windows/Logs/DISM/dism.log'],
      ['ntbtlog.txt', '/Windows/ntbtlog.txt'],
    ]) {
      const entry = { name, path: filename, status: 'UNAVAILABLE' };
      manifest.logs.push(entry);
      const resolvedText = await command(`case-sensitive-path ${quote(filename)}`, true);
      if (!/^\/?Windows\//i.test(resolvedText)) continue;
      const resolved = resolvedText.startsWith('/') ? resolvedText : '/' + resolvedText;
      if (await command(`is-file ${quote(resolved)} followsymlinks:false`, true) !== 'true') continue;
      const sizeText = await command(`filesize ${quote(resolved)}`, true);
      if (!/^\d+$/.test(sizeText)) continue;
      const size = Number(sizeText);
      if (!Number.isSafeInteger(size)) continue;
      const bytes = Math.min(size, 262144);
      const offset = size - bytes;
      const destination = path.join(raw, name);
      if (bytes) await command(`download-offset ${quote(resolved)} ${quote(destination)} ${offset} ${bytes}`);
      else fs.writeFileSync(destination, '');
      const sample = fs.readFileSync(destination);
      if (sample.length !== bytes) throw new Error('short bounded read');
      Object.assign(entry, { status: 'COLLECTED', originalBytes: size, offset, sampleBytes: bytes,
        truncated: offset > 0, sampleSha256: crypto.createHash('sha256').update(sample).digest('hex') });
      fs.writeFileSync(path.join(raw, 'manifest.json'), JSON.stringify(manifest));
    }
    manifest.status = 'COLLECTION_FINISHED';
  } catch (error) { diagnostic(`recovery unavailable: ${error.message}\n`); }
  finally {
    fs.writeFileSync(path.join(raw, 'manifest.json'), JSON.stringify(manifest));
    if (!closed) guest.stdin.end('exit\n');
    // Appliance shutdown is covered by the enclosing owned process-group bound.
  }
})();
JS
