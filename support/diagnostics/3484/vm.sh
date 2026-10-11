#!/usr/bin/env bash
set -euxo pipefail
mkdir -p evidence/cloud /home/runner/tray3484 /tmp/tray3484
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils socat openssh-client imagemagick
curl -fL --retry 3 https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 -o /home/runner/tray3484/arch.qcow2
sha256sum /home/runner/tray3484/arch.qcow2 > evidence/cloud/cloud-image-sha256.txt
qemu-img resize /home/runner/tray3484/arch.qcow2 24G
ssh-keygen -q -t ed25519 -N '' -f /tmp/tray3484/key
probe_key=$(cat /tmp/tray3484/key.pub)
cat > /tmp/tray3484/user-data <<EOF
#cloud-config
users:
  - name: probe
    groups: [wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $probe_key
runcmd:
  - [systemctl, enable, --now, sshd]
EOF
printf 'instance-id: tray3484\nlocal-hostname: tray3484\n' > /tmp/tray3484/meta-data
cloud-localds /home/runner/tray3484/seed.iso /tmp/tray3484/user-data /tmp/tray3484/meta-data
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 6144 \
  -drive file=/home/runner/tray3484/arch.qcow2,if=virtio,format=qcow2 \
  -drive file=/home/runner/tray3484/seed.iso,media=cdrom,readonly=on \
  -device virtio-vga -display none -usb -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
  -monitor unix:/tmp/tray3484/monitor,server,nowait -serial file:evidence/cloud/serial.log -daemonize
ssh_opts=(-i /tmp/tray3484/key -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/tray3484/known_hosts -o ConnectTimeout=5)
for i in $(seq 1 90); do
  if ssh "${ssh_opts[@]}" probe@127.0.0.1 'cloud-init status --wait' > evidence/cloud/cloud-init.log 2>&1; then break; fi
  sleep 5
done
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo mkdir -p /work/support/diagnostics/3484 /work/evidence/cloud; sudo chown -R probe:probe /work'
scp -i /tmp/tray3484/key -P 2222 -o StrictHostKeyChecking=no support/diagnostics/3484/guest.sh support/diagnostics/3484/wayland-session.sh probe@127.0.0.1:/work/support/diagnostics/3484/
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo bash /work/support/diagnostics/3484/guest.sh' > evidence/cloud/provision.log 2>&1
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo reboot' || true
ready=0
for i in $(seq 1 120); do
  if ssh "${ssh_opts[@]}" probe@127.0.0.1 'test -f /work/evidence/cloud/session.done'; then ready=1; break; fi
  sleep 5
done
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo journalctl -b --no-pager' > evidence/cloud/guest-journal.log
scp -r -i /tmp/tray3484/key -P 2222 -o StrictHostKeyChecking=no probe@127.0.0.1:/work/evidence/cloud/. evidence/cloud/
printf 'screendump %s\n' "$PWD/evidence/cloud/guest-final.ppm" | sudo socat - UNIX-CONNECT:/tmp/tray3484/monitor
sudo chown -R "$(id -u):$(id -g)" evidence/cloud
convert evidence/cloud/guest-final.ppm evidence/cloud/guest-final.png
test "$ready" = 1
test "$(cat evidence/cloud/session.done)" = 0
