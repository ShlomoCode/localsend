#!/usr/bin/env bash
set -euo pipefail
trap 'code=$?; set +e; echo "HARNESS_FAILED line=$LINENO command=$BASH_COMMAND" >&2; wmctrl -lpG >evidence/failure-windows.txt 2>&1; xprop -root _NET_ACTIVE_WINDOW >evidence/failure-active-window.txt 2>&1; ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 evidence/failure.png >evidence/failure-capture.log 2>&1; exit "$code"' ERR
for tool in Xvfb gnome-shell gnome-terminal dbus-update-activation-environment xdotool wmctrl xprop ffmpeg glxinfo ruby; do command -v "$tool"; done
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
for n in $(seq 1 45); do grep -q 'GNOME Shell started' evidence/gnome-shell.log && break; sleep 1; done
grep -q 'GNOME Shell started' evidence/gnome-shell.log
xdotool key Escape
sleep 1
{ uname -a; cat /etc/os-release; gnome-shell --version; glxinfo -B; xrandr; env | grep -E '^(ImageOS|ImageVersion|DISPLAY|XDG_|LIBGL_|GALLIUM_)' | sort; } >evidence/environment.txt
# The control proves a live terminal in the same real desktop, including a rendered command.
gnome-terminal --title='PR3129 control terminal' -- bash -c 'echo PR3129_CONTROL_OK; touch /tmp/pr3129-terminal-ready; exec bash --norc -i' >evidence/terminal.log 2>&1 &
for n in $(seq 1 20); do test -e /tmp/pr3129-terminal-ready && break; sleep 1; done
test -e /tmp/pr3129-terminal-ready
terminal=$(xdotool search --onlyvisible --name 'PR3129 control terminal' | head -1)
xdotool key Escape
xdotool windowactivate --sync "$terminal"
xdotool key Escape
sleep 1
xdotool windowfocus --sync "$terminal"
xprop -root _NET_ACTIVE_WINDOW >evidence/terminal-active.txt
xdotool getwindowfocus >evidence/terminal-focus.txt
wmctrl -lpG >evidence/terminal-windows.txt
ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 evidence/terminal-ready.png >evidence/terminal-ready-capture.log 2>&1

xdotool type --clearmodifiers 'echo INPUT_CONTROL_OK > /tmp/pr3129-input-control'
xdotool key Return
sleep 1
grep INPUT_CONTROL_OK /tmp/pr3129-input-control
xdotool getwindowgeometry --shell "$terminal" >evidence/terminal-before.txt
xdotool key alt+F7; xdotool mousemove 350 200; xdotool key Return
xdotool getwindowgeometry --shell "$terminal" >evidence/terminal-after.txt
ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 evidence/control.png >evidence/control-capture.log 2>&1
xdotool windowminimize "$terminal"
# One XTest client emits a paced ~60 Hz input stream. Geometry sampling runs separately.
move_pointer() {
  local target=$1 output=$2 anchor_x=$3 anchor_y=$4 count=${5:-480}
  local -a trajectory=()
  for ((i=0;i<count;i++)); do
    ix=$((i%160)); iy=$((i%120))
    if ((ix>80)); then ix=$((160-ix)); fi
    if ((iy>60)); then iy=$((120-iy)); fi
    trajectory+=(mousemove "$((anchor_x+ix*3))" "$((anchor_y+iy*2))" sleep .016)
  done
  printf 'start=%s count=%s nominal_interval=.016\n' "$EPOCHREALTIME" "$count" >"${output%.txt}-input.txt"
  xdotool "${trajectory[@]}" &
  motion_pid=$!
  while kill -0 "$motion_pid" 2>/dev/null; do
    printf 'time=%s ' "$EPOCHREALTIME" >>"$output"
    xdotool getwindowgeometry --shell "$target" | tr '\n' ' ' >>"$output"; echo >>"$output"
    if [[ "$target" == "$terminal" ]]; then
      xdotool getwindowgeometry --shell "$wid" | tr '\n' ' ' >>"evidence/$name/app-during-terminal-move.txt"; echo >>"evidence/$name/app-during-terminal-move.txt"
    fi
    sleep .025
  done
  wait "$motion_pid"
  printf 'end=%s\n' "$EPOCHREALTIME" >>"${output%.txt}-input.txt"
}

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
  echo terminal_moving >/tmp/pr3129-phase
  xdotool windowactivate --sync "$terminal"
  xdotool key alt+F7
  move_pointer "$terminal" "evidence/$name/terminal-move-geometries.txt" 350 180
  xdotool key Return
  xdotool windowminimize "$terminal"
  xdotool windowactivate --sync "$wid"

  echo moving >/tmp/pr3129-phase
  xdotool mousemove 650 165
  xdotool key alt+F7
  move_pointer "$wid" "evidence/$name/move-geometries.txt" 400 160
  xdotool key Return
  echo stationary_after_move >/tmp/pr3129-phase; sleep 6
  xdotool windowmove "$wid" 200 150
  sleep 2
  echo app_title_drag >/tmp/pr3129-phase
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  drag_x=$((X+50)); drag_y=$((Y+15))
  xdotool mousemove "$drag_x" "$drag_y" mousedown 1
  move_pointer "$wid" "evidence/$name/title-drag-geometries.txt" "$drag_x" "$drag_y"
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
  echo send_stationary >/tmp/pr3129-phase; sleep 6
  echo send_moving >/tmp/pr3129-phase
  xdotool key alt+F7
  move_pointer "$wid" "evidence/$name/send-move-geometries.txt" 400 180
  xdotool key Return
  echo settled >/tmp/pr3129-phase; sleep 3


  ffmpeg -y -f x11grab -video_size 1440x1000 -i :99 -frames:v 1 "evidence/$name/final.png" >"evidence/$name/screenshot.log" 2>&1
  ps -p "$rec" -o pid,pcpu,rss,args >"evidence/$name/recorder-cpu.txt"
  ps -C gnome-shell -o pid,pcpu,rss,args >"evidence/$name/compositor-cpu.txt"
  kill -INT "$rec"; wait "$rec" || true
  # Compare app frame timings without recorder contention. Receive rotation is restored first.
  xdotool windowmove "$wid" 200 150
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  xdotool mousemove "$((X+50))" "$((Y+100))" click 1
  echo no_record_stationary >/tmp/pr3129-phase; sleep 8
  echo no_record_moving >/tmp/pr3129-phase
  xdotool key alt+F7
  move_pointer "$wid" "evidence/$name/no-record-move-geometries.txt" 400 160
  xdotool key Return
  if [[ "$name" == original || "$name" == base1 || "$name" == fix1 ]]; then
    xdotool windowmove "$wid" 200 150
    eval "$(xdotool getwindowgeometry --shell "$wid")"
    drag_x=$((X+50)); drag_y=$((Y+15))
    echo title60_recording >/tmp/pr3129-phase
    ffmpeg -y -f x11grab -framerate 60 -video_size 1440x1000 -i :99 -c:v libx264 -preset ultrafast -crf 25 "evidence/$name/title60.mp4" >"evidence/$name/title60-ffmpeg.log" 2>&1 &
    rec60=$!
    xdotool mousemove "$drag_x" "$drag_y" mousedown 1
    move_pointer "$wid" "evidence/$name/title60-geometries.txt" "$drag_x" "$drag_y" 300
    xdotool mouseup 1
    ps -p "$rec60" -o pid,pcpu,rss,args >"evidence/$name/recorder60-cpu.txt"
    kill -INT "$rec60"; wait "$rec60" || true
  fi

  xdotool getwindowgeometry --shell "$wid" >"evidence/$name/final-geometry.txt"
  kill "$app_pid"; wait "$app_pid" || true
  sleep 2
}
run_case original original
run_case base1 base
run_case fix1 fix
run_case fix2 fix
run_case base2 base
