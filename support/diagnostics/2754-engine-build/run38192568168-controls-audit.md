# Controls and recording audit for run 38192568168

The AB-only run completes the original UI controls and five Text cases, then fails in post-timing accessibility capture and before the interaction trigger. The original recording is readable. This evidence does not compare AB with control or B, because neither cohort ran.

This audit reads retained artifacts only. No product changes, local applications, tests, builds, inferiors, reproductions, cloud retries, or network requests were performed. Retained-media processing was limited to arranging existing Text screenshots, probing the original MP4, and decoding it once. Source and original recordings remain unchanged.

## Completed UI paths

File and Folder native opening, cancellation, and return complete under app PID 4736. Visually inspected chooser screenshots show **Open File** and **Choose Directory**, respectively, with **Cancel** and **Open**. Both Cancel events click root coordinates (1142, 738). The returned screenshots show the Send page and its **Selection**, **File**, **Folder**, **Text**, and **Paste** controls. Return events report an empty visible-chooser list and focused **LocalSend**, original PID 4736, window 37748739. Native chooser windows were 37757458 and 37758629. Observation took 4.9884 seconds for File and 5.1705 seconds for Folder.

Enabled-keyboard Paste is clicked at (980, 450), wall time 1791769667.3525236. The result screenshot visibly shows **Files: 1**, **Size: 30 B**, a message icon, **Edit**, and **Add**. Subsequent Text events establish that the driver continued after clearing this selection.

All five Text cases are reached. Their retained `*-3.png` screenshots visibly show **Type message** and the corresponding case-specific typed input. These are screenshot observations, not independently measured modal onset times. The click wall times are:

| Case | Text click wall time | Instrumentation distinction |
|---|---:|---|
| keyboard-off |1791769475.1043873|Original untraced timing case|
| keyboard-on |1791769575.168912|Original untraced timing case|
| keyboard-on-repeat |1791769679.911392|Separate repeat with strace launched before the trigger|
| keyboard-off-again |1791769760.2221382|Original untraced timing case|
| keyboard-on-stack |1791769840.424111|Separate case with GDB capture at 10 seconds|

The five-image inspection sheet is `/tmp/2754-run38192568168-media/text-contact.png`. It arranges existing screenshots without modifying them. This audit does not derive a timing improvement, compare against missing cohorts, or treat the instrumented repeats as clean timing controls.

## First failure and deadline distinction

The first recorded nonzero subprocess outcome in the post-timing capture is `before.jsonl`'s `process_exit`: status 124, `deadline_hit:true`. It follows root `GetName` query entry (call 50), with no completion entry in that client log. `after.jsonl` independently records the same status 124 and deadline flag at its root GetName entry. The source gives each public-client capture a 180-second timeout. This report does not assign causality to those blocked calls; other agents own wire and debugger interpretation.

The encompassing geometry capture later returns 3. Its phase status records `capture-finished`, `returncode:3`, `deadline_hit:false`, and `rendered_modal_observed:true`. That false flag describes the encompassing 450-second command, not the two inner public-client deadlines. The geometry comparison contains `probe_status:"incomplete"`, `reason:"capture did not finish"`. Neither geometry nor speech/editing validation passed.

After geometry capture, the driver logs a successful Escape command at wall time 1791770277.500029. A command exit of zero does not establish modal dismissal. The next `interactions-fresh-text-before.png` still visibly shows the prior **Type message** dialog with an empty focused input. The app has shifted to approximately (200, 359); the dialog's lower portion extends below the visible desktop area. **Selection** remains visibly present behind the dimmed modal, although full-screen OCR does not report the required exact heading.

The interaction phase stops inside `click_word("Text", ...)`: exact Text is missing, the Text fallback requires an exact OCR **Selection** anchor, and the missing anchor raises `Missing original Selection heading in interactions-fresh-text-before`. The driver never reaches a new Text click, its fresh-modal gate, the interaction fixture launch, or speech/editing actions. Its status is `capture-failed`, `deadline_hit:false`, `speech_status:"unknown"`. The final scenario exception reports the interaction phase did not complete. The later event named `completed` does not override these statuses.

## Recorder and clip outcomes

Status files retain `recorder_exit_status=255`, `clip_exit_status=1`, and `ui_and_loader_exit_status=1`. The clip log fails its first derived `recording-clips/keyboard-off.mp4` for missing or non-monotonic source/frame PTS. Derived clips were not repaired or substituted as passing evidence.

The original full-artifact `scenario.mp4` passes a metadata probe and one full decode, both exit 0. It is H.264, 1280 × 800, nominal 10 fps, with 8,291 frames, duration 829.100 seconds, and size 8,892,609 bytes. Format start time is 1791769451.900000. SHA-256 is:

`1d89c28799ab50756bb341e39c63a8cf713951e89a70b65f12d836102fcac876`

Full decode emits null-output-muxer warnings about non-monotonically increasing DTS, with no reported codec corruption. Decode success confirms original stream readability; it does not certify perfect timing, derived-clip validity, or scenario success. This audit did not independently check every original frame PTS for strict ordering.

The retained-media commands were:

```sh
rtk proxy ffprobe -v error -show_entries format=duration,size,start_time:stream=codec_name,width,height,r_frame_rate,nb_frames -of json ORIGINAL.mp4
rtk proxy ffmpeg -nostdin -v error -i ORIGINAL.mp4 -f null -
rtk proxy shasum -a 256 ORIGINAL.mp4
```

`ORIGINAL.mp4` is `/tmp/2754-packaged-38192568168-full/comparison/AB-package/guest/scenario.mp4`. Tool output preserves the metadata and decode result. The raw scenario statuses, geometry logs, screenshots, and source remain the authoritative evidence for this run.
