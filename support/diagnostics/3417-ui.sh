#!/bin/bash
# Cloud-only QMP and supported accessibility actions. Scaffold credited to issue513.
set -euo pipefail
vm=/home/runner/3417-vm
monitor=$vm/monitor
qmp=$vm/qmp
capture() {
  local name=$1
  printf 'screendump %s\n' "$GITHUB_WORKSPACE/evidence/vm/$name.ppm" | timeout 4 sudo socat - UNIX-CONNECT:"$monitor" >/dev/null
  sudo chown "$(id -u):$(id -g)" "evidence/vm/$name.ppm"
  convert "evidence/vm/$name.ppm" "evidence/vm/$name.png"
  identify "evidence/vm/$name.png" >> evidence/vm/screens.txt
}
qevent() {
  printf '%s %s\n' "$(date +%s.%N)" "$1" >> evidence/vm/action-timings.txt
  { printf '%s\n' '{"execute":"qmp_capabilities"}'; sleep .1; printf '%s\n' "$1"; sleep .1; } | timeout 2 sudo socat - UNIX-CONNECT:"$qmp" >> evidence/vm/input-qmp.log
}
key() { qevent "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $1\"}}"; sleep 2; }
guest() { "$vm/ssh" "env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 $*"; }
tree() { guest python3 /home/probe/3417-accessibility.py > "evidence/vm/$1-tree.json" 2>&1; }
action() {
  local label=$1; shift
  # Labels are shell quoted by callers; output records exact acted element/bounds.
  guest python3 /home/probe/3417-accessibility.py "$@" > "evidence/vm/$label-action.txt" 2>&1
  sleep 3
}
identity() {
  "$vm/ssh" 'sudo bash -s' > "evidence/vm/$1-live-identity.txt" <<'GUEST'
date -u
flatpak ps --columns=instance,pid,application,runtime
for pid in $(pgrep -x localsend || true); do
  echo "PID=$pid"
  cat "/proc/$pid/stat"
  readlink "/proc/$pid/exe"
  base64 -w0 "/proc/$pid/cmdline"; echo
  sha256sum "/proc/$pid/exe"
  cat "/proc/$pid/mountinfo"
  find "/proc/$pid/root/run/user/1000/doc" -maxdepth 5 -type f -name '3417-control.txt' -exec sha256sum {} \; 2>&1 || true
done
flatpak documents
sudo auditctl -s
sudo ausearch -k localsend3417 --raw
GUEST
}
record() {
  ffmpeg -y -loglevel warning -f x11grab -video_size 1280x800 -framerate 15 -i :99.0 -t 30 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "evidence/vm/$1.mp4" > "evidence/vm/$1-record.log" 2>&1 &
  record_pid=$!
  sleep 1
}
capture 00-desktop
key esc
guest "nohup flatpak run org.localsend.localsend_app /home/probe/Downloads/3417-control.txt >/home/probe/3417-control.log 2>&1 </dev/null &"
sleep 12
capture 01-plain-path-control
tree 01-plain-path-control
identity 01-plain-path-control
# A screenshot must show the actual staged control before product conclusions.
guest flatpak kill org.localsend.localsend_app
sleep 3
guest "nohup flatpak run org.localsend.localsend_app >/home/probe/3417-app.log 2>&1 </dev/null &"
sleep 12
capture 02-running-empty
identity 02-running-empty
guest "nohup nautilus /home/probe/Documents >/home/probe/3417-nautilus.log 2>&1 </dev/null &"
sleep 8
key ctrl-a
capture 03-documents-selected
tree 03-documents-selected
record running-open-with
key shift-f10
capture 04-context-menu
tree 04-context-menu
if ! action 05-open-with "'Open With…'" "'Open With...'" "'Open With'" "'Open With Other Application…'" "'Open With Other Application...'"; then
  capture 05-open-with-unavailable
  echo 'HARNESS_OPEN_WITH_ACTION_UNAVAILABLE' > evidence/vm/verdict.txt
  wait "$record_pid"
  exit 2
fi
capture 05-open-with-dialog
tree 05-open-with-dialog
# Older and newer GNOME labels are retained as separately observed action candidates.
action 06-all-apps "'View All Applications'" "'Show All Applications'" "'Show All'" || true
capture 06-all-apps
tree 06-all-apps
if ! action 07-localsend "'LocalSend'"; then
  capture 07-localsend-unavailable
  echo 'HARNESS_LOCALSEND_SELECTION_UNAVAILABLE' > evidence/vm/verdict.txt
  wait "$record_pid"
  exit 2
fi
capture 07-localsend-selected
tree 07-localsend-selected
action 08-open "'Open'" "'Select'" || key ret
sleep 7
capture 08-running-open-with-result
tree 08-running-open-with-result
identity 08-running-open-with-result
wait "$record_pid"
printf 'RUNNING_OPEN_WITH_REACHED_REVIEW_SCREENSHOTS_AND_ARGV\n' > evidence/vm/verdict.txt
