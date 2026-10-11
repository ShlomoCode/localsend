#!/bin/bash
set -euo pipefail
# Observe the unmodified normal builder. Pausing only allows read-only phase snapshots.
# No generated files, binaries or builder source are modified by this observer.
cd /work
expected=$(cut -d' ' -f1 installed-client.sha256)
coproc PACKAGER { exec appimage-builder --recipe AppImageBuilder.yml --skip-test 2>&1; }
builder_pid=$PACKAGER_PID
exec {builder_fd}<&"${PACKAGER[0]}"
trap 'kill -CONT "$builder_pid" 2>/dev/null || true' EXIT
apt_seen=0
runtime_seen=0
while IFS= read -r line <&"$builder_fd"; do
  printf '%s\n' "$line"
  case "$line" in
    'INFO:main:Running file deploy')
      kill -STOP "$builder_pid" 2>/dev/null || true
      bash /diagnostic/inspect-client.sh AppDir "$expected" phase-after-apt.txt
      find /work /tmp /var/cache -type f -name '*.deb' -print0 | while IFS= read -r -d '' archive; do
        case "$(basename "$archive")" in
          libwayland*|libffi*)
            printf 'ARCHIVE %s\n' "$archive"
            dpkg-deb -f "$archive" Package Version
            dpkg-deb -c "$archive"
            ;;
        esac
      done > apt-wayland-ownership.txt
      grep -Fq 'Package: libwayland-cursor0' apt-wayland-ownership.txt
      grep -Fq 'Package: libwayland-egl1' apt-wayland-ownership.txt
      grep -Fq 'Package: libffi8' apt-wayland-ownership.txt
      apt_seen=1
      kill -CONT "$builder_pid" 2>/dev/null || true
      ;;
    'INFO:main:Running deploy record generation')
      kill -STOP "$builder_pid" 2>/dev/null || true
      bash /diagnostic/inspect-client.sh AppDir "$expected" phase-after-runtime.txt
      runtime_seen=1
      kill -CONT "$builder_pid" 2>/dev/null || true
      ;;
  esac
done
wait "$builder_pid"
test "$apt_seen" = 1
test "$runtime_seen" = 1
bash /diagnostic/inspect-client.sh AppDir "$expected" phase-after-packing.txt
cp AppDir/.bundle.yml source-first-bundle-record.txt
