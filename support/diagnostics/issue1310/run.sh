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
for scenario in native healthy-portal missing-portal; do
  export GTK_USE_PORTAL=1
  if [ "$scenario" = native ]; then
    export GTK_USE_PORTAL=0
  elif [ "$scenario" = missing-portal ]; then
    # Disable only the frontend service in this disposable diagnostic container.
    mv /usr/share/dbus-1/services/org.freedesktop.portal.Desktop.service /tmp/issue1310-portal.service
    pkill -f '^/usr/libexec/xdg-desktop-portal$' || true
    pkill -f '^/usr/lib/xdg-desktop-portal/xdg-desktop-portal$' || true
    sleep 2
  fi
  python3 support/diagnostics/issue1310/picker_probe.py "$binary" "evidence/$scenario" || echo "App probe failed for $scenario; inspect result.json" >&2
  for action in folder file multiple; do
    ./gtk-probe "$action" > "evidence/gtk-$scenario-$action.log" 2>&1 &
    probe_pid=$!
    sleep 3
    wmctrl -lpG > "evidence/gtk-$scenario-$action-windows.txt"
    import -window root "evidence/gtk-$scenario-$action.png"
    xdotool key Escape
    sleep 1
    kill "$probe_pid" 2>/dev/null || true
  done
done
