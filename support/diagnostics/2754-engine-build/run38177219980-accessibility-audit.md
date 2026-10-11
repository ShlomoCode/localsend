# AB-package raw accessibility audit — run 38177219980

The AB-package run does not establish strict geometry, editing, accessible actions, dialog/app lifecycle, or speech/audio delivery. Geometry queries hit their process deadlines before any tree node was recorded. The interaction harness never started. These are explicit failed or untested gates, not passes inferred from phase labels.

## Raw geometry facts

Evidence directory: `/tmp/2754-packaged-38177219980-compact/comparison/AB-package/guest/geometry-post-timing`.

- `phase-status.json` says capture-finished with return code 3; the driver observed a rendered modal before capture. This label means the subprocess returned, not that geometry passed.
- Both `before.jsonl` and `after.jsonl` resolve accessible bus `:1.29`, path `/org/a11y/atspi/accessible/root`, to app PID 4618 through successful call 47 GetProcessId. Calls 48 SetCacheMaskNone and 49 ClearCacheSingle return.
- Both streams end at an unmatched call 50 GetName on that application root. Entry times are 13.245 ms before and 13.002 ms after. Neither has a matching result or GError result. Each has a process_exit record with status 124 and deadline_hit true. The capture fixture gives each client a 180-second process deadline.
- There are no recorded nodes, editable targets, extents, point queries, complete traversal summaries, or returned root names. No strict geometry claim can be made from these incomplete streams.
- `validation.stderr` contains two jq compile errors at validator line 78, at the unparenthesized subtraction expressions in host_delta. The validator did not evaluate the raw geometry records. `geometry-comparison.json` remains incomplete with reason capture did not finish; the temporary comparison file is empty. This parser defect is separate from the already-observed public-client timeouts.
- Independent X11 samples show the actual mapped client moving from (190,319) to (280,451), with unchanged 1100×700 size and PID 4618. Before/end and after/end samples match within each phase. Move status is 0. Host-reported coordinates differ and must not substitute for these independent client origins.
- Restore command status is 0, but the final independently observed origin is (200,391), which differs from the original (190,319). A successful restore command does not establish exact restoration.

The recorded geometry-client source hash is `861eafe255533b4a79f8f4d494bf42dea69920476f6896c0a5e2c95b14e78ce7`; the raw fixture hash file retains its executable and X11 helper hashes. The run source revision reviewed is `76946d6a`.

## Interaction boundary

Evidence directory: `/tmp/2754-packaged-38177219980-compact/comparison/AB-package/guest/interactions-post-geometry`.

Only phase-status.json is present. It reports capture-failed, PID 4618, speech_status unknown, and `Missing original Selection heading in interactions-fresh-text-before`. No capture command was reached. There is no compiled interaction client, API JSONL, edit result, action result, event listener, restart record, Orca log, or audio artifact from this phase.

I viewed `/tmp/2754-packaged-38177219980-compact/comparison/AB-package/guest/interactions-fresh-text-before.png`. The Type message modal is still visibly open, partly below the screen, and the Send-page background is dimmed. The driver's geometry escape event records xdotool return code 0, but the subsequent actual image does not support a closed-dialog state. The visible background Selection heading is not proof of successful modal dismissal; the whole-frame OCR exception is an observation boundary, not evidence that interaction editing failed.

The original GetName timeout may involve bridge dispatch or app-side behavior, but these raw records identify only the public call that did not return. They do not establish its internal blocking location or show a method reply trace.

## Process status and scope

The scenario log ends with the requested-interaction-phase failure raised by the UI driver. Recording status files now exist: ui_and_loader_exit_status 1, recorder_exit_status 255, clip_exit_status 1. This records a reached recorder termination/wait path, not valid geometry or speech.

This audit read retained JSON/JSONL, logs, source, and an original PNG. It did not execute a validator, script, test, build, application, VM, or cloud job, and did not edit the diagnostic clone. Source diagnosis of the unmatched call remains separate from these raw observations.
