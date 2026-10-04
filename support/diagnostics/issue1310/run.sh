#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR=/tmp/issue1310-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
xfwm4 > evidence/xfwm.log 2>&1 &
xfsettingsd > evidence/xfsettings.log 2>&1 &
xfce4-panel > evidence/panel.log 2>&1 &
dbus-monitor --session > evidence/dbus.log 2>&1 &
sleep 3
binary=$(cat evidence/binary-path.txt | head -1)
ldd "$binary" > evidence/ldd.txt
for portal in 0 1; do
  export GTK_USE_PORTAL=$portal
  python3 support/diagnostics/issue1310/picker_probe.py "$binary" "evidence/portal-$portal" || echo "App probe failed for portal=$portal; inspect result.json" >&2
  for action in folder file multiple; do
    ./gtk-probe "$action" > "evidence/gtk-$portal-$action.log" 2>&1 &
    probe_pid=$!
    sleep 3
    wmctrl -lpG > "evidence/gtk-$portal-$action-windows.txt"
    import -window root "evidence/gtk-$portal-$action.png"
    xdotool key Escape
    sleep 1
    kill "$probe_pid" 2>/dev/null || true
  done
done
