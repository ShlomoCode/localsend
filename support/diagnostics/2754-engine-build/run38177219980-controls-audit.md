# Native control and recording audit — run 38177219980

Read-only inspection of raw artifacts from source 76946d6a. No product edits, application launches, builds, tests, reproductions, or jobs. Originals remain unchanged in `/tmp/2754-packaged-38177219980-{compact,full}/comparison/{control-system,B-system,AB-package}/guest`. Derived inspection contact sheets and probe/decode outputs are in `/tmp/2754-run38177219980-controls-media`.

## Native File and Folder controls

All six File/Folder open–Cancel–return controls passed. Each variant's before, chooser-1, and returned frames were visually inspected in a derived contact sheet. Layout: top row File before/chooser/return; bottom row Folder before/chooser/return. The source PNGs were merely arranged and reduced to 50% for inspection, not repaired or synthesized.

All File chooser frames show the real GTK Open File window with Cancel/Open. All Folder chooser frames show the real GTK Choose Directory window with Cancel/Open. This run confirms the Folder title and action labels at runtime; they are no longer only source expectations. Returned frames show LocalSend's Send page with Selection and File/Folder/Text/Paste controls and no native chooser.

Both chooser types' actual live button TSVs recognize exact Cancel/Open at confidences 96.605789/96.425331. Events record each Cancel click at root (1142,738), then report an empty visible-chooser list and LocalSend focused under the original app PID:

| Variant | PID | File chooser | Folder chooser | Returned LocalSend window |
|---|---:|---:|---:|---:|
| control-system |4505|41950982|41952195|41943043|
| B-system |4492|39853820|39855016|39845891|
| AB-package |4618|37757448|37758599|37748739|

File observation elapsed 4.8256–5.1736s; Folder elapsed 5.0613–5.3708s. Each native window's retained geometry still reports X 194, Y 359, WIDTH 1096, HEIGHT 441. The rendered action anchor and derived button crop successfully avoid the previously demonstrated geometry-origin error.

This supports actual chooser opening, rendered controls, cancellation, chooser disappearance, same-app focus, and rendered Send return. It does not establish file selection or transfer.

## Actual scenario boundaries

Control-system and B-system proceed through File and Folder return, then stop before any enabled-keyboard Paste click: `Missing UI label Paste in keyboard-on-paste-before`, at click_word line 103. Their event streams end at the Paste-before screenshot. They do not reach enabled Paste result, repeated Text, restored-keyboard repeat, stacks, geometry, or interactions.

AB-package passes the controls and continues the original timing cases and stack sequence. It reaches geometry; geometry-capture-finished returns 3 with deadline_hit=false. Its interaction phase stops before a new Text trigger with `Missing original Selection heading in interactions-fresh-text-before`. The terminal scenario error is the requested interaction phase failing its process/API gates. `completed` in the events is not proof of successful interactions; the status is capture-failed, speech unknown. These are the observed boundaries, not causal conclusions about the geometry failure or original issue.

## Original recording integrity

All three recorder status files say recorder_exit_status 255, clip_exit_status 1, ui_and_loader_exit_status 1. Recorder logs terminate with `Exiting normally, received signal 2`. Therefore 255 must not be treated as proof that the MP4 is unreadable, and successful decoding must not override the separate UI/scenario failure.

The original full-artifact scenario.mp4 files were metadata-probed and fully decoded once each, without rewriting or repairing them:

```sh
rtk proxy ffprobe -v error -show_entries format=duration,size:stream=codec_name,width,height,r_frame_rate,nb_frames -of json ORIGINAL.mp4
rtk proxy ffmpeg -v error -i ORIGINAL.mp4 -f null -
```

| Variant | duration | frames | bytes | probe/decode exit |
|---|---:|---:|---:|---|
| control-system |216.000s|2160|3798338|0/0|
| B-system |216.400s|2164|3688208|0/0|
| AB-package |828.400s|8284|9118672|0/0|

All streams are H.264, 1280 × 800, nominal 10 fps. Full decode completed for all three; no codec corruption error was reported. Null-output muxer warnings report occasional non-monotonically increasing DTS: control 978 bytes of stderr, B 148 bytes, AB 742 bytes (exact outputs are preserved; sizes can be read from files). These timestamp warnings limit timing assumptions; this audit does not rewrite timestamps or claim frame-perfect action synchronization. Original recorder/process status and clip failure remain recorded independently of decode success.

Artifacts preserved: VARIANT-contact.png, VARIANT-probe.json/.stderr, VARIANT-decode.stdout/.stderr. The contact sheets support PNG inspection only. The full decode confirms readability of the original video stream; continuous video playback/action timing was not substituted for the retained PNG/event evidence.
