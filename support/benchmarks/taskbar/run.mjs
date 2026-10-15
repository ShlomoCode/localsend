import { spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [executable, output] = process.argv.slice(2);
if (!executable || !output) throw new Error('Usage: node run.mjs EXECUTABLE OUTPUT_DIRECTORY');
mkdirSync(output, { recursive: true });
const log = createWriteStream(join(output, 'run.log'));
const child = spawn(executable, [], { stdio: ['ignore', 'pipe', 'pipe'] });
const rows = [];
let pending = '';
let done = false;
const timeout = setTimeout(() => {
  console.error('Benchmark exceeded 35 minutes');
  child.kill('SIGKILL');
}, 35 * 60 * 1000);
child.stderr.on('data', chunk => log.write(chunk));
child.stdout.on('data', chunk => {
  log.write(chunk);
  pending += chunk.toString();
  let newline;
  while ((newline = pending.indexOf('\n')) >= 0) {
    const line = pending.slice(0, newline).trim();
    pending = pending.slice(newline + 1);
    const marker = 'TASKBAR_BENCHMARK_ROW ';
    const index = line.indexOf(marker);
    if (index >= 0) {
      const row = JSON.parse(line.slice(index + marker.length));
      rows.push(row);
      writeFileSync(join(output, 'rows.json'), JSON.stringify(rows, null, 2));
      console.log(`pair=${row.pair} variant=${row.variant} warmup=${row.warmup} calls=${row.native_calls} cpu_ms=${((row.app_user_cpu_us + row.app_system_cpu_us) / 1000).toFixed(3)}`);
    }
    if (line.includes('TASKBAR_BENCHMARK_DONE ')) done = true;
    if (line.includes('TASKBAR_BENCHMARK_ERROR')) console.error(line);
  }
});
child.on('error', error => { console.error(error); process.exitCode = 1; });
child.on('close', async (code, signal) => {
  clearTimeout(timeout);
  await new Promise(resolve => log.end(resolve));
  if (code !== 0 || signal || !done) {
    console.error(`Incomplete benchmark: exit=${code} signal=${signal} done=${done}`);
    process.exitCode = 1;
  }
});
