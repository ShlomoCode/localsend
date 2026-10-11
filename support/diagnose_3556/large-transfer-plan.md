# Issue 3556 bounded large transfer diagnostic

This opt-in diagnostic uses the original 1.18.2 Android APK and Windows ZIP. It does not modify LocalSend or establish a fix. The earlier 64 MiB app-to-app control is retained in Actions run 38152476155, artifact 11707163925. Its saved 67,108,864 bytes have SHA-256 `ef75a7f173204678fa2fe8ff8c2bc37f5af84dc8d991dd40aeebcce982b8ce8c`.

One Windows Actions job owns one Samsung Galaxy S20 Android 10 session. The session clock starts before POST /session, including startup time. BrowserStack's documented two-hour maximum remains a hard bound. The Actions job has 135 minutes to include preparation and artifact upload outside the device session.

Run physical transport gates and a real 64 MiB transfer first. Then stop the moderate helper, close its peers, start a fresh helper instance with a 90-minute logical peer lifetime, and start a separate receiver. Existing 90-second HTTP/progress timeouts remain unchanged. Logical peer age spans coalesced HTTP batches. No timeout or silence becomes TCP EOF.

Admission includes controls, staging, selection, and Send. Send must start before session age 20 minutes. Transfer stops at the earliest of Send + 90 minutes, session age 100 minutes, or the earliest real logical peer expiry minus five minutes. Verification finishes by age 105 minutes; cleanup finishes by age 110 minutes.

The fixture is exactly 16,000,000,000 bytes: a valid one-second MP4 followed by a legal extended-length free box. Android must freshly report at least twice the fixture plus 2 GiB free before staging, fixture plus 2 GiB before the File picker can create its cache copy, and 2 GiB reserve before Send. Windows checks fixture plus 2 GiB on the actual Downloads volume before receiving. The real workflow uses Android File/Recent selection, the registered receiver favorite, Windows Accept, and saved content.

After the real app completion observation, Android and Windows hash independently with separately killable workers. Windows checks stable size and modification time around hashing. Large fixture contents never enter the evidence directory or artifact upload. Preserve the moderate saved copy.

Observe actual UI hierarchy and screenshots for ANR, errors, and completion. Helper liveness is transport evidence only. Serialize Appium calls and bound each command by its operation limit and remaining phase deadline. Record every bounded observation and any gap. Reaching a cap or deadline is incomplete evidence, not a successful transfer or absence of ANR.

The syntax-only scenario compiles diagnostic helper source and parses JavaScript/PowerShell in Actions without creating a BrowserStack session. The parent reviews the exact diff, cloud syntax results, and bundled autoreview findings before any large diagnostic dispatch.
