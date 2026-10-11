#!/usr/bin/env bash
# Read-only guest gate. Invoke while the actual scenario process is still alive.
set -euo pipefail
[[ $# == 4 ]] || { echo "Usage: $0 PID BUNDLE_DIR PROVENANCE_DIR OUTPUT_DIR" >&2; exit 2; }
pid=$1
[[ $pid =~ ^[1-9][0-9]*$ ]]
bundle=$(realpath "$2")
provenance=$(realpath "$3")
mkdir -p "$4"
output=$(realpath "$4")
expected=$(jq -er '.engine_so_sha256 | select(test("^[a-f0-9]{64}$"))' "$provenance/manifest.json")
readlink "/proc/$pid/exe" > "$output/process-executable.txt"
[[ $(cat "$output/process-executable.txt") == "$bundle/localsend_app" ]]
cp "/proc/$pid/maps" "$output/process-maps.txt"
awk '/libflutter_linux_gtk\.so/ {
  for (i=6; i<=NF; i++) printf "%s%s", $i, (i==NF ? "\n" : " ")
}' "$output/process-maps.txt" | sort -u > "$output/mapped-engine-paths.txt"
[[ $(wc -l < "$output/mapped-engine-paths.txt") == 1 ]]
mapped=$(cat "$output/mapped-engine-paths.txt")
[[ $mapped != *' (deleted)' && $(realpath "$mapped") == "$bundle/lib/libflutter_linux_gtk.so" ]]
actual=$(sha256sum "$mapped" | awk '{print $1}')
[[ $actual == "$expected" ]]
sha256sum "$mapped" "$bundle/lib/libapp.so" > "$output/loaded-artifact-SHA256SUMS"
[[ $(sha256sum "$bundle/lib/libapp.so" | awk '{print $1}') == "$(jq -er .libapp_sha256 "$provenance/manifest.json")" ]]
readelf -h -d -n "$mapped" > "$output/loaded-engine-elf.txt"
grep -E 'lib(gtk-3|atk-1|atspi|atk-bridge)' "$output/process-maps.txt" > "$output/accessibility-library-maps.txt" || true
dpkg-query -W libgtk-3-0t64 libatk1.0-0t64 libatspi2.0-0t64 libatk-bridge2.0-0t64 \
  > "$output/guest-library-packages.txt" 2>&1 || true
printf 'Loaded engine path, SHA256, and c1ce AOT snapshot match the selected source-build manifest.\n' > "$output/result.txt"
