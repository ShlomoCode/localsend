#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence/vm /home/runner/issue2414-vm /tmp/issue2414-vm
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client
curl --fail --location --retry 3 -o /home/runner/issue2414-vm/ubuntu.img https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
qemu-img resize /home/runner/issue2414-vm/ubuntu.img 24G
ssh-keygen -q -t ed25519 -N '' -f /tmp/issue2414-vm/id
probe_key=$(cat /tmp/issue2414-vm/id.pub)
cat > /tmp/issue2414-vm/user-data <<CONFIG
#cloud-config
users:
  - default
  - name: probe
    groups: [adm, sudo, audio, video, render]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $probe_key
package_update: true
packages:
  - xvfb
  - openbox
  - xdotool
  - scrot
  - tesseract-ocr
  - imagemagick
  - network-manager
  - gsettings-desktop-schemas
  - at-spi2-core
  - libayatana-appindicator3-1
  - libsecret-1-0
  - libgtk-3-0
  - libegl1
  - libgles2
  - libgl1-mesa-dri
  - libopengl0
  - libglx-mesa0
  - gdb
  - curl
  - openssh-server
CONFIG
printf 'instance-id: issue2414\nlocal-hostname: issue2414\n' > /tmp/issue2414-vm/meta-data
cloud-localds /home/runner/issue2414-vm/seed.iso /tmp/issue2414-vm/user-data /tmp/issue2414-vm/meta-data
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu Skylake-Client,vendor=GenuineIntel,-vmx,-hle,-rtm -smp 2 -m 2048 -drive file=/home/runner/issue2414-vm/ubuntu.img,if=virtio,format=qcow2 -drive file=/home/runner/issue2414-vm/seed.iso,media=cdrom,readonly=on -device virtio-vga -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 -display none -serial file:evidence/vm/serial.log -daemonize
opts=(-i /tmp/issue2414-vm/id -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2414-vm/known -o ConnectTimeout=5)
ready=0
for n in $(seq 1 60); do
  if timeout 15 ssh "${opts[@]}" probe@127.0.0.1 'cloud-init status --wait; command -v scrot; command -v tesseract' > evidence/vm/readiness.log 2>&1; then ready=1; break; fi
  sleep 10
done
test "$ready" = 1
scp -i /tmp/issue2414-vm/id -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2414-vm/known support/diagnostics/2414-ui.py probe@127.0.0.1:/home/probe/2414-ui.py
set +e
timeout 800 ssh "${opts[@]}" probe@127.0.0.1 'bash -s' > evidence/vm/scenario.log 2>&1 <<'GUEST'
set -euo pipefail
cd /home/probe
mkdir -p evidence released/base
sudo systemctl start NetworkManager
curl -fL https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.tar.gz -o released/baseline.tar.gz
sha256sum released/baseline.tar.gz > evidence/artifact-sha256.txt
tar xf released/baseline.tar.gz -C released/base
uname -a > evidence/environment.txt
free -m >> evidence/environment.txt
lscpu >> evidence/environment.txt
swapon --show >> evidence/environment.txt
# This ordinary guest's total RAM is 2GiB. There are no per-process caps,
# artificially consumed RAM, disabled runtime dependencies, or injected OOM.
dbus-run-session -- xvfb-run -a -s '-screen 0 1200x800x24' bash -c 'export LIBGL_ALWAYS_SOFTWARE=1; openbox > evidence/openbox.log 2>&1 & python3 2414-ui.py' > evidence/ui-input.log 2>&1
GUEST
scenario_status=$?
set -e
ssh "${opts[@]}" probe@127.0.0.1 'sudo journalctl -k --no-pager; free -m; ps -eo pid,ppid,stat,pcpu,pmem,rss,wchan:32,comm' > evidence/vm/kernel-final.txt || true
scp -r -i /tmp/issue2414-vm/id -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2414-vm/known probe@127.0.0.1:/home/probe/evidence evidence/vm/guest || true
exit "$scenario_status"
