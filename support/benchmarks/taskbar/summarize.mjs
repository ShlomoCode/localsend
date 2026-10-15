import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const output = process.argv[2];
const rows = JSON.parse(readFileSync(join(output, 'rows.json'), 'utf8')).filter(row => !row.warmup);
const before = rows.filter(row => row.variant === 'before').sort((a, b) => a.pair - b.pair);
const after = rows.filter(row => row.variant === 'after').sort((a, b) => a.pair - b.pair);
if (before.length !== 50 || after.length !== 50) throw new Error('Expected exactly 50 measured trials per variant');
for (let i = 0; i < 50; i++) {
  if (before[i].pair !== i || after[i].pair !== i) throw new Error('Missing or duplicated trial');
  if (before[i].frames !== 600 || after[i].frames !== 600 || before[i].native_calls !== 600 || after[i].native_calls !== 101) {
    throw new Error('Unexpected frame or native call counts');
  }
}
const mean = values => values.reduce((sum, value) => sum + value, 0) / values.length;
const quantile = (values, probability) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.round((sorted.length - 1) * probability)];
};
let seed = 44;
const random = () => {
  seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
  return seed / 2 ** 32;
};
const metrics = [
  ['Native calls', row => row.native_calls],
  ['App CPU (ms)', row => (row.app_user_cpu_us + row.app_system_cpu_us) / 1000],
  ['Synchronous Dock handler total (ms)', row => row.native_handler_ns / 1e6],
  ['Trial wall time (ms)', row => row.wall_ms],
];
const results = metrics.map(([name, value]) => {
  const a = before.map(value);
  const b = after.map(value);
  const differences = a.map((item, i) => b[i] - item);
  const bootstrap = Array.from({ length: 10000 }, () => mean(Array.from({ length: 50 }, () => differences[Math.floor(random() * 50)])));
  return {
    name, before_mean: mean(a), after_mean: mean(b), before_median: quantile(a, 0.5), after_median: quantile(b, 0.5),
    paired_mean_change: mean(differences), paired_change_ci95: [quantile(bootstrap, 0.025), quantile(bootstrap, 0.975)],
  };
});
writeFileSync(join(output, 'summary.json'), JSON.stringify(results, null, 2));
const n = value => value.toFixed(3);
const table = results.map(item => `| ${item.name} | ${n(item.before_mean)} | ${n(item.after_mean)} | ${n(item.paired_mean_change)} | ${item.paired_change_ci95.map(n).join(' to ')} |`).join('\n');
const markdown = `# Taskbar progress: 50 before + 50 after\n\nRelease build, real macOS method channel and DockProgress. Three warmup pairs excluded. Each trial submits 600 progress updates on successive Flutter frames, from 0% to 100%. Paired order alternates AB/BA.\n\n| Metric per trial | Before mean | After mean | Paired change (after − before) | 95% bootstrap interval |\n|---|---:|---:|---:|---:|\n${table}\n\nNegative change means less work/time. The interval resamples the 50 pairs 10,000 times with a fixed seed. It describes variation on this runner, not variation across Macs. Raw rows and environment metadata are attached.\n\nThis isolates the taskbar update path. App CPU includes the Flutter harness and native app work; it excludes the separate Dock process. Synchronous handler time excludes later Dock rendering and animation. No files are transferred, so these results do not measure transfer speed or the full transfer screen. Wall time is primarily frame paced by design.\n`;
writeFileSync(join(output, 'summary.md'), markdown);
console.log(markdown);
