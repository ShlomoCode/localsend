#!/bin/bash
set -euo pipefail
export DISPLAY=:99
export XDG_RUNTIME_DIR=/tmp/runtime-probe
export OMP_THREAD_LIMIT=1
mkdir -p "$XDG_RUNTIME_DIR" /evidence/"$ROLE"
chmod 700 "$XDG_RUNTIME_DIR"
xdg-user-dirs-update
test "$(xdg-user-dir DOWNLOAD)" = /home/probe/Downloads
mkdir -p /home/probe/Downloads
cat /home/probe/.config/user-dirs.dirs > /evidence/"$ROLE"/user-dirs.txt
sha256sum /home/probe/LocalSend.AppImage > /evidence/"$ROLE"/release-sha256.txt
cat /etc/os-release > /evidence/"$ROLE"/environment.txt
dpkg-query -W libgtk-3-0 zenity xfce4-session >> /evidence/"$ROLE"/environment.txt
Xvfb :99 -screen 0 1280x800x24 > /evidence/"$ROLE"/xvfb.log 2>&1 &
sleep 2
exec dbus-run-session bash -c 'xfce4-session > /evidence/"$ROLE"/desktop.log 2>&1 & sleep 8; python3 /home/probe/ui.py'
