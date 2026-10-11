# Issue 2414 investigation

Status: preparing cloud real-app harness. No reproduction observed yet.

Reported behavior: sending a directory with 5,000 files to an old PC, then receiving Options, causes hang, large memory use, and OOM. Reporter attributes it to eager file widgets. OS, architecture, exact version, RAM, filename lengths, and file content are unspecified. Other comments about large-file transfers/timeouts are separate claims and will not replace this one.

Historical baseline: unmodified v1.17.0 Linux x86-64 TAR release, published 2025-02-20. Report date: 2025-04-21. Report source commit 09b9482 dates 2025-03-17. This makes 1.17 plausible, not confirmed reporter version.

Candidate existing correction: 76a356a2dd12404d2ce482b8b6aa4cf3afc7b6be (2026-08-08), included v1.18.0+, changes receive Options to ResponsiveListView.builder. Unproven hypothesis. No production patch authorized before valid failure.

Plan: validate small-directory real app selection/send/receive Options/save on cloud host; repeat 5,000 ordinary fixed-content files; run ordinary 2CPU/2GiB Linux guest configuration; measure UI response, RSS/PSS, CPU, available memory; repeat baseline. Then isolate exact correction and current source using identical flow. No artificial per-process memory limit. One Actions job at a time. No BrowserStack.

First cloud run [38103697333](https://github.com/ShlomoCode/localsend/actions/runs/38103697333) starts both original 1.17 apps successfully. The screenshot contains Send, but OCR misses its small text, so selection never happens. Classified as harness failure, not reproduction/nonreproduction. Fix: OCR a 2x copy of the screenshot and keep original pixels for evidence. VM script prepared but not run until small-directory flow validates.

Thread completeness checked through live API on 2026-10-11: issue comments=4 and per_page=100 returns four comments (evidence/comments-2026-10-11.json). No pagination missing. 2025-04-24 dchang0: 3–6 200MB files and post-transfer hang, distinct trigger. 2025-12-17 toshiya14: 10k–100k selected files before transfer, adjacent sender-side performance claim, not receiver Options. 2026-02-27 rtsui-mk: Android sender and ten files/10GB blank screen, distinct trigger. 2026-04-20 dchang0: delayed send timeout, explicit hypothesis and distinct trigger. Comment URLs retained in JSON.

Second cloud run 38103844295 still missed Send in OCR. The actual screenshot establishes Send at (96,188) under the fixed 1000x700 window geometry. Use observed coordinates for that one navigation control, then verify resulting screen. Enlarge-only OCR did not resolve this. Added real peer network namespaces with separate veth IPs and the same default port, avoiding protocol injection and incompatible discovery ports.

Third cloud run 38104034501 confirms real TCP discovery across 10.84.24.2→10.84.24.1 with the same default port (sender log). Send navigation succeeds; screenshot shows Folder at (514,150), but OCR again omits its label. Use the observed Folder bounds. Corrected historical Options assertion: the UI calls the destination section Save to folder, not Destination. No failure claim before the control passes.

Fourth run 38104220074 opens the real GTK Choose Directory dialog and types the real fixture path. It stays in the chooser, so the target assertion is never reached. Initial picker screenshot was taken before the dialog appeared. Next run waits for its Recent label, then navigates and confirms with separate Return actions. This remains infrastructure; no Options measurement has occurred.

Fifth run 38104458684 remains in the legitimate empty-subdirectory chooser (the directory contains files, and the chooser lists folders). Its Open button is disabled with no row selected. Next use the ordinary user workflow: navigate to the parent, select the fixture directory row, and select Open. Download briefly hit HTTP 418; the configured SOCKS5 proxy retrieved the artifacts successfully. This is not a substantive bug experiment.

Sixth run 38104757974 still shows Recent-style columns and no directory rows after typing the parent path. The path entry is visible, but navigation is not established. Next capture native AT-SPI tree before/after, list the real fixture from inside the peer namespace, explicitly focus Choose Directory, and use a completed path ending in slash. Adopt csv.QUOTE_NONE for Tesseract TSV: agent 2007 separately proved literal UI quotes can make the default CSV parser swallow subsequent rows. No safety control is being bypassed; these are our own disposable cloud apps and fixtures.

Seventh run 38105053406 verifies all five files exist in the sender namespace. Native AT-SPI inspection times out; GTK still stays in Recent. The sender uses the receiver's D-Bus session despite separate network stacks. GTK and accessibility services may use namespace-scoped abstract sockets. Next give the sender its own ordinary dbus-run-session while retaining the same X11 display and real files. This tests an infrastructure explanation; no Options failure has been observed.

Eighth run 38105399609 gives the sender a separate D-Bus session but still fails to locate the fixture directory. Screenshot folder-row-0 shows Recent with no location entry after Return; later screenshot folder-row-8 shows the receiver foreground. This does not establish navigation or an Options result. Next run swaps network roles: sender on ordinary host desktop, receiver in separate namespace/D-Bus session; captures explicit location-entry and typed-path stages; restricts execution to five-file control. Also records actual receiver PID for memory sampling.
