#!/usr/bin/env bash
set -euxo pipefail
out=/work/evidence/cloud
trap 'printf "%s\n" "$?" > "$out/session.done"' EXIT
env | sort > "$out/session-environment.txt"
hyprctl version > "$out/hyprland-version.txt"
hyprctl monitors -j > "$out/monitors.json"
quickshell -p "$OMARCHY_PATH/shell/shell.qml" > "$out/quickshell.log" 2>&1 &
sleep 10
flameshot > "$out/flameshot.log" 2>&1 &
sleep 8
for x in 12 24 36 48 60 72; do
  hyprctl dispatch movecursor "$x 16"
  sleep 2
  grim "$out/control-${x}.png"
  tesseract "$out/control-${x}.png" "$out/control-${x}" 2>/dev/null
done
localsend > "$out/localsend.log" 2>&1 &
app_pid=$!
printf '%s\n' "$app_pid" > "$out/app-pid.txt"
sleep 15
kill -0 "$app_pid"
quickshell -p "$OMARCHY_PATH/shell/shell.qml" ipc call shell debugBarGeometry > "$out/bar-geometry.txt" 2>&1 || true
busctl --user list > "$out/dbus-names.txt"
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems > "$out/tray-items.txt"
grim "$out/before-hover.png"
for repeat in 1 2; do
  hyprctl dispatch movecursor '1000 700'
  sleep 1
  for x in 12 24 36 48 60 72 84 96 108 120; do
    hyprctl dispatch movecursor "$x 16"
    sleep 2
    grim "$out/hover-${repeat}-${x}.png"
    tesseract "$out/hover-${repeat}-${x}.png" "$out/hover-${repeat}-${x}" 2>/dev/null
  done
done
kill -0 "$app_pid"
ps -ef > "$out/processes.txt"
