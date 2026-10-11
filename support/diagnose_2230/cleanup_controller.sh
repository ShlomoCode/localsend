#!/usr/bin/env bash
set -euo pipefail
evidence=$1
case_id=$2
[[ "$case_id" =~ ^[A-Za-z0-9_-]+$ ]]
out="$evidence/cases/$case_id/receiver"
test -f "$out/controller.pid" || exit 0
pid=$(cat "$out/controller.pid")
[[ "$pid" =~ ^[1-9][0-9]*$ ]]
test -r "/proc/$pid/cmdline" || exit 0
expected_tick=$(cat "$out/controller.start-tick")
actual_tick=$(awk '{print $22}' "/proc/$pid/stat")
test "$actual_tick" = "$expected_tick"
command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
[[ "$command_line" == *receiver_control.sh* && "$command_line" == *"$case_id"* ]]
printf '%s\tTERM\t%s\n' "$(date -u --iso-8601=ns)" "$pid" > "$out/parent-cleanup.tsv"
kill -TERM "$pid"
for attempt in $(seq 1 850); do
  test -r "/proc/$pid/stat" || exit 0
  if test "$(awk '{print $3}' "/proc/$pid/stat")" = Z; then exit 0; fi
  sleep 0.2
done
printf '%s\tcontroller cleanup timeout\n' "$(date -u --iso-8601=ns)" >> "$out/parent-cleanup.tsv"
exit 1
