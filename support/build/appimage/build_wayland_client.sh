#!/bin/bash
set -euo pipefail

# Build on Ubuntu 22.04, matching the AppImage's dependency baseline.
# Requires build-essential, pkg-config, libffi-dev, libexpat1-dev, libxml2-dev,
# python3-venv, ninja-build, curl, and ca-certificates.
appdir=$(realpath "${1:?Usage: build_wayland_client.sh AppDir}")
test "$(uname -m)" = x86_64
test -d "$appdir"
test -z "$(find "$appdir" -name 'libwayland*' -print -quit)"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

python3 -m venv tools
tools/bin/pip install --disable-pip-version-check meson==1.6.1
curl -fsSL --retry 3 --max-time 120 \
  https://distfiles.gentoo.org/distfiles/8c/wayland-1.26.0.tar.xz \
  -o wayland-1.26.0.tar.xz
echo '64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3  wayland-1.26.0.tar.xz' | sha256sum -c -
tar -xf wayland-1.26.0.tar.xz
tools/bin/meson setup build wayland-1.26.0 --buildtype=release \
  --prefix=/usr --libdir=lib/x86_64-linux-gnu -Dtests=false -Ddocumentation=false
ninja -C build
DESTDIR="$workdir/install" tools/bin/meson install -C build

# Select runtime files from the full upstream installation before packaging.
# Keep cursor and EGL supplied by the recipe's Ubuntu packages.
installed="$workdir/install/usr/lib/x86_64-linux-gnu"
test "$(readlink "$installed/libwayland-client.so.0")" = libwayland-client.so.0.26.0
target="$appdir/usr/lib/x86_64-linux-gnu"
mkdir -p "$target"
cp -p "$installed/libwayland-client.so.0.26.0" "$target/"
cp -P "$installed/libwayland-client.so.0" "$target/"
mkdir -p "$appdir/usr/share/licenses/wayland-client"
cp wayland-1.26.0/COPYING "$appdir/usr/share/licenses/wayland-client/COPYING"
