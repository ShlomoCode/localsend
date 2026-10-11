#!/bin/bash
set -euo pipefail
exec > /home/probe/evidence/atspi254-stock-build.log 2>&1
date -u +%FT%T.%N
task_source_commit=2b2085e3bb98c35cfeaf33a9b2852c610c3a9b7b
task_build_root=/home/probe/evidence/atspi254
test "$(flatpak info --show-commit org.freedesktop.Sdk//25.08)" = 0cc82216a407cc993941b5ddabd446becc3c9a6219d9bcf50125c60101dcad46
mkdir -p "$task_build_root/stock"
curl --fail --location --retry 3 --max-time 300 \
  "https://codeload.github.com/GNOME/at-spi2-core/tar.gz/$task_source_commit" \
  --output "$task_build_root/source.tar.gz"
sha256sum "$task_build_root/source.tar.gz"
tar -xzf "$task_build_root/source.tar.gz" -C "$task_build_root/stock" --strip-components=1
(
  cd "$task_build_root/stock"
  sha256sum --check <<'HASHES'
d6dcb95fe109220d49382fd505ebbd10c1fbbd674be93790dd48676f3ac640fa  atk-adaptor/adaptors/socket-adaptor.c
041f8df75782c2bf367f28c6f9abf2f93cf11bd5e42f57d268b93b01e606c492  atk-adaptor/accessible-register.c
3dc49977b6ab4b896f2683cd1c955b64c6a1fecfcb9e037dc1cc5c28eb8ea48a  atk/atksocket.c
HASHES
)
flatpak info org.freedesktop.Sdk//25.08
flatpak run --filesystem=/home/probe/evidence --command=sh org.freedesktop.Sdk//25.08 -c '
  set -eu
  cd /home/probe/evidence/atspi254/stock
  pkg-config --modversion glib-2.0 gobject-2.0 dbus-1 gtk+-3.0
  meson setup build --buildtype=debugoptimized -Ddocs=false -Dintrospection=disabled -Dgtk2_atk_adaptor=false -Duse_systemd=false
  meson compile -C build
  meson install -C build --destdir /home/probe/evidence/atspi254/stock-stage
  find build/atk-adaptor -maxdepth 2 -name "libatk-bridge*" -type f -exec sha256sum {} \;
  find /home/probe/evidence/atspi254/stock-stage -name "libatk-bridge*.so*" -type f -exec readelf -d {} \;
  date -u +%FT%T.%N
'
touch "$task_build_root/stock-ready"
date -u +%FT%T.%N
