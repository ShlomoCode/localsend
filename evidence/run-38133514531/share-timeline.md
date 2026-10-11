# Native Share observation

This run reached the native LocalSend share path but did not establish Selection, input response, or an ANR for the 16GB file. The observer stopped on an accessibility error before its planned300s window. The accepted experiment count remains3.

## Controller clock (UTC)

- 10:57:12.014: small helper Share action;10:57:15.556: observed chooser LocalSend target touch.
- 10:57:19.186: actual Enter address response;10:57:28.648: Selection observed after focused127.0.0.1 entry and Cancel.
- 11:04:45.246: large helper Share action with owned content://media URI141, exactly16000000000bytes.
- 11:05:03.959: actual observed LocalSend target touch after two bounded chooser gestures.
- First-frame PNG: dimmed helper; XML: empty android system window. No semantic Manual sending bounds, and no stale-coordinate input was sent.
- 11:05:41.450: stage ends incomplete on root AccessibilityNodeInfo15510ms timeout. Source failure is retained; it does not prove app ANR.

## Device log clock

- 11:05:07.080: I/FileDirectory, pid6616, exact name issue3556-1791716276913-16000000000.mp4 (device-logs-redacted.log:1284).
- 11:05:12.290–17.055: fixture helper surface is destroyed/stopped (lines1288–1300). This does not identify the resulting foreground Activity by itself.
- 11:05:13.515,36.158,58.785: LocalSend process GC records (lines1296,1304,1311); these do not establish UI responsiveness or copy progress.
- 11:06:15.899–912: relay cleanup; no later UI outcome is available.

The log has PID only; it supplies neither TID nor native stacks. Exact APK sources show the logged seam then cacheFile creation, content InputStream/FileOutputStream and synchronous8KiB copy loop. Static call chains and this seam do not establish runtime main-thread execution or the reporter's cause.

## Source-video time

The preserved source is705.772267s h264800x800/60fps, without audio. Video times remain separate from controller/device clocks; provider video start/clock alignment has not been established exactly.

- Small:139/141s chooser;143s Selection Files:1 Size:1.0MB;145s Enter address;147s actual127.0.0.1 and keyboard;149s Selection.
- Large:603.50s chooser;603.75s closing;604–609s dimmed helper;609.25–704s nearly black with navigation marks.
- No visible launcher, Selection or ANR dialog in the retained large interval. A black frame alone does not establish main-thread blockage, crash or copy progress.

## Next discriminator

Run38135607838 preserves screenshot and focused package/activity before each source read, retains ordinary logcat when available, and continues only the exact accessibility timeout for bounded900s. It compares native Share1MiB,64MiB and16GB on the original app. Source-independent observations distinguish a tree failure from changing visible UI/foreground. An actual Selection then legitimate Manual input/Cancel, or a visible ANR with observed Wait, is required before claiming an outcome. No ordinary API for release private-cache byte-growth or native thread stacks has been established; no shell/provider permission or production app is changed.
