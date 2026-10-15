// Administrative cloud-driver smoke only. This never launches LocalSend,
// installs dependencies, calls a provider API or establishes product progress.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { platform, arch, release } from 'node:os';
import { pathToFileURL } from 'node:url';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const need = (condition, message) => { if (!condition) throw new Error(message); };
export function runSmoke({ requestPath = process.env.LOCALSEND_DRIVER_REQUEST, outputRoot = process.env.LOCALSEND_DRIVER_OUTPUT, env = process.env } = {}) {
  need(env.GITHUB_ACTIONS === 'true' && env.GITHUB_REPOSITORY === 'ShlomoCode/localsend', 'Administrative smoke requires the authorized cloud driver');
  const request = JSON.parse(readFileSync(requestPath, 'utf8'));
  need(request.schemaVersion === 1 && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(request.operationId ?? '') && /^[a-f0-9]{40}$/.test(request.sourceCommit ?? '') && /^[a-f0-9]{64}$/.test(request.scenarioHash ?? ''), 'Driver request identity is invalid');
  need(/^\d+$/.test(env.GITHUB_RUN_ID ?? '') && /^\d+$/.test(env.GITHUB_RUN_ATTEMPT ?? ''), 'Actual provider run identity is missing');
  const receiptId = `${request.operationId}:github:${env.GITHUB_RUN_ID}:attempt:${env.GITHUB_RUN_ATTEMPT}`;
  need(request.receiptId === receiptId, 'Driver request receipt differs from the current provider run');
  need(({ ubuntu: 'Linux', windows: 'Windows', macos: 'macOS' })[request.runnerOS] === env.RUNNER_OS, 'Actual provider runner differs from the requested OS');
  need(/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? '') && env.GITHUB_REF === 'refs/heads/codex/independent-driver' && env.GITHUB_JOB === 'operation', 'Administrative smoke requires the reviewed driver identity');
  const observation = {
    schemaVersion: 1, administrativeOnly: true, observedAt: new Date().toISOString(),
    operationId: request.operationId, sourceCommit: request.sourceCommit, scenarioHash: request.scenarioHash, receiptId,
    provider: { repository: env.GITHUB_REPOSITORY, runId: env.GITHUB_RUN_ID, runAttempt: env.GITHUB_RUN_ATTEMPT, job: env.GITHUB_JOB, runnerOS: env.RUNNER_OS, driverCommit: env.GITHUB_SHA, driverRef: env.GITHUB_REF },
    runtime: { platform: platform(), architecture: arch(), osRelease: release(), nodeVersion: process.version },
    checks: { requestParsed: true, receiptMatchesProvider: true, providerRunnerMatchesRequest: true, fixedDriverIdentityPresent: true },
  };
  const rawPath = 'raw/administrative-smoke.json', raw = `${JSON.stringify(observation, null, 2)}\n`;
  mkdirSync(join(outputRoot, 'raw'), { recursive: true });
  writeFileSync(join(outputRoot, rawPath), raw, { flag: 'wx' });
  const report = { schemaVersion: 1, operationId: request.operationId, sourceCommit: request.sourceCommit, scenarioHash: request.scenarioHash, stage: 'checks',
    evidence: { commit: request.sourceCommit, scenarioHash: request.scenarioHash, administrativeOnly: true,
      checks: [{ command: 'node .a5c/processes/localsend-independent/cloud-smoke.mjs', commit: request.sourceCommit, receiptId, outcome: 'pass' }],
      administrativeObservation: observation },
    rawFiles: [{ path: rawPath, sha256: hash(raw) }] };
  writeFileSync(join(outputRoot, 'harness-result.json'), `${JSON.stringify(report)}\n`, { flag: 'wx' });
  return report;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { const report = runSmoke(); process.stdout.write(`${JSON.stringify({ administrativeOnly: true, operationId: report.operationId, outcome: 'pass' })}\n`); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
