#!/usr/bin/env bash
set -euo pipefail
cd /home/demo
mkdir -p evidence releases
{ cat /etc/os-release; uname -a; dpkg-query -W '*portal*' '*xfce*'; } > evidence/initial-environment.txt
# Add remote observation tools without removing dependencies or changing
# desktop defaults. First retain the pristine desktop/portal package list.
sudo apt-get update
sudo apt-get install -y xdotool scrot tesseract-ocr ffmpeg
session=$(pgrep -u demo -x xfce4-session | head -1)
test -n "$session"
while IFS= read -r -d '' value; do
  case "$value" in DISPLAY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*|XDG_CURRENT_DESKTOP=*|XDG_SESSION_DESKTOP=*|XDG_SESSION_TYPE=*|GTK_USE_PORTAL=*|XAUTHORITY=*) export "$value";; esac
done < "/proc/$session/environ"
{ printenv; ps -ef; dpkg-query -W '*portal*'; } > evidence/desktop-environment.txt
xdotool getdisplaygeometry
scrot evidence/desktop.png
# Reuse the exact actual-app action sequence of the Ubuntu control, retaining
# this original session instead of creating a substitute desktop.
source ./actions.sh
