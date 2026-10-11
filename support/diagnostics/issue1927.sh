#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p evidence
OUT=$(realpath evidence)
source /home/mint/ui.sh
exec > >(tee "$OUT/run.log") 2>&1
{ date -u; uname -a; cat /etc/os-release; flatpak --version; flatpak info --user org.localsend.localsend_app; flatpak info --user --show-metadata org.localsend.localsend_app; } > "$OUT/identity.txt"
if [ "${EXISTING_DESKTOP:-0}" != 1 ]; then
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
sleep 2
openbox > "$OUT/openbox.log" 2>&1 &
sleep 2
fi
flatpak run --user org.localsend.localsend_app > "$OUT/app.log" 2>&1 &
for i in $(seq 1 30); do
  wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1 || true)
  [ -z "$wid" ] || break
  sleep 1
done
test -n "$wid"
stabilize_window
import -window "$wid" "$OUT/receive.png"
xdotool mousemove --window "$wid" 105 211 click 1
sleep 3
import -window "$wid" "$OUT/settings.png"
tesseract "$OUT/settings.png" "$OUT/settings" tsv
flatpak run --user --command=sh org.localsend.localsend_app -c 'printf "HOME=%s\nXDG_CONFIG_HOME=%s\n" "$HOME" "$XDG_CONFIG_HOME"; ls -ld "$HOME/.config" "$XDG_CONFIG_HOME"; command -v localsend; ls -l /app/localsend_app; cat /.flatpak-info' > "$OUT/sandbox.txt"
find "$HOME/.config/autostart" "$HOME/.var/app/org.localsend.localsend_app/config" -maxdepth 2 -type f -print > "$OUT/files.txt" 2>&1 || true
flatpak kill org.localsend.localsend_app
sleep 2
launch_settings() {
  local label=$1
  flatpak run --user org.localsend.localsend_app > "$OUT/$label-app.log" 2>&1 &
  wid=''
  for i in $(seq 1 30); do
    wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1 || true)
    [ -z "$wid" ] || break
    sleep 1
  done
  test -n "$wid"
  stabilize_window
  xdotool mousemove --window "$wid" 105 211 click 1
  sleep 2
  import -window "$wid" "$OUT/$label-before.png"
}
state() {
  local label=$1 instance app_pid
  instance=$(flatpak ps --columns=instance,application | awk '$2=="org.localsend.localsend_app" {print $1; exit}')
  test -n "$instance"
  flatpak enter "$instance" sh -c 'ls -la "$1/.config/autostart"; cat "$1/.config/autostart/"*.desktop' sh "$HOME" > "$OUT/$label-sandbox-entry.txt" 2>&1 || true
  app_pid=$(pgrep -n -x localsend)
  sudo cat "/proc/$app_pid/environ" | tr '\0' '\n' | grep -E '^(HOME|XDG_CONFIG_HOME|FLATPAK_ID|container)=' > "$OUT/$label-app-environment.txt"
  sudo ls -la "/proc/$app_pid/root$HOME/.config/autostart" > "$OUT/$label-process-root.txt" 2>&1 || true
  sudo find "/proc/$app_pid/root$HOME" -maxdepth 4 -name '*.desktop' -exec cat {} \; >> "$OUT/$label-process-root.txt" 2>&1 || true
  { ls -la "$HOME/.config/autostart"; cat "$HOME/.config/autostart/"*.desktop; } > "$OUT/$label-host-entry.txt" 2>&1 || true
  ps -eo pid,ppid,comm,args | grep -E '[l]ocalsend|[b]wrap' > "$OUT/$label-processes.txt"
  import -window "$wid" "$OUT/$label.png"
}
for repeat in 1 2; do
  label="default-$repeat"
  launch_settings "$label"
  start_ui_recording "$label-toggle"
  date -u --iso-8601=ns > "$OUT/$label-inputs.txt"
  row_y=$(require_switch_state 'Autostart after login' "$label-before-click" OFF)
  xdotool mousemove --window "$wid" 825 "$row_y" click 1
  printf 'click window=(825,%s): OCR-identified Autostart after login\n' "$row_y" >> "$OUT/$label-inputs.txt"
  wait_observed_transition 'Autostart after login' "$label-enable" ON sandbox-enabled
  state "$label-enabled"
  xdotool windowactivate "$wid" key alt+F4
  echo 'Alt+F4: actual app close' >> "$OUT/$label-inputs.txt"
  sleep 4
  wait_app_exit "$label-close"
  flatpak ps --columns=instance,application,pid > "$OUT/$label-after-close.txt"
  if grep -q org.localsend.localsend_app "$OUT/$label-after-close.txt"; then exit 31; fi
  stop_ui_recording
  launch_settings "$label-reopened"
  state "$label-reopened"
  require_switch_state 'Autostart after login' "$label-reopened-observed" OFF > /dev/null
  flatpak kill org.localsend.localsend_app
  sleep 2
done
# This is the documented user workaround, a supported Flatpak permission override.
mkdir -p "$HOME/.config/autostart"
flatpak override --user --filesystem=xdg-config/autostart org.localsend.localsend_app
flatpak override --user --show org.localsend.localsend_app > "$OUT/permission-control.txt"
launch_settings permission
row_y=$(require_switch_state 'Autostart after login' permission-before-click OFF)
xdotool mousemove --window "$wid" 825 "$row_y" click 1
wait_observed_transition 'Autostart after login' permission-enable ON host-native-enabled
state permission-enabled
xdotool windowactivate "$wid" key alt+F4
sleep 4
wait_app_exit permission-close
launch_settings permission-reopened
state permission-reopened
require_switch_state 'Autostart after login' permission-reopened-observed ON > /dev/null
flatpak run --user --command=flatpak-spawn org.localsend.localsend_app --host true > "$OUT/host-spawn-control.txt" 2>&1 || true
flatpak kill org.localsend.localsend_app
