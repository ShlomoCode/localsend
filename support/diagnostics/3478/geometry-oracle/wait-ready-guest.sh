#!/bin/sh
# Use the restarted GNOME session's actual environment and bus.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
attempt=0
while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    if timeout 8s /usr/bin/python3 "$source_dir/snapshot-guest.py" "$@"; then
        exit 0
    fi
    sleep 2
done
printf '%s\n' 'Geometry oracle failed bounded readiness; stop geometry claims.' >&2
exit 1
