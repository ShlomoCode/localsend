#!/usr/bin/env bash
# Run only inside the cloud GNOME VM, in the existing logged-in user session.
set -euo pipefail
cd /home/probe
export EVIDENCE_ROOT=/home/probe/evidence
mkdir -p "$EVIDENCE_ROOT/sender" "$EVIDENCE_ROOT/receiver"
driver_pid=
mount_watcher_pid=

collect() {
  local status=$?
  trap - EXIT
  if [[ -n "$driver_pid" ]]; then kill "$driver_pid" 2>/dev/null || true; wait "$driver_pid" 2>/dev/null || true; fi
  if [[ -n "$mount_watcher_pid" ]]; then kill "$mount_watcher_pid" 2>/dev/null || true; wait "$mount_watcher_pid" 2>/dev/null || true; fi
  touch "$EVIDENCE_ROOT/sender/done"
  cat /proc/self/mountinfo > "$EVIDENCE_ROOT/sender/mountinfo-final.txt"
  loginctl list-sessions > "$EVIDENCE_ROOT/sender/sessions-final.txt" || true
  if [[ -n "${DISPLAY:-}" ]]; then scrot "$EVIDENCE_ROOT/sender/guest-final.png" || true; fi
  printf '%s\n' "$status" > "$EVIDENCE_ROOT/sender/guest-status.txt"
  exit "$status"
}
trap collect EXIT

shell_pid=$(pgrep -u "$(id -u)" -x gnome-shell | head -n 1)
test -n "$shell_pid"
# Whitelist session variables; never export/log the rest of the process environment.
while IFS= read -r -d '' entry; do
  case "$entry" in
    DISPLAY=*|XAUTHORITY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*|XDG_DATA_DIRS=*|XDG_CONFIG_DIRS=*|GTK_PATH=*|GTK_MODULES=*|GDK_PIXBUF_MODULE_FILE=*|GDK_PIXBUF_MODULEDIR=*) export "$entry" ;;
  esac
done < "/proc/$shell_pid/environ"
test "${XDG_SESSION_TYPE:-}" = x11
test -n "${DISPLAY:-}"
test -n "${XAUTHORITY:-}"
test -r "$XAUTHORITY"
test -S "${XDG_RUNTIME_DIR:?}/bus"
export OMP_THREAD_LIMIT=1
printf 'DISPLAY=%s\nXAUTHORITY=%s\nXDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\nXDG_SESSION_TYPE=%s\nXDG_CURRENT_DESKTOP=%s\n' \
  "$DISPLAY" "$XAUTHORITY" "$XDG_RUNTIME_DIR" "${DBUS_SESSION_BUS_ADDRESS:?}" "$XDG_SESSION_TYPE" "${XDG_CURRENT_DESKTOP:-}" \
  > "$EVIDENCE_ROOT/sender/session-environment.txt"
printf 'XDG_DATA_DIRS=%s\nXDG_CONFIG_DIRS=%s\nGTK_PATH=%s\nGTK_MODULES=%s\nGDK_PIXBUF_MODULE_FILE=%s\nGDK_PIXBUF_MODULEDIR=%s\n' \
  "${XDG_DATA_DIRS:-}" "${XDG_CONFIG_DIRS:-}" "${GTK_PATH:-}" "${GTK_MODULES:-}" "${GDK_PIXBUF_MODULE_FILE:-}" "${GDK_PIXBUF_MODULEDIR:-}" \
  >> "$EVIDENCE_ROOT/sender/session-environment.txt"
xdg-user-dirs-update
test "$(xdg-user-dir DOWNLOAD)" = /home/probe/Downloads
mkdir -p /home/probe/Downloads
cp /home/probe/.config/user-dirs.dirs "$EVIDENCE_ROOT/sender/user-dirs.txt"
uname -a > "$EVIDENCE_ROOT/sender/environment.txt"
cat /etc/os-release >> "$EVIDENCE_ROOT/sender/environment.txt"
gnome-shell --version >> "$EVIDENCE_ROOT/sender/environment.txt"
dpkg-query -W libgtk-3-0 zenity gdm3 gnome-shell fuse libfuse2 >> "$EVIDENCE_ROOT/sender/environment.txt"
loginctl list-sessions >> "$EVIDENCE_ROOT/sender/environment.txt"
xrandr >> "$EVIDENCE_ROOT/sender/environment.txt"
display_output=$(xrandr | awk '$2 == "connected" {print $1; exit}')
test -n "$display_output"
xrandr --output "$display_output" --mode 1280x800
xrandr > "$EVIDENCE_ROOT/sender/display-prepared.txt"
ip address > "$EVIDENCE_ROOT/sender/network.txt"
ip route >> "$EVIDENCE_ROOT/sender/network.txt"
test -c /dev/fuse
test -r /dev/fuse
test -w /dev/fuse
curl -fL --retry 3 https://github.com/localsend/localsend/releases/download/v1.8.0/LocalSend-1.8.0.AppImage -o /home/probe/LocalSend.AppImage
printf '%s  %s\n' 49eb71c34bab7c90a21c8f8cb3e220ae88b508b0a00741f906c57a464c7204c1 /home/probe/LocalSend.AppImage | sha256sum -c -
sha256sum /home/probe/LocalSend.AppImage > "$EVIDENCE_ROOT/sender/release-sha256.txt"
chmod +x /home/probe/LocalSend.AppImage
export ROLE=sender SELECTION_MODE=path APP_EXECUTABLE=/home/probe/LocalSend.AppImage MANUAL_PEER=10.0.2.2

# Observe the driver's own ordinary launch; do not extract or start another app.
watch_mount() {
  while true; do
    if awk '$0 ~ /\/tmp\/\.mount_/ && $0 ~ / - fuse/ {found=1} END {exit !found}' /proc/self/mountinfo; then
      cat /proc/self/mountinfo > "$EVIDENCE_ROOT/sender/mountinfo-appimage.txt"
      touch "$EVIDENCE_ROOT/sender/fuse-observed"
      return
    fi
    sleep 1
  done
}
watch_mount &
mount_watcher_pid=$!
set +e
python3 /home/probe/support/diagnostics/402-ui.py &
driver_pid=$!
wait "$driver_pid"
status=$?
driver_pid=
set -e
if [[ ! -e "$EVIDENCE_ROOT/sender/fuse-observed" ]]; then
  printf '%s\n' 'No ordinary AppImage FUSE mount observed during the driver run.' >&2
  status=1
fi
exit "$status"
