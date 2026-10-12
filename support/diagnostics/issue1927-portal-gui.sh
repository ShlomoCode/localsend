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
wait_launch_bookkeeping() {
  local label=$1 identity_label="$1-launch-ready" transition_deadline=$2 attempt=0 rows='' previous_rows='' result uid
  uid=$(identity_command uid id -u) || return 1
  wid=''
  while [ "$SECONDS" -lt "$transition_deadline" ]; do
    attempt=$((attempt+1))
    identity_command "instances-$attempt" flatpak ps --columns=instance,application,pid > "$OUT/$identity_label-$attempt-instances.txt" || return 1
    identity_command "topology-$attempt" ps -u "$uid" -o pid=,ppid=,uid=,comm= > "$OUT/$identity_label-$attempt-topology.txt" || return 1
    identity_command "rows-$attempt" awk '$2=="org.localsend.localsend_app" {print $1,$3}' "$OUT/$identity_label-$attempt-instances.txt" > "$OUT/$identity_label-$attempt-rows.txt" || return 1
    rows=$(identity_command "sort-$attempt" sort "$OUT/$identity_label-$attempt-rows.txt") || return 1
    result=0
    identity_command "anchors-$attempt" awk '
      NR==FNR {present[$1]=1; next}
      $2=="org.localsend.localsend_app" {rows++; if($1 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || !($3 in present)) missing=1}
      END {exit !(rows && !missing)}
    ' "$OUT/$identity_label-$attempt-topology.txt" "$OUT/$identity_label-$attempt-instances.txt" || result=$?
    if [ "$result" != 0 ]; then
      test "$result" = 1 || return 1
      previous_rows=''
      printf 'attempt=%s unresolved-instance-anchors; retaining snapshot, no row excluded\n' "$attempt" >> "$OUT/$identity_label-convergence.txt"
      sleep .25
      continue
    fi
    result=0
    run_ui_observer xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/$identity_label-$attempt-windows.txt" 2> "$OUT/$identity_label-$attempt-window-error.txt" || result=$?
    printf 'attempt=%s bounded-visible-query-status=%s\n' "$attempt" "$result" >> "$OUT/$identity_label-convergence.txt"
    test ! -s "$OUT/$identity_label-$attempt-window-error.txt" || return 1
    if [ "$result" = 0 ] && [ "$rows" = "$previous_rows" ]; then
      wid=$(identity_command "window-first-$attempt" head -n 1 "$OUT/$identity_label-$attempt-windows.txt") || return 1
      test -n "$wid" || return 1
      break
    fi
    test "$result" = 0 || test "$result" = 1 || return 1
    previous_rows=$rows
    sleep .25
  done
  test -n "$wid" && test "$SECONDS" -lt "$transition_deadline"
}
launch_settings() {
  local label=$1 existing_visible_phase=${2:-} foreground_phase=${3:-} pid launcher_pid launcher_result=0
  local launch_deadline=$((SECONDS+30)) remaining
  test -z "$existing_visible_phase" || test -z "$foreground_phase"
  if [ -z "$existing_visible_phase" ]; then
    if [ -n "$foreground_phase" ]; then
      # Reap this owned activation launcher before observing Flatpak bookkeeping.
      remaining=$((launch_deadline-SECONDS))
      test "$remaining" -gt 0
      timeout -s KILL "$remaining" flatpak run --user org.localsend.localsend_app > "$OUT/$label-app.log" 2>&1 &
      launcher_pid=$!
      wait "$launcher_pid" || launcher_result=$?
      printf 'owned_launcher=%s reaped_status=%s\n' "$launcher_pid" "$launcher_result" > "$OUT/$label-launcher-receipt.txt"
      test "$launcher_result" = 0
    else
      flatpak run --user org.localsend.localsend_app > "$OUT/$label-app.log" 2>&1 &
    fi
  fi
  wait_launch_bookkeeping "$label" "$launch_deadline"
  snapshot "$label-before-input"
  wait_rendered_application "$label"
  pid=$(qualified_app_pid "$label")
  wid=$(qualified_visible_window "$label" "$pid")
  if [ -n "$existing_visible_phase" ]; then
    cmp "$OUT/$existing_visible_phase-process-identity.txt" "$OUT/$label-process-identity.txt"
    test "$wid" = "$(cat "$OUT/$existing_visible_phase-window.txt")"
  fi
  if [ -n "$foreground_phase" ]; then
    cmp "$OUT/$foreground_phase-process-identity.txt" "$OUT/$label-process-identity.txt"
  fi
  stabilize_window initialized
  xdotool mousemove --window "$wid" 105 211 click 1
  sleep 2
  import -window "$wid" "$OUT/$label-settings.png"
}
snapshot() {
  local label=$1 identity_label=$1 transition_deadline=$((SECONDS+12)) name window windows
  identity_command sessions loginctl list-sessions > "$OUT/$label-sessions.txt" || true
  identity_command instances flatpak ps --columns=instance,application,pid > "$OUT/$label-processes.txt" || true
  identity_command processes ps -eo pid,ppid,uid,comm,args >> "$OUT/$label-processes.txt" || true
  identity_command desktop import -window root "$OUT/$label-desktop.png" || true
  windows=$(identity_command visible-windows xdotool search --onlyvisible --name '^LocalSend$') || windows=''
  printf '%s\n' "$windows" > "$OUT/$label-visible-windows.txt"
  for window in $windows; do
    identity_command "window-$window" xprop -id "$window" WM_CLASS _NET_WM_PID >> "$OUT/$label-window-properties.txt" || true
  done
  for name in localsend_app org.localsend.localsend_app; do
    identity_command "host-stat-$name" stat "$HOME/.config/autostart/$name.desktop" >> "$OUT/$label-host-entry.txt" || true
    identity_command "host-read-$name" cat "$HOME/.config/autostart/$name.desktop" >> "$OUT/$label-host-entry.txt" || true
  done
  identity_command preferences find "$HOME/.var/app/org.localsend.localsend_app" -maxdepth 5 -name '*preferences*' -type f -exec grep -oE '"flutter.ls_flatpak_auto_start(_hidden)?":(true|false)' {} \; > "$OUT/$label-preferences.txt" || true
  if [ -n "${wid:-}" ]; then identity_command settings import -window "$wid" "$OUT/$label-settings.png" || true; fi
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
snapshot visible-login
start_portal_monitor visible-login
pid=$(qualified_app_pid visible-login)
printf '%s\n' "$pid" > "$OUT/visible-login-pid.txt"
qualified_visible_window visible-login "$pid" > "$OUT/visible-login-window.txt"
launch_settings visible-login-settings visible-login
click_recorded hidden 'Start hidden' OFF ON host-flatpak-hidden
grep -q -- '--hidden' "$HOME/.config/autostart/org.localsend.localsend_app.desktop"
flatpak kill org.localsend.localsend_app
wid=''
relogin
snapshot hidden-login
start_portal_monitor hidden-login
pid=$(qualified_app_pid hidden-login)
printf '%s\n' "$pid" > "$OUT/hidden-login-pid.txt"
window_result=0
run_ui_observer xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/hidden-login-window.txt" 2> "$OUT/hidden-login-window-error.txt" || window_result=$?
test "$window_result" = 1 && test ! -s "$OUT/hidden-login-window.txt" && test ! -s "$OUT/hidden-login-window-error.txt"
# Normal launcher asks the running app to foreground. Preserve PID identity.
launch_settings hidden-login-foreground '' hidden-login
qualified_app_pid hidden-foreground > "$OUT/hidden-foreground-pid.txt"
cmp "$OUT/hidden-login-pid.txt" "$OUT/hidden-foreground-pid.txt"
cmp "$OUT/hidden-login-process-identity.txt" "$OUT/hidden-foreground-process-identity.txt"
click_recorded visible-again 'Start hidden' ON OFF host-flatpak-visible
if grep -q -- '--hidden' "$HOME/.config/autostart/org.localsend.localsend_app.desktop"; then exit 24; fi
flatpak kill org.localsend.localsend_app
wid=''
relogin
snapshot visible-again-login
start_portal_monitor visible-again-login
pid=$(qualified_app_pid visible-again-login)
printf '%s\n' "$pid" > "$OUT/visible-again-login-pid.txt"
qualified_visible_window visible-again-login "$pid" > "$OUT/visible-again-login-window.txt"
launch_settings disable-before visible-again-login
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
run_ui_observer flatpak ps --columns=instance,application,pid > "$OUT/disabled-login-instance-check.txt"
run_ui_observer awk '$2=="org.localsend.localsend_app" {found=1} END {exit found}' "$OUT/disabled-login-instance-check.txt"
kill "$monitor_pid" || true
printf 'Portal command-path diagnostic completed; cached-state design remains unshippable.\n' > "$OUT/result.txt"
