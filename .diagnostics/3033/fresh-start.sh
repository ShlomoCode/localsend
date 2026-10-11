set -eu
. /home/probe/session-env
scale=$1
root=/home/probe/evidence/fresh-start-verified-$scale
mkdir -p "$root"
python3 /home/probe/monitor-scale.py "$scale" > "$root/monitor-state.json"
cat "$root/monitor-state.json"
for trial in 1 2 3; do
  flatpak kill org.localsend.localsend_app 2>/dev/null || true
  sleep 1
  log="$root/trial-$trial.log"
  profile=/tmp/localsend-3033-fresh-$scale-$trial
  flatpak run --env=WAYLAND_DEBUG=1 --env=GDK_BACKEND=wayland --command=sh org.localsend.localsend_app -c 'mkdir -p "$1/config" "$1/data"; export XDG_CONFIG_HOME="$1/config" XDG_DATA_HOME="$1/data"; exec localsend' sh "$profile" > "$log" 2>&1 < /dev/null &
  launcher=$!
  sleep 7
  printf "\nFRESH_START_SCALE=%s TRIAL=%s\n" "$scale" "$trial"
  ps -eo pid,ppid,lstart,comm,args | grep "localsend" | grep -v grep
  if kill -0 "$launcher" 2>/dev/null; then printf "LAUNCHER_ALIVE=yes\n"; else printf "LAUNCHER_ALIVE=no\n"; fi
  grep -E "wl_output.*scale|logical_size|buffer_scale|create_immed|wl_display.*error|Protocol error" "$log" | tail -30 || true
  printf "PROTOCOL_ERROR_COUNT="; grep -c "wl_display.*error\|Protocol error" "$log" || true
  pid=$(pgrep -n -x localsend || true)
  if [ -n "$pid" ]; then tr "\000" "\n" < "/proc/$pid/environ" | grep "^XDG_.*HOME="; fi
  gnome-screenshot -f "$root/trial-$trial.png"
done
printf "\nSCREEN:fresh-start-%s\n" "$scale"
base64 -w0 "$root/trial-3.png"
printf "\n"
