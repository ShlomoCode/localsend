# Android TV keyboard E2E

This test uses the existing LocalSend app and its Device name dialog. It compares
an APK without the Android editor proxy against an APK with it, using the same
emulator, saved device name, and real D-pad sequence. It expects the control to
reject input, the fix to append `we` exactly once, and editing to work after reopening.

Build both APKs with the normal project build commands. Use the same Flutter version
and app source, disabling only the proxy in the control. No separate fixture or
build pipeline is needed. The runner records the APK hashes and device fingerprint.

Use English LocalSend on a disposable landscape TV emulator with English TV Gboard and
`config_preventImeStartupUnlessTextEditor=true` at boot, as in the reproduced failure.
An ordinary emulator may not reproduce it. The script installs both debug APKs but
does not clear their data, change the keyboard, or configure the emulator.

```sh
python3 support/e2e/android_tv/run.py --serial emulator-5556 \
  --adb "$ANDROID_SDK_ROOT/platform-tools/adb" \
  --control /tmp/control.apk --fixed /tmp/fixed.apk --output /tmp/tv-e2e-results
```

Use a new output directory for each run. A failed assertion exits nonzero;
screenshots and `results.json` remain available for inspection. This is a local
device test, separate from the existing unit-test CI job.
