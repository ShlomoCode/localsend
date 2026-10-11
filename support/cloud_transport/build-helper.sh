#!/usr/bin/env bash
set -euo pipefail
sdkmanager 'platforms;android-35' 'build-tools;35.0.0' >/dev/null
mkdir -p /tmp/helper/classes /tmp/helper/dex /tmp/helper/assets
node --input-type=module -e 'import fs from "node:fs";fs.writeFileSync("/tmp/helper/assets/config.json",JSON.stringify({endpoint:"http://bs-local.com:8080",token:process.env.RELAY_TOKEN||"control-only-placeholder"}));'
javac -source 8 -target 8 -classpath "$ANDROID_HOME/platforms/android-35/android.jar" -d /tmp/helper/classes support/cloud_transport/android/*.java
"$ANDROID_HOME/build-tools/35.0.0/d8" --lib "$ANDROID_HOME/platforms/android-35/android.jar" --min-api 26 --output /tmp/helper/dex /tmp/helper/classes/org/localsend/cloudtransport/*.class
"$ANDROID_HOME/build-tools/35.0.0/aapt" package -f -M support/cloud_transport/android/AndroidManifest.xml -I "$ANDROID_HOME/platforms/android-35/android.jar" -A /tmp/helper/assets -F /tmp/helper/unsigned.apk
zip -j /tmp/helper/unsigned.apk /tmp/helper/dex/classes.dex
keytool -genkeypair -keystore /tmp/helper/debug.jks -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 2 -dname 'CN=Cloud diagnostic'
"$ANDROID_HOME/build-tools/35.0.0/apksigner" sign --ks /tmp/helper/debug.jks --ks-pass pass:android --out /tmp/helper/cloud-transport-helper.apk /tmp/helper/unsigned.apk
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify /tmp/helper/cloud-transport-helper.apk
