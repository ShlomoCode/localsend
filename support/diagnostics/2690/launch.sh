#!/bin/bash
set -euxo pipefail
phase=$1
export XDG_SESSION_TYPE=x11
export XDG_RUNTIME_DIR=/tmp/runtime-tester
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
dwm > /evidence/launch/dwm-$phase.log 2>&1 &
wm_pid=$!
trap 'kill "$wm_pid" 2>/dev/null || true' EXIT
xterm -title issue2690-known-working-X11 > /evidence/launch/xterm-$phase.log 2>&1 &
term_pid=$!
sleep 3
xdotool search --name issue2690-known-working-X11 > /evidence/launch/x11-control-$phase.txt
kill "$term_pid"
for iteration in 1 2 3; do
  set +e
  /evidence/original.AppImage > /evidence/launch/$phase-$iteration.log 2>&1 &
  app_pid=$!
  sleep 10
  if kill -0 "$app_pid" 2>/dev/null; then
    xdotool search --onlyvisible --name LocalSend > /evidence/launch/$phase-$iteration.windows
    window_status=$?
    xwd -root -silent -out /evidence/launch/$phase-$iteration.xwd
    kill "$app_pid"
    wait "$app_pid"
    app_status=running
  else
    wait "$app_pid"
    app_status=$?
    window_status=none
  fi
  set -e
  printf '%s\t%s\t%s\t%s\n' "$phase" "$iteration" "$app_status" "$window_status" >> /evidence/launch/results.tsv
  cat /evidence/launch/$phase-$iteration.log
  if [[ $phase == baseline ]]; then
    grep -q 'libwayland-cursor.so.0: cannot open shared object file' /evidence/launch/$phase-$iteration.log
  else
    test "$app_status" = running
    test "$window_status" = 0
  fi
done
