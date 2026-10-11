# Controls and original-media audit — run 38184349418

This single-AB run has no control/B comparison. Audit is read-only: no source changes, apps, builds, tests, reproductions, cloud retries, or repaired evidence. Originals are in `/tmp/2754-packaged-38184349418-full/comparison/AB-package/guest`; derived stills and raw probe/decode data are in `/tmp/2754-run38184349418-media`.

## Actual controls

File and Folder open–Cancel–return passed. Visually inspected before/chooser/returned PNGs show Open File and Choose Directory, both with rendered Cancel/Open, and returned Send Selection controls. File observed after 4.9876s, Folder after 5.0743s. Both Cancel events clicked root (1142,738). Both returns report no visible native chooser and focused LocalSend, original PID 9207, window 39845891. Native chooser IDs were 39854660 (File), 39855821 (Folder). These support actual opening, cancellation, and return; no files were selected or transferred.

Paste was clicked at root (980,450), wall 1791761851.1829631. `keyboard-on-paste-result.png` visibly shows Files: 1, Size: 30 B with the message icon and Edit/Add controls. This establishes the enabled-keyboard real Paste result. Original sequence then cleared selection and reached subsequent Text cases.

## Five reached Text cases

All five recorded Text cases have visible Type message dialogs and corresponding typed input. The independent original-MP4 observations below use click.wall directly, not text-open (which follows command return). Source MP4 frame PTS are absolute epoch values: first 1791761636.0, last 1791762465.0. The nearest frame to click.wall+3s was extracted by decoded frame index, without timestamp changes.

| Case | click.wall | decoded frame | original PTS | error from click+3s |
|---|---:|---:|---:|---:|
| keyboard-off |1791761659.0353155|260|1791761662.0|35.32ms|
| keyboard-on |1791761759.075108|1261|1791761762.1|24.89ms|
| keyboard-on-repeat |1791761863.8759239|2309|1791761866.9|24.08ms|
| keyboard-off-again |1791761944.5187361|3115|1791761947.5|18.74ms|
| keyboard-on-stack |1791762024.7727728|3918|1791762027.8|27.23ms|

All five original extracted frames were visually inspected: modal plus expected case-specific typed control is present. These observations confirm the reached input path; one +3s frame per case does not establish onset latency or a patch/control timing comparison.

Keep instrumentation separate: keyboard-off, keyboard-on, keyboard-off-again are the original untraced timing cases. keyboard-on-repeat launches strace before the trigger; its retained per-thread trace files exist. keyboard-on-stack is a separate case with GDB capture at 10s; its +3s observed frame precedes GDB, but the case must not be presented as an entirely uninstrumented repeat. Native accessibility/geometry work begins only after these five cases, at wall 1791762093.2756717.

## Final scenario boundary

Geometry returns 3 with deadline_hit=false. It is not a timeout verdict. The interaction phase fails before a fresh Text trigger: Missing original Selection heading in interactions-fresh-text-before. Status is capture-failed, speech_status unknown. The final scenario exception reports the requested interaction phase did not complete. An events entry named completed does not override this failure. This audit does not diagnose geometry or interaction failure.

## Original MP4 and derived-clip distinction

Original scenario.mp4: H.264, 1280 × 800, nominal 10 fps, 829.100 s, 8291 frames, 9,093,019 bytes. Metadata probe exit 0; one full decode exit 0. Original SHA256:

`1802ba2c4ab9e5646a05c3dc4911a4707bc27f38f363ac377110f62f953cc033`

All 8291 original best_effort_timestamp_time values are present and strictly increasing; `original-pts-order.json` has non_increasing:[]. Full decode stderr contains 628 bytes of null-output-muxer non-monotonic DTS warnings, rather than a codec-corruption error. The original passes readability/full-decoding and retained frame-PTS ordering checks. These checks do not prove perfect capture timing or successful UI validation.

Recorder status 255 occurred with SIGINT shutdown; the readable finalized MP4 proves that this status alone is insufficient to claim corruption. clip_exit_status 1 and ui_and_loader_exit_status 1 remain independent failures. `recording-clips.log` rejects the FIRST DERIVED `recording-clips/keyboard-off.mp4` for Missing or non-monotonic source/frame PTS. That error names the derived clip, not scenario.mp4. Derived clips are not repaired, synthesized, or reused as passing evidence.

Raw command provenance:

```sh
rtk proxy ffprobe -v error -show_entries format=duration,size,start_time:stream=codec_name,width,height,r_frame_rate,nb_frames,start_time -of json ORIGINAL.mp4
rtk proxy ffmpeg -v error -i ORIGINAL.mp4 -f null -
rtk proxy ffprobe -v error -select_streams v:0 -show_frames -show_entries frame=best_effort_timestamp_time,pkt_duration_time -of json ORIGINAL.mp4
rtk proxy ffmpeg -nostdin -v error -y -i ORIGINAL.mp4 -vf 'select=eq(n\,FRAME_INDEX)' -fps_mode passthrough -frames:v 1 OUTPUT.png
```

The first attempted frame extraction used deprecated -vsync, which this host FFmpeg rejects; no evidence was produced by that command. The final extraction uses supported fps_mode passthrough and does not modify the source. Two exploratory filenames with missing initial letters were caused by FFmpeg reading the shell loop's stdin; both cases were re-extracted with explicit indices and -nostdin. Only correctly named outputs contribute to the final contact sheet.

Retained raw outputs: original-probe.json/.stderr, original-decode.stdout/.stderr, original-frame-pts.json, original-pts-order.json, click-frame-audit.json, original.sha256, audit-output.sha256. Contact sheets merely arrange/reduce original or extracted stills for inspection; original-plus3-contact.png contains five actual frames and an empty sixth slot. Product and original recordings remain unchanged.
