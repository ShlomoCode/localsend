#!/bin/bash
# Diagnostic logging only: return native picker stdout bytes and exit status unchanged.
set -u
backend=$(basename "$0")
capture=$(mktemp /evidence/sender/picker-XXXXXX)
chmod 644 "$capture"
"/usr/bin/$backend" "$@" > "$capture.stdout"
status=$?
printf '%s\n' "$status" > "$capture.status"
printf '%s\n' "$@" > "$capture.args"
od -An -tx1 "$capture.stdout" > "$capture.stdout-hex"
while IFS= read -r selected; do
  printf 'SELECTED %s\n' "$selected" >> "$capture.metadata"
  readlink -v "$selected" >> "$capture.metadata" 2>&1 || true
  stat -L "$selected" >> "$capture.metadata" 2>&1 || true
  realpath "$selected" >> "$capture.metadata" 2>&1 || true
done < "$capture.stdout"
cat "$capture.stdout"
exit "$status"
