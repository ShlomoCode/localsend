#!/bin/bash
set -euo pipefail

# Host Mesa can require wl_fixes_interface, introduced in Wayland 1.24.
# TODO: Use apt instead when the Ubuntu baseline provides Wayland >= 1.24; Ubuntu 24.04 has 1.22.
appdir=$(realpath "${1:?Usage: build_wayland_client.sh AppDir}")
test -d "$appdir"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

python3 -m venv tools
tools/bin/pip install --disable-pip-version-check meson==1.6.1
curl -fsSL --retry 3 --max-time 120 -o wayland-1.26.0.tar.xz \
  https://distfiles.gentoo.org/distfiles/8c/wayland-1.26.0.tar.xz
echo '64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3  wayland-1.26.0.tar.xz' | sha256sum -c -
tar -xf wayland-1.26.0.tar.xz
tools/bin/meson setup build wayland-1.26.0 --buildtype=release \
  --prefix=/usr --libdir=lib/x86_64-linux-gnu -Dtests=false -Ddocumentation=false
ninja -C build
DESTDIR="$workdir/install" tools/bin/meson install -C build

target="$appdir/usr/lib/x86_64-linux-gnu"
mkdir -p "$target"
cp -pP "$workdir/install/usr/lib/x86_64-linux-gnu/"libwayland-client.so.0* "$target/"
mkdir -p "$appdir/usr/share/licenses/wayland-client"
cp wayland-1.26.0/COPYING "$appdir/usr/share/licenses/wayland-client/COPYING"
