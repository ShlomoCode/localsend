# Issue 1774 bounded native display-size diagnostic

This source-only harness proposes one original-app scenario on BrowserStack Samsung Galaxy S23 Android 13. It does not patch LocalSend or reopen fork PR 59. The reported model, release and installation source are unknown; tested 1.18.2 and S23 identities must stay explicit in results.

Use the existing uploaded unchanged official 1.18.2 ARM64 APK bound by `original-apk-binding.json`. `prepare.mjs` resolves only that exact reference hash through a read-only recent-app inventory. If it is unavailable, preparation stops before a device is created. It does not upload an application or create a helper.

The ordinary PNG in `fixture.png` is a retained report-video frame used as arbitrary file bytes (184,874 bytes; SHA-256 `fd9566b940419a8916c484f2279320ba6a2c416a6909283cb705c0bac36d741c`). Supported Appium pushFile writes a unique run/attempt filename into Downloads, and pullFile must return identical bytes. The app must select it through **File** and the real native **Downloads** picker. File preparation is not a product trial.

The controller captures original native font and Screen zoom settings, verifies the monitor action at the observed original position or a qualified lower position through the actual URL dialog, and changes only native **Screen zoom** to its supported upper endpoint. It then inspects the same URL action row, activates the monitor target, and restores the original native zoom setting. Font and orientation remain unchanged. Missing or ambiguous controls stop the scenario with original observations; the controller cannot substitute shell density, Text, synthetic intents, a camera feed, or a helper APK. The native bounds identify controls; screenshots and the retained video still need pixel inspection before a containment/hitbox verdict.

## Admission and budget

Before a push containing `[issue1774-admitted]`, complete the independent consuming review, verify the exact clean source head and absence of another owned job, and obtain a fresh coordinator one-session admission. Set the repository Actions variable `ISSUE1774_ADMISSION` only at that opening. The workflow passes it as an environment value, avoiding a committed head self-reference:

```json
{
  "issue": 1774,
  "sourceHead": "EXACT_FROZEN_ACTIONS_HEAD",
  "stage": "issue1774-native-display-size-original",
  "reservationId": "FRESH_COORDINATOR_RESERVATION_ID",
  "runAttempt": "1",
  "maxJobs": 1,
  "rootSelected": true,
  "admittedAt": "FRESH_COORDINATOR_UTC",
  "expiresAt": "COORDINATOR_EXPIRY_UTC",
  "maxSessions": 1,
  "unknownManualHolds": 2,
  "totalPotentialBefore1774": 2
}
```

The last count is a template, not measured capacity. Use the coordinator actual count, preserving the two separate unknown holds 3084 and 2453. The controller checks a fresh provider plan before its one creation attempt; stale inventories do not grant capacity. The admission variable is intentionally unset during source preparation; preparation writes its verified value only into the evidence directory.

The job has a 20-minute hard timeout. Normal Ubuntu apt update and ffmpeg installation, including version output, run under a 140-second command limit, a five-second TERM-to-KILL grace, and a five-second receipt reserve (150 seconds total). The actual device budget is capped at 12 minutes and at the job deadline minus eight minutes, preserving cleanup, retention and upload time after setup. The owned device has a maximum 12-minute lifetime, including native restoration. Scenario inputs stop early enough to restore and delete the session. Independent cleanup verifies exact build/session ownership before deletion. Provider retention ends before the final four-minute artifact-upload reserve. No new device, automatic scenario rerun, tunnel, desktop application or build is included.

Evidence goes to `evidence/issue1774/`: exact APK/upload and fixture identities, action timestamps, native XML/screenshots/bounds, original setting values and every mutation trajectory, scenario stage results, provider ownership/cleanup, and original video/log retention receipts. The copied provider collector validates complete MP4 decoding and records failures rather than saving HTTP errors as successful media. Derive 5–10-second outcome clips only after correlating actual original frames with screenshots/actions; client timestamps alone do not calibrate provider video frames.

At most five distinct conditions are allowed. Count only different observed native positions; returning to the original position or repeating the maximum does not add a condition. If the original position equals the qualified maximum, one ordinary Decrease supplies a distinct lower working control. Repeat the maximum once when the remaining budget allows. This source does not infer a failure from constrained Row code or count a source check as successful product reproduction. An unchanged baseline failure needs actual image/dialog evidence and root causal assessment before any candidate replay or product patch.

## Source validation status

No source, syntax check, build, unit test or product scenario was executed during preparation. The review is a full consuming source review under this explicit constraint. Runtime qualification of S23/Android13 native Settings, the real Downloads picker and the exact existing upload remains pending.
