#!/usr/bin/env bash
# Run only on the admitted fork Actions runner.
set -euo pipefail
test -n "${GITHUB_RUN_ID:?Actions required}"
test -n "${GITHUB_ENV:?Actions environment required}"
test -n "${RELAY_TOKEN:?Private transport token required}"
test -d "${FIXTURE_DIRECTORY:?Fixture directory required}"
test -f "$FIXTURE_DIRECTORY/manifest.json"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
test -d "$sdk"
sdkmanager --sdk_root="$sdk" 'platforms;android-35' 'build-tools;35.0.0' >/dev/null
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
case "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:?Attempt required}" in *[!0-9-]*) exit 1;; esac
private_root="$(mktemp -d "${RUNNER_TEMP:?Runner temp required}/issue3441-${GITHUB_RUN_ID}-attempt-${GITHUB_RUN_ATTEMPT}-helpers.XXXXXX")"
trap 'rm -rf "$private_root"' EXIT
build() {
  source="$1"; work="$2"; label="$3"
  mkdir -p "$work/classes" "$work/dex" "$work/assets"
  javac -source 8 -target 8 -classpath "$sdk/platforms/android-35/android.jar" -d "$work/classes" "$source"/*.java
  find "$work/classes" -name '*.class' -print0 | xargs -0 "$sdk/build-tools/35.0.0/d8" --lib "$sdk/platforms/android-35/android.jar" --min-api 29 --output "$work/dex"
  "$sdk/build-tools/35.0.0/aapt" package -f -M "$source/AndroidManifest.xml" -I "$sdk/platforms/android-35/android.jar" -A "$work/assets" -F "$work/unsigned.apk"
  zip -q -j "$work/unsigned.apk" "$work/dex/classes.dex"
  "$sdk/build-tools/35.0.0/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
  keytool -genkeypair -keystore "$work/key.jks" -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 2 -dname "CN=$label" >/dev/null 2>&1
  "$sdk/build-tools/35.0.0/apksigner" sign --ks "$work/key.jks" --ks-pass pass:android --out "$work/helper.apk" "$work/aligned.apk"
  "$sdk/build-tools/35.0.0/apksigner" verify "$work/helper.apk"
}
mkdir -p "$private_root/fixture/assets" "$private_root/relay/assets"
cp "$FIXTURE_DIRECTORY"/* "$private_root/fixture/assets/"
build "$here/android" "$private_root/fixture" 'Issue3441 fixture helper'
# Private token/config and token-bearing transport APK never enter evidence folders.
node --input-type=module - "$private_root/relay/assets/config.json" <<'JS'
import {writeFileSync} from 'node:fs';
writeFileSync(process.argv[2],JSON.stringify({endpoint:'http://bs-local.com:8080',token:process.env.RELAY_TOKEN,transport:'stream',peerAbsoluteMs:15*60000}));
JS
build "$root/support/diagnostics/3441/transport/android" "$private_root/relay" 'Issue3441 opaque transport'
node "$here/upload-helpers.mjs" "$private_root/fixture/helper.apk" "$private_root/relay/helper.apk"
