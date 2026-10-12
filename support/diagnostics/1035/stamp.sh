#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r line || test -n "$line"; do
  printf '%s\t%s\n' "$(date --iso-8601=ns)" "$line"
done
