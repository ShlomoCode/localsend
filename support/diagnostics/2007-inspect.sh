#!/usr/bin/env bash
set -euxo pipefail
export NO_AT_BRIDGE=0
gsettings set org.gnome.desktop.interface toolkit-accessibility true
openbox > evidence/openbox.log 2>&1 &
desktop_app=$(find released -type f -name localsend_app | head -n1)
"$desktop_app" > evidence/desktop.log 2>&1 &
desktop_pid=$!
sleep 8
kill -0 "$desktop_pid"
xdotool search --name LocalSend > evidence/desktop-windows.txt
scrot evidence/desktop-initial.png
/usr/bin/python3 support/diagnostics/2007-desktop-tree.py > evidence/desktop-initial-tree.txt
adb install released/android.apk
adb shell settings put system show_touches 1
adb shell am start -n org.localsend.localsend_app/.MainActivity
sleep 8
adb shell uiautomator dump /sdcard/2007-initial.xml
adb pull /sdcard/2007-initial.xml evidence/android-initial.xml
adb exec-out screencap -p > evidence/android-initial.png
adb shell getprop > evidence/android-properties.txt
adb logcat -d > evidence/android-logcat.txt
adb shell pm list packages > evidence/android-packages.txt
