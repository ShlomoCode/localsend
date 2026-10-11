#!/usr/bin/env bash
set -euo pipefail
cd /home/probe
mkdir -p evidence releases payload
printf 'Issue 1310 real file selection control\n' > payload/control.txt
{ cat /etc/os-release; uname -a; dpkg-query -W '*portal*' '*xfce*'; printenv; } > evidence/environment-before.txt
# Full desktop metapackage and its recommended portal services remain intact.
# Xvfb replaces only the physical display of this cloud VM.
nohup dbus-run-session -- bash -c 'export DISPLAY=:99 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce XDG_SESSION_TYPE=x11 LIBGL_ALWAYS_SOFTWARE=1; Xvfb :99 -screen 0 1280x900x24 > /home/probe/evidence/xvfb.log 2>&1 & sleep 2; dbus-update-activation-environment --systemd DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE; export -p > /home/probe/desktop-env.sh; startxfce4 > /home/probe/evidence/xfce.log 2>&1 & sleep 1800' > evidence/session.log 2>&1 < /dev/null &
for n in $(seq 1 30); do test -f desktop-env.sh && break; sleep 1; done
source desktop-env.sh
sleep 20
{ printenv; systemctl --user status xdg-desktop-portal xdg-desktop-portal-gtk --no-pager || true; busctl --user list; } > evidence/desktop-environment.txt
source ./actions.sh
