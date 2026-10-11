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
weston --backend=x11 --renderer=gl --socket=wayland-2690 --idle-time=0 --width=1800 --height=1000 > /evidence/launch/weston.log 2>&1 &
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
  if [[ ${WAYLAND_FRESH_HOME:-0} == 1 ]]; then
    export HOME="/tmp/wayland-home-$label"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
  fi
  set +e
  LD_DEBUG=libs,versions LD_DEBUG_OUTPUT=/evidence/launch/loader-$label "$executable" > /evidence/launch/wayland-$label.log 2>&1 &
  process_pid=$!
  (
    while kill -0 "$process_pid" 2>/dev/null; do
      if [[ -r /proc/$process_pid/maps ]]; then
        cat /proc/$process_pid/maps > /evidence/launch/maps-$label.tmp
        if [[ -s /evidence/launch/maps-$label.tmp ]]; then
          mv /evidence/launch/maps-$label.tmp /evidence/launch/maps-$label.txt
        fi
      fi
      sleep 0.1
    done
  ) &
  maps_pid=$!
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
  wait "$maps_pid" || true
  printf '%s\t%s\n' "$label" "$status" >> /evidence/launch/wayland-results.tsv
  cat /evidence/launch/wayland-$label.log
}
run_window gtk-control /tmp/gtk-control
if [[ ${WAYLAND_FOCUSED:-0} == 1 ]]; then
  run_window current /evidence/current.AppImage
  run_window repacked-baseline /evidence/repacked-baseline.AppImage
  run_window candidate /evidence/repacked-candidate.AppImage
  run_window new-client /evidence/repacked-new-client.AppImage
  run_window current-after /evidence/current.AppImage
  exit 0
fi
run_window original /evidence/original.AppImage
run_window current /evidence/current.AppImage
run_window repacked-baseline /evidence/repacked-baseline.AppImage
run_window candidate /evidence/repacked-candidate.AppImage
run_window new-client /evidence/repacked-new-client.AppImage
run_window cursor-egl /evidence/repacked-cursor-egl.AppImage
run_window client-only /evidence/repacked-client-only.AppImage
run_window cursor-only /evidence/repacked-cursor-only.AppImage
run_window egl-only /evidence/repacked-egl-only.AppImage
run_window current-after /evidence/current.AppImage
mkdir -p /tmp/candidate-dir
cd /tmp/candidate-dir
/evidence/repacked-candidate.AppImage --appimage-extract > /evidence/launch/extract-candidate.log
run_window extracted-old /tmp/candidate-dir/squashfs-root/AppRun
# Diagnostic substitution changes only the client provider. It is not a deployable package.
cp /usr/lib64/libwayland-client.so.0.26.0 /tmp/candidate-dir/squashfs-root/usr/lib/x86_64-linux-gnu/libwayland-client.so.0.20.0
sha256sum /tmp/candidate-dir/squashfs-root/usr/lib/x86_64-linux-gnu/libwayland-client.so.0.20.0 > /evidence/launch/substituted-client.sha256
run_window substituted-client /tmp/candidate-dir/squashfs-root/AppRun
