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
snapshot() {
  scrot "evidence/$1.png"
  tesseract "evidence/$1.png" "evidence/$1" tsv >/dev/null 2>&1
  xwininfo -root -tree > "evidence/$1-windows.txt"
}
click_label() {
  local snap=$1 word=$2
  snapshot "$snap"
  local point
  point=$(awk -F '\t' -v label="$word" '$12==label && $11>35 {print int($7+$9/2), int($8+$10/2);exit}' "evidence/$snap.tsv")
  test -n "$point"
  printf '%s %s %s\n' "$(date --iso-8601=ns)" "$word" "$point" >> evidence/input.log
  xdotool mousemove --sync $point click 1
  sleep 3
}
for version in 1.14.0 1.18.2; do
  mkdir -p "releases/$version"
  curl -fL --retry 3 -o "releases/$version.tar.gz" "https://github.com/localsend/localsend/releases/download/v$version/LocalSend-$version-linux-x86-64.tar.gz"
  sha256sum "releases/$version.tar.gz" >> evidence/release-hashes.txt
  tar xf "releases/$version.tar.gz" -C "releases/$version"
  binary=$(find "releases/$version" -name localsend_app -type f | head -1)
  ldd "$binary" > "evidence/$version-ldd.txt"
  "$binary" > "evidence/$version-app.log" 2>&1 &
  pid=$!
  sleep 15
  window=$(xdotool search --onlyvisible --pid "$pid" | head -1)
  xdotool windowsize "$window" 1050 780 windowmove "$window" 70 60 windowactivate --sync "$window"
  sleep 3
  snapshot "$version-start"
  # Dismiss the ordinary first-start language prompt if the release shows it.
  if awk -F '\t' '$12=="Confirm"{found=1}END{exit !found}' "evidence/$version-start.tsv"; then click_label "$version-confirm" Confirm; fi
  click_label "$version-send" Send
  ffmpeg -y -f x11grab -framerate 10 -video_size 1280x900 -i :99 -t 16 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "evidence/$version-file.mp4" > "evidence/$version-video.log" 2>&1 &
  video=$!
  click_label "$version-before-file" File
  sleep 7
  snapshot "$version-after-file"
  wait "$video"
  xdotool key Escape
  sleep 2
  click_label "$version-before-folder" Folder
  snapshot "$version-after-folder"
  xdotool key Escape
  sleep 2
  click_label "$version-before-text" Text
  snapshot "$version-after-text"
  xdotool key Escape
  sleep 2
  { systemctl --user status xdg-desktop-portal xdg-desktop-portal-gtk --no-pager || true; journalctl --user -u xdg-desktop-portal -u xdg-desktop-portal-gtk --no-pager; } > "evidence/$version-portal-state.txt"
  kill "$pid"
  sleep 3
done
printf 'Actual UI actions completed; inspect screenshots for picker verdicts.\n' > evidence/complete.txt
