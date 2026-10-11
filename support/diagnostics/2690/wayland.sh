#!/bin/bash
set -euxo pipefail
export XDG_RUNTIME_DIR=/tmp/runtime-tester
export WAYLAND_DISPLAY=wayland-2690
export GDK_BACKEND=wayland
export XDG_SESSION_TYPE=wayland
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
dwm > /evidence/launch/dwm-wayland.log 2>&1 &
wm_pid=$!
weston --backend=x11 --renderer=gl --socket=wayland-2690 --idle-time=0 --width=1200 --height=700 > /evidence/launch/weston.log 2>&1 &
compositor_pid=$!
trap 'kill "$compositor_pid" "$wm_pid" 2>/dev/null || true' EXIT
for i in {1..30}; do
  [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
  sleep 1
done
test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
run_window() {
  label=$1
  executable=$2
  set +e
  "$executable" > /evidence/launch/wayland-$label.log 2>&1 &
  process_pid=$!
  sleep 12
  xwd -root -silent -out /evidence/launch/wayland-$label.xwd
  if kill -0 "$process_pid" 2>/dev/null; then
    status=running
    kill "$process_pid"
    wait "$process_pid"
  else
    wait "$process_pid"
    status=$?
  fi
  set -e
  printf '%s\t%s\n' "$label" "$status" >> /evidence/launch/wayland-results.tsv
  cat /evidence/launch/wayland-$label.log
}
run_window gtk-control /tmp/gtk-control
run_window original /evidence/original.AppImage
run_window current /evidence/current.AppImage
run_window repacked-baseline /evidence/repacked-baseline.AppImage
run_window candidate /evidence/repacked-candidate.AppImage
run_window current-after /evidence/current.AppImage
