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
  package_format=${PACKAGE_FORMAT:-tar}
  args=()
  if test "$package_format" = flatpak && test "$version" = 1.14.0; then
    printf 'Historical1.14 Flatpak artifact not identified; no substitute version claimed.\n' > evidence/flatpak-historical-gap.txt
    continue
  fi
  case "$package_format" in
    tar)
      curl -fL --retry 3 -o "releases/$version.tar.gz" "https://github.com/localsend/localsend/releases/download/v$version/LocalSend-$version-linux-x86-64.tar.gz"
      sha256sum "releases/$version.tar.gz" >> evidence/release-hashes.txt
      tar xf "releases/$version.tar.gz" -C "releases/$version"
      binary=$(find "releases/$version" -name localsend_app -type f | head -1)
      ;;
    appimage)
      curl -fL --retry 3 -o "releases/$version.AppImage" "https://github.com/localsend/localsend/releases/download/v$version/LocalSend-$version-linux-x86-64.AppImage"
      sha256sum "releases/$version.AppImage" >> evidence/release-hashes.txt
      chmod +x "releases/$version.AppImage"
      binary="releases/$version.AppImage"
      ;;
    deb)
      curl -fL --retry 3 -o "releases/$version.deb" "https://github.com/localsend/localsend/releases/download/v$version/LocalSend-$version-linux-x86-64.deb"
      sha256sum "releases/$version.deb" >> evidence/release-hashes.txt
      printf 'demo\n' | sudo -S apt-get install -y "$(pwd)/releases/$version.deb"
      dpkg -V localsend > "evidence/$version-package-verification.txt"
      binary=$(dpkg -L localsend | awk '/\/localsend_app$/{print;exit}')
      ;;
    flatpak)
      printf 'demo\n' | sudo -S apt-get install -y flatpak
      flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      flatpak install --user --noninteractive flathub org.localsend.localsend_app
      flatpak info --user org.localsend.localsend_app > evidence/flatpak-info.txt
      actual_version=$(LANG=C flatpak info --user org.localsend.localsend_app | awk '$1=="Version:"{print $2}')
      test "$actual_version" = "$version"
      flatpak info --user --show-commit org.localsend.localsend_app > evidence/flatpak-commit.txt
      flatpak info --user --show-permissions org.localsend.localsend_app > evidence/flatpak-permissions.txt
      flatpak info --user --show-runtime org.localsend.localsend_app > evidence/flatpak-runtime.txt
      binary=$(command -v flatpak)
      args=(run --user org.localsend.localsend_app)
      ;;
    *) exit 2;;
  esac
  printf '%s %s %s\n' "$version" "$package_format" "$binary" >> evidence/artifact-identity.txt
  ldd "$binary" > "evidence/$version-ldd.txt" 2>&1 || true
  "$binary" "${args[@]}" > "evidence/$version-app.log" 2>&1 &
  pid=$!
  sleep 15
  window=$(xdotool search --onlyvisible --name '^LocalSend$' | head -1)
  xprop -id "$window" _NET_WM_PID WM_CLASS >> evidence/app-window-identity.txt
  read -r display_width display_height < <(xdotool getdisplaygeometry)
  window_width=$((display_width - 100))
  window_height=$((display_height - 100))
  if (( window_width > 1050 )); then window_width=1050; fi
  if (( window_height > 780 )); then window_height=780; fi
  printf '%s display %s %s window %s %s\n' "$version" "$display_width" "$display_height" "$window_width" "$window_height" >> evidence/window-layout.txt
  xdotool windowsize "$window" "$window_width" "$window_height" windowmove "$window" 50 50 windowactivate --sync "$window"
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
  if grep -Eiq '"(Open File|Select.*file|Choose.*file)"' "evidence/$version-after-file-windows.txt"; then
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
  file_dialog=0
  folder_dialog=0
  text_dialog=0
  if grep -Eiq '"(Open File|Select.*file|Choose.*file)"' "evidence/$version-after-file-windows.txt"; then file_dialog=1; fi
  if grep -Eiq '"(Choose Directory|Select.*Folder|Choose.*Folder)"' "evidence/$version-after-folder-windows.txt"; then folder_dialog=1; fi
  if awk -F '\t' '$12=="message"{found=1}END{exit !found}' "evidence/$version-after-text.tsv"; then text_dialog=1; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$version" "$package_format" "$file_dialog" "$folder_dialog" "$text_dialog" >> evidence/picker-observations.tsv
  # These are observed window/text signals, not a substitute for raw frames.
  # A File failure retains both known-working controls before reporting red.
  if test "$file_dialog" = 0; then
    printf 'File native dialog absent; inspect same-case controls and raw screenshots.\n' > "evidence/$version-file-assertion-failed.txt"
    exit 1
  fi
  if test "${TRANSFER_CONTROL:-0}" = 1 && { test "$version" = 1.14.0 || test "$package_format" = flatpak; }; then
    snapshot "$version-transfer-before"
    point=$(awk -F '\t' '$12=="devices" && $11>60 {print int($7+$9+58),int($8+$10/2);exit}' "evidence/$version-transfer-before.tsv")
    test -n "$point"
    xdotool mousemove --sync $point
    sleep 2
    snapshot "$version-transfer-manual-tooltip"
    awk -F '\t' '$12=="Manual"{found=1}END{exit !found}' "evidence/$version-transfer-manual-tooltip.tsv"
    xdotool click 1
    sleep 2
    click_label "$version-transfer-ip-mode" IP
    xdotool type --clearmodifiers --delay 50 10.0.2.2
    click_label "$version-transfer-confirm-address" Confirm
    sleep 8
    snapshot "$version-transfer-progress"
    sleep 5
    snapshot "$version-transfer-completion"
    if awk -F '\t' '$12=="Done"{found=1}END{exit !found}' "evidence/$version-transfer-completion.tsv"; then click_label "$version-transfer-done" Done; fi
  fi
  { systemctl --user status xdg-desktop-portal xdg-desktop-portal-gtk --no-pager || true; journalctl --user -u xdg-desktop-portal -u xdg-desktop-portal-gtk --no-pager || true; busctl --user list || true; } > "evidence/$version-portal-state.txt"
  app_pid=$(xprop -id "$window" _NET_WM_PID | awk '{print $NF}')
  kill "$app_pid" "$pid" 2>/dev/null || true
  sleep 3
done
printf 'Actual UI actions completed; inspect screenshots for picker verdicts.\n' > evidence/complete.txt
