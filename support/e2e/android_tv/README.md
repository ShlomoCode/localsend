# Android TV keyboard E2E

Checks that D-pad input fails without the proxy, works with it, and still works after reopening Device name.

Use a disposable landscape TV emulator with English LocalSend, English TV Gboard, and
`config_preventImeStartupUnlessTextEditor=true` at boot. Build both debug APKs from the same source and Flutter version, disabling only the proxy in the control.

```sh
python3 support/e2e/android_tv/run.py --serial emulator-5556 \
  --adb "$ANDROID_SDK_ROOT/platform-tools/adb" \
  --control /tmp/control.apk --fixed /tmp/fixed.apk --output /tmp/tv-e2e-results
```

The runner installs both APKs, preserves app data, and requires a new output directory.
Failures exit nonzero; screenshots and `results.json` capture the results.
