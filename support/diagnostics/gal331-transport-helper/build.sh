#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:?Set ANDROID_HOME or ANDROID_SDK_ROOT}}
platform_jar="$sdk/platforms/android-35/android.jar"
tools="$sdk/build-tools/35.0.0"
output=${1:-"$here/gal331-transport-helper.apk"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/classes" "$work/dex"
javac -source 17 -target 17 -cp "$platform_jar" -d "$work/classes" \
  "$here/src/org/localsend/gal331transport/MainActivity.java" \
  "$here/src/org/localsend/gal331transport/TransportService.java"
jar cf "$work/helper.jar" -C "$work/classes" .
"$tools/d8" --lib "$platform_jar" --output "$work/dex" "$work/helper.jar"
"$tools/aapt2" link -o "$work/unsigned.apk" -I "$platform_jar" \
  --manifest "$here/AndroidManifest.xml" --min-sdk-version 29 --target-sdk-version 34
(cd "$work/dex" && zip -q "$work/unsigned.apk" classes.dex)
"$tools/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
keytool -genkeypair -noprompt -storetype PKCS12 -keystore "$work/key.p12" \
  -storepass temporary -keypass temporary -alias gal331 -keyalg RSA -keysize 2048 \
  -validity 2 -dname 'CN=Gal331 Temporary Helper'
"$tools/apksigner" sign --ks "$work/key.p12" --ks-key-alias gal331 \
  --ks-pass pass:temporary --key-pass pass:temporary --out "$output" "$work/aligned.apk"
"$tools/apksigner" verify "$output"
echo "$output"
