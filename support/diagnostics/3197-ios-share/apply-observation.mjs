import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = process.argv[2];
if (!packageDirectory) throw new Error('Pass the resolved share_handler_ios-0.0.15 package directory.');
const manifest = JSON.parse(fs.readFileSync(path.join(here, 'manifest.json'), 'utf8'));
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const patch = fs.readFileSync(path.join(here, 'share-handler-observation.patch'));
if (hash(patch) !== manifest.patchSha256) throw new Error('Diagnostic patch hash mismatch.');
for (const [relative, hashes] of Object.entries(manifest.files)) {
  if (hash(fs.readFileSync(path.join(packageDirectory, relative))) !== hashes.originalSha256) {
    throw new Error(`Pinned source mismatch: ${relative}`);
  }
}
execFileSync('patch', ['--batch', '--forward', '-p1'], { cwd: packageDirectory, input: patch, stdio: ['pipe', 'inherit', 'inherit'] });
for (const [relative, hashes] of Object.entries(manifest.files)) {
  if (hash(fs.readFileSync(path.join(packageDirectory, relative))) !== hashes.diagnosticSha256) {
    throw new Error(`Diagnostic output mismatch: ${relative}`);
  }
}
console.log(JSON.stringify({ version: manifest.version, patchSha256: manifest.patchSha256, verified: true }));
