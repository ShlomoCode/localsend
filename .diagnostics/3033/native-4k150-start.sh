set -eu
. /home/probe/session-env
root=/home/probe/evidence/native-deb4k150
mkdir -p "$root"
flatpak kill org.localsend.localsend_app 2>/dev/null || true
python3 /home/probe/monitor-scale.py 1.5 "3840x2160@60.000" > "$root/monitor-state.json"
cat "$root/monitor-state.json"
dpkg-query -W localsend libgtk-3-0t64 libegl-mesa0 libegl1
sha256sum /home/probe/evidence/native-deb/localsend.deb /usr/share/localsend_app/localsend_app /usr/share/localsend_app/lib/libflutter_linux_gtk.so
ldd /usr/share/localsend_app/localsend_app
for trial in 1 2 3; do
  pkill -x localsend_app 2>/dev/null || true
  sleep 1
  log="$root/trial-$trial.log"
  WAYLAND_DEBUG=1 GDK_BACKEND=wayland /usr/share/localsend_app/localsend_app > "$log" 2>&1 < /dev/null &
  app=$!
  sleep 7
  printf "\nNATIVE_DEB4K150 TRIAL=%s\n" "$trial"
  ps -p "$app" -o pid,ppid,lstart,comm,args || true
  if kill -0 "$app" 2>/dev/null; then printf "APP_ALIVE=yes\n"; grep -E "libgtk-3|libEGL|dri.so" "/proc/$app/maps" | sort -u > "$root/trial-$trial-maps.txt"; else printf "APP_ALIVE=no\n"; fi
  grep -E "wl_output.*scale|logical_size|buffer_scale|create_immed|wl_display.*error|Protocol error|error while loading" "$log" | tail -35 || true
  printf "PROTOCOL_ERROR_COUNT="; grep -c "wl_display.*error\|Protocol error" "$log" || true
  gnome-screenshot -f "$root/trial-$trial.png"
done
printf "\nSCREEN:native-deb4k150\n"
base64 -w0 "$root/trial-3.png"
printf "\n"
