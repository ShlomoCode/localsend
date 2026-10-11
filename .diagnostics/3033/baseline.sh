set -u
. /home/probe/session-env
mkdir -p /home/probe/evidence/native200
flatpak info --show-metadata org.localsend.localsend_app > /home/probe/evidence/native200/app-metadata.txt
app_root=$(flatpak info -l org.localsend.localsend_app)
sha256sum "$app_root/files/localsend_app" "$app_root/files/lib/libflutter_linux_gtk.so" 2>/dev/null || true
find "$app_root/files" -iname '*manifest*' -o -iname '*flutter*'
gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState > /home/probe/evidence/native200/monitor-state.txt
for trial in 1 2 3; do
  flatpak kill org.localsend.localsend_app 2>/dev/null || true
  sleep 1
  log=/home/probe/evidence/native200/trial-$trial.log
  flatpak run --env=WAYLAND_DEBUG=1 --env=GDK_BACKEND=wayland org.localsend.localsend_app > "$log" 2>&1 < /dev/null &
  launcher=$!
  sleep 8
  printf '\nTRIAL=%s\n' "$trial"
  ps -p "$launcher" -o pid,stat,comm || true
  pgrep -a -x localsend_app || true
  grep -E 'wl_display.*error|buffer_scale|create_immed|Protocol error|Existing version' "$log" | tail -25 || true
  gnome-screenshot -f "/home/probe/evidence/native200/trial-$trial.png" || true
  if kill -0 "$launcher" 2>/dev/null; then printf 'LAUNCHER_ALIVE=yes\n'; else wait "$launcher"; printf 'EXIT_CODE=%s\n' "$?"; fi
  printf 'PROTOCOL_ERROR_COUNT='; grep -c 'wl_display.*error\|Protocol error' "$log" || true
  cp "$log" "/home/probe/evidence/localsend.log"
done
printf 'SCREENSHOT_BASE64\n'
base64 -w0 /home/probe/evidence/native200/trial-3.png
