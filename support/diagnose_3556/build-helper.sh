#!/usr/bin/env bash
set -euo pipefail
sdkmanager 'platforms;android-35' 'build-tools;35.0.0' >/dev/null
mkdir -p /tmp/fixture3556/{classes,dex,assets}
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=10 -t 1 -c:v libx264 -pix_fmt yuv420p -movflags +faststart /tmp/fixture3556/assets/seed.mp4
ffprobe -v error -show_format -show_streams -of json /tmp/fixture3556/assets/seed.mp4 > evidence/seed-probe.json
javac -source 8 -target 8 -classpath "$ANDROID_HOME/platforms/android-35/android.jar" -d /tmp/fixture3556/classes support/diagnose_3556/android/*.java
"$ANDROID_HOME/build-tools/35.0.0/d8" --lib "$ANDROID_HOME/platforms/android-35/android.jar" --min-api 29 --output /tmp/fixture3556/dex /tmp/fixture3556/classes/org/localsend/fixture3556/*.class
"$ANDROID_HOME/build-tools/35.0.0/aapt" package -f -M support/diagnose_3556/android/AndroidManifest.xml -I "$ANDROID_HOME/platforms/android-35/android.jar" -A /tmp/fixture3556/assets -F /tmp/fixture3556/unsigned.apk
zip -j /tmp/fixture3556/unsigned.apk /tmp/fixture3556/dex/classes.dex
keytool -genkeypair -keystore /tmp/fixture3556/debug.jks -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 2 -dname 'CN=Issue3556 fixture helper'
"$ANDROID_HOME/build-tools/35.0.0/apksigner" sign --ks /tmp/fixture3556/debug.jks --ks-pass pass:android --out /tmp/fixture3556/helper.apk /tmp/fixture3556/unsigned.apk
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify /tmp/fixture3556/helper.apk
