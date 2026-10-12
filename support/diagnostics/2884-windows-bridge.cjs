// Cloud-only local evidence receiver and maintained QMP screenshot client.
// The host run invokes this source; do not run it locally.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const [workDir, evidenceDir] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(path.join(workDir, 'config.json'), 'utf8'));
const expectedAuthorization = Buffer.from(`Bearer ${config.bearerToken}`);
const allowedArtifacts = new Set(['windows-identity.json', 'firmware.json', 'feature-before.json',
  'feature-after.json', 'hyperv.json', 'wsl-version.txt', 'wsl-list.txt', 'wsl-command.txt',
  'wsl-proof.json', 'setupact-redacted.txt', 'setuperr-redacted.txt', 'proof-error.json', 'phase.json',
  'cpuid-initial.json', 'cpuid-ordinary.json', 'cpuid-features_reboot_pending.json', 'cpuid-msi_reboot_pending.json',
  'bcd-initial.json', 'bcd-ordinary.json', 'bcd-features_reboot_pending.json', 'bcd-msi_reboot_pending.json',
  'capability-initial.json', 'capability-ordinary.json', 'capability-features_reboot_pending.json', 'capability-msi_reboot_pending.json',
  'ordinary-reboot-control.json', 'windows-volume-identity.json', 'feature-ordinary.json', 'feature-pending.json', 'bcd-enable-auto.json', 'bcd-enable-bootlog.json',
  'enable-VirtualMachinePlatform.json', 'enable-Microsoft-Windows-Subsystem-Linux.json']);
const payloads = new Map([['/payload/wsl.msi', 'wsl.msi'], ['/payload/ubuntu.wsl', 'ubuntu.wsl'], ['/payload/cpuid.exe', 'cpuid.exe']]);
const logPath = path.join(evidenceDir, 'bridge.jsonl');
const log = (value) => fs.appendFileSync(logPath, `${JSON.stringify({ utc: new Date().toISOString(), ...value })}\n`);
const redact = (text) => text.split(config.bearerToken).join('<REDACTED>').split(config.localPassword).join('<REDACTED>');
let stopping = false;
let screenshotBusy = false;
let screenshotIndex = 0;
let repairDetected = false;
// The exact original 1280x800 native PPM was visually verified as Automatic
// Repair in run 38205207093. A match is an observation, never a repair action.
const automaticRepairPpmSha256 = '86e3a3cb9fe0883f3dd22946a78ce2bf4f58d9065f990ba1453f0ae195dfd74b';
function authorized(request) {
  const provided = Buffer.from(request.headers.authorization || '');
  return provided.length === expectedAuthorization.length && crypto.timingSafeEqual(provided, expectedAuthorization);
}
function receive(request, response, filename, isResult) {
  let size = 0;
  const chunks = [];
  request.on('data', (chunk) => {
    size += chunk.length;
    if (size > 8 * 1024 * 1024) { response.writeHead(413).end(); request.destroy(); return; }
    chunks.push(chunk);
  });
  request.on('error', (error) => log({ kind: 'request-error', filename, detail: String(error) }));
  request.on('end', () => {
    if (size > 8 * 1024 * 1024) return;
    const text = redact(Buffer.concat(chunks).toString('utf8'));
    if (isResult) {
      let result;
      try { result = JSON.parse(text); } catch { response.writeHead(400).end(); return; }
      if (!['PASS', 'FAIL'].includes(result.status) || typeof result.stage !== 'string' ||
          (result.status === 'PASS' && result.stage !== 'actual_wsl2_execution')) {
        response.writeHead(400).end(); return;
      }
      // A final result is immutable, including failure. No retry can overwrite it.
      if (fs.existsSync(path.join(evidenceDir, filename))) { response.writeHead(409).end(); return; }
    }
    fs.writeFileSync(path.join(evidenceDir, filename), text);
    log({ kind: 'artifact-received', filename, bytes: size });
    response.writeHead(200, { 'Content-Type': 'text/plain' }).end('saved');
  });
}
const server = http.createServer((request, response) => {
  if (!authorized(request)) { response.writeHead(403).end(); return; }
  if (request.method === 'GET' && payloads.has(request.url)) {
    const file = path.join(workDir, 'payload', payloads.get(request.url));
    response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': fs.statSync(file).size });
    const stream = fs.createReadStream(file);
    stream.on('error', (error) => { log({ kind: 'payload-error', detail: String(error) }); response.destroy(); });
    stream.pipe(response);
    return;
  }
  if (request.method === 'POST' && request.url === '/result') { receive(request, response, 'result.json', true); return; }
  const match = /^\/artifact\/([^/]+)$/.exec(request.url || '');
  if (request.method === 'POST' && match && allowedArtifacts.has(match[1])) {
    receive(request, response, match[1], false); return;
  }
  response.writeHead(404).end();
});
server.requestTimeout = 240000;
server.headersTimeout = 10000;
server.on('error', (error) => { log({ kind: 'server-error', detail: String(error) }); process.exit(2); });
server.listen(8765, '127.0.0.1', () => {
  log({ kind: 'listening', address: '127.0.0.1', port: 8765 });
  fs.writeFileSync(path.join(workDir, 'bridge-ready'), 'ready\n');
});
function qmp(command, args) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port: 8766 });
    let buffer = '';
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('QMP ten-second deadline')); }, 10000);
    const end = (error, result) => {
      clearTimeout(timer); socket.destroy();
      if (error) reject(error); else resolve(result);
    };
    socket.on('error', (error) => end(error));
    socket.on('end', () => end(new Error('QMP connection ended before reply')));
    socket.on('data', (data) => {
      buffer += data.toString('utf8');
      if (buffer.length > 1024 * 1024) { end(new Error('QMP buffer limit')); return; }
      let newline;
      while ((newline = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch { end(new Error('Malformed QMP JSON')); return; }
        if (message.QMP) socket.write(`${JSON.stringify({ execute: 'qmp_capabilities', id: 'caps' })}\n`);
        else if (message.id === 'caps') {
          if (message.error) { end(new Error(JSON.stringify(message.error))); return; }
          socket.write(`${JSON.stringify({ execute: command, arguments: args || {}, id: 'command' })}\n`);
        } else if (message.id === 'command') {
          if (message.error) end(new Error(JSON.stringify(message.error))); else end(null, message.return);
          return;
        }
      }
    });
  });
}
async function screenshot() {
  if (stopping || screenshotBusy) return;
  screenshotBusy = true;
  const started = new Date().toISOString();
  const ordinal = ++screenshotIndex;
  const basename = `screen-${String(ordinal).padStart(4, '0')}`;
  try {
    const status = await qmp('query-status');
    const ppm = path.join(evidenceDir, `${basename}.ppm`);
    await qmp('screendump', { filename: ppm });
    const conversion = spawnSync('/usr/bin/ffmpeg', ['-v', 'error', '-y', '-i', ppm, path.join(evidenceDir, `${basename}.png`)], { timeout: 10000 });
    log({ kind: 'screenshot', ordinal, captureStartedUtc: started, captureFinishedUtc: new Date().toISOString(),
      qemuStatus: status, nativeFile: `${basename}.ppm`, pngCreated: conversion.status === 0 });
    const captureHash = crypto.createHash('sha256').update(fs.readFileSync(ppm)).digest('hex');
    if (!repairDetected && captureHash === automaticRepairPpmSha256) {
      repairDetected = true;
      const observation = { stage: 'native_AutomaticRepair_observed', utc: new Date().toISOString(),
        nativeFile: `${basename}.ppm`, sha256: captureHash, qemuStatus: status,
        response: 'Stop this owned VM for bounded read-only boot diagnostics; do not repair or resume.' };
      fs.writeFileSync(path.join(evidenceDir, 'recovery-observed.json'), JSON.stringify(observation, null, 2));
      log({ kind: 'AutomaticRepair-observed', ...observation });
      try { await qmp('quit'); }
      catch (error) { log({ kind: 'owned-QMP-quit-reply', detail: String(error) }); }
    }
  } catch (error) { log({ kind: 'screenshot-error', ordinal, captureStartedUtc: started, detail: String(error) }); }
  finally { screenshotBusy = false; }
}
const screenshotTimer = setInterval(screenshot, 60000);
setTimeout(screenshot, 2000);
// Normal Windows DVD "press any key" input, confined to the initial boot.
// Do not inject input after reboots or into the installed desktop.
async function initialDvdBoot() {
  // The bridge may become ready before QEMU starts. Anchor input to the owned
  // QEMU's first successful status reply, rather than the bridge process clock.
  const readinessDeadline = Date.now() + 30000;
  for (let attempt = 1; attempt <= 30 && !stopping && Date.now() < readinessDeadline; attempt++) {
    try {
      await qmp('query-status');
      if (stopping || Date.now() >= readinessDeadline) break;
      log({ kind: 'initial-DVD-QMP-ready', attempt });
      for (const delay of [5000, 7000, 9000]) {
        setTimeout(async () => {
          if (stopping) return;
          try {
            await qmp('send-key', { keys: [{ type: 'qcode', data: 'ret' }], 'hold-time': 100 });
            log({ kind: 'initial-DVD-boot-key', key: 'ret', elapsedAfterQmpReadyMilliseconds: delay });
          } catch (error) { log({ kind: 'initial-DVD-boot-key-error', elapsedAfterQmpReadyMilliseconds: delay, detail: String(error) }); }
        }, delay);
      }
      return;
    } catch (error) {
      log({ kind: 'initial-DVD-QMP-wait', attempt, detail: String(error) });
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  if (!stopping) log({ kind: 'initial-DVD-QMP-unavailable' });
}
initialDvdBoot();
function stop() {
  stopping = true; clearInterval(screenshotTimer);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000);
}
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
