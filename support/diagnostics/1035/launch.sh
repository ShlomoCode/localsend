#!/usr/bin/env bash
set -euo pipefail
version=$1
case "$version" in 1.14.0|1.18.2) ;; *) exit 2;; esac
case_root="$ISSUE1035_ROOT/evidence/$version"
mkdir -p "$case_root"
group=$(ps -o pgid= -p "$$" | tr -d ' ')
session=$(ps -o sid= -p "$$" | tr -d ' ')
test "$group" = "$$"
test "$session" = "$$"
printf '%s %s %s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" "$group" "$session" > "$case_root/terminal-process-group.txt"
export XDG_CONFIG_HOME="$ISSUE1035_ROOT/profiles/$version/config"
export XDG_DATA_HOME="$ISSUE1035_ROOT/profiles/$version/data"
export XDG_CACHE_HOME="$ISSUE1035_ROOT/profiles/$version/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
for key in DISPLAY XAUTHORITY XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DBUS_SESSION_BUS_ADDRESS LANG LC_ALL LIBGL_ALWAYS_SOFTWARE ISSUE1035_ROOT; do printf '%s=%s\n' "$key" "${!key-}"; done > "$case_root/launch-environment.txt"
printf '1035 terminal control %s\n' "$version" | tee "$case_root/terminal-control.txt"
printf '1035 stderr collector control %s\n' "$version" |
  bash "$ISSUE1035_ROOT/support/diagnostics/1035/stamp.sh" > "$case_root/collector-control.txt"
(
  printf '1035 owned stderr stream control %s\n' "$version" >&2
  exec "$ISSUE1035_ROOT/releases/$version.AppImage"
) \
  > >(tee "$case_root/stdout.raw" | bash "$ISSUE1035_ROOT/support/diagnostics/1035/stamp.sh" | tee "$case_root/stdout.timed") \
  2> >(tee "$case_root/stderr.raw" | bash "$ISSUE1035_ROOT/support/diagnostics/1035/stamp.sh" | tee "$case_root/stderr.timed" >&2) &
app_launcher=$!
printf '%s\n' "$app_launcher" > "$case_root/launcher-pid.txt"
cat "/proc/$app_launcher/stat" > "$case_root/launcher-stat.txt"
set +e
wait "$app_launcher"
status=$?
set -e
printf '%s\n' "$status" > "$case_root/app-exit.txt"
# Leave the terminal visible after a normal exit; desktop supervisor owns cleanup.
sleep 120
