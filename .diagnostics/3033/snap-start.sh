set -eu
. /home/probe/session-env
root=/home/probe/evidence/snap32-native200
mkdir -p "$root"
snap list localsend | tee "$root/list.txt"
version=$(snap list localsend | awk "NR==2 {print \$2}")
case "$version" in 1.17|1.17.0) ;; *) printf "WRONG_BASELINE_VERSION=%s\n" "$version"; exit 1;; esac
rev=$(snap list localsend | awk "NR==2 {print \$3}")
[ "$rev" = 32 ]
snap connections localsend | tee "$root/connections.txt"
sudo sha256sum "/var/lib/snapd/snaps/localsend_${rev}.snap"
package=$(readlink -f /snap/localsend/current)
find "$package" -type f \( -name localsend_app -o -name libflutter_linux_gtk.so \) -exec sha256sum {} \;
python3 /home/probe/monitor-scale.py 2 "1920x1080@60.000" > "$root/monitor-state.json"
cat "$root/monitor-state.json"
for trial in 1 2 3; do
  pkill -x localsend_app 2>/dev/null || true
  pkill -x localsend 2>/dev/null || true
  sleep 1
  log="$root/trial-$trial.log"
  WAYLAND_DEBUG=1 GDK_BACKEND=wayland snap run localsend > "$log" 2>&1 < /dev/null &
  launcher=$!
  sleep 10
  printf "\nSNAP_NATIVE200 TRIAL=%s\n" "$trial"
  ps -p "$launcher" -o pid,ppid,lstart,comm,args || true
  pid=$(pgrep -n -x localsend_app || pgrep -n -x localsend || true)
  if [ -n "$pid" ]; then
    printf "APP_PID=%s\n" "$pid"
    readlink "/proc/$pid/exe"
    tr "\000" "\n" < "/proc/$pid/environ" | grep -E "^(GDK_BACKEND|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|SNAP|SNAP_REVISION|LD_LIBRARY_PATH)=" || true
    grep -E "libgtk|libEGL|libgallium|dri.so" "/proc/$pid/maps" > "$root/trial-$trial-maps.txt"
  fi
  if kill -0 "$launcher" 2>/dev/null; then printf "LAUNCHER_ALIVE=yes\n"; else printf "LAUNCHER_ALIVE=no\n"; fi
  grep -E "wl_output.*scale|logical_size|buffer_scale|create_immed|create_buffer|wl_surface.*attach|wl_display.*error|Protocol error|cannot open display|snap-confine" "$log" | tail -40 || true
  printf "PROTOCOL_ERROR_COUNT="; grep -c "wl_display.*error\|Protocol error" "$log" || true
  gnome-screenshot -f "$root/trial-$trial.png"
  printf "\nSCREEN:snap32-trial-%s\n" "$trial"
  base64 -w0 "$root/trial-$trial.png"
  printf "\n"
done
