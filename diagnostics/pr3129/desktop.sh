#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:99 XDG_RUNTIME_DIR=/tmp/runtime-$UID XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=x11
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
Xvfb :99 -screen 0 1440x1000x24 +extension GLX +render -noreset >evidence/xvfb.log 2>&1 &
sleep 2
dbus-update-activation-environment DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.interface enable-animations true
gnome-shell --x11 --replace >evidence/gnome-shell.log 2>&1 &
for n in $(seq 1 45); do wmctrl -m >evidence/window-manager.txt 2>&1 && grep -qi GNOME evidence/window-manager.txt && break; sleep 1; done
grep -qi GNOME evidence/window-manager.txt
{ uname -a; cat /etc/os-release; gnome-shell --version; glxinfo -B; xrandr; env | grep -E '^(ImageOS|ImageVersion|DISPLAY|XDG_|LIBGL_|GALLIUM_)' | sort; } >evidence/environment.txt
# The control proves a live terminal in the same real desktop, including a rendered command.
gnome-terminal --title='PR3129 control terminal' -- bash -c 'echo PR3129_CONTROL_OK; touch /tmp/pr3129-terminal-ready; exec bash --norc -i' >evidence/terminal.log 2>&1 &
for n in $(seq 1 20); do test -e /tmp/pr3129-terminal-ready && break; sleep 1; done
test -e /tmp/pr3129-terminal-ready
terminal=$(xdotool search --name 'PR3129 control terminal' | head -1)
xdotool windowactivate --sync "$terminal"
xdotool type --clearmodifiers 'echo INPUT_CONTROL_OK > /tmp/pr3129-input-control'
xdotool key Return
sleep 1
grep INPUT_CONTROL_OK /tmp/pr3129-input-control
xdotool getwindowgeometry --shell "$terminal" >evidence/terminal-before.txt
xdotool key alt+F7; xdotool mousemove 350 200; xdotool key Return
xdotool getwindowgeometry --shell "$terminal" >evidence/terminal-after.txt
ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 evidence/control.png >evidence/control-capture.log 2>&1
xdotool windowminimize "$terminal"
run_case() {
  name=$1; bundle=$2
  mkdir -p "evidence/$name" "/tmp/profile-$name"
  echo warmup >/tmp/pr3129-phase
  XDG_CONFIG_HOME="/tmp/profile-$name" PROBE_LOG="$PWD/evidence/$name/probe.jsonl" "$PWD/bundles/$bundle/localsend_app" >"evidence/$name/app.log" 2>&1 &
  app_pid=$!
  wid=''
  for n in $(seq 1 40); do wid=$(xdotool search --onlyvisible --pid "$app_pid" 2>/dev/null | head -1 || true); test -n "$wid" && break; sleep 1; done
  test -n "$wid"
  xdotool windowactivate --sync "$wid"
  wmctrl -ir "$wid" -b remove,maximized_vert,maximized_horz
  xdotool windowsize "$wid" 950 700
  xdotool windowmove "$wid" 200 150
  sleep 10
  xdotool getwindowgeometry --shell "$wid" >"evidence/$name/initial-geometry.txt"
  ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 "evidence/$name/initial.png" >"evidence/$name/initial-capture.log" 2>&1
  ffmpeg -y -f x11grab -framerate 30 -video_size 1440x1000 -i :99 -c:v libx264 -preset ultrafast -crf 25 "evidence/$name/scenario.mp4" >"evidence/$name/ffmpeg.log" 2>&1 &
  rec=$!
  echo stationary >/tmp/pr3129-phase; sleep 8
  echo moving >/tmp/pr3129-phase
  xdotool mousemove 650 165
  xdotool key alt+F7
  for i in $(seq 1 100); do
    x=$((400+(i%20)*18)); y=$((160+(i%15)*10))
    xdotool mousemove --sync "$x" "$y"
    xdotool getwindowgeometry --shell "$wid" | tr '\n' ' ' >>"evidence/$name/move-geometries.txt"; echo >>"evidence/$name/move-geometries.txt"
    sleep .06
  done
  xdotool key Return
  echo stationary_after_move >/tmp/pr3129-phase; sleep 6
  xdotool windowmove "$wid" 200 150
  sleep 2
  echo app_title_drag >/tmp/pr3129-phase
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  drag_x=$((X+50)); drag_y=$((Y+15))
  xdotool mousemove "$drag_x" "$drag_y" mousedown 1
  for i in $(seq 1 70); do
    x=$((drag_x+(i%18)*15)); y=$((drag_y+(i%12)*8))
    xdotool mousemove --sync "$x" "$y"
    xdotool getwindowgeometry --shell "$wid" | tr '\n' ' ' >>"evidence/$name/title-drag-geometries.txt"; echo >>"evidence/$name/title-drag-geometries.txt"
    sleep .06
  done
  xdotool mouseup 1

  # Return to predictable geometry, then exercise real navigation via pointer input.
  xdotool windowmove "$wid" 200 150
  sleep 2
  xdotool getwindowgeometry --shell "$wid" >"evidence/$name/tab-geometry.txt"
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  tab_x=$((X+50)); receive_y=$((Y+100)); send_y=$((Y+155))
  echo tab_animation >/tmp/pr3129-phase
  for i in $(seq 1 8); do
    xdotool mousemove "$tab_x" "$send_y" click 1; sleep .45
    xdotool mousemove "$tab_x" "$receive_y" click 1; sleep .45
  done
  echo send_tab >/tmp/pr3129-phase
  xdotool mousemove "$tab_x" "$send_y" click 1
  sleep 3
  ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 "evidence/$name/send-tab.png" >"evidence/$name/send-screenshot.log" 2>&1
  echo settled >/tmp/pr3129-phase; sleep 3

  ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 "evidence/$name/final.png" >"evidence/$name/screenshot.log" 2>&1
  kill -INT "$rec"; wait "$rec" || true
  xdotool getwindowgeometry --shell "$wid" >"evidence/$name/final-geometry.txt"
  kill "$app_pid"; wait "$app_pid" || true
  sleep 2
}
run_case original original
run_case base1 base
run_case fix1 fix
run_case fix2 fix
run_case base2 base
