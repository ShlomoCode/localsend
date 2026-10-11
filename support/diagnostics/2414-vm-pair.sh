#!/usr/bin/env bash
# Diagnostic only: ordinary host sender and one 2 CPU / 2 GiB guest receiver.
set -euo pipefail
mkdir -p evidence/vm released/base /tmp/issue2414-vm-pair /home/runner/issue2414-vm-pair
vm_root=/tmp/issue2414-vm-pair
vm_disk_root=/home/runner/issue2414-vm-pair
vm_pair_stage=packages-and-release
trap 'printf "{\"stage\":\"%s\",\"exit_code\":%s,\"classification\":\"setup-infrastructure\"}\n" "$vm_pair_stage" "$?" > evidence/setup-result.json' EXIT
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client xvfb openbox xdotool scrot tesseract-ocr imagemagick network-manager gsettings-desktop-schemas at-spi2-core libayatana-appindicator3-1 libsecret-1-0 libgtk-3-0 libegl1 libgles2 libgl1-mesa-dri libopengl0 libglx-mesa0
sudo systemctl start NetworkManager
curl --fail --location --retry 3 --max-time 240 -o released/baseline.tar.gz https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.tar.gz
sha256sum released/baseline.tar.gz > evidence/artifact-sha256.txt
tar xf released/baseline.tar.gz -C released/base
{ findmnt --target "$vm_disk_root"; df -B1 "$vm_disk_root"; } > evidence/vm/disk-environment.txt
disk_type=$(findmnt -n -o FSTYPE --target "$vm_disk_root")
test "$disk_type" != tmpfs
test "$disk_type" != ramfs
disk_available=$(df -B1 --output=avail "$vm_disk_root" | tail -n 1 | tr -d " ")
# qcow2 allocates physical storage as the guest writes. The 24 GiB virtual
# capacity below is not an upfront reservation on the standard hosted runner.
# This guest installs only desktop/runtime packages, not a source build.
test "$disk_available" -ge 8000000000
curl --fail --location --retry 3 --max-time 300 -o "$vm_disk_root/ubuntu.img" https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
sha256sum "$vm_disk_root/ubuntu.img" > evidence/vm/cloud-image-sha256.txt
{ qemu-system-x86_64 --version; ls -l /dev/kvm || true; } > evidence/vm/hypervisor.txt
qemu-img resize "$vm_disk_root/ubuntu.img" 24G
ssh-keygen -q -t ed25519 -N "" -f "$vm_root/id"
probe_key=$(cat "$vm_root/id.pub")
cat > "$vm_root/user-data" <<CONFIG
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
packages: [xvfb, openbox, xdotool, scrot, network-manager, gsettings-desktop-schemas, at-spi2-core, libayatana-appindicator3-1, libsecret-1-0, libgtk-3-0, libegl1, libgles2, libgl1-mesa-dri, libopengl0, libglx-mesa0, openssh-server]
CONFIG
printf "instance-id: issue2414-pair\nlocal-hostname: issue2414-receiver\n" > "$vm_root/meta-data"
cloud-localds "$vm_disk_root/seed.iso" "$vm_root/user-data" "$vm_root/meta-data"
sudo ip tuntap add dev tap2414 mode tap
sudo nmcli device set tap2414 managed no
sudo ip addr add 172.30.24.1/24 dev tap2414
sudo ip link set tap2414 up
sudo ip route replace 224.0.0.0/4 dev tap2414
vm_pair_stage=guest-boot
opts=(-i "$vm_root/id" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$vm_root/known" -o ConnectTimeout=5)
copy_opts=(-i "$vm_root/id" -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$vm_root/known" -o ConnectTimeout=5)
cleanup() {
  scenario_exit=$?
  classification=setup-infrastructure
  if test "$vm_pair_stage" = real-app-pair; then classification=inspect-case-results; fi
  printf '{"stage":"%s","exit_code":%s,"classification":"%s"}\n' "$vm_pair_stage" "$scenario_exit" "$classification" > evidence/setup-result.json
  timeout 20 ssh "${opts[@]}" probe@127.0.0.1 "sudo journalctl -k --no-pager; free -m; ip addr; ip route; ps -eo pid,ppid,stat,pcpu,pmem,rss,wchan:32,comm" > evidence/vm/kernel-final.txt 2>&1 || true
  timeout 90 scp -r "${copy_opts[@]}" probe@127.0.0.1:/home/probe/evidence evidence/vm/guest || true
  { df -B1 "$vm_disk_root"; du -B1 "$vm_disk_root"/*; } > evidence/vm/disk-final.txt 2>&1 || true
  if test -f "$vm_root/qemu.pid"; then sudo kill "$(cat "$vm_root/qemu.pid")" || true; fi
  sudo ip link delete tap2414 || true
}
trap cleanup EXIT
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu Skylake-Client,vendor=GenuineIntel,-vmx,-hle,-rtm -smp 2 -m 2048 -drive file="$vm_disk_root/ubuntu.img",if=virtio,format=qcow2 -drive file="$vm_disk_root/seed.iso",media=cdrom,readonly=on -device virtio-vga -netdev user,id=nat,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=nat,mac=52:54:00:24:14:01 -netdev tap,id=peer,ifname=tap2414,script=no,downscript=no -device virtio-net-pci,netdev=peer,mac=52:54:00:24:14:02 -display none -serial file:evidence/vm/serial.log -pidfile "$vm_root/qemu.pid" -daemonize
ready=0
for n in $(seq 1 90); do
  if timeout 15 ssh "${opts[@]}" probe@127.0.0.1 "cloud-init status --wait; command -v scrot" > evidence/vm/readiness.log 2>&1; then ready=1; break; fi
  sleep 5
done
test "$ready" = 1
vm_pair_stage=guest-desktop
ssh "${opts[@]}" probe@127.0.0.1 "mkdir -p /home/probe/released/base /home/probe/evidence"
scp "${copy_opts[@]}" released/baseline.tar.gz support/diagnostics/2414-receiver-driver.py probe@127.0.0.1:/home/probe/
ssh "${opts[@]}" probe@127.0.0.1 "bash -s" <<'GUEST'
set -euo pipefail
cd /home/probe
tar xf baseline.tar.gz -C released/base
sha256sum baseline.tar.gz > evidence/artifact-sha256.txt
# NAT remains DHCP; only the additional peer adapter gets the test LAN address.
peer=$(for path in /sys/class/net/*; do if test "$(cat "$path/address")" = 52:54:00:24:14:02; then basename "$path"; fi; done)
test -n "$peer"
sudo systemctl start NetworkManager
sudo nmcli device set "$peer" managed no
sudo ip addr add 172.30.24.2/24 dev "$peer"
sudo ip link set "$peer" up
sudo ip route replace 224.0.0.0/4 dev "$peer"
{ uname -a; lscpu; free -m; swapon --show; ip addr; ip route; cat /etc/os-release; } > evidence/environment.txt
# Keep a separate ordinary D-Bus session alive. Commands source its trusted env.
nohup dbus-run-session -- bash -c 'export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1; export -p > /home/probe/desktop-env.sh; Xvfb :99 -screen 0 1200x800x24 > /home/probe/evidence/xvfb.log 2>&1 & sleep 2; openbox > /home/probe/evidence/openbox.log 2>&1 & sleep 3600' > evidence/desktop.log 2>&1 < /dev/null &
GUEST
desktop_ready=0
for n in $(seq 1 20); do
  if timeout 10 ssh "${opts[@]}" probe@127.0.0.1 'source /home/probe/desktop-env.sh; xdotool getdisplaygeometry' > evidence/vm/desktop-readiness.log 2>&1; then desktop_ready=1; break; fi
  sleep 1
done
test "$desktop_ready" = 1
{ uname -a; lscpu; free -m; swapon --show; ip addr; ip route; cat /etc/os-release; } > evidence/host-environment.txt
# No cgroups, process memory caps, artificial pressure, or synthetic OOM.
vm_pair_stage=real-app-pair
timeout 3000 dbus-run-session -- xvfb-run -a -s "-screen 0 1200x800x24" bash -c 'export LIBGL_ALWAYS_SOFTWARE=1; openbox > evidence/host-openbox.log 2>&1 & python3 support/diagnostics/2414-host-pair-ui.py' > evidence/scenario.log 2>&1
