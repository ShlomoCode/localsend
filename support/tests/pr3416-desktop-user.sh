#!/usr/bin/env bash
# Invoke the controller in the PAM-created desktop user's session.
set -euo pipefail
desktop_uid=$(id -u traytest)
runtime_dir="/run/user/$desktop_uid"
for _ in {1..120}; do
  [[ -S "$runtime_dir/wayland-0" ]] && break
  sleep 1
done
if [[ ! -S "$runtime_dir/wayland-0" ]]; then
  echo "GNOME Wayland socket is missing: $runtime_dir/wayland-0" >&2
  exit 1
fi
sudo -u traytest env -u DISPLAY \
  XDG_RUNTIME_DIR="$runtime_dir" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
  WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland \
  XDG_CURRENT_DESKTOP=ubuntu:GNOME GDK_BACKEND=wayland \
  LIBGL_ALWAYS_SOFTWARE=1 LANG=C.UTF-8 \
  python3 /opt/pr3416/support/tests/pr3416-desktop-check.py "$@"
