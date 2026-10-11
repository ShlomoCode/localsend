set -eu
. /home/probe/session-env
root=/home/probe/evidence/rapid-scale
mkdir -p "$root"
flatpak kill org.localsend.localsend_app 2>/dev/null || true
pkill -x localsend_app 2>/dev/null || true
python3 /home/probe/monitor-scale.py 1 > "$root/initial-state.json"
log="$root/trial-1.log"
flatpak run --env=WAYLAND_DEBUG=1 --env=GDK_BACKEND=wayland org.localsend.localsend_app > "$log" 2>&1 < /dev/null &
launcher=$!
sleep 7
pid=$(pgrep -n -x localsend)
ps -p "$pid" -o pid,lstart,comm
for cycle in 1 2 3 4 5 6 7 8 9 10; do
  for scale in 2 1; do
    printf "CYCLE=%s SCALE=%s\n" "$cycle" "$scale"
    python3 /home/probe/monitor-scale.py "$scale" >> "$root/states.jsonl"
    sleep .1
    if ! kill -0 "$pid" 2>/dev/null; then printf "APP_EXITED cycle=%s scale=%s\n" "$cycle" "$scale"; break 2; fi
  done
done
sleep 5
ps -p "$pid" -o pid,lstart,comm || true
printf "PROTOCOL_ERROR_COUNT="; grep -c "wl_display.*error\|Protocol error" "$log" || true
printf "OUTPUT_SCALE_EVENTS="; grep -c "wl_output.*scale(" "$log" || true
grep -E "wl_output.*scale|logical_size|buffer_scale|create_immed|wl_display.*error|Protocol error" "$log" | tail -55 || true
gnome-screenshot -f "$root/trial-1.png"
printf "\nSCREEN:rapid-scale\n"
base64 -w0 "$root/trial-1.png"
printf "\n"
