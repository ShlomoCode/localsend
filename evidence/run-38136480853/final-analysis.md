# Final save outcome for run 38136480853

The 50-minute outer real-app scenario ended with exit code 124 before the large case could write its final result. `results.json` contains only the completed five-file control. The harness allows a separate 40-minute save window, but the preceding repeated input probes and checkpoint consumed part of the outer window. This is a bounded partial observation, not a completed large transfer.

The large save has 226 retained progress samples, from 8 to 4,602 saved files across 2,343.075 seconds (39.051 minutes). All 225 intervals increase in both saved and hash-complete counts. The final 4,602 files are hash-complete, at an observed average of 1.961 files per second. The full 5,000-file criterion remains unmet; `content_valid=false` alone does not show damaged bytes.

All 5,232 retained large-case memory samples identify PID 13777 with unchanged process start time 39807 ticks. Peak RSS is 1,163.855 MiB, peak PSS 1,130.159 MiB and minimum MemAvailable 546.879 MiB. The final kernel journal contains no OOM event. A broad search finds only the normal `oom_reaper` worker in the final process listing, which is not an OOM report.

This run establishes continued progress until the observer deadline. It establishes neither a stall nor corruption nor OOM, and does not establish full large-case completion. The repeated input observations and material observer overhead are documented separately in `input-comparison-analysis.md`. The structured audit is `final-analysis.json`; all analysis is read-only retained-artifact processing.
