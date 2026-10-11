#!/usr/bin/env bash
# Read-only Debian guest identity gate for the actual source-package scenario PID.
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 HOST_PID control-stock|B-stock|control-A|B-A OUTPUT_DIR" >&2; exit 2; }
pid=$1
case_name=$2
[[ $pid =~ ^[1-9][0-9]*$ ]]
[[ $case_name == control-stock || $case_name == B-stock || $case_name == control-A || $case_name == B-A ]]
mkdir -p "$3"
output=$(realpath "$3")
package=/home/probe/evidence/source-flatpak/$case_name
descriptor=/home/probe/source-input/whole-bundle-descriptor.accepted.json
engine=$(cat "$package/engine-variant.txt")
root=/proc/$pid/root
cp "/proc/$pid/stat" "$output/stat-before.txt"
cp "/proc/$pid/status" "$output/status.txt"
readlink "/proc/$pid/exe" > "$output/exe.txt"
[[ $(cat "$output/exe.txt") == /app/localsend_app ]]
cp "$root/.flatpak-info" "$output/flatpak-info.txt"
flatpak info --user org.localsend.localsend_app//diagnostic > "$output/installed-info.txt"
[[ $(flatpak info --user --show-commit org.localsend.localsend_app//diagnostic) == $(cat "$package/commit.txt") ]]
flatpak ps --columns=instance,pid,application,runtime > "$output/flatpak-instances.txt"
cp "/proc/$pid/maps" "$output/maps.txt"
tr '\0' '\n' < "/proc/$pid/environ" | sed -n \
  '/^GDK_BACKEND=/p; /^WAYLAND_DISPLAY=/p; /^DISPLAY=/p; /^XDG_SESSION_TYPE=/p; /^LD_LIBRARY_PATH=/p; /^LD_PRELOAD=/p; /^GTK_MODULES=/p' \
  > "$output/display-loader-environment.txt"
if grep -Eq '^LD_PRELOAD=.+' "$output/display-loader-environment.txt"; then exit 1; fi
for name in libflutter_linux_gtk.so libapp.so; do
  awk -v library="/$name" '$NF ~ library "$" {print $NF}' "$output/maps.txt" | sort -u > "$output/$name.paths"
  [[ $(cat "$output/$name.paths") == "/app/lib/$name" ]]
  field=engine_so_sha256
  [[ $name != libapp.so ]] || field=libapp_sha256
  [[ $(sha256sum "$root/app/lib/$name" | awk '{print $1}') == $(jq -r --arg v "$engine" --arg f "$field" '.variants[$v][$f]' "$descriptor") ]]
done
# All original source-bundle files survive normal packaging unchanged.
(cd "$root/app" && sha256sum -c "/home/probe/source-input/$engine/artifact/provenance/bundle-files-SHA256SUMS") \
  > "$output/source-bundle-files-check.txt"
awk '$NF ~ /\/libatk-bridge[^/]*\.so/ {print $NF}' "$output/maps.txt" | sort -u > "$output/bridge-paths.txt"
[[ $(wc -l < "$output/bridge-paths.txt") == 1 ]]
bridge=$(cat "$output/bridge-paths.txt")
[[ $bridge == /app/lib/libatk-bridge* ]]
[[ $(sha256sum "$root$bridge" | awk '{print $1}') == $(awk 'NR==1 {print $1}' "$package/bridge-SHA256SUMS") ]]
awk '$NF ~ /\/lib(gtk-3|atk-1|atspi|atk-bridge)[^/]*\.so/ {print $NF}' "$output/maps.txt" | sort -u > "$output/accessibility-library-paths.txt"
while IFS= read -r path; do sha256sum "$root$path"; done < "$output/accessibility-library-paths.txt" \
  > "$output/accessibility-libraries-SHA256SUMS"
cp "/proc/$pid/stat" "$output/stat-after.txt"
[[ $(sed 's/^.*) //' "$output/stat-before.txt" | awk '{print $20}') == $(sed 's/^.*) //' "$output/stat-after.txt" | awk '{print $20}') ]]
date -u +%FT%T.%N > "$output/verified-at.txt"
printf 'Same PID maps selected source-built complete %s Flatpak app and bridge. Geometry/UI still need independent assertions.\n' "$case_name" > "$output/result.txt"
