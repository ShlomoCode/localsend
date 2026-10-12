#!/usr/bin/env bash
set -euo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export XDG_SESSION_TYPE=x11
desktop_deadline=$((SECONDS + ISSUE1035_DESKTOP_SECONDS))
date --iso-8601=ns > evidence/desktop-start.txt
startxfce4 > evidence/xfce.log 2>&1 &
xfce_pid=$!
printf '%s\n' "$xfce_pid" > evidence/xfce-launcher-pid.txt
until xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'; do
  test "$SECONDS" -lt "$desktop_deadline"
  kill -0 "$xfce_pid"
  sleep 1
done
xprop -root _NET_SUPPORTING_WM_CHECK > evidence/window-manager.txt
timeout 5 busctl --user list > evidence/session-bus.txt
for key in DISPLAY XAUTHORITY XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DBUS_SESSION_BUS_ADDRESS LANG LC_ALL LIBGL_ALWAYS_SOFTWARE ISSUE1035_ROOT; do printf '%s=%s\n' "$key" "${!key-}"; done > evidence/desktop-environment.txt
timeout 5 scrot evidence/desktop-ready.png
timeout 5 busctl --system get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Connectivity > evidence/NetworkManager-connectivity.txt
test "$SECONDS" -lt "$desktop_deadline"
printf 'desktop-ready\n' > evidence/stage.txt
date --iso-8601=ns > evidence/desktop-ready.txt
scenario_deadline=$((SECONDS + 350))
guard() { test "$SECONDS" -lt "$scenario_deadline"; }
stamp() { printf '%s\t%s\n' "$(date --iso-8601=ns)" "$*" >> "$case_root/inputs.txt"; }
capture() {
  timeout 5 scrot "$case_root/$1.png"
  xprop -root _NET_ACTIVE_WINDOW > "$case_root/$1-active.txt"
  xprop -id "$window" _NET_WM_PID WM_CLASS > "$case_root/$1-app-window.txt"
}
same_app() {
  test "$(awk '{print $22}' "/proc/$app_pid/stat")" = "$app_start"
  test "$(readlink "/proc/$app_pid/exe")" = "$app_exe"
  test "$(xprop -id "$window" _NET_WM_PID | awk '{print $NF}')" = "$app_pid"
}
active_is() { test "$(xdotool getactivewindow)" = "$1"; }
click_window() {
  local target=$1 label=$2
  local geometry
  geometry=$(xdotool getwindowgeometry --shell "$target")
  local X Y WIDTH HEIGHT SCREEN WINDOW
  eval "$geometry"
  stamp "pointer $label window=$target point=$((X + WIDTH / 2)),$((Y + 30))"
  timeout 5 xdotool mousemove --sync "$((X + WIDTH / 2))" "$((Y + 30))" click 1
  for n in $(seq 1 10); do
    if active_is "$target"; then stamp "foreground $label window=$target"; return; fi
    sleep 0.1
  done
  return 1
}
read_ui() {
  timeout 5 scrot "$case_root/ui-$1.png"
  timeout 5 tesseract "$case_root/ui-$1.png" "$case_root/ui-$1" --psm 11 tsv > /dev/null 2>&1
}
click_ui_label() {
  local label=$1 snapshot=$2 point
  read_ui "$snapshot"
  point=$(awk -F '\t' -v label="$label" '$12==label && $11>55 {print int($7+$9/2),int($8+$10/2); count++} END{if(count!=1)exit 1}' "$case_root/ui-$snapshot.tsv")
  test -n "$point"
  stamp "UI $label point=$point"
  timeout 5 xdotool mousemove --sync $point click 1
  sleep 1
}
for version in 1.14.0 1.18.2; do
  guard
  case_root="$ISSUE1035_ROOT/evidence/$version"
  mkdir -p "$case_root"
  xfce4-terminal --disable-server --title="Issue1035-terminal-$version" --geometry=80x14+650+550 \
    --execute bash "$ISSUE1035_ROOT/support/diagnostics/1035/launch.sh" "$version" > "$case_root/terminal-launch.log" 2>&1 &
  terminal_launcher=$!
  until test -f "$case_root/launcher-pid.txt"; do guard; kill -0 "$terminal_launcher"; sleep 0.2; done
  launcher=$(cat "$case_root/launcher-pid.txt")
  window=
  readiness=$((SECONDS + 45))
  until test -n "$window"; do
    guard
    test "$SECONDS" -lt "$readiness"
    kill -0 "$launcher"
    mapfile -t windows < <(xdotool search --onlyvisible --name '^LocalSend$' || true)
    if test "${#windows[@]}" = 1; then window=${windows[0]}; fi
    sleep 0.2
  done
  app_pid=$(xprop -id "$window" _NET_WM_PID | awk '{print $NF}')
  app_start=$(awk '{print $22}' "/proc/$app_pid/stat")
  app_exe=$(readlink "/proc/$app_pid/exe")
  case "$app_exe" in /tmp/.mount_*/localsend_app) ;; *) exit 51;; esac
  # The rendered window must belong to the terminal-launched immutable app.
  cursor=$app_pid
  while test "$cursor" != "$launcher"; do
    test "$cursor" -gt 1
    cursor=$(awk '{print $4}' "/proc/$cursor/stat")
  done
  printf '%s %s %s %s\n' "$launcher" "$app_pid" "$app_start" "$app_exe" > "$case_root/app-identity.txt"
  cat "/proc/$app_pid/stat" > "$case_root/app-stat.txt"
  tr '\0' '\n' < "/proc/$app_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|XDG_RUNTIME_DIR|XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|XDG_SESSION_TYPE|DBUS_SESSION_BUS_ADDRESS|LANG|LC_ALL|LIBGL_ALWAYS_SOFTWARE|APPIMAGE|APPDIR)=' > "$case_root/app-environment.txt"
  grep -F "XDG_DATA_HOME=$ISSUE1035_ROOT/profiles/$version/data" "$case_root/app-environment.txt"
  find "$ISSUE1035_ROOT/profiles/$version" -type f > "$case_root/profile-files-start.txt"
  mapfile -t terminals < <(xdotool search --onlyvisible --name "^Issue1035-terminal-$version$" || true)
  test "${#terminals[@]}" = 1
  terminal=${terminals[0]}
  test "$terminal" != "$window"
  xprop -id "$terminal" _NET_WM_PID WM_CLASS > "$case_root/terminal-window.txt"
  test "$(cat "$case_root/terminal-control.txt")" = "1035 terminal control $version"
  grep -F "1035 stderr collector control $version" "$case_root/collector-control.txt"
  grep -F "1035 owned stderr stream control $version" "$case_root/stderr.raw"
  grep -F "1035 owned stderr stream control $version" "$case_root/stderr.timed"
  timeout 5 xdotool windowsize "$window" 620 500 windowmove "$window" 30 30
  timeout 5 xdotool windowmove "$terminal" 650 550
  click_window "$window" startup
  # A native GTK window can precede the first Flutter frame. Await rendered
  # ordinary controls instead of treating that native window as UI readiness.
  render_deadline=$((SECONDS + 45))
  rendered=0
  for attempt in $(seq 1 60); do
    guard
    test "$SECONDS" -lt "$render_deadline"
    same_app
    active_is "$window"
    read_ui "startup-$attempt"
    if awk -F '\t' '$12=="Settings" && $11>55{found=1}END{exit !found}' "$case_root/ui-startup-$attempt.tsv"; then
      rendered=1
      stamp "rendered Settings control observed attempt=$attempt"
      break
    fi
    if awk -F '\t' '$12=="Confirm" && $11>55{found=1}END{exit !found}' "$case_root/ui-startup-$attempt.tsv"; then click_ui_label Confirm "confirm-$attempt"; fi
    if awk -F '\t' '$12=="Done" && $11>55{found=1}END{exit !found}' "$case_root/ui-startup-$attempt.tsv"; then click_ui_label Done "done-$attempt"; fi
    sleep 0.5
  done
  test "$rendered" = 1
  # An ordinary in-app navigation control establishes usable rendering before focus claims.
  click_ui_label Settings settings
  general_deadline=$((SECONDS + 10))
  general=0
  for attempt in $(seq 1 15); do
    guard
    test "$SECONDS" -lt "$general_deadline"
    read_ui "settings-result-$attempt"
    if awk -F '\t' '$12=="General" && $11>50{found=1}END{exit !found}' "$case_root/ui-settings-result-$attempt.tsv"; then general=1; break; fi
    sleep 0.3
  done
  test "$general" = 1
  same_app
  capture control-ui
  find "$ISSUE1035_ROOT/profiles/$version" -type f > "$case_root/profile-files-control.txt"
  test -s "$case_root/profile-files-control.txt"
  printf 'qualified ordinary UI, terminal, immutable mounted app and owned window\n' > "$case_root/control-qualified.txt"
  # Each pair is the same real native sequence. Repetitions measure consistency.
  for repetition in 1 2 3; do
    guard
    same_app
    active_is "$window"
    timeout 5 busctl --system get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Connectivity > "$case_root/NM-before-$repetition.txt"
    timeout --foreground --signal=INT --kill-after=2s 15s ffmpeg -nostdin -loglevel error -y -progress "$case_root/video-$repetition-progress.txt" -f x11grab -video_size 1280x900 -framerate 12 -i "$DISPLAY" -t 12 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$case_root/focus-$repetition.mp4" > "$case_root/video-$repetition.log" 2>&1 &
    recorder=$!
    cat "/proc/$recorder/stat" > "$case_root/recorder-$repetition-stat.txt"
    frame_ready=$((SECONDS + 3))
    until test -f "$case_root/video-$repetition-progress.txt" && awk -F= '$1=="frame" && $2>=1{found=1}END{exit !found}' "$case_root/video-$repetition-progress.txt"; do
      test "$SECONDS" -lt "$frame_ready"
      kill -0 "$recorder"
      sleep 0.1
    done
    capture "before-$repetition"
    active_is "$window"
    wc -l "$case_root/stderr.raw" > "$case_root/stderr-negative-start-$repetition.txt"
    kill -0 "$recorder"
    click_window "$terminal" "other-$repetition"
    same_app
    capture "other-$repetition"
    sleep 1
    wc -l "$case_root/stderr.raw" > "$case_root/stderr-offset-$repetition.txt"
    stamp "gain-focus interval start repetition=$repetition"
    kill -0 "$recorder"
    click_window "$window" "localsend-$repetition"
    same_app
    capture "returned-$repetition"
    active_is "$window"
    kill -0 "$recorder"
    returned_video_time=$(awk -F= '$1=="out_time_us"{value=$2}END{print value+0}' "$case_root/video-$repetition-progress.txt")
    sleep 3
    awk -F= -v previous="$returned_video_time" '$1=="out_time_us" && $2>previous+1000000{found=1}END{exit !found}' "$case_root/video-$repetition-progress.txt"
    wc -l "$case_root/stderr.raw" > "$case_root/stderr-end-$repetition.txt"
    wait "$recorder"
    timeout 5 ffprobe -v error -show_entries format=duration:stream=codec_name,width,height -of default=noprint_wrappers=1 "$case_root/focus-$repetition.mp4" > "$case_root/video-$repetition-probe.txt"
    timeout 5 busctl --system get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Connectivity > "$case_root/NM-after-$repetition.txt"
    negative_line=$(awk '{print $1}' "$case_root/stderr-negative-start-$repetition.txt")
    start_line=$(awk '{print $1}' "$case_root/stderr-offset-$repetition.txt")
    if test "$start_line" -gt "$negative_line"; then
      sed -n "$((negative_line + 1)),${start_line}p" "$case_root/stderr.raw" > "$case_root/other-$repetition-stderr.txt"
    else
      : > "$case_root/other-$repetition-stderr.txt"
    fi
    end_line=$(awk '{print $1}' "$case_root/stderr-end-$repetition.txt")
    if test "$end_line" -gt "$start_line"; then
      sed -n "$((start_line + 1)),${end_line}p" "$case_root/stderr.raw" > "$case_root/focus-$repetition-stderr.txt"
    else
      : > "$case_root/focus-$repetition-stderr.txt"
    fi
    if grep -q 'Null check operator used on a null value' "$case_root/focus-$repetition-stderr.txt" && grep -q 'ConnectivityPlusLinuxPlugin._startListenConnectivity' "$case_root/focus-$repetition-stderr.txt"; then
      result=matching-null-after-qualified-focus
    else
      result=no-matching-null-in-window
    fi
    stamp "observation repetition=$repetition result=$result"
    printf '%s\t%s\n' "$repetition" "$result" >> "$case_root/observations.tsv"
  done
  find "$ISSUE1035_ROOT/profiles/$version" -type f > "$case_root/profile-files-end.txt"
  same_app
  active_is "$window"
  stamp "close original app by Alt+F4"
  timeout 5 xdotool key --clearmodifiers alt+F4
  sleep 1
  # If closing minimized to tray, terminate only the freshly verified app PID.
  if test -r "/proc/$app_pid/stat"; then same_app; kill -TERM "$app_pid"; fi
  for n in $(seq 1 20); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  ! kill -0 "$app_pid" 2>/dev/null
  printf 'original app absent\n' > "$case_root/app-cleanup.txt"
  timeout 5 xdotool windowclose "$terminal"
  printf '%s\n' "$version complete" >> evidence/conditions-complete.txt
done
printf 'Both unchanged releases observed; no fixing-change attribution.\n' > evidence/product-observation-complete.txt
