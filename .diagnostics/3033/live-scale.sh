set -eu
. /home/probe/session-env
trial=${1:-1}
root=/home/probe/evidence/live-scale
mkdir -p "$root"
flatpak kill org.localsend.localsend_app 2>/dev/null || true
pkill -x gnome-control-center 2>/dev/null || true
python3 /home/probe/monitor-scale.py 1 > "$root/trial-$trial-scale-1-state.json"
sleep 2
log="$root/trial-$trial.log"
flatpak run --env=WAYLAND_DEBUG=1 --env=GDK_BACKEND=wayland org.localsend.localsend_app > "$log" 2>&1 < /dev/null &
launcher=$!
sleep 7
for scale in 1 1.5 2; do
  if [ "$scale" != 1 ]; then python3 /home/probe/monitor-scale.py "$scale" > "$root/trial-$trial-scale-$scale-state.json"; sleep 5; fi
  printf "\nTRIAL=%s SCALE=%s LOG_LINES=%s\n" "$trial" "$scale" "$(wc -l < "$log")"
  cat "$root/trial-$trial-scale-$scale-state.json"
  ps -eo pid,ppid,lstart,comm,args | grep -E "localsend|bwrap" | grep -v grep
  printf "LAUNCHER_ALIVE="; if kill -0 "$launcher" 2>/dev/null; then printf "yes\n"; else printf "no\n"; fi
  grep -E "wl_output.*scale|logical_size|buffer_scale|create_immed|wl_display.*error|Protocol error" "$log" | tail -45 || true
  printf "PROTOCOL_ERROR_COUNT="; grep -c "wl_display.*error\|Protocol error" "$log" || true
  cp "$log" "$root/trial-$trial-scale-$scale.log"
  gnome-screenshot -f "$root/trial-$trial-scale-$scale.png"
  printf "\nSCREEN:trial-%s-scale-%s\n" "$trial" "$scale"
  base64 -w0 "$root/trial-$trial-scale-$scale.png"
  printf "\n"
done
