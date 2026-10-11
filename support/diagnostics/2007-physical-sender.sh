#!/usr/bin/env bash
set -euxo pipefail
export NO_AT_BRIDGE=0 LIBGL_ALWAYS_SOFTWARE=1 PHYSICAL_2007=1
gsettings set org.gnome.desktop.interface toolkit-accessibility true
openbox > evidence/openbox.log 2>&1 &
released/localsend_app > evidence/desktop.log 2>&1 &
desktop_pid=$!
trap 'kill "$desktop_pid" 2>/dev/null || true' EXIT
sleep 8
kill -0 "$desktop_pid"
desktop_window=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n1)
test -n "$desktop_window"
xdotool windowmove "$desktop_window" 0 0
xdotool windowsize "$desktop_window" 1000 700
xdotool windowactivate --sync "$desktop_window"
sleep 2
scrot evidence/desktop-initial.png
/usr/bin/python3 support/diagnostics/2007-ui.py > evidence/desktop-ui-input.log 2>&1
