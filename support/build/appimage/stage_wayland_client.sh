#!/bin/bash
set -euo pipefail

appdir=$(realpath "${1:?Usage: stage_wayland_client.sh AppDir}")
test -d "$appdir"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

curl -fsSL --retry 3 --max-time 120 -o "$workdir/micromamba" \
  https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-linux-64
echo "366cd9cd8be14df1ab8ed50352a82111082a36686b2d389fdb79a92c3fafb3e3  $workdir/micromamba" | sha256sum -c -
chmod +x "$workdir/micromamba"
MAMBA_ROOT_PREFIX="$workdir/mamba" "$workdir/micromamba" --no-rc create -y -p "$workdir/env" \
  --override-channels -c conda-forge 'wayland=1.26.0=hd6090a7_0'

# Mesa on the host needs a newer client than Ubuntu 22.04 provides.
target="$appdir/usr/lib/x86_64-linux-gnu"
mkdir -p "$target"
cp -pP "$workdir/env/lib/"libwayland-client.so.0* "$target/"
mkdir -p "$appdir/usr/share/licenses/wayland-client"
license=$(find "$workdir/mamba/pkgs" -path '*/wayland-1.26.0-hd6090a7_0/info/licenses/COPYING' -print -quit)
cp "$license" "$appdir/usr/share/licenses/wayland-client/COPYING"
