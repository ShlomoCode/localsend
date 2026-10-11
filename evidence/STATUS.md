# Issue 2414 investigation

Status: preparing cloud real-app harness. No reproduction observed yet.

Reported behavior: sending a directory with 5,000 files to an old PC, then receiving Options, causes hang, large memory use, and OOM. Reporter attributes it to eager file widgets. OS, architecture, exact version, RAM, filename lengths, and file content are unspecified. Other comments about large-file transfers/timeouts are separate claims and will not replace this one.

Historical baseline: unmodified v1.17.0 Linux x86-64 TAR release, published 2025-02-20. Report date: 2025-04-21. Report source commit 09b9482 dates 2025-03-17. This makes 1.17 plausible, not confirmed reporter version.

Candidate existing correction: 76a356a2dd12404d2ce482b8b6aa4cf3afc7b6be (2026-08-08), included v1.18.0+, changes receive Options to ResponsiveListView.builder. Unproven hypothesis. No production patch authorized before valid failure.

Plan: validate small-directory real app selection/send/receive Options/save on cloud host; repeat 5,000 ordinary fixed-content files; run ordinary 2CPU/2GiB Linux guest configuration; measure UI response, RSS/PSS, CPU, available memory; repeat baseline. Then isolate exact correction and current source using identical flow. No artificial per-process memory limit. One Actions job at a time. No BrowserStack.

First cloud run [38103697333](https://github.com/ShlomoCode/localsend/actions/runs/38103697333) starts both original 1.17 apps successfully. The screenshot contains Send, but OCR misses its small text, so selection never happens. Classified as harness failure, not reproduction/nonreproduction. Fix: OCR a 2x copy of the screenshot and keep original pixels for evidence. VM script prepared but not run until small-directory flow validates.

Thread completeness checked through live API on 2026-10-11: issue comments=4 and per_page=100 returns four comments (evidence/comments-2026-10-11.json). No pagination missing. 2025-04-24 dchang0: 3–6 200MB files and post-transfer hang, distinct trigger. 2025-12-17 toshiya14: 10k–100k selected files before transfer, adjacent sender-side performance claim, not receiver Options. 2026-02-27 rtsui-mk: Android sender and ten files/10GB blank screen, distinct trigger. 2026-04-20 dchang0: delayed send timeout, explicit hypothesis and distinct trigger. Comment URLs retained in JSON.

Second cloud run 38103844295 still missed Send in OCR. The actual screenshot establishes Send at (96,188) under the fixed 1000x700 window geometry. Use observed coordinates for that one navigation control, then verify resulting screen. Enlarge-only OCR did not resolve this. Added real peer network namespaces with separate veth IPs and the same default port, avoiding protocol injection and incompatible discovery ports.
