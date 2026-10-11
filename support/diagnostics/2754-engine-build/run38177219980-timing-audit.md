# Original recording Text transition audit — run 38177219980

The original recordings show the keyboard-on Text dialog appearing after approximately 25.2 seconds in both control-system and B-system. Both render the queued text when the dialog becomes visible. AB-package renders a fresh dialog and visibly accepts typed characters promptly in all five reached cases. This is a recorded visible behavior comparison, not proof of internal input-delivery latency or root cause.

## Evidence and method

Read-only source evidence: `/tmp/2754-packaged-38177219980-full/comparison/{control-system,B-system,AB-package}/guest/scenario.mp4` and the corresponding `events.json`. Original source files were neither changed nor repaired. Analysis artifacts are in `/tmp/2754-timing-review/`; `cases.json`, `results.json`, per-case native PNGs, `mapping.json`, and `source-pts.log` preserve the mapping. Dense delayed-transition frames have the prefix `delay-` and matching `delay-source-pts.log`.

The actual logged `click` event with label `Text` is the timing origin, using its `wall` value. The later `text-open` event occurs after the xdotool mouse command returns; it is a harness marker, not a rendered-dialog observation. The marker is approximately 105–110 ms later than the logged click. The logged click itself precedes subprocess input delivery; neither log gives a measured button-down timestamp. All reported intervals therefore include harness/input-dispatch overhead and must not be described as exact application response latency.

Recording command evidence uses X11 x11grab, real pointer, `-use_wallclock_as_timestamps 1`, nominal 10 fps, `-copyts`, and `-vsync 0`. `ffprobe` reports source starts of control 1791755046.6, B 1791755425.9, and AB 1791755806.7 Unix seconds. These are the first retained media PTS, **not** the earlier recording-start request or `start` event. Relative extraction positions were computed from event wall minus actual first source PTS. FFmpeg `-copyts` plus `showinfo` provided each original decoded frame PTS; integer PTS was divided by the stream's 10240 time-base denominator. This confirms the source mapping without assuming frame index / 10 equals timestamp.

Native frames around each prompt transition were inspected, with full-size or full-resolution modal crops used to distinguish a blank caret from visible characters. For the delayed control/B transitions, a sparse overview located the change and dense native frames bounded it. Source-derived PNGs and contact sheets are analysis aids, not replacement clips. The original recordings, rather than the invalid generated clips, are the timing authority.

## Measured visible transitions

The modal bracket gives the last frame without the modal and the first frame visibly containing the modal, measured from the **logged Text click**. A faint but identifiable opening dialog counts as first visible modal; animation settling is a separate transition. The typed upper bound is the first inspected native frame with actual typed characters, rather than an empty caret. Values are rounded to milliseconds, with nominal 100 ms sampling and capture clock quantization; decimal precision does not imply millisecond accuracy.

| Variant | Reached case | Logged Text click wall | First visible modal source PTS | Modal bracket from click (s) | First visible characters source PTS | Visible characters by (s) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| control-system | keyboard-off | 1791755069.774995 | 1791755069.9 | (0.025, 0.125] | 1791755070.1 | 0.325 |
| control-system | keyboard-on | 1791755169.890811 | 1791755195.0 | (25.009, 25.109] | 1791755195.1 | 25.209 |
| B-system | keyboard-off | 1791755448.898824 | 1791755449.1 | (0.101, 0.201] | 1791755449.2 | 0.301 |
| B-system | keyboard-on | 1791755549.175185 | 1791755574.4 | (25.125, 25.225] | 1791755574.4 | 25.225 |
| AB-package | keyboard-off | 1791755829.608560 | 1791755829.8 | (0.091, 0.191] | 1791755829.9 | 0.291 |
| AB-package | keyboard-on | 1791755929.879295 | 1791755930.0 | (0.021, 0.121] | 1791755930.1 | 0.221 |
| AB-package | keyboard-on-repeat | 1791756034.167574 | 1791756034.4 | (0.132, 0.232] | 1791756034.4 | 0.232 |
| AB-package | keyboard-off-again | 1791756114.596799 | 1791756114.7 | (0.003, 0.103] | 1791756114.8 | 0.203 |
| AB-package | keyboard-on-stack | 1791756194.812917 | 1791756194.9 | (-0.013, 0.087] | 1791756195.0 | 0.187 |

The negative lower value in the last row means the preceding blank frame was 13 ms before the logged trigger. It does not mean a negative response time. The first post-trigger retained frame already contains the opening modal. A causal bound from this recording is 0–87 ms from the logged trigger, subject to the dispatch and capture limitations above.

In the two delayed cases, the first typed field already visibly contains `keyboard-on typed control`; typed input was issued earlier by the harness. The recording proves that the queued content was rendered by approximately 25.2 s. It does not establish when hidden application state accepted those keys, nor permit a separate keystroke-response latency measurement. In the prompt cases adjacent frames visibly progress through partial strings, providing direct evidence of editable fields rather than relying on delayed screenshots.

## Reached coverage and instrumentation

control-system and B-system reach only keyboard-off and keyboard-on Text cases. Both abort later before keyboard-on Paste; repeat, off-again and stack are **not reached**, rather than failed Text observations. AB-package reaches all five original Text cases. Subsequent geometry and interaction failures are separate gates; these Text transitions do not establish success for those phases.

The harness starts strace before `keyboard-on-repeat`, attaches to the app, and waits one second before the trigger. Its retained trace-launch output confirms attachment. Thus AB repeat proves a prompt rendered, editable dialog under tracing, but is not a clean uninstrumented latency comparison. The script invokes GDB only in `keyboard-on-stack` after the +10-second screenshot/state sampling; the retained GDB output confirms attachment/detachment. Its initial 0.087/0.187 s transitions precede GDB, while later observations may be debugger-perturbed. These cases should not be pooled indiscriminately with the uninstrumented initial keyboard-on case.

## Timestamp integrity and limits

The neighboring source frames that bound every modal and first-visible-character transition have increasing PTS with 0.1 s spacing. This includes the separately extracted approximately 25 s control/B transitions. Elsewhere the source recordings contain irregular PTS: for example, the larger control keyboard-off extraction contains a 0.2 s step, an approximately 0.0000977 s step, and an approximately 0.0999023 s step. Other retained packet sequences also show near-duplicate timestamps. Global nominal frame rate, total frame count and successful decoding therefore cannot justify a uniform timestamp assumption. The table relies on the actual local source PTS of inspected bounding frames; it does not certify the entire recording's timestamps or the generated clips.

The recorder's nonzero shutdown status and generated-clip timing failures remain recorded defects. Full-decode/metadata validation belongs to the separate media audit. No repair or re-encoding was used as evidence here. The observed difference is large compared with one-frame uncertainty: control and B alone retain the approximately 25 s keyboard-on display delay, while AB eliminates that visible delay in the reached initial case. This run does not isolate which A behavior is necessary, generalize beyond this VM/session, or establish geometry, focus, speech, chooser, and wider accessibility correctness.
