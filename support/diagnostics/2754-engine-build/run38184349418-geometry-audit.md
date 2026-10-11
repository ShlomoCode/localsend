# Run38184349418: independent geometry and interaction gate audit

Retained evidence only. No applications, builds, tests, syntax execution, source changes, or dispatches. Evidence root: /tmp/2754-packaged-38184349418-compact/comparison/AB-package/guest. Stack/transport correlation is separately owned by the consumer reviewer; this report does not infer the internal cause of the unmatched public call.

## Result

Strict geometry did not complete. Both geometry-client processes hit their unchanged180s external deadlines before recording any node or geometry result. The preserved validator also failed to compile. The later interaction harness did not start because its fresh-page observation failed while the prior Text modal was still visibly open. Editing, accessible actions, lifecycle/restart, Orca speech, and audio delivery remain untested.

## Raw geometry

geometry-post-timing/before.jsonl and after.jsonl each have102 lines. Both record GetProcessId call47 for bus :1.29, path /org/a11y/atspi/accessible/root, result9207. They record SetCacheMaskNone48 and ClearCacheSingle49 returning, then public GetName call50 entering at11.399ms before /14.199ms after. Neither contains its return. Each ends process_exit status124, deadline_hit:true. GetName is the public trace label, not proof of an exact wire method or server-side sink.

Both contain a root_public_snapshot explicitly labelled public cached fields, not a live property query: cached_name empty, cached_role0, cached_properties0, is_application_root:true. This is not a returned live name or successful traversal. Neither stream contains recorded nodes, extents, point queries, or completed traversal summaries.

Driver phase-status says capture-finished, returncode3, deadline_hit:false. That is the outer450s command result; it does not erase the two inner180s deadlines. Driver events place geometry-modal-rendered at t648.893421439 and geometry-capture-finished at t1010.304300523, about361.411s later. The phase label means the command returned, not a geometry pass.

validation.stderr preserves the known two jq compile errors at line78, unparenthesized subtraction in host_delta. The validator did not evaluate raw records. geometry-comparison.json remains probe_status:incomplete / capture did not finish, and geometry-comparison.tmp.json is zero bytes. Parser failure and client deadlines are independent failures; fixing parsing alone cannot supply absent geometry data.

Fixture source hash: geometry-client.c861eafe255533b4a79f8f4d494bf42dea69920476f6896c0a5e2c95b14e78ce7. Executable hash b8b6b451ceeee185c84cd6272ec6e0ea05bf2002dc1fe27f4148ae234710404e. These are read from fixture-sha256.txt, not locally rebuilt.

## Actual X11 position

All independent X11 observer status files inspected are0. Window39845891 retains appPID9207 and size1100x700.

| Observation | Client origin |
| --- | --- |
| before | 190,319 |
| before-end | 190,319 |
| after | 280,451 |
| after-end | 280,451 |
| restored | 200,391 |

Requested move is280,419, based on separate xdotool host-before200,359 plus80,60. Actual independent client displacement is90,132. Move and restore command status are both0. Actual restored client origin differs from original by10,72; command success does not establish exact restoration. The separate host-restored observation is210,431.

## Rendered modal / fresh-page boundary

I independently viewed the original geometry-fresh-text-before.png, geometry-modal-wait-1.png, interactions-fresh-text-before.png, interactions-phase-final.png, and the saved modal-gate crop.

- geometry-fresh-text-before.png shows the undimmed Send page with Selection and Text visible, no Text dialog. The gate crop is only a lower-page region and is not a whole-window observation by itself.
- geometry-modal-wait-1.png shows the Type message dialog open and the background dimmed. Driver emits geometry-modal-rendered after this capture. The actual Text modal was therefore reached before geometry queries.
- events.json records geometry-phase-escape at t1010.322606164, returncode0. The next screenshot is interactions-fresh-text-before.png at t1010.448851818, roughly126ms later.
- That actual screenshot still shows Type message open, a caret in its input, dimmed background, and lower dialog content below the screen edge. It is not a fresh ready page. A visible background Selection label does not establish modal dismissal.
- Whole-frame interactions-fresh-text-before.tsv recognizes Type/message and omits Selection. The missing original Selection exception is an OCR/setup observation boundary. It is not evidence that an accessible edit/action operation failed.
- interactions-phase-final.png later shows the undimmed Send page without the modal; its TSV recognizes Selection. This later cleanup image cannot retroactively establish that the initial interaction boundary was ready.

## Interaction and speech gates

interactions-post-geometry contains only phase-status.json: capture-failed, appPID9207, window39845891, speech_status:unknown, error Missing original Selection heading in interactions-fresh-text-before, deadline_hit:false. No interaction-client stream, editing/API verdict, action/event record, restart observation, Orca record, or speech/audio artifact exists in the inspected guest inventory. events.json contains no later interaction harness execution evidence; it records interactions-phase-ended failure and completed.

scenario.log ends with the UI driver's RuntimeError that the requested interaction phase did not complete its process/API gates. Do not treat the driver completed event as acceptance. Recording files report ui_and_loader_exit_status1, recorder_exit_status255, clip_exit_status1. recording-clips.log reports Missing or non-monotonic source/frame PTS for derived keyboard-off.mp4. No media repair or decoding probe was performed here, and no valid speech delivery is inferred from screen recording artifacts.

The run preserves the diagnostic failure and reaches recording status retention, but establishes no strict geometry, interaction, or speech pass.
