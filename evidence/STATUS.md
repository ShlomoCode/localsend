# Issue 2830: long clipboard transfer freezes Android

Status: Repairing the cloud UI harness. The original Windows app reached Send, but the Clipboard action was not executed. No app-to-app control or reported failure has been established. No production patch exists.

## Report and evidence boundary

The reporter uses Dell Inspiron 3501, Windows 11 Pro, and Xiaomi Redmi Note 10 Pro, MIUI 14, Android 13. They describe roughly 105K clipboard text and select Send → Clipboard → target in the Windows application. The Android application freezes until removed from recents. The source does not define K, encoding, number of lines, acceptance setting, or precise LocalSend version. Version 1.17.0 is a date-based inference, not reporter confirmation.

## Cloud plan

1. Use original release applications on both ends. Record each downloaded artifact SHA-256 and package/version metadata.
2. Establish Windows Send → Clipboard → Android short-text control through actual application UI. Relay controls supplement this gate but cannot replace it.
3. Send deterministic ASCII payloads: 105000 characters without line breaks, 105000 characters including LF line breaks, and 107520 characters (105 KiB). Record UTF-8 and Windows UTF-16 clipboard sizes separately.
4. Observe incoming prompt, acceptance, displayed text, and UI response at fixed deadlines. Capture before, trigger, and outcome screenshots, video, source, BrowserStack logs, relay timing, and permitted lifecycle/resource diagnostics.
5. Repeat any matching failure under identical conditions. Then select an experiment that discriminates its cause before proposing a patch.

## Environment gaps

- No device reservation or Actions job is active for this issue.
- The shared transport is validated as byte-exact, but the actual app-to-app control is still being validated by the 3393 investigator.
- Windows 11 runner is ARM with original x64 release under emulation. Dell hardware and native x64 remain different.
- BrowserStack Android 13 device availability and Xiaomi/MIUI coverage remain unconfirmed.
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
