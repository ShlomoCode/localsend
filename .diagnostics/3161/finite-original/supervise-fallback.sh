#!/bin/bash
set -u
out=/home/probe/evidence/finite-original
timeout --signal=TERM --kill-after=2s 345s bash /home/probe/finite-source/fallback-guest.sh
rc=$?
# Written only after timeout has joined the sole guardian and its bounded restore.
printf 'FALLBACK_JOINED exit=%s uptime=%s\n' "$rc" "$(cut -d' ' -f1 /proc/uptime)" > "$out/fallback-finished"
exit "$rc"
