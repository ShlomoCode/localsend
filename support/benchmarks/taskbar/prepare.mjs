#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const [base, candidate] = process.argv.slice(2);
if (process.argv.length !== 4 || ![base, candidate].every(ref => /^[a-f0-9]{40}$/.test(ref ?? ''))) {
  throw new Error('Usage: node support/benchmarks/taskbar/prepare.mjs BASE_SHA CANDIDATE_SHA');
}
const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, '../../..');
const helper = 'app/lib/util/native/taskbar_helper.dart';
const candidateSource = spawnSync('git', ['-C', root, 'show', `${candidate}:${helper}`], { encoding: 'utf8' });
if (candidateSource.status !== 0 || candidateSource.stdout !== readFileSync(path.join(root, helper), 'utf8')) {
  throw new Error('Working tree helper differs from the requested candidate commit');
}
const prepared = spawnSync('ruby', [path.join(directory, 'prepare.rb'), base], { cwd: root, stdio: 'inherit' });
if (prepared.status !== 0) process.exit(prepared.status ?? 1);
console.log(`Candidate helper verified against ${candidate}`);
