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
  if awk -F '\t' '$12=="Done"{found=1}END{exit !found}' "evidence/$version-start.tsv"; then click_label "$version-whats-new" Done; fi
  click_label "$version-send" Send
  geometry=$(xdotool getdisplaygeometry | tr ' ' x)
  ffmpeg -y -f x11grab -framerate 10 -video_size "$geometry" -i "$DISPLAY" -t 16 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "evidence/$version-file.mp4" > "evidence/$version-video.log" 2>&1 &
  video=$!
  click_label "$version-before-file" File
  sleep 7
  snapshot "$version-after-file"
  wait "$video"
  # Exercise a real choice through the native dialog, then retain the app's
  # selected-file state. Merely seeing a dialog is a narrower control.
  mkdir -p payload
  printf 'Issue 1310 real file selection control\n' > payload/control.txt
  sha256sum payload/control.txt >> evidence/payload-sha256.txt
  xdotool key ctrl+l
  xdotool type --clearmodifiers --delay 30 "$(pwd)/payload/control.txt"
  xdotool key Return
  sleep 2
  snapshot "$version-file-selected"
  if ! awk -F '\t' '$12=="control.txt"{found=1}END{exit !found}' "evidence/$version-file-selected.tsv"; then
    xdotool key Return
    sleep 2
    snapshot "$version-file-selected-confirmed"
  fi
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
  { systemctl --user status xdg-desktop-portal xdg-desktop-portal-gtk --no-pager || true; journalctl --user -u xdg-desktop-portal -u xdg-desktop-portal-gtk --no-pager || true; busctl --user list || true; } > "evidence/$version-portal-state.txt"
  kill "$pid"
  sleep 3
done
printf 'Actual UI actions completed; inspect screenshots for picker verdicts.\n' > evidence/complete.txt
