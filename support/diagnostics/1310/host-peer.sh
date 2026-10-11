#!/usr/bin/env bash
# Real receiver app control. No protocol sender or mocked peer.
set -euo pipefail
mkdir -p evidence/host-peer /home/runner/issue1310-peer/bundle /home/runner/Downloads
peerroot=/home/runner/issue1310-peer
sudo apt-get install -y xvfb openbox xdotool scrot tesseract-ocr libayatana-appindicator3-1 libsecret-1-0 libopengl0
curl -fL --retry 3 -o "$peerroot/release.tar.gz" https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0-linux-x86-64.tar.gz
sha256sum "$peerroot/release.tar.gz" > evidence/host-peer/release-sha256.txt
tar xf "$peerroot/release.tar.gz" -C "$peerroot/bundle"
# Use the app's normal fresh profile and default Downloads destination.
dbus-run-session -- xvfb-run -a -s '-screen 0 1100x800x24' bash -s <<'DESKTOP'
set -euo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
openbox > evidence/host-peer/openbox.log 2>&1 &
/home/runner/issue1310-peer/bundle/localsend_app > evidence/host-peer/app.log 2>&1 &
receiver=$!
trap 'kill "$receiver" 2>/dev/null || true' EXIT
for n in $(seq 1 120); do
  if test -f /home/runner/Downloads/control.txt; then
    sha256sum /home/runner/Downloads/control.txt > evidence/host-peer/saved-sha256.txt
    cp /home/runner/Downloads/control.txt evidence/host-peer/saved-control.txt
    scrot evidence/host-peer/completed.png
    printf 'real receiver saved file\n' > evidence/host-peer/result.txt
    exit 0
  fi
  scrot evidence/host-peer/current.png
  tesseract evidence/host-peer/current.png evidence/host-peer/current tsv >/dev/null 2>&1
  confirm=$(awk -F '\t' '$12=="Confirm" && $11>60 {print int($7+$9/2),int($8+$10/2);exit}' evidence/host-peer/current.tsv)
  if test -n "$confirm"; then
    cp evidence/host-peer/current.png evidence/host-peer/first-launch-confirm.png
    printf '%s Confirm %s\n' "$(date --iso-8601=ns)" "$confirm" >> evidence/host-peer/input.log
    xdotool mousemove --sync $confirm click 1
    sleep 3
    continue
  fi
  point=$(awk -F '\t' '$12=="Accept" && $11>60 {print int($7+$9/2),int($8+$10/2);exit}' evidence/host-peer/current.tsv)
  if test -n "$point"; then
    cp evidence/host-peer/current.png evidence/host-peer/before-accept.png
    printf '%s Accept %s\n' "$(date --iso-8601=ns)" "$point" >> evidence/host-peer/input.log
    xdotool mousemove --sync $point click 1
  fi
  sleep 3
done
printf 'Receiver app did not save control.txt within deadline\n' > evidence/host-peer/result.txt
exit 1
DESKTOP
