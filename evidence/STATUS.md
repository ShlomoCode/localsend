# Issue 2830: long clipboard transfer freezes Android

Status: Preparing the cloud reproduction. No application experiment has run for this issue. No production patch exists.

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
