#!/usr/bin/env bash
set -euxo pipefail
export NO_AT_BRIDGE=0
export LIBGL_ALWAYS_SOFTWARE=1
gsettings set org.gnome.desktop.interface toolkit-accessibility true
openbox > evidence/openbox.log 2>&1 &
desktop_app=$(find released -type f -name localsend_app | head -n1)
"$desktop_app" > evidence/desktop.log 2>&1 &
desktop_pid=$!
sleep 8
kill -0 "$desktop_pid"
xdotool search --name LocalSend > evidence/desktop-windows.txt
desktop_window=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n1)
xdotool windowmove "$desktop_window" 0 0
xdotool windowsize "$desktop_window" 1000 700
xdotool windowactivate --sync "$desktop_window"
sleep 2
scrot evidence/desktop-initial.png
if ! timeout 25s /usr/bin/python3 support/diagnostics/2007-desktop-tree.py > evidence/desktop-initial-tree.txt 2> evidence/desktop-accessibility-error.txt; then
  echo 'AT-SPI inspection unavailable; actual GUI input will use observed screenshot text.' >> evidence/desktop-accessibility-error.txt
fi
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
/usr/bin/python3 support/diagnostics/2007-ui.py
