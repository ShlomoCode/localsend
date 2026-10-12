#!/usr/bin/env node
'use strict';

// Cloud-host-only preparation: never installs, opens, or extracts a package.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { createReadStream } = require('node:fs');
const SNAPSHOT = '20260726T000000Z';
const PREFIX = `/ubuntu/${SNAPSHOT}/`;
const utc = () => new Date().toISOString();
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };
const safeName = value => /^[A-Za-z0-9][A-Za-z0-9.+_~:%-]*\.deb$/.test(value);
// APT QuoteString's filename quoting; hex case is accepted on comparison.
const aptQuote = (value, escaped) => [...value].map(char => escaped.includes(char) ? `%${char.charCodeAt(0).toString(16)}` : char).join('');
const sizeValue = value => {
  if (!/^[1-9][0-9]*$/.test(value) || !Number.isSafeInteger(Number(value))) fail(`Invalid size: ${value}`);
  return Number(value);
};
async function hashFile(file) {
  const hash = crypto.createHash('sha256');
  let bytes = 0;
  for await (const chunk of createReadStream(file)) { bytes += chunk.length; hash.update(chunk); }
  return { bytes, sha256: hash.digest('hex') };
}
function packageRecords(text) {
  const records = new Map();
  for (const paragraph of text.replace(/\r\n/g, '\n').split(/\n[ \t]*\n/)) {
    if (!paragraph.trim()) continue;
    const record = {};
    let field;
    for (const line of paragraph.split('\n')) {
      if (!line) continue;
      if (/^[ \t]/.test(line)) {
        if (!field) fail('Packages continuation without field');
        record[field] += `\n${line}`;
        continue;
      }
      const match = /^([A-Za-z0-9-]+):[ \t]*(.*)$/.exec(line);
      if (!match || Object.hasOwn(record, match[1])) fail('Malformed or duplicate Packages field');
      field = match[1]; record[field] = match[2];
    }
    if (!record.Filename) continue;
    const filename = record.Filename;
    if (!/^pool\/[A-Za-z0-9+_.~\/-]+\.deb$/.test(filename) || filename.split('/').some(part => !part || part === '.' || part === '..')) fail(`Unsafe Packages Filename: ${filename}`);
    if (!/^[a-fA-F0-9]{64}$/.test(record.SHA256 || '')) fail(`Missing SHA256: ${filename}`);
    if (!/^[a-z0-9][a-z0-9+.-]*$/.test(record.Package || '') || !/^[A-Za-z0-9.+:~_-]+$/.test(record.Version || '') || !/^[a-z0-9][a-z0-9.-]*$/.test(record.Architecture || '')) fail(`Invalid package identity: ${filename}`);
    const entry = { filename, size: sizeValue(record.Size || ''), sha256: record.SHA256.toLowerCase(), package: record.Package, version: record.Version, architecture: record.Architecture };
    const previous = records.get(filename);
    if (previous && JSON.stringify(previous) !== JSON.stringify(entry)) fail(`Conflicting Packages records: ${filename}`);
    records.set(filename, entry);
  }
  return records;
}
function manifestFrom(text, records) {
  const byName = new Map();
  const byUri = new Map();
  const byFilename = new Map();
  for (const line of text.replace(/\r\n/g, '\n').split('\n')) {
    // apt prints progress and its proposed transaction before the URI lines.
    if (!line.startsWith("'")) continue;
    const match = /^'([^']+)' ([^\s]+) ([0-9]+) (?:[A-Za-z0-9-]+:[a-fA-F0-9]+)$/.exec(line);
    if (!match) fail(`Malformed apt URI line: ${line}`);
    const [, uri, basename, rawSize] = match;
    if (!safeName(basename)) fail(`Unsafe download basename: ${basename}`);
    const url = new URL(uri);
    if (url.protocol !== 'https:' || url.hostname !== 'snapshot.ubuntu.com' || url.port || url.username || url.password || url.search || url.hash || !uri.startsWith(`https://snapshot.ubuntu.com${PREFIX}`)) fail(`Untrusted URI: ${uri}`);
    let filename;
    try { filename = decodeURIComponent(url.pathname.slice(PREFIX.length)); } catch { fail(`Invalid URI encoding: ${uri}`); }
    // URL normalization must never hide traversal or encoded separators.
    if (url.pathname !== uri.slice('https://snapshot.ubuntu.com'.length) || /%2f|%5c/i.test(uri) || !filename.startsWith('pool/')) fail(`Non-exact URI path: ${uri}`);
    const record = records.get(filename);
    if (!record) fail(`No exact signed Packages record: ${filename}`);
    const size = sizeValue(rawSize);
    if (size !== record.size) fail(`URI/Packages size mismatch: ${basename}`);
    const archiveName = path.posix.basename(filename);
    const aptName = `${aptQuote(record.package, '_:')}_${aptQuote(record.version, '_:')}_${aptQuote(record.architecture, '_:.')}.deb`;
    const normalizedEscapes = value => value.replace(/%[a-fA-F0-9]{2}/g, escape => escape.toLowerCase());
    if (basename !== archiveName && normalizedEscapes(basename) !== aptName) fail(`Download basename does not identify package: ${basename}`);
    const entry = { basename, uri, filename, size, sha256: record.sha256, package: record.package, version: record.version, architecture: record.architecture };
    for (const prior of [byName.get(basename), byUri.get(uri), byFilename.get(filename)]) {
      if (prior && JSON.stringify(prior) !== JSON.stringify(entry)) fail(`Ambiguous URI or basename: ${basename}`);
    }
    byName.set(basename, entry); byUri.set(uri, entry); byFilename.set(filename, entry);
  }
  if (!byName.size) fail('No apt download URI records');
  return [...byName.values()].sort((a, b) => a.basename.localeCompare(b.basename, 'en'));
}
async function download(entry, root) {
  const part = path.join(root, 'partial', `${entry.basename}.part`);
  const receipt = { ...entry, startUtc: utc(), endUtc: null, curlExit: null, signal: null, bytes: null, actualSha256: null, admitted: false };
  const stderr = await fs.open(path.join(root, 'receipts', `${entry.basename}.curl-stderr.txt`), 'wx');
  const response = await fs.open(path.join(root, 'receipts', `${entry.basename}.curl-response.txt`), 'wx');
  try {
    // Ignore .curlrc; disable redirects, proxies and retries. Every URL is the
    // exact apt-resolved signed snapshot object. TLS verification stays on.
    const result = await new Promise(resolve => {
      const child = spawn('curl', ['--disable', '--fail', '--silent', '--show-error', '--proto', '=https', '--noproxy', '*', '--retry', '0', '--connect-timeout', '30', '--max-time', '900', '--max-filesize', String(entry.size), '--dump-header', path.join(root, 'receipts', `${entry.basename}.curl-headers.txt`), '--write-out', 'http_code=%{http_code}\nurl_effective=%{url_effective}\n', '--output', part, '--url', entry.uri], { shell: false, stdio: ['ignore', response.fd, stderr.fd] });
      child.once('error', error => resolve({ code: null, signal: null, error: error.message }));
      child.once('close', (code, signal) => resolve({ code, signal }));
    });
    receipt.curlExit = result.code; receipt.signal = result.signal;
    if (result.error) receipt.error = result.error;
    const responseText = await fs.readFile(path.join(root, 'receipts', `${entry.basename}.curl-response.txt`), 'utf8');
    const responseMatch = /^http_code=([0-9]{3})\nurl_effective=([^\r\n]+)\n$/.exec(responseText);
    const headers = await fs.readFile(path.join(root, 'receipts', `${entry.basename}.curl-headers.txt`), 'utf8');
    const headerLines = headers.split(/\r?\n/);
    const statuses = headerLines.filter(line => /^HTTP\//i.test(line));
    receipt.httpCode = responseMatch?.[1] || null;
    receipt.effectiveUri = responseMatch?.[2] || null;
    receipt.locationPresent = headerLines.some(line => /^location\s*:/i.test(line));
    receipt.directResponseAdmitted = Boolean(responseMatch && receipt.httpCode === '200' && receipt.effectiveUri === entry.uri && !receipt.locationPresent && statuses.length && /^HTTP\/\S+\s+200(?:\s.*)?$/.test(statuses.at(-1)));
    try {
      const actual = await hashFile(part);
      receipt.bytes = actual.bytes; receipt.actualSha256 = actual.sha256;
    } catch (error) { receipt.fileError = error.message; }
    if (result.code === 0 && receipt.directResponseAdmitted && receipt.bytes === entry.size && receipt.actualSha256 === entry.sha256) {
      await fs.rename(part, path.join(root, 'archives', entry.basename));
      receipt.admitted = true;
    } else receipt.error ||= 'curl, direct HTTP200/no-Location/exact-URI, byte count, or SHA256 validation failed';
  } catch (error) { receipt.error = error.message; }
  finally {
    receipt.endUtc = utc();
    await stderr.close();
    await response.close();
    await fs.writeFile(path.join(root, 'receipts', `${entry.basename}.json`), `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
    // Emit only after the retained evidence file has been written. Await stdout
    // completion so each finished worker is observable before the final gate.
    await new Promise((resolve, reject) => {
      process.stdout.write(`${JSON.stringify({ type: 'package-completed', ...receipt })}\n`, error => error ? reject(error) : resolve());
    });
  }
  return receipt;
}
async function main() {
  if (process.platform !== 'linux' || process.env.GITHUB_ACTIONS !== 'true' || process.env.RUNNER_OS !== 'Linux') fail('Only a Linux GitHub Actions cloud host may run this helper');
  const args = process.argv.slice(2);
  const requestedMode = args.shift();
  const mode = requestedMode === 'manifest' ? 'manifest-only' : requestedMode;
  if (!['manifest-only', 'download'].includes(mode) || args.length !== 6) fail('Usage: node 3417-package-cache.cjs manifest|manifest-only|download --uris FILE --packages FILE --output NEW_DIRECTORY');
  const flags = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--uris', '--packages', '--output'].includes(args[i]) || flags[args[i]] || !args[i + 1]) fail('Invalid or duplicate argument');
    flags[args[i]] = args[i + 1];
  }
  if (Object.keys(flags).length !== 3) fail('All input/output flags are required');
  const root = path.resolve(flags['--output']);
  // Exclusive fresh directory: no existing cache, symlinks or mixed run state.
  await fs.mkdir(root, { mode: 0o700 });
  const final = { schemaVersion: 1, mode, snapshot: SNAPSHOT, startedUtc: utc(), endedUtc: null, success: false, concurrency: 8, entries: [], receipts: [] };
  try {
    await fs.mkdir(path.join(root, 'inputs'));
    await fs.mkdir(path.join(root, 'archives'));
    await fs.mkdir(path.join(root, 'partial'));
    await fs.mkdir(path.join(root, 'receipts'));
    const uris = await fs.readFile(flags['--uris']);
    const packages = await fs.readFile(flags['--packages']);
    await fs.writeFile(path.join(root, 'inputs', 'apt-print-uris.txt'), uris, { flag: 'wx' });
    await fs.writeFile(path.join(root, 'inputs', 'Packages.concat'), packages, { flag: 'wx' });
    final.inputs = { uris: { bytes: uris.length, sha256: digest(uris) }, packages: { bytes: packages.length, sha256: digest(packages) } };
    final.entries = manifestFrom(uris.toString('utf8'), packageRecords(packages.toString('utf8')));
    const manifest = {
      schemaVersion: 1, snapshot: SNAPSHOT, inputs: final.inputs, cacheDir: path.join(root, 'archives'),
      files: final.entries.map(entry => ({ filename: entry.basename, sha256: entry.sha256, size: entry.size, uri: entry.uri, indexFilename: entry.filename })),
      entries: final.entries,
    };
    await fs.writeFile(path.join(root, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
    if (mode === 'download') {
      let next = 0;
      const workers = await Promise.allSettled(Array.from({ length: Math.min(8, final.entries.length) }, async () => {
        while (next < final.entries.length) {
          const entry = final.entries[next++];
          final.receipts.push(await download(entry, root));
        }
      }));
      final.receipts.sort((a, b) => a.basename.localeCompare(b.basename, 'en'));
      if (workers.some(worker => worker.status === 'rejected')) fail('Receipt or filesystem failure in download worker');
      if (final.receipts.some(receipt => !receipt.admitted)) fail('One or more packages failed; cache is incomplete');
      await fs.writeFile(path.join(root, 'validated-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
      await fs.writeFile(path.join(root, 'tar-files.txt'), final.entries.map(entry => `archives/${entry.basename}`).join('\n') + '\n', { flag: 'wx' });
    }
    final.success = true;
  } catch (error) { final.error = error.message; process.exitCode = 1; }
  finally {
    final.endedUtc = utc();
    await fs.writeFile(path.join(root, 'final-receipt.json'), `${JSON.stringify(final, null, 2)}\n`, { flag: 'wx' });
    process.stdout.write(`${JSON.stringify({ type: 'cache-completed', output: root, success: final.success, receipt: path.join(root, 'final-receipt.json') })}\n`);
  }
}
main().catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
