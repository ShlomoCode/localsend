#!/usr/bin/env bash
# Sourced in the normal Mint session; relogin/session_environment come from VM harness.
set -Eeuo pipefail
mkdir -p evidence/candidate
OUT=$(realpath evidence/candidate)
source /home/mint/ui.sh
{ flatpak info --user org.localsend.localsend_app; flatpak info --user --show-metadata org.localsend.localsend_app; } > "$OUT/identity.txt"
start_portal_monitor() {
  local label=$1
  if [ -n "${monitor_pid:-}" ]; then kill "$monitor_pid" 2>/dev/null || true; fi
  dbus-monitor --session "interface='org.freedesktop.portal.Request'" > "$OUT/$label-portal-responses.txt" 2>&1 &
  monitor_pid=$!
  sleep 1
  kill -0 "$monitor_pid"
}
start_portal_monitor initial
launch_settings() {
  local label=$1
  flatpak run --user org.localsend.localsend_app > "$OUT/$label-app.log" 2>&1 &
  wid=''
  for i in $(seq 1 30); do
    wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1 || true)
    [ -z "$wid" ] || break
    sleep 1
  done
  test -n "$wid"
  stabilize_window
  xdotool mousemove --window "$wid" 105 211 click 1
  sleep 2
  import -window "$wid" "$OUT/$label-settings.png"
}
snapshot() {
  local label=$1
  { date -u --iso-8601=ns; loginctl list-sessions; flatpak ps --columns=instance,application,pid; pgrep -ax localsend || true; } > "$OUT/$label-processes.txt"
  { ls -la "$HOME/.config/autostart"; cat "$HOME/.config/autostart/"*.desktop; } > "$OUT/$label-host-entry.txt" 2>&1 || true
  find "$HOME/.var/app/org.localsend.localsend_app" -maxdepth 5 -name '*preferences*' -type f -exec cat {} \; > "$OUT/$label-preferences.txt"
  import -window root "$OUT/$label-desktop.png"
  if [ -n "${wid:-}" ]; then import -window "$wid" "$OUT/$label-settings.png"; fi
}
click_recorded() {
  local label=$1 phrase=$2 before=$3 after=$4 entry_kind=$5 y
  y=$(require_switch_state "$phrase" "$label-before-click" "$before")
  start_ui_recording "$label"
  date -u --iso-8601=ns > "$OUT/$label-inputs.txt"
  xdotool mousemove --window "$wid" 825 "$y" click 1
  printf 'Actual Settings click at window=(825,%s)\n' "$y" >> "$OUT/$label-inputs.txt"
  wait_observed_transition "$phrase" "$label-transition" "$after" "$entry_kind"
  snapshot "$label"
  sleep 2
  stop_ui_recording
}
launch_settings initial
click_recorded enable 'Autostart after login' OFF ON host-flatpak-visible
# An actual host entry, not a remembered preference, gates the causal experiment.
test -f "$HOME/.config/autostart/org.localsend.localsend_app.desktop"
grep -q 'flatpak' "$HOME/.config/autostart/org.localsend.localsend_app.desktop"
xdotool windowactivate "$wid" key alt+F4
sleep 4
wait_app_exit enable-close
flatpak ps --columns=instance,application,pid > "$OUT/enable-after-close.txt"
launch_settings enabled-reopened
snapshot enabled-reopened
require_switch_state 'Autostart after login' enabled-reopened-observed ON > /dev/null
flatpak kill org.localsend.localsend_app
wid=''
relogin
start_portal_monitor visible-login
pgrep -x localsend > "$OUT/visible-login-pid.txt"
xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/visible-login-window.txt"
snapshot visible-login
launch_settings visible-login-settings
click_recorded hidden 'Start hidden' OFF ON host-flatpak-hidden
grep -q -- '--hidden' "$HOME/.config/autostart/org.localsend.localsend_app.desktop"
flatpak kill org.localsend.localsend_app
wid=''
relogin
start_portal_monitor hidden-login
pgrep -x localsend > "$OUT/hidden-login-pid.txt"
xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/hidden-login-window.txt" || true
test ! -s "$OUT/hidden-login-window.txt"
snapshot hidden-login
# Normal launcher asks the running app to foreground. Preserve PID identity.
launch_settings hidden-login-foreground
pgrep -x localsend > "$OUT/hidden-foreground-pid.txt"
cmp "$OUT/hidden-login-pid.txt" "$OUT/hidden-foreground-pid.txt"
click_recorded visible-again 'Start hidden' ON OFF host-flatpak-visible
if grep -q -- '--hidden' "$HOME/.config/autostart/org.localsend.localsend_app.desktop"; then exit 24; fi
flatpak kill org.localsend.localsend_app
wid=''
relogin
start_portal_monitor visible-again-login
pgrep -x localsend > "$OUT/visible-again-login-pid.txt"
xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/visible-again-login-window.txt"
snapshot visible-again-login
launch_settings disable-before
click_recorded disable 'Autostart after login' ON OFF host-absent
test ! -e "$HOME/.config/autostart/org.localsend.localsend_app.desktop"
xdotool windowactivate "$wid" key alt+F4
sleep 4
wait_app_exit disable-close
launch_settings disabled-reopened
snapshot disabled-reopened
require_switch_state 'Autostart after login' disabled-reopened-observed OFF > /dev/null
flatpak kill org.localsend.localsend_app
wid=''
relogin
snapshot disabled-login
if pgrep -x localsend; then exit 25; fi
kill "$monitor_pid" || true
printf 'Portal command-path diagnostic completed; cached-state design remains unshippable.\n' > "$OUT/result.txt"
