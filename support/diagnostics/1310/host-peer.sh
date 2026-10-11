#!/usr/bin/env bash
# Real receiver app control. No protocol sender or mocked peer.
set -euo pipefail
mkdir -p evidence/host-peer /home/runner/issue1310-peer/bundle /home/runner/Downloads
peerroot=/home/runner/issue1310-peer
test ! -e /home/runner/control.txt
test ! -e /home/runner/Downloads/control.txt
sudo apt-get install -y xvfb openbox xdotool scrot tesseract-ocr libayatana-appindicator3-1 libsecret-1-0 libopengl0 libegl1 libegl-mesa0 libgl1-mesa-dri network-manager at-spi2-core
sudo systemctl start NetworkManager
{ systemctl status NetworkManager --no-pager; busctl --system list; } > evidence/host-peer/desktop-services.txt
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
  saved_path=
  for candidate in /home/runner/Downloads/control.txt /home/runner/control.txt; do
    if test -f "$candidate"; then saved_path=$candidate; break; fi
  done
  if test -n "$saved_path"; then
    printf '%s\n' "$saved_path" > evidence/host-peer/actual-save-path.txt
    sha256sum "$saved_path" > evidence/host-peer/saved-sha256.txt
    cp "$saved_path" evidence/host-peer/saved-control.txt
    printf 'Issue 1310 real file selection control\n' > evidence/host-peer/expected-control.txt
    cmp evidence/host-peer/expected-control.txt evidence/host-peer/saved-control.txt
    sha256sum evidence/host-peer/expected-control.txt evidence/host-peer/saved-control.txt > evidence/host-peer/content-comparison.txt
    scrot evidence/host-peer/completed.png
    printf 'real receiver saved file\n' > evidence/host-peer/result.txt
    exit 0
  fi
  # scrot preserves an existing filename by adding a suffix. Capture an
  # explicit unique frame and update the OCR input to these current pixels.
  scrot "evidence/host-peer/frame-$n.png"
  cp "evidence/host-peer/frame-$n.png" evidence/host-peer/current.png
  convert evidence/host-peer/current.png -colorspace Gray -resize 200% -threshold 70% -negate evidence/host-peer/current-ocr.png
  tesseract evidence/host-peer/current-ocr.png evidence/host-peer/current-ocr --psm 11 tsv >/dev/null 2>&1
  awk -F '\t' -v OFS='\t' 'NR>1{for(i=7;i<=10;i++)$i=$i/2}{print}' evidence/host-peer/current-ocr.tsv > evidence/host-peer/current.tsv
  confirm=$(awk -F '\t' '$12=="Confirm" && $11>60 {print int($7+$9/2),int($8+$10/2);exit}' evidence/host-peer/current.tsv)
  if test -n "$confirm"; then
    cp evidence/host-peer/current.png evidence/host-peer/first-launch-confirm.png
    printf '%s Confirm %s\n' "$(date --iso-8601=ns)" "$confirm" >> evidence/host-peer/input.log
    xdotool mousemove --sync $confirm click 1
    sleep 3
    continue
  fi
  point=$(awk -F '\t' '$12=="Accept" && $11>60 {print int($7+$9/2),int($8+$10/2);exit}' evidence/host-peer/current.tsv)
  if test -z "$point" && awk -F '\t' '$12=="wants" && $11>60{w=1}$12=="send" && $11>60{s=1}$12=="file" && $11>60{f=1}END{exit !(w&&s&&f)}' evidence/host-peer/current.tsv; then
    # Reviewed raw request frames show Accept at the right bottom of the
    # actual compact receiver window. Require its current request text first.
    window=$(xdotool search --onlyvisible --name '^LocalSend$' | head -1)
    eval "$(xdotool getwindowgeometry --shell "$window")"
    point="$((X + WIDTH * 67 / 100)) $((Y + HEIGHT - 50))"
    printf 'Accept anchored to reviewed current request window %s\n' "$point" >> evidence/host-peer/input.log
  fi
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
