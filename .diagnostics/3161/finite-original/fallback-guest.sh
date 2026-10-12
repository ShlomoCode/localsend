#!/bin/bash
# One saved-baseline fallback, no application input and no mutable command feed.
set -u
. /home/probe/session-env
out=/home/probe/evidence/finite-original
due=$(jq -er '.fallbackDue | select(type == "number" and . > 0)' "$out/baseline.json") || exit 1
[[ "$due" =~ ^[0-9]+([.][0-9]+)?$ ]] || exit 1
printf 'FALLBACK_READY uptime=%s due=%s\n' "$(cut -d' ' -f1 /proc/uptime)" "$due" > "$out/fallback-ready"
while ! test -e "$out/cleanup-request"; do
  now=$(cut -d' ' -f1 /proc/uptime)
  awk -v now="$now" -v due="$due" 'BEGIN {exit !(now >= due)}' && break
  sleep 1
done
timeout --signal=TERM --kill-after=2s 65s /usr/bin/python3 -u /home/probe/finite-source/display-session.py restore "$out" > "$out/restore.log" 2>&1
rc=$?
printf 'RESTORE_RETURNED exit=%s uptime=%s\n' "$rc" "$(cut -d' ' -f1 /proc/uptime)" > "$out/restore-returned"
exit "$rc"
