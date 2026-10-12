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
guest() { timeout 25 "$vm/ssh" "env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 $*"; }
tree() { guest timeout 20 python3 /home/probe/3417-accessibility.py dump > "evidence/vm/$1-tree.json" 2>&1; }
action() {
  local label=$1; shift
  local status=0
  # Conditional callers suppress errexit; preserve the actual guest status.
  guest timeout 20 python3 /home/probe/3417-accessibility.py "$@" > "evidence/vm/$label-action.txt" 2>&1 || status=$?
  if [[ "$status" != 0 ]]; then return "$status"; fi
  sleep 3
  return 0
}
visual_row() {
  local label=$1 mode=$2 geometry
  capture "$label"
  [[ "$(identify -format '%wx%h' "evidence/vm/$label.png")" == 1280x800 ]]
  guest timeout 20 python3 /home/probe/3417-accessibility.py bounds > "evidence/vm/$label-native-geometry.json"
  # Retain the original color capture and its derived contrast-normalized input.
  # Original V11's exact fixture text scored 69.31; this same-pixel derivation
  # scored 79.36 while preserving the exact match and confidence threshold.
  convert "evidence/vm/$label.png" -colorspace Gray -contrast-stretch 2%x2% "evidence/vm/$label-anchor-gray.png"
  timeout 15 tesseract "evidence/vm/$label-anchor-gray.png" "evidence/vm/$label-anchor-ocr" --psm 11 tsv > "evidence/vm/$label-anchor-ocr.log" 2>&1
  node support/diagnostics/3417-visual.cjs chooser-region "evidence/vm/$label-native-geometry.json" \
    "evidence/vm/$label-anchor-ocr.tsv" "evidence/vm/$label-region-receipt.json" > "evidence/vm/$label-bounds.json"
  geometry=$(node support/diagnostics/3417-visual.cjs crop "evidence/vm/$label-bounds.json")
  convert "evidence/vm/$label.png" -crop "$geometry" +repage "evidence/vm/$label-dialog.png"
  timeout 15 tesseract "evidence/vm/$label-dialog.png" "evidence/vm/$label-ocr" --psm 6 tsv > "evidence/vm/$label-ocr.log" 2>&1
  node support/diagnostics/3417-visual.cjs "$mode" "evidence/vm/$label-bounds.json" \
    "evidence/vm/$label-ocr.tsv" evidence/vm/installed-appnames.json "evidence/vm/$label-visual.json" > "evidence/vm/$label-point.txt"
}
click_row() {
  local label=$1 button=${2:-left} x y kind extra
  [[ "$button" == left || "$button" == right ]]
  read -r x y kind extra < "evidence/vm/$label-point.txt"
  [[ -z "$extra" && "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ && "$x" -lt 1280 && "$y" -lt 800 ]]
  qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$((x * 32767 / 1279))}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$((y * 32767 / 799))}}]}}"
  qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"$button\"}}]}}"
  qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"$button\"}}]}}"
  sleep 1
}
identity() {
  timeout 25 "$vm/ssh" 'sudo bash -s' > "evidence/vm/$1-live-identity.txt" 2>&1 <<'GUEST'
date -u
flatpak ps --columns=instance,pid,application,runtime
for pid in $(pgrep -x localsend || true); do
  echo "PID=$pid"
  cat "/proc/$pid/stat"
  readlink "/proc/$pid/exe"
  base64 -w0 "/proc/$pid/cmdline"; echo
  sha256sum "/proc/$pid/exe"
  cat "/proc/$pid/mountinfo"
  # Document-portal FUSE access belongs to the app user, including observation
  # through that live app's mount namespace.
  runuser -u probe -- find "/proc/$pid/root/run/user/1000/doc" -maxdepth 5 -type f -name '3417-control.txt' -exec sha256sum {} \; 2>&1 || true
done
sudo auditctl -s
# bash -s receives this script on stdin. Select audit logs explicitly rather
# than letting ausearch search the exhausted script input.
audit_status=0
sudo ausearch --input-logs -k localsend3417 --raw || audit_status=$?
printf 'AUSEARCH_EXIT=%s\n' "$audit_status"
# Status 1 includes no matches and minor errors. Retain it as ambiguous
# supplementary evidence rather than certifying audit-read success.
[[ "$audit_status" -le 1 ]] || exit "$audit_status"
GUEST
  guest flatpak documents > "evidence/vm/$1-probe-documents.txt" 2>&1
}
record_pid=
record() {
  # The UI step is bounded at 300 seconds; stop only after its final state.
  ffmpeg -y -loglevel warning -f x11grab -video_size 1280x800 -framerate 15 -i :99.0 -t 330 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "evidence/vm/$1.mp4" > "evidence/vm/$1-record.log" 2>&1 &
  record_pid=$!
  sleep 1
}
finish() {
  local status=$?
  trap - EXIT
  capture 99-final-state || true
  if [[ -n "$record_pid" ]]; then
    kill -INT "$record_pid" 2>/dev/null || true
    if ! timeout 15 tail --pid="$record_pid" -f /dev/null; then kill -KILL "$record_pid" 2>/dev/null || true; fi
    wait "$record_pid" || true
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
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
# V7 first-login update prompts stole the foreground before file selection.
# Retain their qualified native dismissal, then request Files' normal activation.
action 03-desktop-prompts desktop
guest "nohup nautilus /home/probe/Documents >>/home/probe/3417-nautilus.log 2>&1 </dev/null &"
sleep 3
record running-open-with
capture 03-visible-file
[[ "$(identify -format '%wx%h' evidence/vm/03-visible-file.png)" == 1280x800 ]]
# File selection uses the unique rendered fixture in the full screenshot.
# These are screen bounds, not GTK Wayland's unavailable native file bounds.
printf '[0,0,1280,800]\n' > evidence/vm/03-visible-file-screen-bounds.json
timeout 15 tesseract evidence/vm/03-visible-file.png evidence/vm/03-visible-file-ocr --psm 11 tsv > evidence/vm/03-visible-file-ocr.log 2>&1
node support/diagnostics/3417-visual.cjs file evidence/vm/03-visible-file-screen-bounds.json \
  evidence/vm/03-visible-file-ocr.tsv unused evidence/vm/03-visible-file-visual.json > evidence/vm/03-visible-file-point.txt
click_row 03-visible-file
capture 03-documents-selected
tree 03-documents-selected
click_row 03-visible-file right
capture 04-context-menu
tree 04-context-menu
if ! action 05-open-with file-menu-command; then
  capture 05-open-with-unavailable
  echo 'HARNESS_OPEN_WITH_ACTION_UNAVAILABLE' > evidence/vm/verdict.txt
  exit 2
fi
capture 05-open-with-dialog
tree 05-open-with-dialog
action 05-dialog-gate dialog
# Nautilus 46.4 exposes other apps directly in Open File; it has no reported
# View All Applications step. This is an explicitly recorded sequence variant.
printf 'Nautilus 46.4 native variant: Open With -> Open File; no View All Applications control.\n' > evidence/vm/native-sequence-boundary.txt
guest timeout 20 python3 /home/probe/3417-accessibility.py appnames > evidence/vm/installed-appnames.json
visual_row 06-visible-app row
click_row 06-visible-app
action 06-focused-dialog-gate dialog
action 06-selected-app-open-ready button "'Open'"
if [[ "$(awk '{print $3}' evidence/vm/06-visible-app-point.txt)" == focus ]]; then
  # A single click on the observed app row focuses GtkTreeView. Its supported
  # name search selects/scrolls without activation. Never press Return here.
  search_start=$(date +%s%N)
  qevent '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ctrl-f"}}'
  for letter in l o c a l s e n d; do
    qevent "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $letter\"}}"
  done
  # Keep the whole input sequence below the popup's five-second lifetime.
  # Continuous original video, not a blocking mid-search capture, retains it.
  [[ $(( $(date +%s%N) - search_start )) -lt 4000000000 ]]
  qevent '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey esc"}}'
  [[ $(( $(date +%s%N) - search_start )) -lt 5000000000 ]]
  sleep 1
fi
# Re-observe a unique rendered LocalSend row inside the still-open native
# dialog, then click once. AT-SPI cannot expose this GTK backend's app rows.
visual_row 07-localsend target
click_row 07-localsend
capture 07-localsend-selected
tree 07-localsend-selected
action 07-still-open-dialog-gate dialog
action 07-open-ready button "'Open'"
printf 'REVIEW_REQUIRED: visible LocalSend selection, native dialog/search state, and single-click input. No selected-row accessibility assertion is available.\n' > evidence/vm/07-selection-review-required.txt
action 08-open chooser "'Open'"
sleep 7
capture 08-running-open-with-result
tree 08-running-open-with-result
identity 08-running-open-with-result
printf 'NATIVE_ACTIONS_REACHED_FINAL_OBSERVATION_REVIEW_RAW_UI_AND_ARGV\n' > evidence/vm/verdict.txt
