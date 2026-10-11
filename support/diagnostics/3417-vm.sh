#!/bin/bash
# Cloud-only VM bootstrap. QEMU/QMP/VNC scaffold adapted from the issue 513
# diagnostics by ShlomoCode, commit faf78534eb0de3ab3399277cbdef7a97a60cf74e.
set -euo pipefail
vm=/home/runner/3417-vm
evidence="$PWD/evidence/vm"
image_base=https://cloud-images.ubuntu.com/releases/24.04/release-20260725
image_name=ubuntu-24.04-server-cloudimg-amd64.img
# Read from the official dated release metadata on 2026-10-12:
# https://cloud-images.ubuntu.com/releases/24.04/release-20260725/SHA256SUMS
# Its official manifest contains base-files 13ubuntu10.4 (Ubuntu 24.04.4)
# and the standard image kernel 6.8.0-136, unlike the reported 7.0.0-30.
image_sha256=d1940f7d69d343355e183dff1e08a59852d32e7309baa7a4bad8365b11b005ac

prepare() {
  mkdir -p "$vm" "$evidence"
  date -u > "$evidence/start-time.txt"
  git rev-parse HEAD > "$evidence/harness-commit.txt"
  printf 'IMAGE_BASE=%s\nIMAGE_NAME=%s\n' "$image_base" "$image_name" > "$evidence/image-source.txt"
  sudo apt-get update
  sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils socat imagemagick xvfb tigervnc-viewer ffmpeg x11-utils tesseract-ocr
  curl -fL --retry 3 "$image_base/SHA256SUMS" -o "$vm/SHA256SUMS"
  curl -fL --retry 3 "$image_base/$image_name" -o "$vm/$image_name"
  (cd "$vm"; awk -v name="$image_name" '$2 == name || $2 == "*" name {print}' SHA256SUMS > selected.sha256; test -s selected.sha256; sha256sum -c selected.sha256)
  (cd "$vm"; printf '%s  %s\n' "$image_sha256" "$image_name" | sha256sum -c -)
  cp "$vm/SHA256SUMS" "$vm/selected.sha256" "$evidence/"
  sha256sum "$vm/$image_name" > "$evidence/image-sha256.txt"
  qemu-img info "$vm/$image_name" > "$evidence/image-info.txt"
  qemu-img resize "$vm/$image_name" 35G
  ssh-keygen -q -t ed25519 -N '' -f "$vm/key"
  cat > "$vm/guest-bootstrap.sh" <<'GUEST'
#!/bin/bash
set -euo pipefail
trap 'touch /home/probe/3417-bootstrap-failed' ERR
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
app=org.localsend.localsend_app
out=/home/probe/3417-provenance
historical_commit=31f3f559da9fc85ec88a82923e3d7287a873240573cbb9d6bd54bf4a26ad1ccd
mkdir -p "$out"
test "$(id -u probe)" = 1000
cat /etc/os-release > "$out/os-release-before-install.txt"
uname -a > "$out/kernel-before-install.txt"
dpkg-query -W base-files > "$out/base-files-before-install.txt"
apt-mark showhold > "$out/package-holds.txt"
apt-config dump > "$out/apt-config.txt"
cat /etc/apt/sources.list.d/ubuntu.sources > "$out/apt-sources.txt"
test "$(grep -c '^Snapshot: 20260726T000000Z$' "$out/apt-sources.txt")" = 2
apt-cache policy base-files ubuntu-desktop-minimal gdm3 gnome-shell nautilus flatpak > "$out/apt-package-policy.txt"
cp /var/lib/apt/lists/*InRelease "$out/"
systemctl stop gdm3 || true
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# Capture official history before any artifact/runtime gate, including failures.
flatpak remote-info --log flathub "$app" > "$out/flathub-history.txt"
flatpak remote-info --commit="$historical_commit" flathub "$app" > "$out/historical-remote-info.txt"
flatpak remote-info --commit="$historical_commit" --show-metadata flathub "$app" > "$out/historical-remote-metadata.txt"
flatpak remote-info --commit="$historical_commit" --show-commit flathub "$app" > "$out/historical-remote-commit.txt"
test "$(cat "$out/historical-remote-commit.txt")" = "$historical_commit"
grep -Fx 'runtime=org.freedesktop.Platform/x86_64/25.08' "$out/historical-remote-metadata.txt"
grep -Eq '^ *Version: *1\.18\.2 *$' "$out/historical-remote-info.txt"
# Official manifest parent baaea3098bfef8324d41bbc98c80563d0f37c734 uses
# runtime 25.08 and release 1.18.2. The following package parent was recorded
# by Flatpak itself in scout 38181076198; admit its signed remote metadata
# above, then use Flatpak's supported historical-commit installation path.
flatpak install --noninteractive -y flathub "$app"
flatpak info "$app" > "$out/latest-app-info.txt"
flatpak info --show-metadata "$app" > "$out/latest-app-metadata.txt"
flatpak install --noninteractive -y flathub org.freedesktop.Platform/x86_64/25.08
flatpak update --noninteractive -y --commit="$historical_commit" "$app"
flatpak info "$app" > "$out/app-info.txt"
flatpak info --show-commit "$app" > "$out/app-commit.txt"
flatpak info --show-origin "$app" > "$out/app-origin.txt"
flatpak info --show-runtime "$app" > "$out/app-runtime.txt"
flatpak info --show-metadata "$app" > "$out/app-metadata.txt"
test "$(cat "$out/app-origin.txt")" = flathub
test "$(cat "$out/app-commit.txt")" = "$historical_commit"
grep -Eq '^ *Version: *1\.18\.2 *$' "$out/app-info.txt"
test "$(cat "$out/app-runtime.txt")" = org.freedesktop.Platform/x86_64/25.08
flatpak info org.freedesktop.Platform/x86_64/25.08 > "$out/runtime-info.txt"
flatpak info --show-commit org.freedesktop.Platform/x86_64/25.08 > "$out/runtime-commit.txt"
for scope in system user; do
  for target in global app; do
    args=()
    if [[ "$target" == app ]]; then args+=("$app"); fi
    if [[ "$scope" == system ]]; then
      flatpak override --system --show "${args[@]}" > "$out/override-$scope-$target.txt"
    else
      runuser -u probe -- flatpak override --user --show "${args[@]}" > "$out/override-$scope-$target.txt"
    fi
    test ! -s "$out/override-$scope-$target.txt"
  done
done
location=$(flatpak info --show-location "$app")
printf '%s\n' "$location" > "$out/app-location.txt"
cp "$location/export/share/applications/$app.desktop" "$out/exported-desktop-entry.txt"
sha256sum "$location/export/share/applications/$app.desktop" > "$out/exported-desktop-entry-sha256.txt"
find "$location/files" -maxdepth 4 -type f -name '*localsend*' -exec sha256sum {} \; > "$out/app-binary-sha256.txt"
cat /etc/os-release > "$out/os-release.txt"
grep -Fx 'VERSION="24.04.4 LTS (Noble Numbat)"' "$out/os-release.txt"
test "$(dpkg-query -W -f='${Version}' base-files)" = 13ubuntu10.4
uname -a > "$out/kernel.txt"
dpkg-query -W ubuntu-desktop-minimal ubuntu-session gdm3 gnome-shell nautilus flatpak xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk > "$out/desktop-packages.txt"
find /usr/share/wayland-sessions -maxdepth 1 -type f -exec sh -c 'echo "$1"; cat "$1"' sh {} \; > "$out/wayland-sessions.txt"
systemctl start auditd
auditctl -a always,exit -F arch=b64 -S execve,execveat -F uid=1000 -k localsend3417
auditctl -l > "$out/audit-rules.txt"
auditctl -s > "$out/audit-status-start.txt"
mkdir -p /home/probe/Downloads /home/probe/Documents
printf 'LocalSend issue 3417 real Open With control\n' > /home/probe/Documents/3417-control.txt
cp /home/probe/Documents/3417-control.txt /home/probe/Downloads/3417-control.txt
sha256sum /home/probe/{Documents,Downloads}/3417-control.txt > "$out/fixture-sha256.txt"
chown -R probe:probe "$out" /home/probe/Downloads /home/probe/Documents
# GDM's supported configuration; no app or exported desktop-entry rewrites.
cat > /etc/gdm3/custom.conf <<'GDM'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=probe
WaylandEnable=true
GDM
systemctl set-default graphical.target
systemctl enable gdm3
touch /home/probe/3417-bootstrap-pass
systemctl restart gdm3
GUEST
  {
    cat <<'CLOUD'
#cloud-config
users:
  - name: probe
    uid: 1000
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
CLOUD
    printf '      - %s\n' "$(cat "$vm/key.pub")"
    cat <<'CLOUD'
# Supported cloud-init sources_list input and Ubuntu APT Snapshot field.
# All guest package installation uses the dated official signed archive.
# https://snapshot.ubuntu.com/ documents this field for Ubuntu 24.04 onwards.
apt:
  preserve_sources_list: false
  sources_list: |
    Types: deb
    URIs: http://archive.ubuntu.com/ubuntu
    Suites: noble noble-updates
    Components: main restricted universe multiverse
    Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
    Snapshot: 20260726T000000Z

    Types: deb
    URIs: http://security.ubuntu.com/ubuntu
    Suites: noble-security
    Components: main restricted universe multiverse
    Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
    Snapshot: 20260726T000000Z
package_update: true
packages:
  - ubuntu-desktop-minimal
  - flatpak
  - xdg-desktop-portal-gnome
  - xdg-desktop-portal-gtk
  - dbus-user-session
  - openssh-server
  - acl
  - auditd
  - python3-pyatspi
write_files:
  - path: /root/3417-bootstrap.sh
    permissions: '0700'
    encoding: b64
CLOUD
    printf '    content: %s\n' "$(base64 -w 0 "$vm/guest-bootstrap.sh")"
    printf 'runcmd:\n  - [bash, /root/3417-bootstrap.sh]\n'
  } > "$vm/user-data"
  printf 'instance-id: localsend-3417\nlocal-hostname: localsend-3417\n' > "$vm/meta-data"
  cloud-localds "$vm/seed.iso" "$vm/user-data" "$vm/meta-data"
  # Select the CPU explicitly: host is valid for KVM, max for TCG fallback.
  accel=tcg
  cpu=max
  if [[ -e /dev/kvm ]] && sudo test -r /dev/kvm && sudo test -w /dev/kvm; then accel=kvm; cpu=host; fi
  printf 'ACCELERATOR=%s\nCPU=%s\n' "$accel" "$cpu" > "$evidence/qemu-platform.txt"
  sudo qemu-system-x86_64 -machine "accel=$accel" -cpu "$cpu" -smp 2 -m 6144 \
    -drive "file=$vm/$image_name,if=virtio,format=qcow2" \
    -drive "file=$vm/seed.iso,media=cdrom,readonly=on" \
    -device virtio-vga -display none -vnc 127.0.0.1:1 -usb -device usb-tablet \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
    -monitor "unix:$vm/monitor,server,nowait" -qmp "unix:$vm/qmp,server,nowait" \
    -serial "file:$evidence/serial.log" -pidfile "$vm/qemu.pid" -daemonize
  cat > "$vm/ssh" <<'SSH'
#!/bin/bash
exec timeout 120 ssh -i /home/runner/3417-vm/key -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/home/runner/3417-vm/known_hosts -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 probe@127.0.0.1 "$@"
SSH
  chmod +x "$vm/ssh"
  deadline=$((SECONDS + 1800))
  ready=0
  while (( SECONDS < deadline )); do
    if timeout 10 "$vm/ssh" 'test -e /home/probe/3417-bootstrap-failed'; then
      printf 'Guest bootstrap failed; inspect collected cloud-init and provenance logs.\n' >&2
      return 1
    fi
    if timeout 12 "$vm/ssh" 'test -e /var/lib/cloud/instance/boot-finished && test -e /home/probe/3417-bootstrap-pass && systemctl is-active --quiet gdm3 && test -S /run/user/1000/wayland-0 && test -S /run/user/1000/bus && loginctl list-sessions --no-legend | awk '\''$3 == "probe" {print $1}'\'' | xargs -r -I{} loginctl show-session {} -p Type -p State | grep -q "Type=wayland"'; then ready=1; break; fi
    sleep 10
  done
  test "$ready" = 1
  timeout 60 scp -i "$vm/key" -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$vm/known_hosts" -o ConnectTimeout=5 support/diagnostics/3417-accessibility.py probe@127.0.0.1:/home/probe/3417-accessibility.py
  timeout 60 "$vm/ssh" 'bash -s' > "$evidence/desktop-ready.txt" 2>&1 <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0
cloud-init status --long
loginctl list-sessions
for session in $(loginctl list-sessions --no-legend | awk '$3 == "probe" {print $1}'); do loginctl show-session "$session" -p Type -p Desktop -p State -p Name; done
systemctl --user show-environment
gdbus introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop
gdbus introspect --session --dest org.freedesktop.portal.Documents --object-path /org/freedesktop/portal/documents
pgrep -u 1000 -x gnome-shell
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.interface enable-animations false
nohup dbus-monitor --session "path='/org/freedesktop/portal/documents'" "sender='org.freedesktop.portal.Documents'" > /home/probe/3417-portal-calls.txt 2>&1 < /dev/null &
echo "$!" > /home/probe/3417-portal-monitor.pid
GUEST
}

collect() {
  mkdir -p "$evidence"
  if [[ -x "$vm/ssh" ]]; then
    timeout 60 "$vm/ssh" 'sudo bash -s' > "$evidence/guest-logs.txt" 2>&1 <<'GUEST' || true
date -u
cloud-init status --long
cat /var/log/cloud-init-output.log
systemctl status gdm3 --no-pager
loginctl list-sessions
journalctl -u gdm3 --no-pager -n 100
journalctl _UID=1000 --no-pager -n 400
cat /home/probe/3417*.log /home/probe/3417-portal-calls.txt 2>/dev/null
flatpak ps --columns=all
auditctl -s
auditctl -l
ausearch -k localsend3417 --raw
GUEST
    timeout 20 "$vm/ssh" 'env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus flatpak documents' > "$evidence/probe-flatpak-documents.txt" 2>&1 && documents_status=0 || documents_status=$?
    printf 'FLATPAK_DOCUMENTS_EXIT=%s\n' "$documents_status" > "$evidence/probe-flatpak-documents-status.txt"
    timeout 60 "$vm/ssh" 'sudo tar -C /home/probe -czf - 3417-provenance' > "$evidence/guest-provenance.tar.gz" 2> "$evidence/provenance-collection.log" || true
    timeout 60 "$vm/ssh" 'sudo find /home/probe -maxdepth 1 -type f -name "3417*" -print0 | sudo tar --null -T - -czf -' > "$evidence/guest-scenario-files.tar.gz" 2> "$evidence/scenario-collection.log" || true
    timeout 60 "$vm/ssh" 'sudo cat /var/log/audit/audit.log' > "$evidence/audit.log" 2> "$evidence/audit-collection.log" || true
    timeout 60 "$vm/ssh" 'sudo bash -s' > "$evidence/process-identities.txt" 2>&1 <<'GUEST' || true
for pid in $(pgrep -u 1000 -f 'localsend|nautilus|portal'); do
  test -e "/proc/$pid/cmdline" || continue
  printf '\nPID=%s\n' "$pid"
  cat "/proc/$pid/stat"
  readlink "/proc/$pid/exe"
  # Base64 preserves NUL boundaries; decode as bytes when reviewing argv.
  printf 'CMDLINE_BASE64='
  base64 -w 0 "/proc/$pid/cmdline"
  printf '\n'
  cat "/proc/$pid/status"
  cat "/proc/$pid/root/.flatpak-info" 2>/dev/null || true
done
GUEST
    if [[ -S "$vm/monitor" ]]; then
      printf 'screendump %s\n' "$evidence/final-desktop.ppm" | timeout 4 sudo socat - "UNIX-CONNECT:$vm/monitor" > "$evidence/final-capture.log" 2>&1 || true
      if [[ -f "$evidence/final-desktop.ppm" ]]; then sudo convert "$evidence/final-desktop.ppm" "$evidence/final-desktop.png" || true; fi
    fi
  fi
  sudo chown -R "$(id -u):$(id -g)" "$evidence"
}

cleanup() {
  # Kill only processes whose saved PID still identifies this diagnostic VM
  # or its own recording display. A PID file alone is not sufficient identity.
  for item in qemu xvfb viewer; do
    pidfile="$vm/$item.pid"
    test -f "$pidfile" || continue
    pid=$(cat "$pidfile")
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    test -e "/proc/$pid/cmdline" || continue
    cmdline=$(sudo tr '\0' ' ' < "/proc/$pid/cmdline")
    case "$item:$cmdline" in
      qemu:*qemu-system-x86_64*"$vm/$image_name"*|xvfb:*Xvfb*":99"*|viewer:*vncviewer*"127.0.0.1:5901"*)
        sudo kill -TERM "$pid" || true
        ;;
      *) printf 'Refusing cleanup of changed process identity PID=%s\n' "$pid" >&2; continue ;;
    esac
    for attempt in $(seq 1 10); do test ! -e "/proc/$pid" && break; sleep 1; done
    if test -e "/proc/$pid/cmdline"; then
      remaining=$(sudo tr '\0' ' ' < "/proc/$pid/cmdline")
      if [[ "$remaining" == "$cmdline" ]]; then sudo kill -KILL "$pid" || true; fi
    fi
  done
}

case "${1:-}" in
  prepare) prepare ;;
  collect) collect ;;
  cleanup) cleanup ;;
  *) printf 'Usage: %s prepare|collect|cleanup\n' "$0" >&2; exit 2 ;;
esac
