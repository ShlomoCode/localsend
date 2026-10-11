#!/usr/bin/env bash
# Cloud Mint session only. Run after opening the real Text dialog.
set -euo pipefail
# This script compiles and queries an app; reject execution outside the staged
# Mint guest even if somebody accidentally invokes it from a local checkout.
[[ ${PROBE_CLOUD_GEOMETRY:-0} == 1 ]] || { printf "Cloud UI integration authorization flag missing\n" >&2; exit 8; }
[[ $(uname -s) == Linux && $(id -un) == mint && -d /home/mint && -d /proc ]] || { printf "Requires the Mint cloud guest user and filesystem\n" >&2; exit 8; }
[[ -r /etc/os-release ]] || exit 8
. /etc/os-release
[[ ${ID:-} == linuxmint ]] || { printf "Requires Linux Mint cloud guest\n" >&2; exit 8; }
[[ -f /home/mint/evidence/bootstrap-complete ]] || { printf "Cloud Mint bootstrap marker missing\n" >&2; exit 8; }
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ $here == /home/mint/support/diagnostics/2754-accessibility ]] || { printf "Requires the fixture staged in /home/mint\n" >&2; exit 8; }
pid=${1:?PID required}
label=${2:?label required}
out=${3:?output directory required}
[[ $pid =~ ^[1-9][0-9]*$ ]] || exit 2
mkdir -p "$out"
# Even setup failures have an explicit global result; raw files remain beside it.
printf '{"probe_status":"incomplete","reason":"capture did not finish"}\n' > "$out/geometry-comparison.json"
version=$(pkg-config --modversion atspi-2)
[[ $version == 2.52.* ]] || { printf "Expected libatspi 2.52.x, found %s\n" "$version" >&2; exit 3; }
printf "%s\n" "$version" > "$out/libatspi-version.txt"
dpkg-query -W libatspi2.0-0 libatspi2.0-dev libglib2.0-0 libglib2.0-dev libx11-6 libx11-dev > "$out/package-versions.txt" 2>&1 || true
pkg-config --modversion x11 > "$out/x11-version.txt"
pkg-config --cflags --libs x11 > "$out/x11-build-flags.txt"
cc -std=c11 -Wall -Wextra -O0 -g "$here/x11-window.c" -o "$out/x11-window" $(pkg-config --cflags --libs x11) 2> "$out/x11-build.log"
pkg-config --cflags --libs atspi-2 glib-2.0 gobject-2.0 > "$out/build-flags.txt"
# Intentional word splitting for the pkg-config compiler flags.
cc -std=c11 -Wall -Wextra -O0 -g "$here/geometry-client.c" -o "$out/geometry-client" $(pkg-config --cflags --libs atspi-2 glib-2.0 gobject-2.0) 2> "$out/build.log"
sha256sum "$here/geometry-client.c" "$out/geometry-client" "$here/x11-window.c" "$out/x11-window" > "$out/fixture-sha256.txt"
if [[ -n ${4:-} ]]; then
  window=$4
else
  xdotool search --onlyvisible --pid "$pid" > "$out/window-candidates.txt" || true
  mapfile -t candidates < "$out/window-candidates.txt"
  [[ ${#candidates[@]} == 1 ]] || { printf "Ambiguous window; supply actual Text dialog window ID explicitly\n" >&2; exit 6; }
  window=${candidates[0]}
fi
[[ $window =~ ^[0-9]+$ ]] || exit 2
xdotool getwindowpid "$window" > "$out/window-pid.txt"
[[ $(cat "$out/window-pid.txt") == "$pid" ]] || { printf "Window PID mismatch\n" >&2; exit 7; }
printf "%s\n" "$window" > "$out/window-id.txt"
xdotool getwindowname "$window" > "$out/window-name.txt"
host_geometry() {
  local phase=$1 rc=0
  timeout --kill-after=2s 10s "$out/x11-window" "$window" > "$out/x11-$phase.raw.json" 2> "$out/x11-$phase.stderr" || rc=$?
  # Never discard malformed/partial raw output or treat an observer failure as 0.
  if [[ $rc == 0 ]] && jq -e . "$out/x11-$phase.raw.json" > /dev/null 2> "$out/x11-$phase.parse.stderr"; then
    cp "$out/x11-$phase.raw.json" "$out/x11-$phase.json"
  else
    printf 'null\n' > "$out/x11-$phase.json"
    [[ $rc != 0 ]] || rc=9
  fi
  printf '{"status":%d}\n' "$rc" > "$out/x11-$phase.status.json"
  xdotool getwindowgeometry --shell "$window" > "$out/host-$phase.env"
  # Parse the observed output without executing it.
  awk -F= '$1=="X"{x=$2} $1=="Y"{y=$2} $1=="WIDTH"{w=$2} $1=="HEIGHT"{h=$2} END {if(x==""||y==""||w==""||h=="")exit 1; printf "{\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}\n",x,y,w,h}' "$out/host-$phase.env" > "$out/host-$phase.json"
}
probe() {
  local phase=$1 rc=0
  # Preserve partial JSONL on deadline. A separate process may still hang despite
  # the public per-call timeout, so the entire session is externally bounded.
  timeout --kill-after=5s 180s "$out/geometry-client" "$pid" "$label-$phase" > "$out/$phase.jsonl" 2> "$out/$phase.stderr" || rc=$?
  printf "{\"kind\":\"process_exit\",\"phase\":\"%s\",\"status\":%d,\"deadline_hit\":%s}\n" "$phase" "$rc" "$([[ $rc == 124 || $rc == 137 ]] && printf true || printf false)" >> "$out/$phase.jsonl"
}
host_geometry before
x=$(jq -r .x "$out/host-before.json")
y=$(jq -r .y "$out/host-before.json")
restore_on_exit() {
  local rc=$? restore_rc=0
  trap - EXIT
  timeout --kill-after=2s 15s xdotool windowmove --sync "$window" "$x" "$y" > "$out/restore.stdout" 2> "$out/restore.stderr" || restore_rc=$?
  printf '{"status":%d}\n' "$restore_rc" > "$out/restore-status.json"
  host_geometry restored || true
  exit "$rc"
}
trap restore_on_exit EXIT
probe before
host_geometry before-end
# Request an actual move, retain requested and observed values independently.
jq -n --argjson x "$((x+80))" --argjson y "$((y+60))" '{x:$x,y:$y}' > "$out/move-request.json"
move_rc=0
timeout --kill-after=2s 15s xdotool windowmove --sync "$window" "$((x+80))" "$((y+60))" > "$out/move.stdout" 2> "$out/move.stderr" || move_rc=$?
printf '{"status":%d}\n' "$move_rc" > "$out/move-status.json"
host_geometry after
probe after
host_geometry after-end
jq -s --argjson pid "$pid" --slurpfile hb "$out/host-before.json" --slurpfile ha "$out/host-after.json" \
  --slurpfile xb "$out/x11-before.json" --slurpfile xa "$out/x11-after.json" \
  --slurpfile xbs "$out/x11-before.status.json" --slurpfile xas "$out/x11-after.status.json" \
  --slurpfile xbe "$out/x11-before-end.json" --slurpfile xae "$out/x11-after-end.json" \
  --slurpfile xbes "$out/x11-before-end.status.json" --slurpfile xaes "$out/x11-after-end.status.json" \
  --slurpfile move "$out/move-status.json" -f "$here/validate-geometry.jq" "$out/before.jsonl" "$out/after.jsonl" \
  > "$out/geometry-comparison.tmp.json" 2> "$out/validation.stderr"
mv "$out/geometry-comparison.tmp.json" "$out/geometry-comparison.json"
jq -e '.probe_status == "pass"' "$out/geometry-comparison.json" > /dev/null || exit 9
# EXIT trap restores position even if validation fails on partial JSONL.
