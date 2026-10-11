#!/usr/bin/env bash
set -euxo pipefail
export XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE DESKTOP_SESSION=plasma XDG_SESSION_TYPE=x11 QT_QPA_PLATFORM=xcb LIBGL_ALWAYS_SOFTWARE=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
export XDG_RUNTIME_DIR="${RUNNER_TEMP}/runtime-3546"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
dbus-update-activation-environment --all
export KDE_SKIP_SYSTEMD_BOOT=1
mkdir -p /run/dbus
dbus-daemon --system --fork || true
NetworkManager --no-daemon > evidence/networkmanager.log 2>&1 &
sleep 2
startplasma-x11 > evidence/plasma.log 2>&1 &
sleep 30
plasma-apply-lookandfeel -a org.kde.breezedark.desktop
sleep 3
kquitapp6 plasma-welcome || true
qdbus_bin=$(command -v qdbus6 || command -v qdbus || echo /usr/lib/qt6/bin/qdbus)
"$qdbus_bin" org.kde.plasmashell /PlasmaShell > evidence/plasma-dbus.txt
"$qdbus_bin" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript 'var ps=panels(); for(var i=0;i<ps.length;i++){var ws=ps[i].widgets();for(var j=0;j<ws.length;j++){print(ws[j].id+":"+ws[j].type);}}' > evidence/widgets.txt || true
find release -maxdepth 3 -type f > evidence/release-files.txt
app=$(find "$PWD/release" -name localsend_app -type f | head -1)
cd "$(dirname "$app")"
"$app" > "$GITHUB_WORKSPACE/evidence/app.log" 2>&1 &
export APP_PID=$! APP_EXE="$app" FULL_SCENARIO=1
cd "$GITHUB_WORKSPACE"
sleep 15
import -window root evidence/desktop.png
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems > evidence/items.txt
xdotool search --onlyvisible --name . getwindowname > evidence/windows.txt || true
import -window root evidence/desktop.png
# Open the actual tray context menu and capture its contents.
xdotool mousemove 1100 775 click 3
sleep 2
import -window root evidence/tray-context.png
cp "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" evidence/plasma-config.txt
xdotool key Escape
xdotool search --name '^Welcome Center$' windowminimize || true
xdotool search --name '^LocalSend$' windowminimize || true
sleep 1
import -window root evidence/tray-settings.png
python3 support/diagnostics/3546/accessibility.py
