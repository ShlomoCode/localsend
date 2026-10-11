#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y build-essential pkg-config libffi-dev libexpat1-dev libxml2-dev python3-pip ninja-build curl ca-certificates
pip3 install --no-cache-dir meson==1.6.1
cd /work
cat /etc/os-release > client-build-os.txt
dpkg-query -W libc6 libffi8 libffi-dev gcc python3-pip > client-build-packages.txt
meson --version > client-build-meson.txt
# Gentoo's mirror uses BLAKE2B(filename)'s first byte, documented in layout.conf.
# These source bytes also match the upstream release and Gentoo's SHA512 Manifest.
curl -fsSL --retry 3 --max-time 120 https://distfiles.gentoo.org/distfiles/8c/wayland-1.26.0.tar.xz -o wayland-1.26.0.tar.xz
echo '64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3  wayland-1.26.0.tar.xz' | sha256sum -c -
sha256sum wayland-1.26.0.tar.xz > client-source.sha256
tar -xf wayland-1.26.0.tar.xz
configure_args=(--buildtype=release -Dtests=false -Ddocumentation=false)
if [[ ${SOURCE_FIRST:-false} == true ]]; then
  configure_args+=(--prefix=/usr --libdir=lib/x86_64-linux-gnu)
fi
meson setup build wayland-1.26.0 "${configure_args[@]}"
ninja -C build
if [[ ${SOURCE_FIRST:-false} == true ]]; then
  # Normal full upstream installation; client selection occurs later during fresh assembly.
  DESTDIR=/work/upstream-install meson install -C build
  cp build/meson-logs/install-log.txt upstream-install-log.txt
  (cd upstream-install && find . -type f -print0 | sort -z | xargs -0 sha256sum) > upstream-install-files.txt
  (cd upstream-install && find . -type l -printf '%p -> %l\n' | sort) > upstream-install-links.txt
  cp upstream-install/usr/lib/x86_64-linux-gnu/libwayland-client.so.0.26.0 client-jammy.so
  cp wayland-1.26.0/COPYING client-COPYING.txt
else
  cp build/src/libwayland-client.so.0.26.0 client-jammy.so
fi
readelf -d client-jammy.so > client-jammy-dynamic.txt
grep -Fq 'Library soname: [libwayland-client.so.0]' client-jammy-dynamic.txt
readelf -Ws client-jammy.so > client-jammy-symbols.txt
readelf --version-info client-jammy.so > client-jammy-versions.txt
sha256sum client-jammy.so > client-jammy.sha256
for symbol in wl_fixes_interface wl_display_create_queue_with_name wl_display_dispatch_queue_timeout; do
  awk -v symbol="$symbol" '$5 == "GLOBAL" && $6 == "DEFAULT" && $7 != "UND" && $8 == symbol { found = 1 } END { exit !found }' client-jammy-symbols.txt
done
floor=$(grep -oE 'GLIBC_[0-9]+\.[0-9]+' client-jammy-versions.txt | sort -Vu | tail -1)
printf '%s\n' "$floor" > client-jammy-glibc-floor.txt
test "$(printf '%s\n' GLIBC_2.35 "$floor" | sort -V | tail -1)" = GLIBC_2.35
