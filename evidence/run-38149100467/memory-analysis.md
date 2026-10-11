# Qualified control, 500-file cancellation, delayed 5000-file transitions

Run: https://github.com/ShlomoCode/localsend/actions/runs/38149100467
Head: 50c51abbbb8fa449af950848d5337db0a152e4e8. Completed failure; no job remains active.

The five-file control fully qualifies: all five saved names/content hashes match, both exact Finished gates pass, receiver and sampler remain alive, and kernel baseline/final reads succeed without OOM. The 500-file case shows initial/held Options, Back and normal Decline, returns home and verifies zero saved files.

For 5000 files, the initial post-click image still shows normal approval, not a blank Options frame. Options input starts at guest194.097375426; initial capture runs195.123984973–195.188556452. The held capture runs205.392450800–205.460373721 and shows Options, Save, Files and file rows. Therefore approval is still observed around1.09s after input initiation and the list is observed by11.363s; no exact appearance latency follows from these sparse frames. The held-capture result field records capture start (11.295s), not completion.

The immediate Back frame still shows Options, so the one-frame predicate fails before Decline. A later guest failure capture visibly shows normal5000-file approval. This is recovered transition evidence, not a confirmed persistent hang. Large-case cancellation/no-save qualification is incomplete. Receiver PID5398/starttime16540 and sampler remain alive, kernel reads succeed with no OOM/victim entries, and final exit -15 is explicitly harness cleanup.

Back input initiation is guest210.994780576. The negative capture runs212.082578071–212.196948206 (input+1.088–1.202s); the recovered approval capture runs214.277554884–214.392756895 (input+3.283–3.398s). No further GUI input occurs except pointer movement outside the window. Approval is thus observed by3.398s after input initiation; sparse capture/SSH evidence does not establish exact transition latency. The corrected harness retains bounded Back polling and uses the successfully observed frame for exact action-label OCR, after the measured Options window.

Aggregate `/proc` samples, restricted to records with readable receiver status:

| Files | Valid status samples | Peak RSS KiB | Peak process VmSwap KiB | Minimum MemAvailable KiB | Peak system swap used KiB | Maximum sampler read ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | 109 | 237928 | 0 | 557844 | 1292 | 1.234 |
| 500 | 104 | 349712 | 0 | 464912 | 3864 | 2.331 |
| 5000 | 100 | 832660 | 215168 | 12320 | 487424 | 33.982 |

Each case has one additional missing-status record after harness cleanup; it is excluded from process memory maxima rather than converted to zero. All records retain the expected PID/starttime. Stage PSS at nominal +1/+5/+10 after the wrapper is607024/783655/781337KiB; stage Swap is53100/222904/196032KiB. These stage readings and aggregate VmSwap maxima have different observation times. At +10, MemAvailable is32292KiB and memory PSI avg10 is8.71% some/6.27% full. The sampler consumes0.02/0.03/0.04CPU seconds across the respective ~16.5s metadata-to-held windows (~0.061/0.091/0.121% of two-CPU capacity). No high-frequency screenshots/OCR run inside those windows.

The approved Debian12/Openbox 1GiB/two-CPU desktop with ordinary fixed2GiB disk swap therefore exhibits material memory pressure and bounded delayed UI transitions for5000 files. It does not reproduce OOM or a proven persistent hang. Reporter hardware, OS and swap remain unknown; differences from the earlier Ubuntu2GiB/no-swap experiment prevent an isolated RAM comparison. No causal parent/fix probe or production fix has run.
