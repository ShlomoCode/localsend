set -u
. /home/probe/session-env
mkdir -p /home/probe/evidence/variants200
for variant in csd0 llvmpipe; do
  for trial in 1 2 3; do
    flatpak kill org.localsend.localsend_app 2>/dev/null || true
    sleep 1
    log=/home/probe/evidence/variants200/$variant-$trial.log
    if [ "$variant" = csd0 ]; then extra=--env=GTK_CSD=0; else extra=--env=LIBGL_ALWAYS_SOFTWARE=1; fi
    flatpak run --env=WAYLAND_DEBUG=1 --env=GDK_BACKEND=wayland "$extra" org.localsend.localsend_app > "$log" 2>&1 < /dev/null &
    launcher=$!
    sleep 7
    printf '\nVARIANT=%s TRIAL=%s\n' "$variant" "$trial"
    ps -p "$launcher" -o pid,stat,comm || true
    grep -E 'wl_display.*error|buffer_scale|create_immed|Protocol error' "$log" | tail -15 || true
    printf 'PROTOCOL_ERROR_COUNT='; grep -c 'wl_display.*error\|Protocol error' "$log" || true
    if kill -0 "$launcher" 2>/dev/null; then printf 'LAUNCHER_ALIVE=yes\n'; else wait "$launcher"; printf 'EXIT_CODE=%s\n' "$?"; fi
    gnome-screenshot -f "/home/probe/evidence/variants200/$variant-$trial.png"
  done
  printf '\nSCREEN:%s\n' "$variant"; base64 -w0 "/home/probe/evidence/variants200/$variant-3.png"; printf '\n'
done
