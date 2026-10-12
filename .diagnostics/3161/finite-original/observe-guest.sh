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
for pid in $(pgrep -x localsend_app || true); do
  readout cat "/proc/$pid/stat"
  readout readlink "/proc/$pid/exe"
  readout sha256sum "/proc/$pid/exe"
  readout cat "/proc/$pid/status"
  readout cat "/proc/$pid/root/.flatpak-info"
  readout cat "/proc/$pid/stat"
done
printf 'OBSERVE_END UTC=%s UPTIME=%s\n' "$(date -u +%FT%T.%N)" "$(cat /proc/uptime)"
printf 'OBSERVATION_FAILURES=%s INFERENCE=inconclusive\n' "$failures"
