#!/bin/bash
set -euxo pipefail
phase=$1
artifact=${2:-/evidence/original.AppImage}
expected_missing=${3:-libwayland-cursor.so.0}
export XDG_SESSION_TYPE=x11
export XDG_RUNTIME_DIR=/tmp/runtime-tester
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
dwm > /evidence/launch/dwm-$phase.log 2>&1 &
wm_pid=$!
trap 'kill "$wm_pid" 2>/dev/null || true' EXIT
xterm -title issue2690-known-working-X11 -e sleep 60 > /evidence/launch/xterm-$phase.log 2>&1 &
term_pid=$!
sleep 3
if ! xdotool search --name issue2690-known-working-X11 > /evidence/launch/x11-control-$phase.txt; then
  xdotool search --onlyvisible --class '.' getwindowname %@ || true
  cat /evidence/launch/xterm-$phase.log /evidence/launch/dwm-$phase.log /evidence/xvfb.log
  exit 1
fi
kill "$term_pid"
if [[ -x /tmp/gtk-control ]]; then
  /tmp/gtk-control > /evidence/launch/gtk-$phase.log 2>&1 &
  gtk_pid=$!
  sleep 2
  xdotool search --onlyvisible --name issue2690-native-GTK-X11-control > /evidence/launch/gtk-$phase.windows
  xwd -root -silent -out /evidence/launch/gtk-$phase.xwd
  kill "$gtk_pid"
fi
for iteration in 1 2 3; do
  set +e
  if [[ ${TRACE_LOADER:-0} == 1 ]]; then
    LD_DEBUG=libs,versions LD_DEBUG_OUTPUT=/evidence/launch/loader-$phase-$iteration "$artifact" > /evidence/launch/$phase-$iteration.log 2>&1 &
  else
    "$artifact" > /evidence/launch/$phase-$iteration.log 2>&1 &
  fi
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
  if [[ $phase == observe-* ]]; then
    : # Record unchanged controls without assuming their old-host outcome.
  elif [[ $phase == baseline* ]]; then
    grep -Fq "$expected_missing: cannot open shared object file" /evidence/launch/$phase-$iteration.log
  else
    test "$app_status" = running
    test "$window_status" = 0
  fi
done
