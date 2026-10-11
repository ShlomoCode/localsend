# Run 38133441018: deadline with ongoing progress

The 5000-file case reached the harness's 40-minute save deadline with **4660 saved and hash-complete files**. The full-save gate was unmet. All 230 intervals between retained progress samples advanced both saved and verified counts, including the final interval. This outcome establishes incomplete transfer at the deadline; it does not establish a hang, OOM, or persistent filename/content corruption.

The five-file control passed the real application transfer and verified all five files. The 5000-file case also passed the observed Options, wheel scroll, filename editor draft/Cancel, and Back interactions before saving.

## Save progress and baseline

| Observation | Current run 38133441018 | Accepted baseline 38111506442 |
| --- | ---: | ---: |
| Final saved and verified files | 4660 / 5000 | 5000 / 5000 |
| Full name/content criterion | Unmet | Passed |
| Observed progress duration | 2397.739 s (39.962 min) | 1900.853 s (31.681 min) |
| Average observed progress | 1.940 files/s | 2.619 files/s |
| Finished state | Not shown | Confirmed by parent |

The current observed rate was **25.9% lower** than the baseline. These are distinct runs, and the added editor/scroll actions and normal run variation were not isolated causal variables. The rates cover retained progress windows, not exact Accept-to-completion throughput.

The current progress audit covers all 231 samples from `final/files-5000-save-progress.jsonl`. The first sample had eight saved files at guest monotonic time 210.627314184; the last had 4660 at 2608.366081155. Saved deltas ranged from 15 to 28 per interval. The largest sampling gap was 11.033648769 seconds and still advanced by 20 saved and verified files. Neither count decreased or stayed flat between retained samples.

Three interim samples showed one saved file not yet hash-complete: 681/680, 1028/1027, and 3930/3929. Concurrent enumeration and hashing of actively written files can explain these transient observations. The final count was 4660/4660. The expected content SHA-256 remained `6632a5e5b167e55fdbbb9e3ad38fd7ff042e66b620a00fb744b0d7f7e21534fb` throughout.

The harness message `Saved names or bytes differ from fixture` is broader than the established failure: the final count was short by 340 files. The evidence does not establish filename corruption. A straight-line projection at the observed average would put the remaining files at about 175 seconds, but that projection does not prove completion would have occurred.

## Receiver memory and kernel evidence

All 4916 samples in `final/vm/guest/files-5000-metrics.jsonl` referenced receiver PID 7803; there were no non-JSON metric lines.

| Metric | MiB |
| --- | ---: |
| Peak sampled RSS | 1165.371 |
| Peak sampled PSS | 1131.446 |
| Minimum system MemAvailable | 562.992 |
| Last sampled RSS | 547.770 |
| Last sampled PSS | 513.671 |

The guest had no swap, and the sampled process swap stayed at zero. `final/vm/kernel-final.txt` contained no matches for `Out of memory`, `Killed process`, or `oom-kill`. Its final free output showed 1967 MiB total memory and 1582 MiB available. This evidence does not demonstrate an OOM event.

## Final screenshots

The inspected `final/files-5000-host-failure.png` shows **Sending files**, early rows marked Done, a mostly filled progress bar, and Cancel. `final/files-5000-guest-failure.png` shows **Receiving files**, destination `/home/probe/received-5000`, early rows marked Done, a mostly filled progress bar, and Cancel. Neither shows Finished. These are still-active transfer states at capture time; the screenshots cannot establish continuous UI responsiveness or a freeze.

## Limits and disposition

The full 5000-file completion result remains unproven for this run. Progress sampling includes SSH/observer work, starts after eight files were saved, and ends at the deadline. Sequential `/proc` reads are close observations rather than atomic memory snapshots. Retained sample intervals cannot exclude pauses shorter than the sampling gaps.

This analysis used existing artifacts only. No application workload, build, test, harness edit, dispatch, or Git operation was performed. Exact values, source paths, and the complete sample audit are recorded in `final-analysis.json`.
