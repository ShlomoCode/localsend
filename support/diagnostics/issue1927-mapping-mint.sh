#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
(cd evidence/packages && sha256sum -c SHA256SUMS)
mkdir -p evidence/cloud /home/runner/issue1927-mint /tmp/issue1927-mint/seed
QEMU_PID=
QEMU_TICKS=
process_ticks() {
  local stat_line
  stat_line=$(cat "/proc/$1/stat") || return 1
  stat_line=${stat_line##*) }
  set -- $stat_line
  printf '%s\n' "${20}"
}
owned_qemu() {
  [[ -n "$QEMU_PID" && -n "$QEMU_TICKS" && -r /proc/$QEMU_PID/stat ]] || return 1
  [[ $(process_ticks "$QEMU_PID") == "$QEMU_TICKS" ]] || return 1
  [[ $(cat "/proc/$QEMU_PID/comm") == qemu-system-x86* ]]
}
collect() {
  result=$?
  trap - EXIT TERM INT
  set +e
  guest_collect_exit=not_attempted
  if [ -f /tmp/issue1927-mint/id ]; then
    timeout --signal=TERM --kill-after=5s 55s scp -r -i /tmp/issue1927-mint/id -P 2277 -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest
    guest_collect_exit=$?
  fi
  printf 'harness_exit=%s\nguest_collect_exit=%s\n' "$result" "$guest_collect_exit" > evidence/cloud/result.txt
  if owned_qemu; then
    sudo kill -TERM "$QEMU_PID"
    for attempt in $(seq 1 5); do owned_qemu || break; sleep 1; done
    if owned_qemu; then sudo kill -KILL "$QEMU_PID"; fi
  fi
  exit "$result"
}
trap collect EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage socat imagemagick openssh-client tesseract-ocr
for mirror in https://mirror.csclub.uwaterloo.ca/linuxmint https://mirrors.edge.kernel.org/linuxmint; do
  if curl -fL --connect-timeout 20 --max-time 600 "$mirror/stable/22.2/linuxmint-22.2-cinnamon-64bit.iso" -o /home/runner/issue1927-mint/mint.iso; then break; fi
done
printf '759c9b5a2ad26eb9844b24f7da1696c705ff5fe07924a749f385f435176c2306  /home/runner/issue1927-mint/mint.iso\n' | sha256sum -c - | tee evidence/cloud/iso-hash.txt
ssh-keygen -q -t ed25519 -N '' -f /tmp/issue1927-mint/id
cp /tmp/issue1927-mint/id.pub /tmp/issue1927-mint/seed/id.pub
cp support/diagnostics/issue1927-mapping-probe.sh /tmp/issue1927-mint/seed/mapping-probe.sh
cp support/diagnostics/issue1927-mapping-predicate.sh /tmp/issue1927-mint/seed/mapping-predicate.sh
cp support/diagnostics/issue1927-mapping-mint.sh /tmp/issue1927-mint/seed/mapping-mint.sh
cp evidence/packages/{baseline,exposed}.flatpak evidence/packages/SHA256SUMS /tmp/issue1927-mint/seed/
cat > /tmp/issue1927-mint/seed/bootstrap.sh <<'BOOT'
#!/bin/bash
set -euxo pipefail
exec > >(tee /tmp/issue1927-bootstrap.log /dev/ttyS0) 2>&1
mkdir -p /home/mint/.ssh /home/mint/evidence
cp /mnt/id.pub /home/mint/.ssh/authorized_keys
cp /mnt/{mapping-probe.sh,mapping-predicate.sh,baseline.flatpak,exposed.flatpak,SHA256SUMS} /home/mint/
sha256sum /mnt/mapping-mint.sh /mnt/mapping-probe.sh /mnt/mapping-predicate.sh > /home/mint/evidence/mapping-source-SHA256SUMS
chown -R mint:mint /home/mint/.ssh /home/mint/evidence /home/mint/mapping-*.sh /home/mint/*.flatpak /home/mint/SHA256SUMS
chmod 700 /home/mint/.ssh
chmod 600 /home/mint/.ssh/authorized_keys
# Normal user installation on ext4; retain the Mint session and its normal HOME.
mkfs.ext4 -F -L FLATPAK /dev/vda
mkdir -p /home/mint/.local/share/flatpak
mount /dev/vda /home/mint/.local/share/flatpak
chown mint:mint /home/mint/.local/share/flatpak
mkdir -p /home/mint/.local/share/flatpak/db
chown mint:mint /home/mint/.local/share/flatpak/db
stat -Lc 'path=%n owner=%U mode=%a device=%d inode=%i' /home/mint/.local/share/flatpak/db > /home/mint/evidence/permission-storage-parent.txt
df -Th / /home/mint/.local/share/flatpak > /home/mint/evidence/installation-storage.txt
cp -a /etc/apt /home/mint/evidence/apt-before
for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  test -f "$source" || continue
  sed -i '/^[[:space:]]*deb.*cdrom:/s/^/# Live-media cdrom source disabled: /' "$source"
done
timeout --foreground 240 apt-get update
timeout --foreground 600 apt-get install -y openssh-server jq
systemctl start ssh
touch /home/mint/evidence/bootstrap-complete
BOOT
genisoimage -quiet -o /home/runner/issue1927-mint/probe.iso -V PROBE -r /tmp/issue1927-mint/seed
qemu-img create -f qcow2 /home/runner/issue1927-mint/flatpak.qcow2 12G
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -boot d -drive file=/home/runner/issue1927-mint/mint.iso,media=cdrom,readonly=on -drive file=/home/runner/issue1927-mint/probe.iso,media=cdrom,readonly=on -drive file=/home/runner/issue1927-mint/flatpak.qcow2,if=virtio,format=qcow2 -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2277-:22 -device virtio-net-pci,netdev=net0 -display none -monitor unix:/tmp/issue1927-mint/monitor,server,nowait -serial file:evidence/cloud/serial.log -pidfile /tmp/issue1927-mint/qemu.pid -daemonize
QEMU_PID=$(sudo cat /tmp/issue1927-mint/qemu.pid)
[[ "$QEMU_PID" =~ ^[0-9]+$ ]]
QEMU_TICKS=$(process_ticks "$QEMU_PID")
printf 'pid=%s start_ticks=%s\n' "$QEMU_PID" "$QEMU_TICKS" > evidence/cloud/qemu-owned-process.txt
ready=0
for n in $(seq 1 18); do
  sleep 15
  printf 'screendump %s/evidence/cloud/desktop.ppm\n' "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
  sudo chmod a+r evidence/cloud/desktop.ppm
  convert evidence/cloud/desktop.ppm evidence/cloud/desktop.png
  tesseract evidence/cloud/desktop.png stdout > evidence/cloud/desktop.txt 2>/dev/null
  if grep -Eq 'Computer|Home|Install.*Mint' evidence/cloud/desktop.txt; then ready=1; break; fi
done
test "$ready" = 1
printf 'sendkey ctrl-alt-t\n' | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
sleep 5
command='sudo mount /dev/sr1 /mnt; sudo bash /mnt/bootstrap.sh'
for ((index=0; index<${#command}; index++)); do
  key=${command:index:1}
  case "$key" in ' ') key=spc;; '/') key=slash;; ';') key=semicolon;; '.') key=dot;; '-') key=minus;; esac
  printf 'sendkey %s 40\n' "$key" | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor >/dev/null
  sleep .08
done
printf 'sendkey ret 80\n' | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
opts=(-i /tmp/issue1927-mint/id -p 2277 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known -o ConnectTimeout=5)
ready=0
for n in $(seq 1 60); do
  if timeout 10 ssh "${opts[@]}" mint@127.0.0.1 'test -f /home/mint/evidence/bootstrap-complete && pgrep -x cinnamon'; then ready=1; break; fi
  sleep 15
done
test "$ready" = 1
timeout --signal=TERM --kill-after=10s 1200s ssh "${opts[@]}" mint@127.0.0.1 'timeout --signal=TERM --kill-after=10s 1200s bash -s' > evidence/cloud/mapping.log 2>&1 <<'GUEST'
set -Eeuo pipefail
cd /home/mint
(cd /home/mint && sha256sum -c SHA256SUMS)
desktop_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
tr '\0' '\n' < "/proc/$desktop_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE)=' > evidence/session-environment.txt
while IFS= read -r assignment; do export "$assignment"; done < evidence/session-environment.txt
{ cat /etc/os-release; uname -a; cinnamon --version; flatpak --version; dpkg-query -W flatpak libflatpak0; printf 'HOME=%s\n' "$HOME"; } > evidence/host-identity.txt
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive -y flathub org.freedesktop.Platform/x86_64/26.08
flatpak install --user --noninteractive -y ./exposed.flatpak
EXPECTED_APP_COMMIT=$(flatpak info --user --show-commit org.localsend.localsend_app)
[[ "$EXPECTED_APP_COMMIT" =~ ^[0-9a-f]{64}$ ]]
printf '%s\n' "$EXPECTED_APP_COMMIT" > evidence/exposed-installed-app-commit.txt
flatpak info --user org.localsend.localsend_app > evidence/exposed-installed-app-info.txt
flatpak info --user org.freedesktop.Platform/x86_64/26.08 > evidence/runtime-info.txt
flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08 > evidence/runtime-commit.txt
flatpak list --user --runtime --columns=application,arch,branch,version,commit > evidence/installed-runtimes.txt
flatpak override --user --show org.localsend.localsend_app > evidence/exposed-overrides.txt
timeout --signal=TERM --kill-after=10s 300s bash /home/mint/mapping-probe.sh /home/mint/evidence/mapping /home/mint/mapping-predicate.sh "$EXPECTED_APP_COMMIT"
GUEST
