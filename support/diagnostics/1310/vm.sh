#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence/vm /home/runner/issue1310-vm
root=/home/runner/issue1310-vm
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client
curl -fL --retry 3 -o "$root/ubuntu.img" https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img
sha256sum "$root/ubuntu.img" > evidence/vm/image-sha256.txt
qemu-img resize "$root/ubuntu.img" 25G
ssh-keygen -q -t ed25519 -N '' -f "$root/id"
key=$(cat "$root/id.pub")
cat > "$root/user-data" <<CONFIG
#cloud-config
users:
  - default
  - name: probe
    groups: [adm, sudo, audio, video, render]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $key
package_update: true
packages: [xubuntu-desktop, xvfb, xdotool, scrot, tesseract-ocr, ffmpeg, openssh-server, libayatana-appindicator3-1, libsecret-1-0]
CONFIG
printf 'instance-id: issue1310-xfce\nlocal-hostname: issue1310-xfce\n' > "$root/meta-data"
cloud-localds "$root/seed.iso" "$root/user-data" "$root/meta-data"
opts=(-i "$root/id" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$root/known" -o ConnectTimeout=5)
copy=(-i "$root/id" -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$root/known" -o ConnectTimeout=5)
cleanup() {
  result=$?
  printf '%s\n' "$result" > evidence/vm/host-exit-code.txt
  timeout 120 scp -r "${copy[@]}" probe@127.0.0.1:/home/probe/evidence evidence/vm/guest || true
  sudo chown -R "$(id -u):$(id -g)" evidence
  if test -f "$root/qemu.pid"; then sudo kill "$(sudo cat "$root/qemu.pid")" || true; fi
}
trap cleanup EXIT
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -drive file="$root/ubuntu.img",if=virtio,format=qcow2 -drive file="$root/seed.iso",media=cdrom,readonly=on -device virtio-vga -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 -display none -serial file:evidence/vm/serial.log -pidfile "$root/qemu.pid" -daemonize
ready=0
for n in $(seq 1 180); do
  if timeout 20 ssh "${opts[@]}" probe@127.0.0.1 'cloud-init status --wait; command -v startxfce4' > evidence/vm/readiness.log 2>&1; then ready=1; break; fi
  sleep 5
done
test "$ready" = 1
scp "${copy[@]}" support/diagnostics/1310/guest.sh support/diagnostics/1310/actions.sh probe@127.0.0.1:/home/probe/
timeout 1000 ssh "${opts[@]}" probe@127.0.0.1 'bash /home/probe/guest.sh' | tee evidence/scenario.log
