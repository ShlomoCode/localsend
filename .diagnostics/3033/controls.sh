set -u
. /home/probe/session-env
mkdir -p /home/probe/evidence/controls200
app_root=$(flatpak info -l org.localsend.localsend_app)
cat "$app_root/files/manifest.json" > /home/probe/evidence/controls200/manifest.json
cat "$app_root/files/manifest.json"
printf '\nNATIVE_INITIAL_PROTOCOL\n'
head -160 /home/probe/evidence/native200/trial-1.log
flatpak kill org.localsend.localsend_app 2>/dev/null || true
WAYLAND_DEBUG=1 GDK_BACKEND=wayland gnome-calculator > /home/probe/evidence/controls200/calculator.log 2>&1 < /dev/null &
sleep 6
ps -C gnome-calculator -o pid,stat,comm
grep -E 'buffer_scale|create_immed|wl_display.*error|Protocol error' /home/probe/evidence/controls200/calculator.log | tail -12 || true
gnome-screenshot -f /home/probe/evidence/controls200/calculator.png
printf '\nSCREEN:calculator\n'; base64 -w0 /home/probe/evidence/controls200/calculator.png; printf '\n'
pkill -x gnome-calculator || true
for trial in 1 2 3; do
  flatpak kill org.localsend.localsend_app 2>/dev/null || true
  sleep 1
  log=/home/probe/evidence/controls200/xwayland-$trial.log
  flatpak run --env=WAYLAND_DEBUG=1 --env=GDK_BACKEND=x11 org.localsend.localsend_app > "$log" 2>&1 < /dev/null &
  launcher=$!
  sleep 7
  printf '\nXWAYLAND_TRIAL=%s\n' "$trial"
  ps -p "$launcher" -o pid,stat,comm || true
  xwininfo -root -tree | grep -i localsend || true
  grep -E 'wl_display.*error|buffer_scale|Protocol error|Existing version' "$log" | tail -12 || true
  gnome-screenshot -f "/home/probe/evidence/controls200/xwayland-$trial.png"
  printf 'PROTOCOL_ERROR_COUNT='; grep -c 'wl_display.*error\|Protocol error' "$log" || true
  if kill -0 "$launcher" 2>/dev/null; then printf 'LAUNCHER_ALIVE=yes\n'; else wait "$launcher"; printf 'EXIT_CODE=%s\n' "$?"; fi
done
printf '\nSCREEN:xwayland\n'; base64 -w0 /home/probe/evidence/controls200/xwayland-3.png; printf '\n'
