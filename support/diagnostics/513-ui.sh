#!/bin/bash
# Cloud VM only: actual USB-tablet input, unchanged applications.
set -euo pipefail
monitor=/home/runner/513-vm/monitor
qmp=/home/runner/513-vm/qmp
native_identity() {
  /home/runner/513-vm/ssh 'sudo bash -s' >> evidence/vm/mapped-native-identity.txt <<'GUEST'
date -u
for maps in /proc/[0-9]*/maps; do
  plugin=$(awk '/desktop_drop.*\.so/ {print $NF; exit}' "$maps" 2>/dev/null) || continue
  test -n "$plugin" || continue
  pid=${maps#/proc/}; pid=${pid%/maps}
  printf 'PID=%s\n' "$pid"
  tr '\0' ' ' < "/proc/$pid/cmdline"
  printf '\n'
  cat "$maps" | grep desktop_drop
  sha256sum "/proc/$pid/root$plugin"
done
GUEST
}
capture() {
  local name=$1
  printf 'screendump %s\n' "$GITHUB_WORKSPACE/evidence/vm/$name.ppm" | timeout 4 sudo socat - UNIX-CONNECT:$monitor >/dev/null
  sudo chown "$(id -u):$(id -g)" "evidence/vm/$name.ppm"
  convert "evidence/vm/$name.ppm" "evidence/vm/$name.png"
  identify "evidence/vm/$name.png" >> evidence/vm/screens.txt
}
key() { qevent "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $1\"}}"; sleep 2; }
qevent() {
  printf '%s %s\n' "$(date +%s.%N)" "$1" >> evidence/vm/action-timings.txt
  { printf '%s\n' '{"execute":"qmp_capabilities"}'; sleep .1; printf '%s\n' "$1"; sleep .1; } | timeout 2 sudo socat - UNIX-CONNECT:$qmp >> evidence/vm/input-qmp.log
}
move() {
  local x=$(( $1 * 32767 / width )) y=$(( $2 * 32767 / height ))
  qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$x}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$y}}]}}"
}
button() { qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":$1,\"button\":\"left\"}}]}}"; }
record() {
  ffmpeg -y -loglevel warning -f x11grab -video_size 1280x800 -framerate 15 -i :99.0 -t 10 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "evidence/vm/$1.mp4" > "evidence/vm/$1-record.log" 2>&1 &
  record_pid=$!
  sleep 1
}
sleep 15
capture 00-startup
read -r width height < <(identify -format '%w %h\n' evidence/vm/00-startup.png)
key esc
# Keep a visible LocalSend strip below the minimum-width Files window.
/home/runner/513-vm/ssh 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nohup nautilus /home/probe/Downloads >/home/probe/513-nautilus.log 2>&1 </dev/null &'
sleep 10
key esc
capture 01-windows
if [[ "${SOURCE_ADDRESS:-ip}" == hashtag ]]; then
  # Match the fresh-process geometry used by the Documents cases.
  /home/runner/513-vm/ssh 'flatpak kill org.localsend.localsend_app; export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nohup flatpak run org.localsend.localsend_app >>/home/probe/513-app.log 2>&1 </dev/null &'
  sleep 10
  capture 01b-normalized-app
  move 400 55
  button true
  button false
fi
# Select the sole file using the file manager's actual selection action.
key ctrl-a
capture 02-downloads-selected
record downloads-drag
move 330 155
button true
move 350 175
move 500 400
move 600 650
capture 03-downloads-drag-overlay
button false
sleep 2
capture 04-downloads-drop
move 600 705
button true
button false
sleep 2
capture 04b-downloads-app-result
native_identity
wait "$record_pid"
# Relaunch the application to avoid keeping an earlier selection.
/home/runner/513-vm/ssh 'flatpak kill org.localsend.localsend_app; export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nohup flatpak run org.localsend.localsend_app >>/home/probe/513-app.log 2>&1 </dev/null &'
sleep 10
# Focus the original Files window, then choose its Documents sidebar item.
move 400 55
button true
button false
move 100 215
button true
button false
sleep 3
key ctrl-a
capture 05-documents-selected
record documents-drag
move 330 155
button true
move 350 175
move 500 400
move 600 650
capture 06-documents-drag-overlay
button false
sleep 2
capture 07-documents-drop
move 600 705
button true
button false
sleep 2
capture 07b-documents-app-result
native_identity
wait "$record_pid"
# Repeat the exact Documents condition in fresh application processes.
for repetition in 2 3; do
  /home/runner/513-vm/ssh "printf '\\nDOCUMENTS_REPEAT_$repetition\\n' >> /home/probe/513-app.log; flatpak kill org.localsend.localsend_app; export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nohup flatpak run org.localsend.localsend_app >>/home/probe/513-app.log 2>&1 </dev/null &"
  sleep 10
  move 400 55
  button true
  button false
  move 330 155
  button true
  move 350 175
  move 500 400
  move 600 650
  capture "repeat-$repetition-overlay"
  button false
  sleep 5
  # A click on the exposed app content foregrounds it without changing settings.
  move 600 705
  button true
  button false
  capture "repeat-$repetition-result"
  native_identity
done
# Supported file chooser path: same Documents file, without filesystem overrides.
if [[ "${SOURCE_DROP_SEND:-0}" == 1 ]]; then
  # Candidate sends the selection produced by the actual final Documents drop.
  capture 11-documents-drop-send-selection
  /home/runner/513-vm/ssh 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; flatpak run --command=sh org.localsend.localsend_app -c '\''if test -e /home/probe/Documents/513-control.txt; then echo RAW_DOCUMENTS_PATH_VISIBLE; else echo RAW_DOCUMENTS_PATH_NOT_VISIBLE; fi; find /run/user/$(id -u)/doc -maxdepth 3 -type f -name 513-control.txt -exec sha256sum {} \; '\''' > evidence/vm/drop-access-state.txt 2>&1
else
move 140 285
button true
button false
sleep 2
capture 08-empty-send
move 380 225
button true
button false
sleep 4
capture 09-file-chooser
key ctrl-l
for character in / h o m e / p r o b e / D o c u m e n t s / 5 1 3 - c o n t r o l . t x t; do
  case "$character" in
    /) code=slash;;
    -) code=minus;;
    .) code=dot;;
    D) code=shift-d;;
    *) code=$character;;
  esac
  qevent "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $code 50\"}}"
done
capture 10-chooser-path
key ret
sleep 5
capture 11-documents-chooser-result
/home/runner/513-vm/ssh 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; flatpak run --command=sh org.localsend.localsend_app -c '\''ls -l /home/probe/Documents/513-control.txt; find /run/user/$(id -u)/doc -maxdepth 3 -type f -name 513-control.txt -exec sha256sum {} \; '\''' > evidence/vm/chooser-access-control.txt 2>&1
fi
bash support/diagnostics/513-peer.sh
capture 12-peer-app
# GNOME groups both LocalSend windows; focus the exposed sender strip directly.
move 80 700
button true
button false
capture 13-sender-peer-list
# Actual manual-address action; capture the dialog before completing discovery.
move 540 438
button true
button false
sleep 2
capture 14-manual-address
if [[ "${SOURCE_ADDRESS:-ip}" == hashtag ]]; then
  # The c1ce source offers a hashtag input, using the observed veth suffix.
  qevent '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey 2 50"}}'
  capture 15-manual-address-filled
  key ret
else
for code in 1 9 2 dot 1 6 8 dot 5 1 dot 2; do
  qevent "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $code 50\"}}"
done
capture 15-manual-address-filled
move 565 495
button true
button false
fi
sleep 5
capture 16-after-manual-confirm
# Confirming the manual-address dialog starts the actual sending session.
sleep 5
capture 17-after-send
# Foreground the peer using its exposed strip and retain its approval screen.
move 975 700
button true
button false
sleep 2
capture 18-receiver-pending
# The default receiver requires its actual Accept button.
record receive-accept
move 615 720
button true
button false
sleep 5
capture 19-after-accept
wait "$record_pid"
move 80 700
button true
button false
capture 20-sender-result
/home/runner/513-vm/ssh 'sudo find /home/receiver/Downloads -maxdepth 2 -type f -exec sha256sum {} \; -exec wc -c {} \; ; sha256sum /home/probe/Documents/513-control.txt; cat /home/probe/513-peer.log' > evidence/vm/transfer-result.txt 2>&1
/home/runner/513-vm/ssh 'sudo cmp /home/probe/Documents/513-control.txt /home/receiver/Downloads/513-control.txt && printf "ACTUAL_APP_TRANSFER_HASH_AND_CONTENT_PASS\n"' >> evidence/vm/transfer-result.txt 2>&1
/home/runner/513-vm/ssh 'cat /home/probe/513-peer.log; flatpak documents; sudo ls -la /home/receiver/Downloads; sudo ip netns exec issue513peer ss -lntup' > evidence/vm/peer-state.txt 2>&1
