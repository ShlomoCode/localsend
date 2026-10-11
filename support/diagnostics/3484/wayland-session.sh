#!/usr/bin/env bash
set -euxo pipefail
out=/work/evidence/cloud
trap 'printf "%s\n" "$?" > "$out/session.done"' EXIT
event_seq=0
move_pointer() {
  event_seq=$((event_seq + 1))
  printf '%s %s %s\n' "$event_seq" "$1" "$2" > /work/input/request
  for i in $(seq 1 100); do
    if [ "$(cat /work/input/ack 2>/dev/null || true)" = "$event_seq" ]; then return; fi
    sleep 0.1
  done
  return 1
}
env | sort > "$out/session-environment.txt"
hyprctl version > "$out/hyprland-version.txt"
hyprctl monitors -j > "$out/monitors.json"
cat > "$OMARCHY_PATH/shell/Probe3484.qml" <<'PROBE'
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as HostCommons
ShellRoot {
  Component.onCompleted: {
    console.log("PROBE3484 Color=" + Color + " bar=" + Color.bar + " background=" + Color.background)
    console.log("PROBE3484 Alias=" + HostCommons.Color + " bar=" + HostCommons.Color.bar + " background=" + HostCommons.Color.background)
    console.log("PROBE3484 Style=" + Style + " family=" + Style.font.family)
  }
}
PROBE
timeout 5 quickshell -p "$OMARCHY_PATH/shell/Probe3484.qml" > "$out/module-probe.log" 2>&1 || true
quickshell -p "$OMARCHY_PATH/shell/shell.qml" > "$out/quickshell.log" 2>&1 &
sleep 10
flameshot > "$out/flameshot.log" 2>&1 &
sleep 8
for x in 12 24 36 48 60 72; do
  move_pointer "$x" 16
  sleep 2
  grim "$out/control-${x}.png"
  tesseract "$out/control-${x}.png" "$out/control-${x}" 2>/dev/null
done
grep -i -q flameshot "$out"/control-*.txt
for app_case in release current-base; do
mkdir -p "$out/$app_case" "$HOME/cases/$app_case/data" "$HOME/cases/$app_case/config"
if [ "$app_case" = release ]; then app_binary=/opt/localsend/localsend; else app_binary=/opt/current-base/localsend_app; fi
XDG_DATA_HOME="$HOME/cases/$app_case/data" XDG_CONFIG_HOME="$HOME/cases/$app_case/config" "$app_binary" > "$out/$app_case/localsend.log" 2>&1 &
app_pid=$!
printf '%s\n' "$app_pid" > "$out/$app_case/app-pid.txt"
sleep 15
kill -0 "$app_pid"
quickshell -p "$OMARCHY_PATH/shell/shell.qml" ipc call shell debugBarGeometry > "$out/bar-geometry.txt" 2>&1 || true
busctl --user list > "$out/$app_case/dbus-names.txt"
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems > "$out/$app_case/tray-items.txt"
grim "$out/$app_case/before-hover.png"
for repeat in 1 2; do
  move_pointer 1000 700
  sleep 1
  for x in 12 24 36 48 60 72 84 96 108 120; do
    move_pointer "$x" 16
    sleep 2
    grim "$out/$app_case/hover-${repeat}-${x}.png"
    tesseract "$out/$app_case/hover-${repeat}-${x}.png" "$out/$app_case/hover-${repeat}-${x}" 2>/dev/null
  done
done
kill -0 "$app_pid"
kill "$app_pid"
wait "$app_pid" || true
sleep 2
done
ps -ef > "$out/processes.txt"
