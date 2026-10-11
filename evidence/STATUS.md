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

Cloud run 38103974509 on diagnostic commit b658c1b verifies the Windows short-text clipboard selection only. It cannot establish an app-to-app control or reproduce the Android freeze. The separate BrowserStack session has not started. Live capacity before preparation was 0 of 5 running sessions. The catalog has Redmi Note 11 / Android 11 only; Samsung Galaxy S23 / Android 13 is the selected initial comparison environment. Xiaomi Redmi Note 10 Pro, MIUI 14, remains uncovered.

## Resumed investigation

Read the complete issue snapshot and REST comment page on 2026-10-11. A fresh issue metadata read confirms one comment, matching both retained snapshots. The comment asks whether an English version would be better and adds no reproduction details. The issue was created on 2025-11-15; the stated latest release remains an inferred 1.17.0.

Run 38103974509 failed at `windows2830-ui.ps1:19`: `FindWindowEx` returned no immediate child named `FLUTTERVIEW`. This happened before mouse input. `app-window-send.png` shows the original app's Send page, including the partially visible Paste tile; `release-ui-report.json` records PID 244 and a visible 400×500 `FLUTTER_RUNNER_WIN32_WINDOW`. The result is a harness failure, not an Android freeze.

The next diagnostic changes only input targeting: enumerate descendant HWNDs with class, parent and PID; hit-test the requested client point; map coordinates into the child; reject a target from another process. This reuses the original release startup helper's hit-test method. A fresh cloud run will preserve both the window tree and the post-click screenshot. It must demonstrate clipboard selection before the app-to-app run.

Live BrowserStack capacity after resumption: zero sessions running, shared maximum five. No session was created by this investigator.
