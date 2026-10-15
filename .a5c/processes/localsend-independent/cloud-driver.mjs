// Reviewed generic cloud executor. A supplied harness owns actual product work
// and observations; this driver establishes identity and retains its raw bytes.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, realpathSync, lstatSync } from 'node:fs';
import { join, resolve, relative, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const need = (condition, reason) => { if (!condition) throw new Error(reason); };
const commitPattern = /^[a-f0-9]{40}$/;
const hashPattern = /^[a-f0-9]{64}$/;
export const operationPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
export function artifactPath(root, path) {
  need(typeof path === 'string' && path && !path.includes('\\') && !isAbsolute(path) && !path.split('/').some(segment => !segment || segment === '.' || segment === '..'), 'Artifact path must be relative without traversal');
  const target = realpathSync(resolve(root, path));
  const rel = relative(realpathSync(root), target);
  need(rel && !rel.startsWith('..') && !isAbsolute(rel) && lstatSync(target).isFile(), 'Artifact path escapes its root or is not a file');
  return target;
}
export async function execute(executable, args, { cwd, env, timeoutMs = 60 * 60000, maxOutputBytes = 16 * 1024 * 1024 } = {}) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(executable, args, { cwd, env, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
    const stdout = [], stderr = []; let size = 0, failure;
    const terminate = reason => { failure ??= reason; child.kill('SIGKILL'); child.stdout.destroy(); child.stderr.destroy(); };
    const timer = setTimeout(() => terminate('Harness timeout'), timeoutMs);
    for (const [stream, parts] of [[child.stdout, stdout], [child.stderr, stderr]]) stream.on('data', bytes => { size += bytes.length; if (size > maxOutputBytes) terminate('Harness output limit'); else parts.push(bytes); });
    child.on('error', reject);
    child.on('close', (code, signal) => { clearTimeout(timer); resolveResult({ code, signal, failure, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) }); });
  });
}
export async function runDriver({ sourceRoot, outputRoot, operationId, sourceCommit, scenarioHash, harnessPath, harnessSha256, runnerOS, env = process.env, executeCommand = execute }) {
  need(env.GITHUB_ACTIONS === 'true' && env.GITHUB_REPOSITORY === 'ShlomoCode/localsend', 'Driver requires the authorized fork GitHub Actions environment');
  need(operationPattern.test(operationId), 'Operation ID must be artifact-safe');
  need(commitPattern.test(sourceCommit) && hashPattern.test(scenarioHash) && hashPattern.test(harnessSha256), 'Exact source, scenario and harness hashes required');
  need(['ubuntu', 'windows', 'macos'].includes(runnerOS) && ({ ubuntu: 'Linux', windows: 'Windows', macos: 'macOS' })[runnerOS] === env.RUNNER_OS, 'Runner OS differs from reviewed request');
  need(/^\d+$/.test(env.GITHUB_RUN_ID ?? '') && /^\d+$/.test(env.GITHUB_RUN_ATTEMPT ?? '') && commitPattern.test(env.GITHUB_SHA ?? '') && env.GITHUB_JOB, 'Actual provider identity required');
  sourceRoot = realpathSync(sourceRoot); outputRoot = resolve(outputRoot);
  const outputRelative = relative(sourceRoot, outputRoot);
  need(outputRelative === '..' || outputRelative.startsWith('../') || outputRelative.startsWith('..\\') || isAbsolute(outputRelative), 'Output must be outside source checkout');
  mkdirSync(outputRoot, { recursive: true });
  const git = async args => {
    const result = await executeCommand('git', ['-C', sourceRoot, ...args], { env, timeoutMs: 30000 });
    need(result.code === 0 && !result.failure, 'Source identity inspection failed'); return result.stdout.toString('utf8').trim();
  };
  need(await git(['rev-parse', 'HEAD']) === sourceCommit, 'Checked-out source differs from reviewed commit');
  need(!(await git(['status', '--porcelain', '--untracked-files=no'])), 'Tracked source differs before execution');
  const harness = artifactPath(sourceRoot, harnessPath);
  need(harnessPath.endsWith('.mjs') && sha(readFileSync(harness)) === harnessSha256, 'Harness bytes differ from reviewed source');
  const receiptId = `${operationId}:github:${env.GITHUB_RUN_ID}:attempt:${env.GITHUB_RUN_ATTEMPT}`;
  const request = { schemaVersion: 1, operationId, sourceCommit, scenarioHash, receiptId, harness: { path: harnessPath, sha256: harnessSha256 }, runnerOS };
  const requestPath = join(outputRoot, 'request.json'); writeFileSync(requestPath, `${JSON.stringify(request)}\n`, { flag: 'wx' });
  const result = await executeCommand(process.execPath, [harness], { cwd: sourceRoot, env: { ...env, LOCALSEND_DRIVER_REQUEST: requestPath, LOCALSEND_DRIVER_OUTPUT: outputRoot } });
  writeFileSync(join(outputRoot, 'harness.stdout'), result.stdout); writeFileSync(join(outputRoot, 'harness.stderr'), result.stderr);
  need(!result.failure && result.code === 0, `Harness did not complete successfully: ${result.failure ?? result.code}`);
  need(await git(['rev-parse', 'HEAD']) === sourceCommit && !(await git(['status', '--porcelain', '--untracked-files=no'])), 'Tracked source changed during execution');
  need(sha(readFileSync(harness)) === harnessSha256, 'Harness changed during execution');
  const report = JSON.parse(readFileSync(artifactPath(outputRoot, 'harness-result.json'), 'utf8'));
  need(report.schemaVersion === 1 && report.operationId === operationId && report.sourceCommit === sourceCommit && report.scenarioHash === scenarioHash && ['baseline', 'replay', 'checks'].includes(report.stage), 'Harness result identity or stage differs');
  need(report.evidence && report.evidence.commit === sourceCommit && report.evidence.scenarioHash === scenarioHash && Array.isArray(report.rawFiles) && report.rawFiles.length > 0, 'Harness must retain actual evidence and raw files');
  const seen = new Set();
  for (const ref of report.rawFiles) {
    need(!seen.has(ref.path) && !['result.json', 'harness-result.json', 'request.json', 'harness.stdout', 'harness.stderr'].includes(ref.path) && hashPattern.test(ref.sha256), 'Raw file identity is duplicate, reserved or unpinned');
    need(sha(readFileSync(artifactPath(outputRoot, ref.path))) === ref.sha256, 'Raw file bytes differ from harness report'); seen.add(ref.path);
  }
  for (const observation of report.evidence.observations ?? []) need(seen.has(observation.rawPath) && report.rawFiles.some(ref => ref.path === observation.rawPath && ref.sha256 === observation.rawHash), 'Observation raw output is not retained');
  const retained = ['request.json', 'harness-result.json', 'harness.stdout', 'harness.stderr'].map(path => ({ path, sha256: sha(readFileSync(join(outputRoot, path))) }));
  const manifest = { schemaVersion: 1, operationId, sourceCommit, scenarioHash, receiptId, stage: report.stage,
    provider: { repository: env.GITHUB_REPOSITORY, runId: env.GITHUB_RUN_ID, runAttempt: env.GITHUB_RUN_ATTEMPT, job: env.GITHUB_JOB, runnerOS: env.RUNNER_OS, driverCommit: env.GITHUB_SHA, driverRef: env.GITHUB_REF },
    harness: request.harness, evidence: report.evidence, rawFiles: [...report.rawFiles, ...retained] };
  writeFileSync(join(outputRoot, 'result.json'), `${JSON.stringify(manifest)}\n`, { flag: 'wx' });
  return manifest;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { await runDriver({ sourceRoot: process.env.SOURCE_ROOT, outputRoot: process.env.OUTPUT_ROOT, operationId: process.env.OPERATION_ID, sourceCommit: process.env.SOURCE_COMMIT, scenarioHash: process.env.SCENARIO_HASH, harnessPath: process.env.HARNESS_PATH, harnessSha256: process.env.HARNESS_SHA256, runnerOS: process.env.REQUESTED_RUNNER_OS }); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
