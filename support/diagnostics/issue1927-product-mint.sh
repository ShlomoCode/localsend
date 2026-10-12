#!/usr/bin/env bash
# One normal Mint VM, one shared wall deadline, five product conditions.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
START=$(date +%s)
WALL=${ISSUE1927_WALL_DEADLINE:-$((START+1200))}
[[ $WALL =~ ^[0-9]+$ ]]
(( WALL <= START+1200 )) || WALL=$((START+1200))
SETUP=$((START+420)); (( SETUP <= WALL )) || SETUP=$WALL
run() {
  local left=$((SETUP-$(date +%s)))
  ((left>0)) || return 124
  timeout --foreground --signal=TERM --kill-after=5 "$left" "$@"
}
(cd evidence/packages && sha256sum -c SHA256SUMS)
mkdir -p evidence/cloud /home/runner/issue1927-mint /tmp/issue1927-mint/seed
QEMU_PID= QEMU_TICKS=
process_ticks() { local s; s=$(cat "/proc/$1/stat") || return; s=${s##*) }; set -- $s; printf '%s\n' "${20}"; }
owned_qemu() {
  [[ -n $QEMU_PID && -n $QEMU_TICKS && -r /proc/$QEMU_PID/stat ]] || return 1
  [[ $(process_ticks "$QEMU_PID") == "$QEMU_TICKS" && $(cat "/proc/$QEMU_PID/comm") == qemu-system-x86* ]]
}
collect() {
  local result=$? collected=not_attempted
  trap - EXIT; trap '' TERM INT
  set +e
  if [[ -f /tmp/issue1927-mint/id ]]; then
    timeout --signal=TERM --kill-after=5 55 scp -r -i /tmp/issue1927-mint/id -P 2277 -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest
    collected=$?
  fi
  printf 'harness_exit=%s\nguest_collect_exit=%s\n' "$result" "$collected" > evidence/cloud/result.txt
  if owned_qemu; then
    sudo kill -TERM "$QEMU_PID"
    for attempt in 1 2 3 4 5; do owned_qemu || break; sleep 1; done
    if owned_qemu; then sudo kill -KILL "$QEMU_PID"; fi
  fi
  exit "$result"
}
trap collect EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
run sudo apt-get update
run sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage socat imagemagick openssh-client tesseract-ocr
for mirror in https://mirror.csclub.uwaterloo.ca/linuxmint https://mirrors.edge.kernel.org/linuxmint; do
  if run curl -fL --connect-timeout 15 "$mirror/stable/22.2/linuxmint-22.2-cinnamon-64bit.iso" -o /home/runner/issue1927-mint/mint.iso; then break; fi
done
printf '759c9b5a2ad26eb9844b24f7da1696c705ff5fe07924a749f385f435176c2306  /home/runner/issue1927-mint/mint.iso\n' | sha256sum -c - | tee evidence/cloud/iso-hash.txt
run ssh-keygen -q -t ed25519 -N '' -f /tmp/issue1927-mint/id
cp /tmp/issue1927-mint/id.pub /tmp/issue1927-mint/seed/id.pub
cp support/diagnostics/issue1927-product-{mint,ui}.sh support/diagnostics/issue1927-ui.sh support/diagnostics/issue1927-xres-owner.c /tmp/issue1927-mint/seed/
cp evidence/packages/{baseline,candidate}.flatpak evidence/packages/SHA256SUMS /tmp/issue1927-mint/seed/
cp evidence/packages/provenance/runtime-commit.txt /tmp/issue1927-mint/seed/expected-runtime-commit.txt
printf '%s\n' "$SETUP" > /tmp/issue1927-mint/seed/setup-deadline.txt
sha256sum support/diagnostics/issue1927-product-{mint,ui}.sh support/diagnostics/issue1927-ui.sh support/diagnostics/issue1927-xres-owner.c > evidence/cloud/product-source-SHA256SUMS
cat > /tmp/issue1927-mint/seed/bootstrap.sh <<'BOOT'
#!/bin/bash
set -Eeuo pipefail
exec > >(tee /tmp/issue1927-bootstrap.log /dev/ttyS0) 2>&1
SETUP=$(cat /mnt/setup-deadline.txt)
run() { local left=$((SETUP-$(date +%s))); ((left>0)) || return 124; timeout --foreground --signal=TERM --kill-after=5 "$left" "$@"; }
mkdir -p /home/mint/.ssh /home/mint/evidence
cp /mnt/id.pub /home/mint/.ssh/authorized_keys
cp /mnt/issue1927-*.sh /mnt/issue1927-xres-owner.c /mnt/{baseline,candidate}.flatpak /mnt/SHA256SUMS /mnt/expected-runtime-commit.txt /home/mint/
sha256sum /mnt/issue1927-*.sh /mnt/issue1927-xres-owner.c > /home/mint/evidence/product-seed-SHA256SUMS
chown -R mint:mint /home/mint/.ssh /home/mint/evidence /home/mint/issue1927-* /home/mint/*.flatpak /home/mint/SHA256SUMS /home/mint/expected-runtime-commit.txt
chmod 700 /home/mint/.ssh; chmod 600 /home/mint/.ssh/authorized_keys
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
run apt-get update
run apt-get install -y openssh-server xdotool imagemagick tesseract-ocr ffmpeg gcc pkg-config libx11-dev libxres-dev
run gcc -std=c11 -Wall -Wextra -Werror /home/mint/issue1927-xres-owner.c -o /home/mint/xres-owner $(pkg-config --cflags --libs x11 xres)
{ pkg-config --modversion x11 xres; dpkg-query -W libxres1 libxres-dev libx11-6; sha256sum /home/mint/issue1927-xres-owner.c /home/mint/xres-owner; } > /home/mint/evidence/xres-build-provenance.txt
systemctl start ssh
touch /home/mint/evidence/bootstrap-complete
BOOT
run genisoimage -quiet -o /home/runner/issue1927-mint/probe.iso -V PROBE -r /tmp/issue1927-mint/seed
run qemu-img create -f qcow2 /home/runner/issue1927-mint/flatpak.qcow2 12G
run sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -boot d -drive file=/home/runner/issue1927-mint/mint.iso,media=cdrom,readonly=on -drive file=/home/runner/issue1927-mint/probe.iso,media=cdrom,readonly=on -drive file=/home/runner/issue1927-mint/flatpak.qcow2,if=virtio,format=qcow2 -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2277-:22 -device virtio-net-pci,netdev=net0 -display none -monitor unix:/tmp/issue1927-mint/monitor,server,nowait -serial file:evidence/cloud/serial.log -pidfile /tmp/issue1927-mint/qemu.pid -daemonize
QEMU_PID=$(sudo cat /tmp/issue1927-mint/qemu.pid)
[[ $QEMU_PID =~ ^[0-9]+$ ]]; QEMU_TICKS=$(process_ticks "$QEMU_PID")
printf 'pid=%s start_ticks=%s\n' "$QEMU_PID" "$QEMU_TICKS" > evidence/cloud/qemu-owned-process.txt
while (( $(date +%s) < SETUP )); do
  run sleep 3
  printf 'screendump %s/evidence/cloud/desktop.ppm\n' "$GITHUB_WORKSPACE" | run sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
  run sudo chmod a+r evidence/cloud/desktop.ppm
  run convert evidence/cloud/desktop.ppm evidence/cloud/desktop.png
  run tesseract evidence/cloud/desktop.png stdout > evidence/cloud/desktop.txt 2>/dev/null
  if grep -Eq 'Computer|Home|Install.*Mint' evidence/cloud/desktop.txt; then break; fi
done
run grep -Eq 'Computer|Home|Install.*Mint' evidence/cloud/desktop.txt
printf 'sendkey ctrl-alt-t\n' | run sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
run sleep 2
command='sudo mount /dev/sr1 /mnt; sudo bash /mnt/bootstrap.sh'
for ((index=0; index<${#command}; index++)); do
  key=${command:index:1}
  case "$key" in ' ') key=spc;; '/') key=slash;; ';') key=semicolon;; '.') key=dot;; '-') key=minus;; esac
  printf 'sendkey %s 40\n' "$key" | run sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor >/dev/null
  run sleep .06
done
printf 'sendkey ret 80\n' | run sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
opts=(-i /tmp/issue1927-mint/id -p 2277 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known -o ConnectTimeout=5)
while ! run ssh "${opts[@]}" mint@127.0.0.1 'test -f /home/mint/evidence/bootstrap-complete && pgrep -x cinnamon'; do run sleep 2; done
# Installation is setup, not a fresh 420-second budget.
run ssh "${opts[@]}" mint@127.0.0.1 "SETUP=$SETUP bash -s" > evidence/cloud/install.log 2>&1 <<'INSTALL'
set -Eeuo pipefail
run() { local left=$((SETUP-$(date +%s))); ((left>0)) || return 124; timeout --foreground --signal=TERM --kill-after=5 "$left" "$@"; }
cd /home/mint
sha256sum -c SHA256SUMS
{ cat /etc/os-release; uname -a; cinnamon --version; flatpak --version; dpkg-query -W flatpak libflatpak0; printf 'HOME=%s\n' "$HOME"; } > evidence/host-identity.txt
run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
EXPECTED_RUNTIME=$(cat expected-runtime-commit.txt)
[[ $EXPECTED_RUNTIME =~ ^[0-9a-f]{64}$ ]]
run flatpak install --user --noninteractive -y flathub org.freedesktop.Platform/x86_64/26.08
run flatpak update --user --noninteractive -y --commit="$EXPECTED_RUNTIME" org.freedesktop.Platform/x86_64/26.08
[[ $(run flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08) == "$EXPECTED_RUNTIME" ]]
run flatpak info --user org.freedesktop.Platform/x86_64/26.08 > evidence/runtime-info.txt
run flatpak install --user --noninteractive -y ./baseline.flatpak
INSTALL
NOW=$(date +%s); CONDITIONS=$((NOW+780)); ((CONDITIONS<=WALL)) || CONDITIONS=$WALL
LEFT=$((CONDITIONS-NOW)); ((LEFT>0))
printf 'started=%s setup_deadline=%s conditions_deadline=%s wall_deadline=%s\n' "$START" "$SETUP" "$CONDITIONS" "$WALL" > evidence/cloud/deadlines.txt
# Guest derives its SECONDS deadline once from this absolute wall deadline.
timeout --signal=TERM --kill-after=5 "$LEFT" ssh "${opts[@]}" mint@127.0.0.1 "ISSUE1927_CONDITIONS_DEADLINE=$CONDITIONS bash /home/mint/issue1927-product-ui.sh" > evidence/cloud/product.log 2>&1
