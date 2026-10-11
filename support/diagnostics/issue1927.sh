#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p evidence
OUT=$(realpath evidence)
exec > >(tee "$OUT/run.log") 2>&1
{ date -u; uname -a; cat /etc/os-release; flatpak --version; flatpak info --user org.localsend.localsend_app; flatpak info --user --show-metadata org.localsend.localsend_app; } > "$OUT/identity.txt"
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
sleep 2
openbox > "$OUT/openbox.log" 2>&1 &
sleep 2
flatpak run --user org.localsend.localsend_app > "$OUT/app.log" 2>&1 &
for i in $(seq 1 30); do
  wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1 || true)
  [ -z "$wid" ] || break
  sleep 1
done
test -n "$wid"
xdotool windowmove "$wid" 0 0
xdotool windowsize "$wid" 1000 700
sleep 3
import -window "$wid" "$OUT/receive.png"
xdotool mousemove --window "$wid" 105 211 click 1
sleep 3
import -window "$wid" "$OUT/settings.png"
tesseract "$OUT/settings.png" "$OUT/settings" tsv
flatpak run --user --command=sh org.localsend.localsend_app -c 'printf "HOME=%s\nXDG_CONFIG_HOME=%s\n" "$HOME" "$XDG_CONFIG_HOME"; ls -ld "$HOME/.config" "$XDG_CONFIG_HOME"; command -v localsend; ls -l /app/localsend_app; cat /.flatpak-info' > "$OUT/sandbox.txt"
find "$HOME/.config/autostart" "$HOME/.var/app/org.localsend.localsend_app/config" -maxdepth 2 -type f -print > "$OUT/files.txt" 2>&1 || true
flatpak kill org.localsend.localsend_app
