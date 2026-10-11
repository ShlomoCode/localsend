#!/bin/bash
set -euo pipefail
exec > /home/probe/evidence/atspi254-A-build.log 2>&1
date -u +%FT%T.%N
task_build_root=/home/probe/evidence/atspi254
test "$(flatpak info --show-commit org.freedesktop.Sdk//25.08)" = 0cc82216a407cc993941b5ddabd446becc3c9a6219d9bcf50125c60101dcad46
sha256sum --check <<'HASHES'
ef4f2a528f76edc7cb37b70d0143a51fa5e049ae93198c4426befd2c250c3b03  /home/probe/evidence/atspi254/source.tar.gz
d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d  /home/probe/evidence/A-local-dispatch.patch
HASHES
mkdir -p "$task_build_root/A"
tar -xzf "$task_build_root/source.tar.gz" -C "$task_build_root/A" --strip-components=1
(
  cd "$task_build_root/A"
  git apply --check /home/probe/evidence/A-local-dispatch.patch
  git apply /home/probe/evidence/A-local-dispatch.patch
)
flatpak info org.freedesktop.Sdk//25.08
flatpak run --filesystem=/home/probe/evidence --command=sh org.freedesktop.Sdk//25.08 -c '
  set -eu
  cd /home/probe/evidence/atspi254/A
  pkg-config --modversion glib-2.0 gobject-2.0 dbus-1 gtk+-3.0
  meson setup build --buildtype=debugoptimized -Ddocs=false -Dintrospection=disabled -Dgtk2_atk_adaptor=false -Duse_systemd=false
  meson compile -C build
  meson install -C build --destdir /home/probe/evidence/atspi254/A-stage
  find /home/probe/evidence/atspi254/A-stage -name "libatk-bridge*.so*" -type f -exec sha256sum {} \;
  find /home/probe/evidence/atspi254/A-stage -name "libatk-bridge*.so*" -type f -exec readelf -d {} \;
  date -u +%FT%T.%N
'
touch "$task_build_root/A-ready"
date -u +%FT%T.%N
