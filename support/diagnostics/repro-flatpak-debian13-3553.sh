#!/usr/bin/env bash
set -Eeuo pipefail

# Container setup only. The common experiment installs and runs the unmodified
# LocalSend release as an ordinary desktop user in a real Flatpak sandbox.
exec > >(tee /evidence/container-setup.log) 2>&1
cat /etc/os-release
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl sudo dbus dbus-user-session dbus-x11 flatpak \
  fontconfig xvfb openbox xdotool x11-utils imagemagick \
  iproute2 procps gdb strace file binutils libegl1 libgles2

# The official Brave Origin Nightly package depends on Brave's signed keyring.
# Use Brave's release repository only for that dependency; the browser binary
# itself remains the exact release asset downloaded by the common experiment.
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
  https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
  https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends brave-keyring

dbus-uuidgen --ensure=/etc/machine-id
mkdir -p /run/dbus
dbus-daemon --system --fork
dbus-send --system --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.ListNames > /evidence/system-bus.txt

useradd --create-home --shell /bin/bash probe
printf 'probe ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-probe
chmod 0440 /etc/sudoers.d/90-probe
mkdir -p /run/user/1000
chown probe:probe /run/user/1000
chmod 0700 /run/user/1000

# Test the namespace prerequisite before downloading the pinned artifacts.
# A failed probe is an infrastructure failure, not a LocalSend outcome.
if ! runuser -u probe -- unshare --user --map-root-user true; then
  echo 'Debian container cannot create the user namespace required by Flatpak.' | tee /evidence/infrastructure-failures.txt
  exit 20
fi

if [[ "${PROBE_ONLY:-0}" == 1 ]]; then
  test -s /evidence/cache-snapshots/brave-1.99.20.tar.gz
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fonts-katex
  dpkg-query -W -f='${Package} ${Version}\n' fonts-katex > /evidence/native-probe-fonts-katex-package.txt
  runuser -u probe -- env \
    HOME=/home/probe USER=probe LOGNAME=probe \
    XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=OPENBOX XDG_SESSION_TYPE=x11 \
    dbus-run-session -- bash -c '
      set -Eeuo pipefail
      flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      flatpak install --user --noninteractive -y flathub org.localsend.localsend_app
      flatpak update --user --noninteractive -y --commit=a7a6bc3f9debbbfd90c2e8874a83a5606db10b53dffc187449b0684991e7740c org.localsend.localsend_app
      flatpak update --user --noninteractive -y --commit=92659297ffdb4f9f14dd1562bd919b48160b0dc42c99653dcfc0688096af41df org.freedesktop.Platform/x86_64/26.08
      test "$(flatpak info --user --show-commit org.localsend.localsend_app)" = a7a6bc3f9debbbfd90c2e8874a83a5606db10b53dffc187449b0684991e7740c
      test "$(flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08)" = 92659297ffdb4f9f14dd1562bd919b48160b0dc42c99653dcfc0688096af41df
      bash /repo/support/diagnostics/repro-flatpak-debian13-fontconfig-probe.sh
    '
  exit 0
fi

runuser -u probe -- env \
  HOME=/home/probe USER=probe LOGNAME=probe \
  XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=OPENBOX XDG_SESSION_TYPE=x11 \
  GITHUB_WORKSPACE=/repo OUT=/evidence GUI_MODE=virtual \
  EXPECTED_APP_COMMIT=a7a6bc3f9debbbfd90c2e8874a83a5606db10b53dffc187449b0684991e7740c \
  EXPECTED_RUNTIME_COMMIT=92659297ffdb4f9f14dd1562bd919b48160b0dc42c99653dcfc0688096af41df \
  dbus-run-session -- bash /repo/support/diagnostics/repro-flatpak-3553.sh

# Preserve the exact runtime ELFs used by the captured main-thread PCs.
mkdir -p /evidence/native-symbols
for library in libfontconfig.so.1.17.0 libc.so.6; do
  source_file=$(find /home/probe/.local/share/flatpak/runtime/org.freedesktop.Platform \
    -type f -name "$library" -print -quit)
  test -n "$source_file"
  cp "$source_file" "/evidence/native-symbols/$library"
  readelf -n "$source_file" > "/evidence/native-symbols/$library.notes.txt"
  nm -D --numeric-sort "$source_file" > "/evidence/native-symbols/$library.dynamic-symbols.txt"
done
objdump -d -M intel --start-address=0x2d3d0 --stop-address=0x2d520 \
  /evidence/native-symbols/libfontconfig.so.1.17.0 > /evidence/native-symbols/fontconfig-caller-disassembly.txt
objdump -d -M intel --start-address=0x180d80 --stop-address=0x180f00 \
  /evidence/native-symbols/libc.so.6 > /evidence/native-symbols/libc-hot-disassembly.txt

runuser -u probe -- env \
  HOME=/home/probe USER=probe LOGNAME=probe XDG_RUNTIME_DIR=/run/user/1000 \
  dbus-run-session -- bash /repo/support/diagnostics/repro-flatpak-debian13-fontconfig-probe.sh
