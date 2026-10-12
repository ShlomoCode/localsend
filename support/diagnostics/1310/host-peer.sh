#!/usr/bin/env bash
# Real receiver app control. No protocol sender or mocked peer.
set -euo pipefail
phase=${1:-all}
case "$phase" in all|prepare|run) ;; *) exit 2;; esac
mkdir -p evidence/host-peer /home/runner/issue1310-peer/bundle /home/runner/Downloads
printf 'Issue 1310 real file selection control\n' > evidence/host-peer/expected-control.txt
peerroot=/home/runner/issue1310-peer
test ! -e /home/runner/control.txt
test ! -e /home/runner/Downloads/control.txt
if test "$phase" != run; then
  sudo apt-get install -y bash coreutils diffutils mawk curl tar dbus-x11 xvfb xauth x11-utils imagemagick openbox xdotool scrot tesseract-ocr tesseract-ocr-eng libayatana-appindicator3-1 libsecret-1-0 libopengl0 libegl1 libegl-mesa0 libgl1-mesa-dri network-manager at-spi2-core
  sudo systemctl start NetworkManager
  { systemctl status NetworkManager --no-pager; busctl --system list; } > evidence/host-peer/desktop-services.txt
  curl -fL --retry 3 -o "$peerroot/release.tar.gz" https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0-linux-x86-64.tar.gz
  sha256sum "$peerroot/release.tar.gz" > evidence/host-peer/release-sha256.txt
  tar xf "$peerroot/release.tar.gz" -C "$peerroot/bundle"
fi
# Close the full remaining command path before either LocalSend app starts.
# Internal bash operations (mapfile/read/test/printf/kill) are shell builtins.
for required in bash timeout date mkdir cp wc head sleep sha256sum cmp awk curl tar dbus-run-session xvfb-run Xvfb xauth mktemp openbox xdotool scrot xprop xwininfo convert tesseract systemctl busctl dpkg-query ldd; do
  command -v "$required" >> evidence/host-peer/command-inventory.txt
done
dpkg-query -W bash coreutils diffutils mawk curl tar dbus-x11 xvfb xauth x11-utils imagemagick openbox xdotool scrot tesseract-ocr tesseract-ocr-eng > evidence/host-peer/tool-package-versions.txt
timeout 10 convert -version > evidence/host-peer/imagemagick-version.txt
awk 'NR==1 && $3=="6.9.11-60"{found=1}END{exit !found}' evidence/host-peer/imagemagick-version.txt
timeout 10 tesseract --list-langs > evidence/host-peer/ocr-languages.txt 2>&1
awk '$0=="eng"{found=1}END{exit !found}' evidence/host-peer/ocr-languages.txt
# Qualify the exact installed serialization, not an inferred quantum format.
timeout 10 convert -size 2x2 xc:white -colorspace Gray -alpha off -depth 8 -define connected-components:verbose=true -connected-components 8 null: > evidence/host-peer/component-preflight.txt
awk '$2=="2x2+0+0" && $4==4 && ($5=="gray(255)" || $5=="gray(100%)"){found=1}END{exit !found}' evidence/host-peer/component-preflight.txt
ldd "$peerroot/bundle/localsend_app" > evidence/host-peer/receiver-ldd.txt
if awk '/not found/{found=1}END{exit !found}' evidence/host-peer/receiver-ldd.txt; then exit 1; fi
printf '%s receiver preparation qualified\n' "$(date --iso-8601=ns)" > evidence/host-peer/prepared.txt
if test "$phase" = prepare; then exit 0; fi
# Use the app's normal fresh profile and observe its actual save destination.
dbus-run-session -- xvfb-run -a -s '-screen 0 1100x800x24' bash -s <<'DESKTOP'
set -euo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
openbox > evidence/host-peer/openbox.log 2>&1 &
/home/runner/issue1310-peer/bundle/localsend_app > evidence/host-peer/app.log 2>&1 &
receiver=$!
trap 'kill "$receiver" 2>/dev/null || true' EXIT
n=0
capture_peer_pixels() {
  n=$((n + 1))
  scrot "evidence/host-peer/frame-$n.png"
  cp "evidence/host-peer/frame-$n.png" evidence/host-peer/current.png
  printf '%s frame-%s\n' "$(date --iso-8601=ns)" "$n" >> evidence/host-peer/frames.log
}
observe_peer() {
  timeout 10 convert evidence/host-peer/current.png -colorspace Gray -resize 200% -threshold 70% -negate evidence/host-peer/current-ocr.png
  timeout 10 tesseract evidence/host-peer/current-ocr.png evidence/host-peer/current-ocr --psm 11 tsv >/dev/null 2>&1
  awk -F '\t' -v OFS='\t' 'NR>1{for(i=7;i<=10;i++)$i=$i/2}{print}' evidence/host-peer/current-ocr.tsv > evidence/host-peer/current.tsv
}
capture_peer() {
  capture_peer_pixels
  observe_peer
}
request_visible() {
  awk -F '\t' '$12=="wants" && $11>60{w=1}$12=="send" && $11>60{s=1}$12=="file" && $11>60{f=1}END{exit !(w&&s&&f)}' evidence/host-peer/current.tsv
}
save_if_received() {
  saved_path=
  for candidate in /home/runner/Downloads/control.txt /home/runner/control.txt; do
    if test -f "$candidate"; then saved_path=$candidate; break; fi
  done
  if test -n "$saved_path"; then
    # Creation precedes completion. Wait for the actual payload rather than
    # treating a partially written file as a failed completed transfer.
    if test "$(wc -c < "$saved_path")" != 39 || ! cmp -s evidence/host-peer/expected-control.txt "$saved_path"; then return 0; fi
    printf '%s observed verified save, receiver elapsed %ss\n' "$(date --iso-8601=ns)" "$SECONDS" > evidence/host-peer/save-observed-at.txt
    if test -n "${click_started:-}"; then
      printf 'Observed %ss after Accept; this records observation time, not filesystem completion time.\n' "$((SECONDS - click_started))" >> evidence/host-peer/save-observed-at.txt
    fi
    printf '%s\n' "$saved_path" > evidence/host-peer/actual-save-path.txt
    sha256sum "$saved_path" > evidence/host-peer/saved-sha256.txt
    cp "$saved_path" evidence/host-peer/saved-control.txt
    cmp evidence/host-peer/expected-control.txt evidence/host-peer/saved-control.txt
    sha256sum evidence/host-peer/expected-control.txt evidence/host-peer/saved-control.txt > evidence/host-peer/content-comparison.txt
    scrot evidence/host-peer/completed.png
    test "$(wc -c < evidence/host-peer/saved-control.txt)" = 39
    printf 'real receiver saved file\n' > evidence/host-peer/result.txt
    exit 0
  fi
}
ready_deadline=$((SECONDS + 360))
while (( SECONDS < ready_deadline )); do
  save_if_received
  # scrot preserves an existing filename by adding a suffix. Capture an
  # explicit unique frame and update the OCR input to these current pixels.
  capture_peer
  confirm=$(awk -F '\t' '$12=="Confirm" && $11>60 {print int($7+$9/2),int($8+$10/2);exit}' evidence/host-peer/current.tsv)
  if test -n "$confirm"; then
    cp evidence/host-peer/current.png evidence/host-peer/first-launch-confirm.png
    printf '%s Confirm %s\n' "$(date --iso-8601=ns)" "$confirm" >> evidence/host-peer/input.log
    xdotool mousemove --sync $confirm click 1
    sleep 3
    continue
  fi
  if request_visible; then
    mapfile -t windows < <(xdotool search --onlyvisible --name '^LocalSend$')
    test "${#windows[@]}" = 1
    window=${windows[0]}
    xprop -id "$window" _NET_WM_PID WM_CLASS > evidence/host-peer/request-window.txt
    window_pid=$(awk '/_NET_WM_PID/{print $NF}' evidence/host-peer/request-window.txt)
    test "$window_pid" = "$receiver"
    timeout 5 xdotool windowactivate --sync "$window"
    test "$(xdotool getactivewindow)" = "$window"
    xdotool getwindowgeometry --shell "$window" > evidence/host-peer/request-xdotool-geometry.txt
    xwininfo -id "$window" > evidence/host-peer/request-xwininfo.txt
    xwininfo -root -tree > evidence/host-peer/request-window-tree.txt
    # xwininfo records the client rectangle in root coordinates. Keep the
    # xdotool convention separately; do not add its position to client height.
    read -r client_x client_y client_width client_height < <(awk '
      /Absolute upper-left X:/{x=$NF} /Absolute upper-left Y:/{y=$NF}
      /^  Width:/{w=$NF} /^  Height:/{h=$NF} END{print x,y,w,h}
    ' evidence/host-peer/request-xwininfo.txt)
    capture_peer
    request_visible
    # Measure the current primary-colored button component from raw pixels.
    # The reviewed request has one such component: Accept. Reject any other
    # layout or ambiguous component rather than inventing a bottom offset.
    timeout 10 convert evidence/host-peer/current.png -fuzz 3% -fill black +opaque '#006a60' -fill white -opaque '#006a60' -colorspace Gray -alpha off -depth 8 evidence/host-peer/accept-mask.png
    convert -version > evidence/host-peer/imagemagick-version.txt
    timeout 10 convert evidence/host-peer/accept-mask.png -define connected-components:verbose=true -connected-components 8 null: > evidence/host-peer/accept-components.txt
    awk -v x="$client_x" -v y="$client_y" -v w="$client_width" -v h="$client_height" '
      ($5=="gray(255)" || $5=="gray(100%)") && $4>2000 {
        split($2,b,/[x+]/)
        if(b[1]>=90 && b[1]<=200 && b[2]>=30 && b[2]<=60 && b[3]>x && b[4]>y && b[3]+b[1]<x+w && b[4]+b[2]<y+h)
          print b[1],b[2],b[3],b[4]
      }
    ' evidence/host-peer/accept-components.txt > evidence/host-peer/accept-rectangles.txt
    test "$(wc -l < evidence/host-peer/accept-rectangles.txt)" = 1
    read -r button_width button_height button_x button_y < evidence/host-peer/accept-rectangles.txt
    point="$((button_x + button_width / 2)) $((button_y + button_height / 2))"
    cp evidence/host-peer/current.png evidence/host-peer/before-accept.png
    printf '%s Accept %s\n' "$(date --iso-8601=ns)" "$point" >> evidence/host-peer/input.log
    click_started=$SECONDS
    timeout 5 xdotool mousemove --sync $point click 1
    click_deadline=$((click_started + 30))
    sleep 3
    capture_peer_pixels
    cp evidence/host-peer/current.png evidence/host-peer/after-accept-3s.png
    sleep 5
    capture_peer_pixels
    cp evidence/host-peer/current.png evidence/host-peer/after-accept-8s.png
    save_if_received
    observe_peer
    save_if_received
    if request_visible; then
      printf 'Driver click did not leave the observed receive request; no second click.\n' > evidence/host-peer/result.txt
      exit 1
    fi
    while (( SECONDS < click_deadline )); do
      save_if_received
      sleep 1
    done
    capture_peer_pixels
    cp evidence/host-peer/current.png evidence/host-peer/after-accept-deadline.png
    save_if_received
    if test -n "$saved_path"; then cp "$saved_path" evidence/host-peer/unverified-control.txt; fi
    printf 'Receive request changed, but no verified saved file within 30 seconds.\n' > evidence/host-peer/result.txt
    exit 1
  fi
  sleep 3
done
printf 'Receiver app did not save control.txt within deadline\n' > evidence/host-peer/result.txt
exit 1
DESKTOP
