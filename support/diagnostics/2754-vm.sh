#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence/cloud /home/runner/issue2754-vm /tmp/issue2754-vm
# Assess runner disk and memory before image preparation.
df -Th /home/runner /tmp > evidence/cloud/host-resources.txt
free -m >> evidence/cloud/host-resources.txt
lscpu >> evidence/cloud/host-resources.txt
test "$(df -Pk /home/runner | awk "NR==2 {print \$4}")" -ge 12582912
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client
curl -fL --retry 3 https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img -o /home/runner/issue2754-vm/ubuntu.img
sha256sum /home/runner/issue2754-vm/ubuntu.img > evidence/cloud/image-sha256.txt
qemu-img resize /home/runner/issue2754-vm/ubuntu.img 28G
ssh-keygen -q -t ed25519 -N "" -f /tmp/issue2754-vm/id
probe_key=$(cat /tmp/issue2754-vm/id.pub)
cat > /tmp/issue2754-vm/user-data <<CONFIG
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
  - cinnamon-desktop-environment
  - lightdm
  - xdotool
  - scrot
  - tesseract-ocr
  - xclip
  - ffmpeg
  - gdb
  - curl
  - openssh-server
  - libayatana-appindicator3-1
runcmd:
  - [sh, -c, "mkdir -p /etc/lightdm/lightdm.conf.d; printf \u0027[Seat:*]\\nautologin-user=probe\\nuser-session=cinnamon\\n\u0027 > /etc/lightdm/lightdm.conf.d/50-probe.conf"]
  - [systemctl, set-default, graphical.target]
  - [systemctl, enable, lightdm]
power_state:
  mode: reboot
  timeout: 30
  condition: true
CONFIG
printf "instance-id: issue2754\nlocal-hostname: issue2754\n" > /tmp/issue2754-vm/meta-data
cloud-localds /home/runner/issue2754-vm/seed.iso /tmp/issue2754-vm/user-data /tmp/issue2754-vm/meta-data
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -drive file=/home/runner/issue2754-vm/ubuntu.img,if=virtio,format=qcow2 -drive file=/home/runner/issue2754-vm/seed.iso,media=cdrom,readonly=on -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2275-:22 -device virtio-net-pci,netdev=net0 -display none -serial file:evidence/cloud/serial.log -daemonize
opts=(-i /tmp/issue2754-vm/id -p 2275 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-vm/known -o ConnectTimeout=5)
ready=0
for n in $(seq 1 100); do
 if timeout 12 ssh "${opts[@]}" probe@127.0.0.1 "cloud-init status --wait; pgrep -x cinnamon" > evidence/cloud/readiness.log 2>&1; then ready=1; break; fi
 sleep 15
done
test "$ready" = 1
ssh "${opts[@]}" probe@127.0.0.1 "mkdir -p /home/probe/support/diagnostics /home/probe/evidence"
scp -i /tmp/issue2754-vm/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-vm/known support/diagnostics/2754-ui.py probe@127.0.0.1:/home/probe/support/diagnostics/
set +e
timeout 600 ssh "${opts[@]}" probe@127.0.0.1 "bash -s" > evidence/cloud/scenario.log 2>&1 <<"GUEST"
set -euo pipefail
cd /home/probe
curl -fL https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.deb -o /tmp/localsend.deb
sha256sum /tmp/localsend.deb > evidence/release-sha256.txt
sudo apt-get install -y /tmp/localsend.deb
export DISPLAY=:0 XAUTHORITY=/home/probe/.Xauthority XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
uname -a > evidence/environment.txt
cat /etc/os-release >> evidence/environment.txt
cinnamon --version >> evidence/environment.txt
dpkg-query -W cinnamon cinnamon-settings-daemon caribou localsend >> evidence/environment.txt || true
loginctl list-sessions >> evidence/environment.txt
xrandr >> evidence/environment.txt
ffmpeg -y -f x11grab -framerate 10 -video_size 1280x800 -i :0 -c:v libx264 -preset ultrafast evidence/scenario.mp4 > evidence/video.log 2>&1 &
video_pid=$!
set +e
python3 support/diagnostics/2754-ui.py
status=$?
kill -INT "$video_pid"
wait "$video_pid"
sudo journalctl -b --no-pager > evidence/journal.txt
exit "$status"
GUEST
status=$?
set -e
scp -r -i /tmp/issue2754-vm/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-vm/known probe@127.0.0.1:/home/probe/evidence evidence/cloud/guest || true
exit "$status"
