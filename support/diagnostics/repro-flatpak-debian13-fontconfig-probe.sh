#!/usr/bin/env bash
set -Eeuo pipefail

out=/evidence/native-probe
host_cache="$HOME/.cache/fontconfig"
app_cache="$HOME/.var/app/org.localsend.localsend_app/cache/fontconfig"
mkdir -p "$out"

case_fc_list() {
  local label="$1" status=0
  rm -rf "$app_cache"
  timeout 12s flatpak run --user --command=fc-list org.localsend.localsend_app : family \
    > "$out/$label.txt" 2>&1 || status=$?
  printf '%s\t%s\t%s\n' "$label" "$status" "$(wc -l < "$out/$label.txt")" >> "$out/summary.tsv"
}

printf 'case\texit_code\toutput_lines\n' > "$out/summary.tsv"
rm -rf "$host_cache"
mkdir -p "$host_cache"
tar -xzf /evidence/cache-snapshots/brave-1.99.20.tar.gz -C "$host_cache"
case_fc_list brave_cache
rm -rf "$host_cache"
mkdir -p "$host_cache"
case_fc_list empty_cache
