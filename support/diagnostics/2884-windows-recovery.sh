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
  const manifestFile = bounded('manifest.json', 16384);
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
  const statusText = redact(JSON.stringify(status));
  if (Buffer.byteLength(statusText) > 16384) throw new Error('published metadata exceeded 16 KiB');
  publish('status.json', statusText);
} catch {
  publish('status.json', JSON.stringify({ status: 'UNAVAILABLE', workerExitCode: Number(exitCode), readOnly: true,
    diskRetained: false, dumpBytesRetained: false, wslCapabilityInferred: false,
    reason: 'Worker metadata, exact-secret redaction, or bounded publication unavailable; no raw text published' }));
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
node - "$work_dir" "$raw_dir" "$evidence_dir" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const [work, raw, evidence] = process.argv.slice(2);
const manifest = { status: 'UNAVAILABLE', partition: null, selection: 'native_GPT_guid_geometry_type_match', logs: [] };
function saveManifest() {
  const text = JSON.stringify(manifest);
  if (Buffer.byteLength(text) > 16384) throw new Error('offline metadata exceeded 16 KiB');
  fs.writeFileSync(path.join(raw, 'manifest.json'), text);
}
function guid(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.startsWith('{') && value.endsWith('}') ? value.slice(1, -1) : value;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(normalized)
    ? normalized.toLowerCase() : null;
}
function decimal(value) {
  return typeof value === 'string' && /^(0|[1-9]\d{0,19})$/.test(value) ? value : null;
}
function nativeTarget() {
  const filename = path.join(evidence, 'windows-volume-identity.json');
  const fd = fs.openSync(filename, 'r');
  let snapshot;
  try {
    const size = fs.fstatSync(fd).size;
    if (size < 1 || size > 16384) throw new Error('native snapshot size outside bounds');
    const bytes = Buffer.alloc(size);
    if (fs.readSync(fd, bytes, 0, size, 0) !== size) throw new Error('incomplete native snapshot read');
    snapshot = JSON.parse(bytes.toString('utf8'));
  } finally { fs.closeSync(fd); }
  const target = snapshot.partition;
  if (snapshot.schemaVersion !== 1 || snapshot.status !== 'AVAILABLE' || !target || target.diskNumber !== 0 ||
      !Array.isArray(snapshot.partitions) || snapshot.partitions.length < 1 || snapshot.partitions.length > 8 ||
      !snapshot.bitLockerStatus || typeof snapshot.bitLockerStatus !== 'object' || Array.isArray(snapshot.bitLockerStatus) ||
      !Number.isInteger(target.partitionNumber) || target.partitionNumber < 1 || target.partitionNumber > 128 ||
      !guid(target.guid) || !guid(target.gptType) || !decimal(target.offsetBytes) || !decimal(target.sizeBytes) ||
      BigInt(target.sizeBytes) === 0n || !/^[A-Z]:$/i.test(snapshot.systemDrive || '') ||
      typeof snapshot.windowsDirectory !== 'string' || typeof snapshot.systemDirectory !== 'string' ||
      snapshot.windowsDirectory.toLowerCase() !== `${snapshot.systemDrive}\\Windows`.toLowerCase() ||
      snapshot.systemDirectory.toLowerCase() !== `${snapshot.systemDrive}\\Windows\\System32`.toLowerCase()) {
    throw new Error('native Windows volume snapshot unavailable or incomplete');
  }
  return { systemDrive: snapshot.systemDrive, windowsDirectory: snapshot.windowsDirectory,
    systemDirectory: snapshot.systemDirectory, partition: { diskNumber: 0, partitionNumber: target.partitionNumber,
      guid: guid(target.guid), gptType: guid(target.gptType), offsetBytes: target.offsetBytes, sizeBytes: target.sizeBytes },
    measurementPhase: 'before_features', bitLockerStateInferred: false };
}
function partitionTable(text, devices) {
  if (text.length > 4096) throw new Error('partition table exceeded bounds');
  const pattern = /\[(\d+)\] = \{\n  part_num: (\d+)\n  part_start: (\d+)\n  part_end: (\d+)\n  part_size: (\d+)\n\}/g;
  const matches = [...text.matchAll(pattern)];
  if (matches.length !== devices.length || text.replace(pattern, '').trim()) throw new Error('unexpected partition table format');
  const entries = matches.map((entry, index) => {
    const number = Number(entry[2]);
    const [offsetBytes, endBytes, sizeBytes] = entry.slice(3, 6);
    if (Number(entry[1]) !== index || !Number.isInteger(number) || number < 1 || number > 128 ||
        !decimal(offsetBytes) || !decimal(endBytes) || !decimal(sizeBytes) || BigInt(sizeBytes) === 0n ||
        BigInt(endBytes) < BigInt(offsetBytes) || BigInt(endBytes) - BigInt(offsetBytes) + 1n !== BigInt(sizeBytes) ||
        !devices.includes(`/dev/sda${number}`)) throw new Error('inconsistent partition geometry');
    return { device: `/dev/sda${number}`, partitionNumber: number, offsetBytes, endBytes, sizeBytes };
  });
  if (new Set(entries.map(entry => entry.device)).size !== entries.length) throw new Error('duplicate partition geometry');
  return entries;
}
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
async function directoryPresence(requested) {
  const original = await command(`is-dir ${quote(requested)} followsymlinks:false`, true);
  const entry = { requested, originalIsDirectory: original === 'true' ? true : original === 'false' ? false : null };
  const resolvedText = await command(`case-sensitive-path ${quote(requested)}`, true);
  const resolved = resolvedText.startsWith('/') ? resolvedText : '/' + resolvedText;
  if (resolved.toLowerCase() === requested.toLowerCase()) {
    entry.resolved = resolved;
    const exists = await command(`is-dir ${quote(resolved)} followsymlinks:false`, true);
    entry.resolvedIsDirectory = exists === 'true' ? true : exists === 'false' ? false : null;
  } else entry.resolution = 'UNAVAILABLE_OR_UNEXPECTED';
  return entry;
}
(async () => {
  try {
    manifest.native = nativeTarget();
    saveManifest();
    // Keep direct-backend QEMU and its recovery helper in our timeout group.
    await command('set-pgroup false');
    await command('run');
    const inventory = await command('list-partitions');
    if (inventory.length > 4096) throw new Error('owned partition inventory exceeded bounds');
    manifest.partitionDevices = inventory.split('\n');
    saveManifest();
    const devices = manifest.partitionDevices;
    if (devices.length < 1 || devices.length > 8 || devices.some(device => !/^\/dev\/sda[1-9]\d{0,2}$/.test(device)) ||
        new Set(devices).size !== devices.length) throw new Error('unexpected, duplicate, or excessive owned partitions');
    manifest.partitionTable = await command('part-list /dev/sda');
    saveManifest();
    manifest.partitions = partitionTable(manifest.partitionTable, devices);
    for (const entry of manifest.partitions) {
      const probe = async text => {
        const value = await command(text, true);
        if (value.length > 256) throw new Error('partition metadata field exceeded bounds');
        return value;
      };
      entry.vfsType = await probe(`vfs-type ${entry.device}`);
      entry.label = await probe(`vfs-label ${entry.device}`);
      entry.labelState = entry.label ? 'REPORTED' : 'EMPTY_OR_UNAVAILABLE';
      entry.guid = await probe(`part-get-gpt-guid /dev/sda ${entry.partitionNumber}`);
      entry.gptType = await probe(`part-get-gpt-type /dev/sda ${entry.partitionNumber}`);
      saveManifest();
    }
    if (manifest.partitions.some(entry => !guid(entry.guid) || !guid(entry.gptType))) {
      throw new Error('owned GPT inventory identity unavailable');
    }
    const target = manifest.native.partition;
    manifest.comparisons = manifest.partitions.map(entry => ({ device: entry.device,
      guidMatches: guid(entry.guid) === target.guid, offsetMatches: entry.offsetBytes === target.offsetBytes,
      sizeMatches: entry.sizeBytes === target.sizeBytes, gptTypeMatches: guid(entry.gptType) === target.gptType,
      partitionNumberMatches: entry.partitionNumber === target.partitionNumber }));
    saveManifest();
    const matches = manifest.comparisons.filter(entry => entry.guidMatches && entry.offsetMatches && entry.sizeMatches && entry.gptTypeMatches);
    if (matches.length !== 1) throw new Error('native Windows partition correspondence unavailable or ambiguous');
    manifest.partition = matches[0].device;
    saveManifest();
    if (manifest.partitions.find(entry => entry.device === manifest.partition).vfsType !== 'ntfs') {
      throw new Error('matched native Windows partition is not readable as NTFS');
    }
    await command(`mount-ro ${manifest.partition} /`);
    manifest.mount = 'READ_ONLY_MOUNT_COMPLETED';
    manifest.rootPresence = [];
    for (const requested of ['/Windows', '/Users', '/Program Files', '/Recovery']) {
      manifest.rootPresence.push(await directoryPresence(requested));
      saveManifest();
    }
    const windows = manifest.rootPresence.find(entry => entry.requested === '/Windows');
    if (windows.resolvedIsDirectory !== true) throw new Error('matched Windows directory unavailable');
    manifest.windowsDirectory = windows.resolved;
    manifest.system32Presence = await directoryPresence(windows.resolved + '/System32');
    saveManifest();
    for (const [name, filename] of [
      ['SrtTrail.txt', `${windows.resolved}/System32/LogFiles/Srt/SrtTrail.txt`],
      ['CBS.log', `${windows.resolved}/Logs/CBS/CBS.log`],
      ['dism.log', `${windows.resolved}/Logs/DISM/dism.log`],
      ['ntbtlog.txt', `${windows.resolved}/ntbtlog.txt`],
    ]) {
      const entry = { name, path: filename, status: 'UNAVAILABLE' };
      manifest.logs.push(entry);
      const resolvedText = await command(`case-sensitive-path ${quote(filename)}`, true);
      const resolved = resolvedText.startsWith('/') ? resolvedText : '/' + resolvedText;
      if (resolved.toLowerCase() !== filename.toLowerCase()) continue;
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
      saveManifest();
    }
    manifest.status = 'COLLECTION_FINISHED';
  } catch (error) {
    manifest.reason = String(error.message).slice(0, 256);
    diagnostic(`recovery unavailable: ${manifest.reason}\n`);
  }
  finally {
    try { saveManifest(); } catch { diagnostic('final metadata exceeded bounds; prior bounded metadata retained\n'); }
    if (!closed) guest.stdin.end('exit\n');
    // Appliance shutdown is covered by the enclosing owned process-group bound.
  }
})();
JS
