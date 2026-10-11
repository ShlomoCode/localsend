# Run 38136480853: typing versus paste checkpoint

All twelve bursts reached the full draft, restored the original name on Cancel, and returned to Options, as reported by the retained checkpoint gates. The images reproduce a short partial draft after xdotool exits in all three 5000-file typing repetitions. Paste also leaves the original field visible briefly after command exit before replacing it in full. These observations show delayed displayed state under the measured setup; they do not identify application event consumption, first paint, or a per-character validation defect.

## Frame and event timeline

The first caret-aware full frame was manually inspected in every repetition. A trailing caret was ignored only when classifying analysis candidates; the harness matcher and OCR outputs remain unchanged. Times below are capture completion bounds after input starts, not actual first paint.

| Files / mode / repetition | Command duration s | X raw event span s | First full frame | Full capture end after start s | Full capture end after command exit s | Exact OCR capture end after start s |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| 5 / paste / 0 | 0.041 | 0.022 | frame-0012.png | 0.169 | 0.129 | 0.668 |
| 5 / paste / 1 | 0.044 | 0.020 | frame-0012.png | 0.167 | 0.123 | 0.667 |
| 5 / paste / 2 | 0.040 | 0.021 | frame-0012.png | 0.161 | 0.121 | 0.661 |
| 5 / typing / 0 | 0.298 | 0.281 | frame-0015.png | 0.459 | 0.160 | 0.859 |
| 5 / typing / 1 | 0.301 | 0.287 | frame-0015.png | 0.465 | 0.164 | 0.965 |
| 5 / typing / 2 | 0.297 | 0.275 | frame-0014.png | 0.363 | 0.066 | 0.864 |
| 5000 / paste / 0 | 0.044 | 0.020 | frame-0014.png | 0.387 | 0.343 | 0.958 |
| 5000 / paste / 1 | 0.043 | 0.025 | frame-0014.png | 0.368 | 0.325 | 0.982 |
| 5000 / paste / 2 | 0.047 | 0.025 | frame-0014.png | 0.392 | 0.346 | 1.006 |
| 5000 / typing / 0 | 0.299 | 0.278 | frame-0016.png | 0.593 | 0.295 | 1.080 |
| 5000 / typing / 1 | 0.299 | 0.279 | frame-0016.png | 0.595 | 0.296 | 1.088 |
| 5000 / typing / 2 | 0.293 | 0.276 | frame-0016.png | 0.533 | 0.240 | 1.120 |

For five files, typing visibly progresses through prefixes during command execution, and the first captured full draft ends 0.363–0.465 seconds after input starts. Paste ends its first full capture at 0.161–0.169 seconds. For 5000 files, typing ends its first full capture at 0.533–0.595 seconds, while paste ends at 0.368–0.392 seconds. Full drafts precede exact OCR matches because the caret changes the recognized token. The exact-match values around one second cannot be treated as typing completion.

In 5000 typing repetition 0, frames 14 and 15 show `Pr`, starting about 0.027 and 0.127 seconds after command exit. Repetition 1 frames 14 and 15 show `Probe2414.` starting about 0.030 and 0.131 seconds after exit. Repetition 2 frame 15 shows `Probe2414.` starting about 0.075 seconds after exit. All three reach a full caret-bearing draft in frame 16. OCR omits the dot in the latter partial tokens; pixel inspection resolves it. For 5000 paste, frames 12 and 13 still show the selected original name after command exit, and frame 14 contains the full replacement. No comparable post-exit incomplete frame was retained for the five-file cases. This is a sampled distinction, not proof that five-file processing is synchronous.

Typing commands last about 0.293–0.301 seconds and their retained X raw input event spans are 0.275–0.287 seconds. Paste commands last 0.040–0.047 seconds with raw event spans 0.020–0.025 seconds. The typing/paste display difference therefore includes the longer delivery sequence. The 5000-file effect is visible with paste too; it is not exclusively a sequence of character edits. Raw X event `time` values establish server event sequencing, while line receipt times include observer scheduling and buffering. The observed receipt-minus-server numerical offsets remain below 5.3ms, with no retained multi-second observer delivery gap. No formal clock synchronization was performed. Neither timestamp is an application acknowledgement.

## CPU and observer cost

All 1116 receiver task/memory samples and 1112 retained frames across twelve bursts were audited. CPU is the sum of utime+stime deltas for task IDs retained at both phase endpoints, divided by elapsed sampled seconds. One fully used core is 100%; this VM has two cores (200% capacity). Idle is the roughly one-second window before select-all, with the same frame/task observer active. Input ends at the first full capture; these short windows have coarse tick resolution.

| Case | Idle receiver % | Idle helper + reaped children % | Input receiver % | Input helper + children % | After-full receiver % | After-full helper + children % |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| files-5-input-paste-0 | 36.0 | 50.9 | 69.9 | 49.9 | 39.1 | 52.6 |
| files-5-input-paste-1 | 40.8 | 52.8 | 99.0 | 39.6 | 41.6 | 53.6 |
| files-5-input-paste-2 | 41.9 | 52.9 | insufficient samples | insufficient samples | 39.8 | 52.9 |
| files-5-input-typing-0 | 39.8 | 53.7 | 76.4 | 56.4 | 39.2 | 53.1 |
| files-5-input-typing-1 | 38.9 | 52.9 | 69.9 | 54.9 | 41.8 | 53.7 |
| files-5-input-typing-2 | 38.0 | 51.9 | 69.7 | 59.7 | 39.9 | 53.1 |
| files-5000-input-paste-0 | 50.9 | 59.8 | 99.6 | 46.5 | 54.5 | 60.2 |
| files-5000-input-paste-1 | 51.8 | 59.8 | 89.3 | 56.3 | 55.6 | 60.0 |
| files-5000-input-paste-2 | 51.8 | 59.8 | 116.5 | 59.9 | 54.5 | 59.5 |
| files-5000-input-typing-0 | 50.8 | 60.8 | 97.4 | 62.4 | 56.7 | 59.6 |
| files-5000-input-typing-1 | 49.7 | 58.7 | 99.8 | 61.9 | 56.2 | 60.2 |
| files-5000-input-typing-2 | 52.6 | 59.9 | 107.4 | 62.4 | 52.1 | 59.5 |

The helper plus its reaped children uses approximately 51–54% of one core during five-file idle windows and 59–61% during 5000-file idle windows: about 25–30% of total two-core capacity. This is material observer CPU work even before input. It remains near 53–54% and 60% after the full draft. The helper itself uses roughly 5–6% of one core in five-file idle windows and about 11–12% in 5000-file idle windows; most remaining accounted observer work is child CPU. xinput accumulated no measurable CPU tick in these windows; zero at 10ms accounting resolution does not prove zero work. Child accounting includes reaped capture/input helpers, excludes still-running children, and must not have xinput added again if it later enters the reaped-child total.

During 5000-file input windows, the task named `io.flutter.ui` accumulates 0.19–0.38 CPU seconds; the corresponding five-file windows show 0.00–0.04 seconds. In five-file idle windows, most receiver CPU appears in tasks named `llvmpipe-0/1`; in 5000 idle windows those tasks remain active and the process-leader task also accumulates CPU. The JSON retains every task delta. These names support a distinction between observed CPU locations, but do not independently verify a Flutter main thread, reveal call stacks, or establish why the work occurred. The sums can miss threads absent at either phase endpoint.

## Memory and capture cost

| Case | Peak receiver RSS MiB | Peak receiver PSS MiB | Minimum MemAvailable MiB | Median screenshot capture s |
| --- | ---: | ---: | ---: | ---: |
| files-5-input-paste-0 | 265.051 | 230.832 | 1402.020 | 0.066 |
| files-5-input-paste-1 | 266.000 | 231.771 | 1413.453 | 0.067 |
| files-5-input-paste-2 | 264.781 | 230.622 | 1417.695 | 0.066 |
| files-5-input-typing-0 | 264.184 | 230.003 | 1427.926 | 0.066 |
| files-5-input-typing-1 | 265.508 | 231.346 | 1421.078 | 0.066 |
| files-5-input-typing-2 | 266.039 | 231.832 | 1415.492 | 0.066 |
| files-5000-input-paste-0 | 1126.750 | 1092.885 | 569.703 | 0.067 |
| files-5000-input-paste-1 | 1127.090 | 1093.104 | 575.340 | 0.068 |
| files-5000-input-paste-2 | 1128.414 | 1094.534 | 580.422 | 0.068 |
| files-5000-input-typing-0 | 1119.840 | 1086.026 | 580.645 | 0.067 |
| files-5000-input-typing-1 | 1130.547 | 1096.730 | 571.684 | 0.067 |
| files-5000-input-typing-2 | 1135.055 | 1101.240 | 575.980 | 0.067 |

The resident helper is approximately 17–18 MiB and xinput about 2.6 MiB in sampled phases. These exclude transient screenshot children and X server allocations. The receiver uses about 264–266 MiB RSS for five files versus 1120–1135 MiB for 5000; at least about 570 MiB system memory remains available in the 5000 bursts. The checkpoint does not demonstrate memory exhaustion caused by instrumentation, and it cannot measure the complete observer memory footprint.

Median screenshot capture lasts about 66–68ms against a 100ms target interval. Captures and sequential `/proc` reads occupy a substantial part of each interval, so a 10Hz target is not a zero-cost passive trace. The maximum retained capture was 0.124 seconds and the maximum frame-start gap was also 0.124 seconds; per-burst values are retained in JSON. Identical observation in both counts helps comparison but does not eliminate differing interaction with receiver load, nor isolate observer-induced delay.

## Interpretation limits

The run reproduces post-command-exit partial input for 5000 files, while the full draft appears within the retained subsecond capture bounds. It does not reproduce an eleven-second or multi-second input completion delay in these bursts. Both typing and paste show a larger display delay at 5000 files than at five files. CPU location and memory differences justify investigating application/renderer work and scheduling, but the substantial observer CPU overhead prevents a clean attribution without an observer-off or lower-overhead control. No receiver-side acknowledgement, verified main-thread identity, call-stack trace, or presentation clock isolates input handling from rendering and scheduling.

This report covers checkpoint input only. It does not decide the ongoing full-save result. Existing source, JSONL data, and image artifacts were analyzed offline; no application workload, harness edit, dispatch, build, test, or Git operation was performed.
