# Approved 1 GiB experiment completed successfully

Run: https://github.com/ShlomoCode/localsend/actions/runs/38150625402
Immutable workload head: 488d94c35ebaaf67487f0f09b10724c7ea8b9cf0. Workflow completed with success; no job remains active.

The installed Debian 12/Openbox receiver has 1024 MiB configured RAM, two CPUs and ordinary fixed 2 GiB disk swap. It runs the unchanged hash-verified official v1.17.0 release. The sender selects real folders of ordinary 49-byte files. There is no artificial memory pressure, application memory cap or swap tuning.

All required outcomes qualify. The five-file control saves all five expected names and hashes and shows Finished on both sender and receiver. Both 500 and 5000 cases show metadata approval and the held Options list, return through Back, perform one normal Decline, return to receiver home and verify zero saved files. All receiver/sampler identities remain alive through the final status, kernel baseline/final reads succeed with no OOM/victim entries, and subsequent -15 exits are explicitly harness cleanup. No large save is attempted.

| Files | Initial / held Options | Back approval observed by (s) | Decline home observed by (s) | Save result |
| --- | --- | ---: | ---: | --- |
| 5 | true / true | 0.860 | — | 5 names and hashes, both Finished |
| 500 | true / true | 0.866 | 1.069 | 0 files |
| 5000 | false / true | 1.415 | 4.682 | 0 files |

Offsets use the guest clock from input initiation to successful capture completion. They include SSH/input/capture and, for repeated observations, OCR/observer delays; they are upper observation bounds, not exact drawing latency or continuous responsiveness measurements. Back/Decline are each clicked once, with no input retry or post-click normalization. Independent read-only pixel/TSV review confirms the stated control and cancellation outcomes. The 5000 first Options capture still shows approval at input+1.121–1.190 seconds; the held capture shows the list by input+11.277 seconds (start+11.213 seconds).

After the 5000 Decline input, `cancel-observed-0` visibly contains a blank application client at input+2.092–2.161 seconds. `cancel-observed-1` shows the normal receiver home at +4.649–4.682 seconds. The transient blank is retained evidence; successful eventual rejection does not imply uninterrupted rendering or responsiveness.

Full-case aggregate memory samples with readable receiver status:

| Files | Valid status samples | Peak RSS KiB | Peak process VmSwap KiB | Minimum MemAvailable KiB | Peak system swap used KiB | Maximum read ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | 90 | 244172 | 0 | 536912 | 1292 | 0.495 |
| 500 | 89 | 351808 | 0 | 459876 | 4644 | 16.750 |
| 5000 | 96 | 841360 | 275588 | 6932 | 730664 | 1126.069 |

One additional missing receiver-status sample per case follows harness cleanup and is excluded from process maxima. PIDs/starttimes are 4607/9852, 5033/14610 and 5434/19084 respectively. Full-case maxima include post-hold transitions; they are not assigned solely to Options. Peaks/minima are sampled values, and record fields are read sequentially rather than as atomic snapshots. Read wall duration includes scheduling and I/O, not just CPU time. The sampler CPU estimate excludes SSH, PSS helpers, scrot and Xvfb, so it is not total observation overhead.

5000 stage PSS at actual input offsets +2.139/+6.155/+10.989 seconds is 779879/789166/795401 KiB, with stage Swap 113736/209828/183352 KiB. At the latter two stages, memory PSI avg10 some/full is 19.78/17.51% and 16.01/13.65%. Process VmSwap and stage Swap are observed at different times. The +10 PSS plus Swap is approximately 956 MiB, illustrating the pressure without claiming all of it is caused exclusively by the list.

The aggregate sampler uses 0.01/0.01/0.03 CPU seconds across ~16.0/16.0/16.15 second metadata-to-held windows, approximately 0.031/0.031/0.093% of two-CPU capacity. In the 5000 case it nevertheless suffers a 1.126-second read starting guest219.397839, inside the measured Options window, and the maximum inter-sample gap is 1.126450 seconds. Thus the nominal 0.5-second observer is not continuously uniform under pressure; cheap CPU cost does not establish absence of all observer effects. Only the planned approval, initial Options and held Options snapshots are taken; no OCR or high-frequency UI observer runs within that window.

The approved experiment shows substantial swap use, low available memory and delayed UI observation for 5000 files, while still completing normal rejection without OOM or a persistent hang. Reporter OS/RAM/swap/content are unknown. Debian/Openbox/disk-swap and earlier Ubuntu/no-swap runs differ in several conditions, so this is not an isolated RAM comparison or proof of the reporter's cause. No causal parent/fix probe, production fix or upstream publication has occurred. Further experiments require the coordinator's decision.
