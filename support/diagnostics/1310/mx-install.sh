#!/usr/bin/env bash
# Diagnostic only. Use the ISO's official Gazelle installer and its config API.
set -euo pipefail
cd "$HOME"
mkdir -p evidence/install
session=$(pgrep -u "$(id -u)" -x xfce4-session | head -1)
test -n "$session"
while IFS= read -r -d '' value; do
  case "$value" in DISPLAY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*|XAUTHORITY=*) export "$value";; esac
done < "/proc/$session/environ"
{ dpkg-query -W mx-installer gazelle-installer-data; sha256sum /usr/sbin/minstall; /usr/sbin/minstall --version; /usr/sbin/minstall --help; } > evidence/install/installer-identity.txt 2>&1
# Config compatibility is version-dependent; do not guess on another ISO build.
test "$(dpkg-query -W -f='${Version}' mx-installer)" = 24.01.01mx23
printf 'LANG=%s\n' "${LANG:-}" >> evidence/install/installer-identity.txt
case "${LANG:-}" in en*|C*) ;; *) exit 2;; esac
cat > evidence/install/minstall.conf <<'CONFIG'
[Storage]
Target=Drive
Drive=vda
DriveEncrypt=false
RootPortion=100
[Network]
ComputerName=mx1310
Domain=localdomain
Workgroup=WORKGROUP
[User]
Username=issue1310
UserPass=demo
Autologin=true
SaveDesktop=false
EnableRoot=true
RootPass=demo
OldHomeAction=Delete
CONFIG
{ date -u; cat /etc/os-release; lsblk -f; cat /proc/cmdline; } > evidence/install/before.txt
# The live demo account is reserved. The official installer creates issue1310.
# The virtual target is a newly-created, dedicated 24GB disk.
printf 'demo\n' | sudo -S env LANG="$LANG" DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" /usr/sbin/minstall --auto --poweroff "$HOME/evidence/install/minstall.conf" 2>&1 | tee evidence/install/installer-output.log
