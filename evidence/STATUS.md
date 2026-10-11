# Issue 2830: long clipboard transfer freezes Android

Status: Short-text control, 105,000 ASCII characters without line breaks, 105,000 characters with LF line breaks, and 105 KiB passed on Galaxy S23 / Android 13. Xiaomi short control 38110353448 failed during Favorites discovery; 38111742971 repeats it with Windows error details and MIUI/build diagnostics. The reported Android freeze has not been reproduced. No production patch exists.

## Report and evidence boundary

The reporter uses Dell Inspiron 3501, Windows 11 Pro, and Xiaomi Redmi Note 10 Pro, MIUI 14, Android 13. They describe roughly 105K clipboard text and select Send → Clipboard → target in the Windows application. The Android application freezes until removed from recents. The source does not define K, encoding, number of lines, acceptance setting, or precise LocalSend version. Version 1.17.0 is a date-based inference, not reporter confirmation.

## Cloud plan

1. Use original release applications on both ends. Record each downloaded artifact SHA-256 and package/version metadata.
2. Establish Windows Send → Clipboard → Android short-text control through actual application UI. Relay controls supplement this gate but cannot replace it.
3. Send deterministic ASCII payloads: 105000 characters without line breaks, 105000 characters including LF line breaks, and 107520 characters (105 KiB). Record UTF-8 and Windows UTF-16 clipboard sizes separately.
4. Observe incoming prompt, acceptance, displayed text, and UI response at fixed deadlines. Capture before, trigger, and outcome screenshots, video, source, BrowserStack logs, relay timing, and permitted lifecycle/resource diagnostics.
5. Repeat any matching failure under identical conditions. Then select an experiment that discriminates its cause before proposing a patch.

## Environment gaps

- One owned job/session at a time is allowed for this issue; the Xiaomi short-control job is currently active.
- The shared transport and actual short-text app-to-app control have passed.
- Windows 11 runner is ARM with original x64 release under emulation. Dell hardware and native x64 remain different.
- Galaxy S23 / Android 13 is available. Xiaomi Redmi Note 11 / Android 11 is the next comparison; its MIUI version is unknown. Redmi Note 10 Pro / MIUI 14 / Android 13 remains uncovered.
- BrowserStack public devices reject unrestricted ADB. Memory/CPU and lifecycle trace coverage must be determined with supported commands; absence of those metrics will be explicit.

## Gates

Baseline failure: unmet. Deterministic failure: unmet. Cause: unmet. Fix: not started. Same-scenario validation: unmet. Independent review: not applicable yet. Internal PR: not started.

## Current execution

Cloud run 38103974509 on diagnostic commit b658c1b reached the Windows Send page but failed before Clipboard selection. It cannot establish an app-to-app control or reproduce the Android freeze. The separate BrowserStack session has not started. Live capacity before preparation was 0 of 5 running sessions. The catalog has Redmi Note 11 / Android 11 only; Samsung Galaxy S23 / Android 13 is the selected initial comparison environment. Xiaomi Redmi Note 10 Pro, MIUI 14, remains uncovered.

## Resumed investigation

Read the complete issue snapshot and REST comment page on 2026-10-11. A fresh issue metadata read confirms one comment, matching both retained snapshots. The comment asks whether an English version would be better and adds no reproduction details. The issue was created on 2025-11-15; the stated latest release remains an inferred 1.17.0.

Run 38103974509 failed at `windows2830-ui.ps1:19`: `FindWindowEx` returned no immediate child named `FLUTTERVIEW`. This happened before mouse input. `app-window-send.png` shows the original app's Send page, including the partially visible Paste tile; `release-ui-report.json` records PID 244 and a visible 400×500 `FLUTTER_RUNNER_WIN32_WINDOW`. The result is a harness failure, not an Android freeze.

The next diagnostic changes only input targeting: enumerate descendant HWNDs with class, parent and PID; hit-test the requested client point; map coordinates into the child; reject a target from another process. This reuses the original release startup helper's hit-test method. A fresh cloud run will preserve both the window tree and the post-click screenshot. It must demonstrate clipboard selection before the app-to-app run.

Live BrowserStack capacity after resumption: zero sessions running, shared maximum five. No session was created by this investigator.

Readiness run 38104902432 on 3a8a9b02 passed. Inspected screenshot shows one selected text item, 44 B. The fixture reports 44 ASCII characters, 44 UTF-8 bytes, 88 UTF-16 bytes, successful Windows clipboard roundtrip, and SHA-256 `10f6b75f53e5d94f86ef113f23647fba57e411f34f8ba74c30ca334e92b02fd4`. The recorded target is FLUTTERVIEW, PID 3836, matching the parent and enumerated child. This proves Windows clipboard selection only.

The physical control uses the unmodified 1.17.0 Android arm64 release, SHA-256 `2c7f5fd4872da25115bb8e5e62f92de94dda47b0f249ff387ac667b13871dc3e`, uploaded as `bs://574bec77a4f5e69c930410dd76792eac94625a15`. The diagnostic workflow reuses 3393's foreground BrowserStack Local process in the same step as session creation, with a live plan check before starting the owned issue2830 session. The relay/service copies come from shared transport 187f39d1; helper UI inset handling comes from 3393 commit 6c171bc0. All changes are diagnostic and remain outside a production PR.

Physical run 38105952674 on 9629ea87 created its own Galaxy S23 / Android 13 session, f83d6c380f5021a64e8547568ee57b3b44e45bd5. The helper Start button is visible and Appium records a successful click. Device logs show service-start at 02:46:08.171 UTC, GET /pull IOException at 02:46:08.267, then service-destroy. No byte control completed and LocalSend was never activated. The session timed out after 134 seconds; the controller's first socket read ended with ECONNRESET. This is an infrastructure failure.

Comparing the workflow with 3393 found that this run generated RELAY_TOKEN through GITHUB_ENV and built the helper in the same step. GitHub exposes the new environment value to subsequent steps, so the helper build could not receive it while the controller's later step did. The next run separates helper building into the next step and records only boolean presence and length on both sides. HTTP exception details and unauthorized request traces are added without recording credentials. The first run did not record the HTTP status, so 401 is a prediction until discriminated, not a captured fact. The retry also corrects the portable preference keys to `flutter.ls_alias` and `flutter.ls_favorites`, as verified by 3393's actual Favorites dialog.

Run 38106982847 on bbd4b1c2 passed all four byte controls (0, 1, 65,537, and 8,388,608 bytes) with exact hashes and replies after half-close on Galaxy S23 / Android 13. Both capability reports show presence true and length 48. This restores the transport gate after separating the build step. The original Android LocalSend activated. Windows startup then exited 1 despite a valid Send screenshot, errors [], and imageChanged true. The retained startup helper's final exit condition only accepted file-selection statuses; it omitted its StartupOnly statuses. The next run corrects that diagnostic exit gate, requiring StartupOnly, no errors, a verified Send image transition, and a captured status. No real app-to-app transfer has occurred yet.

Run 38107484781 on 3f8cd787 passed the same byte controls and reached Windows clipboard selection and the actual Favorites target. The Windows target screenshot shows Error; Android stays on the normal Receive page. The helper handoff failed before any app response: device logs show the control service destroyed at 03:14:50.711 UTC, a new relay service started at 03:14:51.390, and GET /pull returned HTTP 409 at 03:14:51.435. The relay permits one pending long poll, lasting up to 15 seconds. Stopping the first service did not immediately release that pending request. The next diagnostic waits for the relay's explicit pending-poll state to clear, with a 20-second deadline, before starting the LocalSend relay. This is a transport handoff failure, not the reported Android freeze. Short-text app-to-app control remains unmet.

Run 38108176962 on c3bc4478 passed the actual short-text UI control. The Windows original 1.17 app selected the 44-byte clipboard item and sent it through Favorites. Android original 1.17 on Galaxy S23 / Android 13 showed the exact text. Its first preview source response took 197 ms. Clicking Copy dismissed the preview; the clipboard readback is byte-identical to the source, with SHA-256 `10f6b75f53e5d94f86ef113f23647fba57e411f34f8ba74c30ca334e92b02fd4`. Both before/after screenshots were inspected. The transport handoff waited 14,686 ms until the pending poll ended. Next: repeat this sequence with 105,000 ASCII characters, keeping device, releases, settings, and harness unchanged.

Run 38108693595 on the same c3bc4478 passed the actual 105,000-character ASCII transfer without LF or CR. Windows clipboard roundtrip verified 105,000 UTF-8 bytes and 210,000 UTF-16 bytes. Android displayed the preview, Copy dismissed it, and readback matches all source bytes: SHA-256 `83b801b3087bde5b41b2309cd1e364dbcccf7d9a8c86652a8479e08d3bffaf5a`. The result field sourceMatches=false means that the supplementary XML equality check runs only for the short fixture; clipboardVerified=true is the complete-content assertion. This is non-reproduction for the stated fixture and Galaxy S23 environment, not proof of resolution on Xiaomi/MIUI or attribution to any fix.

Run 38109163891 on unchanged c3bc4478 passed the 105,000-character LF fixture on the same applications and Galaxy S23. The source contains 1,640 LF characters and no CR; UTF-8 is 105,000 bytes, UTF-16 is 210,000 bytes. Both source and clipboard readback have SHA-256 `caad1d316ceadf1c0b89ce451b846056c35476f84fd662c7c32177fd7c60c838`. Inspected screenshots show the real preview and the Receive page after Copy, with Quick Save Off. The first preview source response took 351 ms. See `source-matches-erratum.md` for the unchanged raw result-field semantics. Run 38109605530 now changes only the fixture to 107,520 ASCII characters (105 KiB).

Run 38109605530 on unchanged c3bc4478 passed 107,520 ASCII characters (105 KiB), without LF/CR, on Galaxy S23. Source and clipboard readback have SHA-256 `0dbb926773683d012337417d054047989fa9eed6319736bec4e26931ccf1da56`; UTF-16 is 215,040 bytes. Inspected preview and after-Copy screenshots confirm visible preview and return to Receive. The first preview source response took 333 ms. Run 38110353448 uses diagnostic 721bfc80 and the same original applications for a short-text Xiaomi Note 11 / Android 11 control. Its MIUI version is unknown.

Supplementary memory snapshots are available despite rejected `dumpsys activity` commands. Multiline PSS is 277,208→308,309 KiB and RSS is 380,084→412,696 KiB, before/preview. ASCII PSS is 256,023→311,900 KiB. These are snapshots in separate non-failing sessions, not peak memory or ANR measurements; they do not establish a cause.

Xiaomi short run 38110353448 / 721bfc80 passed all four socket controls and the pending-poll handoff (14,385 ms). The original Android app remains on Receive; inspected before/receiver screenshots show different positions of its animated logo, while Windows Favorites shows Error. No preview appeared and no text transfer was completed. Relay metrics show 2,542 bytes returned after the controls, with two additional connections closing. Retained device logs show target-connected/eof for those connections and continued relay polling, without a 409, connection-refused message, or ANR. This is a discovery/readiness failure, not the reported long-text freeze, and does not count as a substantive application experiment.

Run 38111742971 / 9eccc165 repeats the same 44-byte fixture, original applications, and Xiaomi device. It adds MIUI/build property diagnostics and a Windows error-details screenshot after failure; transport, timeouts, and product behavior are unchanged. Exact error text is needed before choosing a readiness correction.
