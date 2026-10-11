#!/usr/bin/env bash
# Guest read-only gate. Use the exact process that receives the recorded actions.
set -euo pipefail
[[ $# == 5 ]] || { echo "Usage: $0 PID BUNDLE_DIR MANIFEST ACCEPTED_DESCRIPTOR OUTPUT_DIR" >&2; exit 2; }
pid=$1
[[ $pid =~ ^[1-9][0-9]*$ ]]
bundle=$(realpath "$2")
manifest=$(realpath "$3")
descriptor=$(realpath "$4")
mkdir -p "$5"
output=$(realpath "$5")
variant=$(jq -er '.variant | select(. == "control" or . == "B")' "$manifest")
jq -e '.root_accepted == true' "$descriptor"
[[ $(sha256sum "$manifest" | awk '{print $1}') == $(jq -r --arg v "$variant" '.variants[$v].manifest_sha256' "$descriptor") ]]
cp "/proc/$pid/stat" "$output/process-stat-before.txt"
readlink "/proc/$pid/exe" > "$output/process-executable.txt"
[[ $(cat "$output/process-executable.txt") == "$bundle/localsend_app" ]]
cp "/proc/$pid/maps" "$output/process-maps.txt"
tr '\0' '\n' < "/proc/$pid/environ" | sed -n \
  '/^GDK_BACKEND=/p; /^WAYLAND_DISPLAY=/p; /^DISPLAY=/p; /^XDG_SESSION_TYPE=/p; /^LD_LIBRARY_PATH=/p; /^LD_PRELOAD=/p; /^GTK_MODULES=/p' \
  > "$output/process-display-loader-environment.txt"
# A whole source bundle must run through its normal loader paths.
if grep -Eq '^LD_(LIBRARY_PATH|PRELOAD)=.+' "$output/process-display-loader-environment.txt"; then
  echo 'Runtime library injection is outside this whole-bundle gate.' >&2
  exit 1
fi
for name in libflutter_linux_gtk.so libapp.so; do
  awk -v library="/$name" '$NF ~ library "$" {print $NF}' "$output/process-maps.txt" | sort -u > "$output/$name.paths"
  [[ $(wc -l < "$output/$name.paths") == 1 ]]
  path=$(cat "$output/$name.paths")
  [[ $(realpath "$path") == "$bundle/lib/$name" ]]
  field=engine_so_sha256
  [[ $name != libapp.so ]] || field=libapp_sha256
  [[ $(sha256sum "$path" | awk '{print $1}') == $(jq -er --arg f "$field" '.[$f]' "$manifest") ]]
  readelf -h -d -n "$path" > "$output/$name.elf.txt"
done
awk '$NF ~ /\/lib(gtk-3|atk-1|atspi|atk-bridge)[^/]*\.so/ {print $NF}' "$output/process-maps.txt" | sort -u > "$output/accessibility-library-paths.txt"
while IFS= read -r path; do
  [[ -f $path && $path != *' (deleted)' ]]
  sha256sum "$path"
  dpkg-query -S "$path" 2>/dev/null || true
done < "$output/accessibility-library-paths.txt" > "$output/accessibility-library-identities.txt"
dpkg-query -W libgtk-3-0t64 libatk1.0-0t64 libatspi2.0-0t64 libatk-bridge2.0-0t64 \
  > "$output/guest-library-packages.txt"
cat /etc/os-release > "$output/guest-os.txt"
gnome-shell --version > "$output/gnome-version.txt"
loginctl list-sessions > "$output/login-sessions.txt"
cp "/proc/$pid/stat" "$output/process-stat-after.txt"
# Linux stat has a parenthesized comm; starttime follows field 19 after it.
before=$(sed 's/^.*) //' "$output/process-stat-before.txt" | awk '{print $20}')
after=$(sed 's/^.*) //' "$output/process-stat-after.txt" | awk '{print $20}')
[[ $before == "$after" ]]
date -u +%FT%T.%N > "$output/verified-at.txt"
printf 'Same live PID maps the complete approved %s app/engine pair through normal paths. Runtime library identities are retained for separate environment acceptance.\n' "$variant" > "$output/result.txt"
