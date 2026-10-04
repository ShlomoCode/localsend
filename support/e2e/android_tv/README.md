# Android TV keyboard E2E

This focused harness checks upstream Flutter issue number 177360 through Android's
real keyboard and D-pad input. It uses the production `TextFieldWithActions`, which
contains a normal Flutter `TextFormField`. The control disables LocalSend's Android
editor proxy; the fixed APK enables it. Both are built from the same committed
source with the same Flutter version and field configuration.

<!-- TODO: Merge this focused infrastructure into a generic E2E runner when more scenarios are added. -->

The test requires the control to reject remote input and the fixed version to add
exactly `we` to `Nice Grape`. It also closes and reopens the fixed editor and checks
that input still works. If the control starts working after a Flutter update, this
comparison fails deliberately: investigate whether the workaround can be removed.
There are no mocked input connections and no `adb input text` calls.

## Environment

Use a **dedicated, disposable emulator**, not a phone or a personal LocalSend
installation. The APK package is `org.localsend.localsend_app.tv_e2e`; the runner
clears only that package before each case and leaves it installed but stopped.

The currently verified environment is Android 14 arm64, TV Gboard
`12.8.11.514158943-tv_release-arm64-v8a`, and these conditions:

- `android.software.leanback` is advertised by the device.
- TV Gboard is selected as the default input method.
- `android:bool/config_preventImeStartupUnlessTextEditor` is `true` **at boot**.

An ordinary emulator can let the control work and therefore cannot validate this
regression. Use a TV image that has the startup gate enabled, or a rooted userdebug
image with an immutable framework resource overlay installed before boot. A
mutable overlay enabled after boot does not reliably update the input service's
cached setting. The runner checks the resource value and records the device and
keyboard versions; the control is the behavioral check that the environment
actually reproduces the failure. Device provisioning is separate from the test,
which does not root, remount, change the keyboard, or install system overlays.

For a disposable Android 14 userdebug AVD launched with `-writable-system`, the
overlay sources are in `environment/`. Build them using the installed Android
build tools and the debug signing key created by a Flutter debug build:

```sh
export TV_E2E_TOOLS="$ANDROID_SDK_ROOT/build-tools/36.0.0"
export TV_E2E_ENV=support/e2e/android_tv/environment
mkdir -p /tmp/localsend-tv-overlay
"$TV_E2E_TOOLS/aapt2" compile --dir "$TV_E2E_ENV/res" -o /tmp/localsend-tv-overlay/resources.zip
"$TV_E2E_TOOLS/aapt2" link --manifest "$TV_E2E_ENV/AndroidManifest.xml" \
  -I "$ANDROID_SDK_ROOT/platforms/android-34/android.jar" \
  -o /tmp/localsend-tv-overlay/unsigned.apk /tmp/localsend-tv-overlay/resources.zip
"$TV_E2E_TOOLS/zipalign" -f 4 /tmp/localsend-tv-overlay/unsigned.apk /tmp/localsend-tv-overlay/overlay.apk
"$TV_E2E_TOOLS/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android \
  --key-pass pass:android /tmp/localsend-tv-overlay/overlay.apk
```

Target the disposable emulator explicitly in each command (replace `emulator-5556`
if needed). Never install these files on a physical device or a personal AVD:

```sh
adb -s emulator-5556 root
adb -s emulator-5556 remount
adb -s emulator-5556 push "$TV_E2E_ENV/tv-features.xml" /system/etc/permissions/localsend-tv-test.xml
adb -s emulator-5556 push /tmp/localsend-tv-overlay/overlay.apk /product/overlay/LocalSendImeGateOverlay.apk
adb -s emulator-5556 reboot
```

Wait for boot completion, then verify that `adb -s emulator-5556 shell cmd overlay
lookup android android:bool/config_preventImeStartupUnlessTextEditor` reports
`true`. If remount requests a reboot before writes can succeed, reboot, wait for
boot completion, then repeat root/remount before pushing. Use `/product/overlay`;
`/system/overlay` is not scanned on the verified Android 14 image.

Install a TV Gboard APK obtained from an Android TV system image and select
`com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME` with
`adb shell ime enable` and `adb shell ime set` on the same serial. The phone Gboard
that ships in a Google APIs image has the same package name but a different
signature. On a disposable userdebug image it must be removed before installing
TV Gboard; do not assume that selecting a package with the same name proves it is
the TV version. The runner checks its `tv_release` version string.

For LocalSend development, use `avdslim` to enable the AVD's D-pad. Record its
settings and preserve keyboard services. The successful reproduction used 4 GB
RAM without low-RAM mode; the test does not change AVD tuning.

## Build and run

Install Python 3, FVM, the project's pinned Flutter SDK, and the Android/Rust build
prerequisites documented in the repository. Set `ANDROID_HOME` and
`ANDROID_SDK_ROOT` to the same SDK, and `JAVA_HOME` to a compatible JDK.

From the repository root containing the proxy:

```sh
python3 support/e2e/android_tv/build_pair.py --ref HEAD --output /tmp/localsend-tv-pair
python3 support/e2e/android_tv/run.py \
  --adb "$ANDROID_SDK_ROOT/platform-tools/adb" \
  --serial emulator-5554 \
  --pair /tmp/localsend-tv-pair \
  --output /tmp/localsend-tv-results
```

The builder uses a temporary checkout and never modifies the source worktree. It
builds the fixed APK first, then disables only the TV proxy setup in that temporary
checkout to build the control. `pair.json` records the source commit, Flutter
version, fixture hash, and APK hashes. Pass `--repo` to build from another checkout.
If the installed NDK differs from Flutter's default, pass `--ndk-version` with its
version (for example `28.2.13676358`). This applies the same override to both APKs
and records it in `pair.json`.

The fixture opens a real production dialog using a tap to select its button. All
**keyboard actions** are remote D-pad events, including typing and submitting. No
application network services or saved personal preferences are needed.

The runner exits nonzero for a failed assertion or missing prerequisite, and saves
`results.json`, screenshots, fresh UI XML, and input-service dumps outside the
repository. Inspect these when a run fails; do not treat a missing UI snapshot as
an expected control failure. Keep binary artifacts out of the PR. This harness is
an opt-in device test and is not added to the ordinary Flutter unit-test CI job.
Use new, empty output directories for each build pair and run so that a failed
attempt cannot leave a successful result or APK manifest from an earlier attempt.
