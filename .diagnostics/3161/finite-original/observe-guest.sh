#!/bin/bash
set -u
failures=0
readout() { timeout --kill-after=1s 2s "$@"; rc=$?; printf "READ_EXIT=%s COMMAND=%s\n" "$rc" "$1"; test "$rc" = 0 || failures=$((failures+1)); }
. /home/probe/session-env
printf 'OBSERVE_START UTC=%s UPTIME=%s\n' "$(date -u +%FT%T.%N)" "$(cat /proc/uptime)"
readout gsettings get org.gnome.desktop.a11y.applications screen-magnifier-enabled
readout dconf read /org/gnome/desktop/a11y/applications/screen-magnifier-enabled
readout gsettings list-recursively org.gnome.desktop.a11y.magnifier
readout python3 /home/probe/source-input/geometry-oracle/snapshot-guest.py
identity=/home/probe/evidence/finite-original/app-identity.json
if test -f "$identity"; then
  readout cat "$identity"
  pid=$(timeout --kill-after=1s 2s jq -er '.process.pid | select(type == "number" and . == floor and . > 0)' "$identity")
  pid_rc=$?
  expected_ticks=$(timeout --kill-after=1s 2s jq -er '.process.startTicks | select(type == "string" and test("^[0-9]+$"))' "$identity")
  ticks_rc=$?
  if test "$pid_rc" = 0 && test "$ticks_rc" = 0; then
    ticks=$(timeout --kill-after=1s 2s awk '{sub(/^.*\) /, ""); print $20}' "/proc/$pid/stat")
    if test "$?" = 0 && test "$ticks" = "$expected_ticks"; then
      readout cat "/proc/$pid/stat"
      readout readlink "/proc/$pid/exe"
      readout sha256sum "/proc/$pid/exe"
      readout cat "/proc/$pid/status"
      readout cat "/proc/$pid/root/.flatpak-info"
      readout cat "/proc/$pid/stat"
      ticks=$(timeout --kill-after=1s 2s awk '{sub(/^.*\) /, ""); print $20}' "/proc/$pid/stat")
      if test "$?" != 0 || test "$ticks" != "$expected_ticks"; then
        printf 'QUALIFIED_APP_PID_CHANGED_DURING_OBSERVATION=%s\n' "$pid"
        failures=$((failures+1))
      fi
    else
      printf 'QUALIFIED_APP_PID_UNAVAILABLE_OR_REUSED=%s\n' "$pid"
      failures=$((failures+1))
    fi
  else
    printf 'QUALIFIED_APP_IDENTITY_INVALID\n'
    failures=$((failures+1))
  fi
else
  # GTK control runs before app qualification; no app identity is inferred here.
  printf 'QUALIFIED_APP_IDENTITY_NOT_YET_AVAILABLE\n'
fi
printf 'OBSERVE_END UTC=%s UPTIME=%s\n' "$(date -u +%FT%T.%N)" "$(cat /proc/uptime)"
printf 'OBSERVATION_FAILURES=%s INFERENCE=inconclusive\n' "$failures"
