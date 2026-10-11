#!/usr/bin/env bash
# Guest only. Install and launch one normal source package, retaining owned state.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 CASE_NAME x11|wayland" >&2; exit 2; }
case_name=$1
backend=$2
[[ $case_name == control-stock || $case_name == B-stock || $case_name == control-A || $case_name == B-A ]]
[[ $backend == x11 || $backend == wayland ]]
. /home/probe/session-env
package=/home/probe/evidence/source-flatpak/$case_name
[[ -s $package/commit.txt ]]
flatpak kill org.localsend.localsend_app 2>/dev/null || true
flatpak remote-add --user --if-not-exists --no-gpg-verify "diagnostic-3161-$case_name" "$package/repo"
flatpak install --user -y --reinstall --no-related --no-deps "diagnostic-3161-$case_name" org.localsend.localsend_app//diagnostic
[[ $(flatpak info --user --show-commit org.localsend.localsend_app//diagnostic) == $(cat "$package/commit.txt") ]]
launch=/home/probe/evidence/launch-$case_name-$backend-$(date -u +%Y%m%dT%H%M%S)
mkdir -p "$launch"
# Retain existing app-owned profile before giving the candidate an equivalent fresh one.
profile=/home/probe/.var/app/org.localsend.localsend_app
if [[ -d $profile ]]; then mv "$profile" "$launch/profile-before"; fi
printf '%s\n' "$launch" > /home/probe/evidence/current-launch.txt
gsettings get org.gnome.desktop.a11y.applications screen-magnifier-enabled > "$launch/zoom-before.txt"
gsettings get org.gnome.desktop.interface toolkit-accessibility > "$launch/accessibility-before.txt"
date -u +%FT%T.%N > "$launch/launched-at.txt"
backend_permissions=()
# fallback-x11 is intentionally unavailable when the host Wayland socket works.
# Grant X11 explicitly only for the separately labeled Xwayland control.
[[ $backend != x11 ]] || backend_permissions=(--socket=x11)
printf 'flatpak run --user %s --env=GDK_BACKEND=%s --env=G_MESSAGES_DEBUG=all org.localsend.localsend_app//diagnostic\n' "${backend_permissions[*]}" "$backend" > "$launch/command.txt"
nohup flatpak run --user "${backend_permissions[@]}" --env=GDK_BACKEND="$backend" --env=G_MESSAGES_DEBUG=all \
  org.localsend.localsend_app//diagnostic > "$launch/app.log" 2>&1 < /dev/null &
printf '%s\n' "$!" > "$launch/launcher-pid.txt"
# The UI controller must locate and retain the actual host app PID; launcher PID is not that assertion.
printf 'Launched %s with explicit %s backend. Verify actual app PID/maps and independent geometry before assertions.\n' "$case_name" "$backend"
