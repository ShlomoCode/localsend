#!/usr/bin/env bash
set -euxo pipefail
out=/work/evidence/cloud
openbox > "$out/openbox.log" 2>&1 &
quickshell -p "$OMARCHY_PATH/shell/shell.qml" > "$out/quickshell.log" 2>&1 &
shell_pid=$!
sleep 8
kill -0 "$shell_pid"
flameshot > "$out/flameshot.log" 2>&1 &
control_pid=$!
sleep 8
kill -0 "$control_pid"
for x in 12 24 36 48 60 72; do
  xdotool mousemove "$x" 16
  sleep 2
  import -window root "$out/control-${x}.png"
  tesseract "$out/control-${x}.png" "$out/control-${x}" 2>/dev/null
done
localsend > "$out/localsend.log" 2>&1 &
app_pid=$!
printf '%s\n' "$app_pid" > "$out/app-pid.txt"
sleep 15
kill -0 "$app_pid"
quickshell -p "$OMARCHY_PATH/shell/shell.qml" ipc call shell debugBarGeometry > "$out/bar-geometry.txt" 2>&1 || true
busctl --user list > "$out/dbus-names.txt"
import -window root "$out/before-hover.png"
for repeat in 1 2; do
  xdotool mousemove 1000 700
  sleep 1
  for x in 12 24 36 48 60 72 84 96 108 120; do
    xdotool mousemove "$x" 16
    sleep 2
    import -window root "$out/hover-${repeat}-${x}.png"
    tesseract "$out/hover-${repeat}-${x}.png" "$out/hover-${repeat}-${x}" 2>/dev/null
  done
done
kill -0 "$app_pid"
ps -ef > "$out/processes.txt"
