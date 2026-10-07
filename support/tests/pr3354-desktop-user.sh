#!/usr/bin/env bash
set -euo pipefail
desktop_uid=$(id -u traytest)
sudo -u traytest env DISPLAY=:99 XDG_RUNTIME_DIR="/run/user/$desktop_uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$desktop_uid/bus" \
  XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=ubuntu:GNOME LANG=C.UTF-8 \
  python3 /opt/pr3354/support/tests/pr3354-desktop-check.py "$@"
