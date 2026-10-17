#!/bin/bash
set -euo pipefail

# Host Mesa can require wl_fixes_interface, introduced in Wayland 1.24.
# TODO: Use apt instead when the Ubuntu baseline provides Wayland >= 1.24; Ubuntu 24.04 has 1.22.
appdir=$(realpath "${1:?Usage: stage_wayland_client.sh AppDir}")
test -d "$appdir"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fsSL --retry 3 --max-time 120 -o wayland.conda \
  https://conda.anaconda.org/conda-forge/linux-64/wayland-1.26.0-hd6090a7_0.conda
echo '6b9e182021ef3a64ab3bf788ebdab6de6775035612237c639ccafc941639eb13  wayland.conda' | sha256sum -c -
unzip -q wayland.conda

target="$appdir/usr/lib/x86_64-linux-gnu"
mkdir -p "$target" "$appdir/usr/share/licenses/wayland-client"
tar --zstd -xf pkg-wayland-*.tar.zst -C "$target" --strip-components=1 lib/libwayland-client.so.0 lib/libwayland-client.so.0.26.0
tar --zstd -xf info-wayland-*.tar.zst -C "$appdir/usr/share/licenses/wayland-client" --strip-components=2 info/licenses/COPYING
