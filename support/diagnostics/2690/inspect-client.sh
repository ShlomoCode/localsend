#!/bin/bash
set -euo pipefail
root=$(readlink -f "$1")
expected=$2
destination=$3
client_dir="$root/usr/lib/x86_64-linux-gnu"
{
  find "$root" -name 'libwayland*' -printf '%y %p -> %l\n' | sort
  mapfile -t providers < <(find "$root" -type f -name 'libwayland-client.so*')
  test "${#providers[@]}" = 1
  test "${providers[0]}" = "$client_dir/libwayland-client.so.0.26.0"
  test -L "$client_dir/libwayland-client.so.0"
  test "$(readlink "$client_dir/libwayland-client.so.0")" = libwayland-client.so.0.26.0
  mapfile -t links < <(find "$root" -type l -name 'libwayland-client.so*')
  test "${#links[@]}" = 1
  resolved=$(readlink -f "$client_dir/libwayland-client.so.0")
  test "$resolved" = "${providers[0]}"
  actual=$(sha256sum "$resolved" | cut -d' ' -f1)
  test "$actual" = "$expected"
  sha256sum "$resolved"
  stat -c '%n uid=%u gid=%g mode=%a' "$resolved" "$client_dir/libwayland-client.so.0"
  readelf -d "$resolved"
  readelf -V "$resolved"
} > "$destination"
