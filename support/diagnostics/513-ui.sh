#!/bin/bash
# Cloud VM only: actual USB-tablet input, unchanged applications.
set -euo pipefail
monitor=/home/runner/513-vm/monitor
qmp=/home/runner/513-vm/qmp
capture() {
  local name=$1
  printf 'screendump %s\n' "$GITHUB_WORKSPACE/evidence/vm/$name.ppm" | timeout 4 sudo socat - UNIX-CONNECT:$monitor >/dev/null
  sudo chown "$(id -u):$(id -g)" "evidence/vm/$name.ppm"
  convert "evidence/vm/$name.ppm" "evidence/vm/$name.png"
  identify "evidence/vm/$name.png" >> evidence/vm/screens.txt
}
key() { printf 'sendkey %s\n' "$1" | timeout 2 sudo socat - UNIX-CONNECT:$monitor >/dev/null; sleep 2; }
qevent() {
  { printf '%s\n' '{"execute":"qmp_capabilities"}'; sleep .1; printf '%s\n' "$1"; sleep .1; } | timeout 2 sudo socat - UNIX-CONNECT:$qmp >> evidence/vm/input-qmp.log
}
move() {
  local x=$(( $1 * 32767 / width )) y=$(( $2 * 32767 / height ))
  qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$x}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$y}}]}}"
}
button() { qevent "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":$1,\"button\":\"left\"}}]}}"; }
sleep 15
capture 00-startup
read -r width height < <(identify -format '%w %h\n' evidence/vm/00-startup.png)
key esc
# App focus then tile left. Nautilus receives normal desktop launch and tile right.
key super-left
/home/runner/513-vm/ssh 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nohup nautilus /home/probe/Downloads >/home/probe/513-nautilus.log 2>&1 </dev/null &'
sleep 10
key esc
key super-right
capture 01-windows
# Select the sole file using the file manager's actual selection action.
key ctrl-a
capture 02-downloads-selected
move $((width*3/4)) 165
button true
sleep 1
move $((width*5/8)) 240
move $((width*3/8)) 330
capture 03-downloads-drag-overlay
button false
sleep 8
capture 04-downloads-drop
# Relaunch the application to avoid keeping an earlier selection.
/home/runner/513-vm/ssh 'flatpak kill org.localsend.localsend_app; export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nohup flatpak run org.localsend.localsend_app >>/home/probe/513-app.log 2>&1 </dev/null &'
sleep 10
key super-left
/home/runner/513-vm/ssh 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; nautilus /home/probe/Documents'
sleep 5
key super-right
key ctrl-a
capture 05-documents-selected
move $((width*3/4)) 165
button true
sleep 1
move $((width*5/8)) 240
move $((width*3/8)) 330
capture 06-documents-drag-overlay
button false
sleep 8
capture 07-documents-drop
