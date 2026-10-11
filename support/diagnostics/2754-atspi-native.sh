#!/usr/bin/env bash
# Cloud-only native source gate. This script does not execute LocalSend or a VM.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'This native build/test gate is restricted to GitHub Actions.' >&2
  exit 2
fi
NATIVE_OUTPUT=${1:?Usage: 2754-atspi-native.sh OUTPUT_DIR}
mkdir -p "$NATIVE_OUTPUT"
NATIVE_OUTPUT=$(realpath "$NATIVE_OUTPUT")
NATIVE_ASSETS=$(cd "$(dirname "${BASH_SOURCE[0]}")/2754-atspi-native" && pwd)
NATIVE_WORK=$(mktemp -d /tmp/issue2754-atspi-native.XXXXXX)
exec > >(tee "$NATIVE_OUTPUT/native-A.log") 2>&1
trap 'NATIVE_EXIT=$?; printf "exit_status=%s\n" "$NATIVE_EXIT" > "$NATIVE_OUTPUT/result.txt"; if [[ -f "$NATIVE_WORK/build-A/meson-logs/testlog.txt" ]]; then cp "$NATIVE_WORK/build-A/meson-logs/testlog.txt" "$NATIVE_OUTPUT/testlog-A.txt"; fi' EXIT

uname -a > "$NATIVE_OUTPUT/uname.txt"
cp /etc/os-release "$NATIVE_OUTPUT/os-release.txt"
dpkg-query -W > "$NATIVE_OUTPUT/packages.tsv"
git rev-parse HEAD > "$NATIVE_OUTPUT/diagnostic-head.txt"
cp "$NATIVE_ASSETS/A-local-dispatch.patch" "$NATIVE_OUTPUT/"
sha256sum "$NATIVE_ASSETS/A-local-dispatch.patch" "$NATIVE_ASSETS/stock-self-query.c" > "$NATIVE_OUTPUT/diagnostic-assets.sha256"
printf '%s  %s\n' e09038c6105700a89f14facbb423ae77a26c226111def4934f338cad2334df07 "$NATIVE_ASSETS/A-local-dispatch.patch" | sha256sum -c -
for NATIVE_PACKAGE in libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64; do
  test "$(dpkg-query -W -f='${Version}' "$NATIVE_PACKAGE")" = 2.52.0-1build1
done
pkg-config --modversion gtk+-3.0 atk glib-2.0 dbus-1 > "$NATIVE_OUTPUT/pkg-config-versions.txt"

NATIVE_ARCHIVE_BASE=https://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core
for NATIVE_ARCHIVE in at-spi2-core_2.52.0.orig.tar.xz at-spi2-core_2.52.0-1build1.debian.tar.xz at-spi2-core_2.52.0-1build1.dsc; do
  curl --fail --location --retry 3 "$NATIVE_ARCHIVE_BASE/$NATIVE_ARCHIVE" -o "$NATIVE_OUTPUT/$NATIVE_ARCHIVE"
done
(
  cd "$NATIVE_OUTPUT"
  printf '%s\n' \
    '0ac3fc8320c8d01fa147c272ba7fa03806389c6b03d3c406d0823e30e35ff5ab  at-spi2-core_2.52.0.orig.tar.xz' \
    '20bda0a6815fb1e7c6ca286a02b4b70aaa706f304664aad30bd88a4ee163b91c  at-spi2-core_2.52.0-1build1.debian.tar.xz' | tee source.sha256 | sha256sum -c -
)
tar -xf "$NATIVE_OUTPUT/at-spi2-core_2.52.0.orig.tar.xz" -C "$NATIVE_WORK"
NATIVE_STOCK="$NATIVE_WORK/at-spi2-core-2.52.0"
tar -xf "$NATIVE_OUTPUT/at-spi2-core_2.52.0-1build1.debian.tar.xz" -C "$NATIVE_STOCK"
cp "$NATIVE_STOCK/debian/patches/series" "$NATIVE_OUTPUT/downstream-series.txt"
(
  cd "$NATIVE_STOCK"
  while IFS= read -r NATIVE_DOWNSTREAM; do
    [[ -z "$NATIVE_DOWNSTREAM" || "$NATIVE_DOWNSTREAM" == \#* ]] && continue
    patch -p1 < "debian/patches/$NATIVE_DOWNSTREAM"
  done < debian/patches/series
)
NATIVE_CANDIDATE="$NATIVE_WORK/at-spi2-core-candidate"
cp -a "$NATIVE_STOCK" "$NATIVE_CANDIDATE"
git -C "$NATIVE_CANDIDATE" apply --check "$NATIVE_ASSETS/A-local-dispatch.patch"
git -C "$NATIVE_CANDIDATE" apply "$NATIVE_ASSETS/A-local-dispatch.patch"
sha256sum "$NATIVE_STOCK/atk-adaptor/adaptors/socket-adaptor.c" \
  "$NATIVE_CANDIDATE/atk-adaptor/adaptors/socket-adaptor.c" \
  "$NATIVE_CANDIDATE/tests/at-spi2-atk/socket-local-experiment.c" > "$NATIVE_OUTPUT/tested-source.sha256"

meson setup "$NATIVE_WORK/build-stock" "$NATIVE_STOCK" -Ddocs=false -Dintrospection=disabled 2>&1 | tee "$NATIVE_OUTPUT/configure-stock.log"
meson compile -C "$NATIVE_WORK/build-stock" atk-bridge-2.0 2>&1 | tee "$NATIVE_OUTPUT/build-stock.log"
meson setup "$NATIVE_WORK/build-A" "$NATIVE_CANDIDATE" -Ddocs=false -Dintrospection=disabled 2>&1 | tee "$NATIVE_OUTPUT/configure-A.log"
meson compile -C "$NATIVE_WORK/build-A" socket-local-experiment 2>&1 | tee "$NATIVE_OUTPUT/build-A.log"

NATIVE_STOCK_BUILD="$NATIVE_WORK/build-stock"
test -f "$NATIVE_STOCK_BUILD/xml/introspection.h"
sha256sum "$NATIVE_STOCK_BUILD/xml/introspection.h" > "$NATIVE_OUTPUT/stock-introspection-header.sha256"
cc -std=c99 -I"$NATIVE_STOCK" -I"$NATIVE_STOCK_BUILD" -I"$NATIVE_STOCK_BUILD/xml" -I"$NATIVE_STOCK/atk-adaptor" -I"$NATIVE_STOCK/droute" \
  "$NATIVE_ASSETS/stock-self-query.c" \
  -L"$NATIVE_STOCK_BUILD/atk-adaptor" -L"$NATIVE_STOCK_BUILD/atspi" -L"$NATIVE_STOCK_BUILD/atk" \
  -Wl,-rpath,"$NATIVE_STOCK_BUILD/atk-adaptor" -Wl,-rpath,"$NATIVE_STOCK_BUILD/atspi" -Wl,-rpath,"$NATIVE_STOCK_BUILD/atk" \
  "$NATIVE_STOCK_BUILD/droute/libdroute.a" -latk-bridge-2.0 -latspi -latk-1.0 \
  $(pkg-config --cflags --libs glib-2.0 gobject-2.0 gmodule-2.0 dbus-1) \
  -o "$NATIVE_OUTPUT/stock-self-query" 2>&1 | tee "$NATIVE_OUTPUT/build-stock-probe.log"
ldd "$NATIVE_OUTPUT/stock-self-query" > "$NATIVE_OUTPUT/loader-stock.txt"
readelf -d "$NATIVE_OUTPUT/stock-self-query" > "$NATIVE_OUTPUT/elf-stock.txt"
NATIVE_TEST="$NATIVE_WORK/build-A/tests/at-spi2-atk/socket-local-experiment"
ldd "$NATIVE_TEST" > "$NATIVE_OUTPUT/loader-A.txt"
readelf -d "$NATIVE_TEST" > "$NATIVE_OUTPUT/elf-A.txt"
grep -F "$NATIVE_WORK/build-A/atk-adaptor/" "$NATIVE_OUTPUT/loader-A.txt"
grep -F "$NATIVE_WORK/build-stock/atk-adaptor/" "$NATIVE_OUTPUT/loader-stock.txt"
cp "$NATIVE_TEST" "$NATIVE_OUTPUT/socket-local-experiment"
for NATIVE_VARIANT in stock A; do
  NATIVE_LIBRARY="$NATIVE_WORK/build-$NATIVE_VARIANT/atk-adaptor/libatk-bridge-2.0.so.0"
  readelf -n "$NATIVE_LIBRARY" > "$NATIVE_OUTPUT/bridge-build-id-$NATIVE_VARIANT.txt"
  sha256sum "$NATIVE_LIBRARY" > "$NATIVE_OUTPUT/bridge-$NATIVE_VARIANT.sha256"
  cp -L "$NATIVE_LIBRARY" "$NATIVE_OUTPUT/libatk-bridge-$NATIVE_VARIANT.so.0"
done
set +e
dbus-run-session -- strace -f -tt -T -s 4096 -e trace=poll,ppoll,sendmsg,recvmsg,write,writev,read,readv,sendto,recvfrom \
  -o "$NATIVE_OUTPUT/stock-self-query.strace" \
  timeout --signal=TERM --kill-after=2s 3s "$NATIVE_OUTPUT/stock-self-query" \
  > "$NATIVE_OUTPUT/stock-self-query.log" 2>&1
NATIVE_STOCK_STATUS=$?
set -e
printf 'stock_probe_exit_status=%s\n' "$NATIVE_STOCK_STATUS" > "$NATIVE_OUTPUT/stock-control.txt"
test "$NATIVE_STOCK_STATUS" = 124
grep -q 'stock_same_process_query' "$NATIVE_OUTPUT/stock-self-query.log"
grep -q 'GetExtents' "$NATIVE_OUTPUT/stock-self-query.strace"
grep -Eq 'poll\(.*2[45][0-9]{3}' "$NATIVE_OUTPUT/stock-self-query.strace"
! grep -q 'unexpected_stock_return' "$NATIVE_OUTPUT/stock-self-query.log"

G_MESSAGES_DEBUG=all meson test -C "$NATIVE_WORK/build-A" --suite socket-local-experiment --print-errorlogs \
  2>&1 | tee "$NATIVE_OUTPUT/test-A.log"
cp "$NATIVE_WORK/build-A/meson-logs/testlog.txt" "$NATIVE_OUTPUT/testlog-A.txt"
printf 'stock_self_wait_detected=true\ncandidate_native_suite_passed=true\n' > "$NATIVE_OUTPUT/gates.txt"
