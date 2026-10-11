#!/usr/bin/env bash
set -Eeuxo pipefail
out=/work/evidence/cloud
trap 'failure_status=$?; printf "status=%s line=%s command=%s\n" "$failure_status" "$LINENO" "$BASH_COMMAND" >> "$out/session-errors.txt"' ERR
trap 'printf "%s\n" "$?" > "$out/session.done"' EXIT
exec > >(tee "$out/session-trace.log") 2>&1
cat /proc/sys/kernel/random/boot_id > "$out/boot-id-after.txt"
sudo systemctl status sshd --no-pager > "$out/guest-sshd-status.txt" 2>&1 || true
sudo journalctl -u sshd -b --no-pager > "$out/guest-sshd-journal.txt" 2>&1 || true
event_seq=0
move_pointer() {
  event_seq=$(cat /work/input/ack 2>/dev/null || printf '0')
  event_seq=$((event_seq + 1))
  printf '%s %s %s\n' "$event_seq" "$1" "$2" > /work/input/request
  for i in $(seq 1 450); do
    if [ "$(cat /work/input/ack 2>/dev/null || true)" = "$event_seq" ]; then return; fi
    sleep 0.1
  done
  return 1
}
capture_ocr() {
  grim "$1.png"
  if magick "$1.png" -crop 400x52+0+28 -colorspace gray -negate -resize 300% -bordercolor white -border 12 "$1-ocr.png" 2> "$1-ocr-error.txt"; then
    tesseract "$1-ocr.png" "$1" --psm 6 2>> "$1-ocr-error.txt" || true
  fi
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
  capture_ocr "$out/control-${x}"
done
if grep -i -q flameshot "$out"/control-*.txt; then
  printf 'OCR located Flameshot; inspect original control screenshot before accepting application results.\n' > "$out/control-observation.txt"
else
  printf 'OCR missed control; manual inspection of original control screenshots is required.\n' > "$out/control-observation.txt"
fi
stop_recording() {
  if [ -n "${record_pid:-}" ]; then
    kill -INT "$record_pid" 2>/dev/null || true
    for i in $(seq 1 50); do
      kill -0 "$record_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$record_pid" 2>/dev/null || true
    record_status=0
    wait "$record_pid" || record_status=$?
    printf '%s\n' "$record_status" > "$out/$app_case/recording-exit.txt"
    record_pid=
  fi
}
capture_case() (
set -euxo pipefail
app_case=$1
app_pid=
record_pid=
capture_completed=false
recording_valid=false
case_finish() {
  case_status=$?
  trap - EXIT
  set +e
  stop_recording
  if [ -n "$app_pid" ]; then
    kill "$app_pid" 2>/dev/null || true
    for i in $(seq 1 50); do
      kill -0 "$app_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  jq -n --argjson status "$case_status" --argjson capture "$capture_completed" --argjson video "$recording_valid" '{exit_status:$status,capture_completed:$capture,recording_valid:$video,visual:"pending",manual_acceptance_required:true}' > "$out/$app_case/capture-manifest.json"
  exit "$case_status"
}
trap case_finish EXIT
mkdir -p "$out/$app_case" "$HOME/cases/$app_case/data" "$HOME/cases/$app_case/config"
if [ "$app_case" = release ]; then
  app_binary=/opt/localsend/localsend
elif [ "$app_case" = candidate ]; then
  app_binary=/opt/candidate/localsend_app
else
  app_binary=/opt/current-base/localsend_app
fi
XDG_DATA_HOME="$HOME/cases/$app_case/data" XDG_CONFIG_HOME="$HOME/cases/$app_case/config" "$app_binary" > "$out/$app_case/localsend.log" 2>&1 &
app_pid=$!
printf '%s\n' "$app_pid" > "$out/$app_case/app-pid.txt"
sleep 15
kill -0 "$app_pid"
hyprctl clients -j > "$out/$app_case/window-properties.json"
quickshell -p "$OMARCHY_PATH/shell/shell.qml" ipc call shell debugBarGeometry > "$out/bar-geometry.txt" 2>&1 || true
busctl --user list > "$out/$app_case/dbus-names.txt" 2> "$out/$app_case/dbus-names-error.txt" || true
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems > "$out/$app_case/tray-items.txt" 2>&1 || true
for service in $(awk -v pid="$app_pid" '$2 == pid {print $1}' "$out/$app_case/dbus-names.txt"); do
  service_file=${service//:/_}
  busctl --user tree --list "$service" > "$out/$app_case/dbus-tree-${service_file}.txt" || true
  while read -r object_path; do
    if [[ "$object_path" = /org/ayatana/NotificationItem/* ]]; then
      object_file=${object_path//\//_}
      object_file=${object_file//:/_}
      stem="$out/$app_case/sni-${service_file}-${object_file}"
      busctl --user introspect "$service" "$object_path" org.kde.StatusNotifierItem > "$stem-introspection.txt" 2>&1 || true
      # busctl introspection returns success even for a missing interface.
      # A readable mandatory property distinguishes the SNI from its Menu.
      if busctl --user get-property "$service" "$object_path" org.kde.StatusNotifierItem Id > "$stem-Id.txt" 2>&1; then
        printf '%s\t%s\n' "$service" "$object_path" >> "$out/$app_case/sni-objects.tsv"
        for property in Title ToolTip; do
          busctl --user get-property "$service" "$object_path" org.kde.StatusNotifierItem "$property" > "$stem-$property.txt" 2>&1 || true
        done
      fi
    fi
  done < "$out/$app_case/dbus-tree-${service_file}.txt"
done
grim "$out/$app_case/before-hover.png"
for repeat in 1 2; do
  move_pointer 1000 700
  sleep 1
  for x in 12 24 36 48 60 72 84 96 108 120; do
    move_pointer "$x" 16
    sleep 2
    capture_ocr "$out/$app_case/hover-${repeat}-${x}"
  done
done
kill -0 "$app_pid"
capture_completed=true
hover_x=
for x in 12 24 36 48 60 72 84 96 108 120; do
  if grep -Eiq 'LocalSend|org[.]localsend' "$out/$app_case/hover-1-$x.txt"; then hover_x=$x; break; fi
done
if [ -z "$hover_x" ]; then
  printf 'No OCR-located LocalSend hover; manual original screenshot review required before recording coordinates can be accepted.\n' > "$out/$app_case/recording-observation.txt"
  kill -0 "$app_pid"
  exit 0
fi
printf '%s\t16\n' "$hover_x" > "$out/$app_case/recorded-hover-point.tsv"
move_pointer 1000 700
wf-recorder --no-dmabuf -c libx264 -f "$out/$app_case/actual-hover.mp4" > "$out/$app_case/recording.log" 2>&1 &
record_pid=$!
record_ready=0
for i in $(seq 1 50); do
  kill -0 "$record_pid" 2>/dev/null || break
  if [ -s "$out/$app_case/actual-hover.mp4" ]; then record_ready=1; break; fi
  sleep 0.1
done
if [ "$record_ready" = 0 ]; then
  printf 'Recorder did not become ready.\n' > "$out/$app_case/recording-observation.txt"
  kill -0 "$app_pid"
  exit 0
fi
sleep 1
move_pointer "$hover_x" 16
sleep 3
move_pointer 1000 700
sleep 3
stop_recording
if ffprobe -v error -show_streams -show_format -of json "$out/$app_case/actual-hover.mp4" > "$out/$app_case/video-probe.json" 2> "$out/$app_case/video-probe-error.txt"; then
  if jq -e 'any(.streams[]; .codec_type == "video") and (.format.duration | tonumber) >= 5' "$out/$app_case/video-probe.json"; then
    if ffmpeg -xerror -v error -i "$out/$app_case/actual-hover.mp4" -f null - > "$out/$app_case/video-decode.log" 2>&1; then
      recording_valid=true
      ffprobe -v error -show_frames -of json "$out/$app_case/actual-hover.mp4" > "$out/$app_case/video-original-frames.json" 2> "$out/$app_case/video-original-frames-error.txt" || true
      mkdir -p "$out/$app_case/video-frames"
      ffmpeg -i "$out/$app_case/actual-hover.mp4" -vf 'fps=1,showinfo' "$out/$app_case/video-frames/frame-%03d.png" > "$out/$app_case/video-frames.log" 2>&1 || true
    fi
  fi
fi
kill -0 "$app_pid"
)
session_status=0
app_cases=(release current-base)
if [ -x /opt/candidate/localsend_app ]; then app_cases+=(candidate); fi
for app_case in "${app_cases[@]}"; do
  set +e
  capture_case "$app_case"
  case_status=$?
  set -e
  if [ "$case_status" != 0 ]; then session_status=1; fi
  sleep 2
done
ps -ef > "$out/processes.txt"
exit "$session_status"
