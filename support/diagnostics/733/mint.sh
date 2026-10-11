#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
(cd evidence/package && sha256sum -c bundle.sha256)
mkdir -p evidence/cloud /home/runner/issue733-mint /tmp/issue733-mint/seed
collect() {
  result=$?
  set +e
  if [ -f /tmp/issue733-mint/id ]; then
    timeout 60 scp -r -i /tmp/issue733-mint/id -P 2277 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue733-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest
  fi
  sudo chown -R "$(id -u):$(id -g)" evidence
  printf 'harness_exit=%s\n' "$result" > evidence/cloud/result.txt
}
trap collect EXIT
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage socat imagemagick openssh-client tesseract-ocr
for mirror in https://mirror.csclub.uwaterloo.ca/linuxmint https://mirrors.edge.kernel.org/linuxmint; do
  if curl -fL --connect-timeout 20 --max-time 600 "$mirror/stable/21.2/linuxmint-21.2-cinnamon-64bit.iso" -o /home/runner/issue733-mint/mint.iso; then break; fi
done
printf '116578dda0e03f1421c214acdd66043b586e7afc7474e0796c150ac164a90a2a  /home/runner/issue733-mint/mint.iso\n' | sha256sum -c - | tee evidence/cloud/iso-hash.txt
ssh-keygen -q -t ed25519 -N '' -f /tmp/issue733-mint/id
cp /tmp/issue733-mint/id.pub /tmp/issue733-mint/seed/id.pub
cp support/diagnostics/733/scenario.sh /tmp/issue733-mint/seed/scenario.sh
cp support/diagnostics/733/transfer.sh /tmp/issue733-mint/seed/transfer.sh
cp evidence/package/historical.flatpak /tmp/issue733-mint/seed/
cat > /tmp/issue733-mint/seed/bootstrap.sh <<'BOOT'
#!/bin/bash
set -euxo pipefail
exec > >(tee /tmp/issue733-bootstrap.log /dev/ttyS0) 2>&1
mkdir -p /home/mint/.ssh /home/mint/evidence
cp /mnt/id.pub /home/mint/.ssh/authorized_keys
cp /mnt/scenario.sh /home/mint/scenario.sh
cp /mnt/transfer.sh /home/mint/transfer.sh
cp /mnt/historical.flatpak /home/mint/
chown -R mint:mint /home/mint/.ssh /home/mint/evidence /home/mint/scenario.sh
chmod 700 /home/mint/.ssh
chmod 600 /home/mint/.ssh/authorized_keys
# Give the normal user Flatpak installation real ext4 storage instead of the
# live ISO's small RAM overlay. App code, permissions, HOME and session stay stock.
mkfs.ext4 -F -L FLATPAK /dev/vda
mkdir -p /home/mint/.local/share/flatpak
mount /dev/vda /home/mint/.local/share/flatpak
chown mint:mint /home/mint/.local/share/flatpak
df -Th / /home/mint/.local/share/flatpak > /home/mint/evidence/installation-storage.txt
cp -a /etc/apt /home/mint/evidence/apt-before
for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  test -f "$source" || continue
  sed -i '/^[[:space:]]*deb.*cdrom:/s/^/# Live-media cdrom source disabled: /' "$source"
done
timeout --foreground 240 apt-get update
timeout --foreground 600 apt-get install -y openssh-server xdotool imagemagick tesseract-ocr ffmpeg
systemctl start ssh
touch /home/mint/evidence/bootstrap-complete
BOOT
genisoimage -quiet -o /home/runner/issue733-mint/probe.iso -V PROBE -r /tmp/issue733-mint/seed
qemu-img create -f qcow2 /home/runner/issue733-mint/flatpak.qcow2 12G
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -boot d -drive file=/home/runner/issue733-mint/mint.iso,media=cdrom,readonly=on -drive file=/home/runner/issue733-mint/probe.iso,media=cdrom,readonly=on -drive file=/home/runner/issue733-mint/flatpak.qcow2,if=virtio,format=qcow2 -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2277-:22 -device virtio-net-pci,netdev=net0 -display none -monitor unix:/tmp/issue733-mint/monitor,server,nowait -serial file:evidence/cloud/serial.log -daemonize
sleep 10
printf 'screendump %s/evidence/cloud/boot-menu.ppm\n' "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue733-mint/monitor >/dev/null
sudo chmod a+r evidence/cloud/boot-menu.ppm
convert evidence/cloud/boot-menu.ppm evidence/cloud/boot-menu.png
tesseract evidence/cloud/boot-menu.png stdout > evidence/cloud/boot-menu.txt 2>/dev/null
if grep -q 'Start Linux Mint' evidence/cloud/boot-menu.txt; then
  printf 'sendkey ret 80\n' | sudo socat - UNIX-CONNECT:/tmp/issue733-mint/monitor >/dev/null
  date -u --iso-8601=ns > evidence/cloud/boot-selection.txt
fi
ready=0
for n in $(seq 1 18); do
  sleep 15
  printf 'screendump %s/evidence/cloud/desktop.ppm\n' "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue733-mint/monitor
  sudo chmod a+r evidence/cloud/desktop.ppm
  convert evidence/cloud/desktop.ppm evidence/cloud/desktop.png
  tesseract evidence/cloud/desktop.png stdout > evidence/cloud/desktop.txt 2>/dev/null
  if grep -Eq 'Computer|Home|Install.*Mint' evidence/cloud/desktop.txt; then ready=1; break; fi
done
test "$ready" = 1
printf 'sendkey ctrl-alt-t\n' | sudo socat - UNIX-CONNECT:/tmp/issue733-mint/monitor
sleep 5
command='sudo mount /dev/sr1 /mnt; sudo bash /mnt/bootstrap.sh'
for ((index=0; index<${#command}; index++)); do
  key=${command:index:1}
  case "$key" in ' ') key=spc;; '/') key=slash;; ';') key=semicolon;; '.') key=dot;; '-') key=minus;; esac
  printf 'sendkey %s 40\n' "$key" | sudo socat - UNIX-CONNECT:/tmp/issue733-mint/monitor >/dev/null
  sleep .08
done
printf 'sendkey ret 80\n' | sudo socat - UNIX-CONNECT:/tmp/issue733-mint/monitor
opts=(-i /tmp/issue733-mint/id -p 2277 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue733-mint/known -o ConnectTimeout=5)
ready=0
for n in $(seq 1 60); do
  if timeout 10 ssh "${opts[@]}" mint@127.0.0.1 'test -f /home/mint/evidence/bootstrap-complete && pgrep -x cinnamon'; then ready=1; break; fi
  sleep 15
done
test "$ready" = 1
timeout 1500 ssh "${opts[@]}" mint@127.0.0.1 'bash /home/mint/scenario.sh' > evidence/cloud/scenario.log 2>&1
