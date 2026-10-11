#!/usr/bin/env bash
# Diagnostic only: Debian desktop, 1024 MiB RAM and ordinary 2 GiB disk swap.
set -euo pipefail
vm_root=/tmp/issue2414-memory-pair
vm_disk_root=/home/runner/issue2414-memory-pair
stage=packages-and-release
mkdir -p evidence/vm released/base "$vm_root" "$vm_disk_root"
opts=(-i "$vm_root/id" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$vm_root/known" -o ConnectTimeout=5)
copy_opts=(-i "$vm_root/id" -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$vm_root/known" -o ConnectTimeout=5)
cleanup() {
  status=$?
  trap - EXIT
  printf '{"stage":"%s","exit_code":%s,"note":"Inspect case results; setup/timeout is not proof of app OOM."}\n' "$stage" "$status" > evidence/setup-result.json
  if test -s "$vm_root/qemu.pid"; then
    timeout 25 ssh "${opts[@]}" probe@127.0.0.1 'sudo cloud-init status --long; sudo tail -n 160 /var/log/cloud-init-output.log; sudo journalctl -u cloud-final -o short-monotonic --no-pager' > evidence/vm/cloud-init-final.txt 2>&1 || true
    timeout 25 ssh "${opts[@]}" probe@127.0.0.1 'sudo journalctl -k -o short-monotonic --no-pager; free -m; /sbin/swapon --show --bytes; cat /proc/pressure/memory; ps -eo pid,ppid,stat,pcpu,pmem,rss,wchan:32,comm' > evidence/vm/kernel-final.txt 2>&1 || true
    timeout 90 scp -r "${copy_opts[@]}" probe@127.0.0.1:/home/probe/evidence evidence/vm/guest || true
    # VM shutdown is harness cleanup, not an application failure observation.
    date --iso-8601=ns > evidence/vm/harness-shutdown-utc.txt
    sudo kill "$(sudo cat "$vm_root/qemu.pid")" || true
  fi
  { df -B1 "$vm_disk_root"; du -B1 "$vm_disk_root"/*; } > evidence/vm/disk-final.txt 2>&1 || true
  sudo ip link delete tap2414 || true
  sudo chown -R "$(id -u):$(id -g)" evidence || true
  exit "$status"
}
trap cleanup EXIT
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client xvfb openbox xdotool scrot tesseract-ocr imagemagick network-manager gsettings-desktop-schemas at-spi2-core libayatana-appindicator3-1 libsecret-1-0 libgtk-3-0 libegl1 libgles2 libgl1-mesa-dri libopengl0 libglx-mesa0 binutils
sudo systemctl start NetworkManager
artifact_sha=${ISSUE2414_ARCHIVE_SHA:-6f05e851b72dbeaac764d3446b5a61c34db22f6278baa92607d5b080997f8c81}
[[ "$artifact_sha" =~ ^[0-9a-f]{64}$ ]]
if [[ -n "${ISSUE2414_ARCHIVE:-}" ]]; then
  cp "$ISSUE2414_ARCHIVE" released/baseline.tar.gz
else
  curl --fail --location --retry 3 --max-time 240 -o released/baseline.tar.gz https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.tar.gz
fi
printf '%s  %s\n' "$artifact_sha" released/baseline.tar.gz | sha256sum --check > evidence/artifact-hash-verification.txt
sha256sum released/baseline.tar.gz > evidence/artifact-sha256.txt
tar xf released/baseline.tar.gz -C released/base
{ findmnt --target "$vm_disk_root"; df -B1 "$vm_disk_root"; } > evidence/vm/disk-environment.txt
disk_type=$(findmnt -n -o FSTYPE --target "$vm_disk_root")
test "$disk_type" != tmpfs
test "$disk_type" != ramfs
disk_available=$(df -B1 --output=avail "$vm_disk_root" | tail -n 1 | tr -d ' ')
test "$disk_available" -ge 10000000000

# Installed cloud disk, not a live ISO. Retain and verify Debian's published hash.
image_name=debian-12-genericcloud-amd64.qcow2
image_url=https://cloud.debian.org/images/cloud/bookworm/latest
curl --fail --location --retry 3 --max-time 60 -o evidence/vm/SHA512SUMS "$image_url/SHA512SUMS"
curl --fail --location --retry 3 --max-time 300 -o "$vm_disk_root/$image_name" "$image_url/$image_name"
image_hash=$(awk -v name="$image_name" '$2 == name || $2 == "*" name { print $1 }' evidence/vm/SHA512SUMS)
test "${#image_hash}" = 128
printf '%s  %s\n' "$image_hash" "$vm_disk_root/$image_name" | sha512sum --check > evidence/vm/image-hash-verification.txt
printf '%s/%s\n' "$image_url" "$image_name" > evidence/vm/image-source.txt
sha512sum "$vm_disk_root/$image_name" > evidence/vm/image-sha512.txt
{ qemu-system-x86_64 --version; ls -l /dev/kvm || true; } > evidence/vm/hypervisor.txt
qemu-img resize "$vm_disk_root/$image_name" 24G
ssh-keygen -q -t ed25519 -N '' -f "$vm_root/id"
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
swap:
  filename: /swap.img
  size: 2147483648
  maxsize: 2147483648
package_update: true
packages: [xvfb, openbox, xdotool, x11-utils, scrot, fonts-dejavu-core, network-manager, gsettings-desktop-schemas, at-spi2-core, libayatana-appindicator3-1, libsecret-1-0, libgtk-3-0, libegl1, libgles2, libgl1-mesa-dri, libopengl0, libglx-mesa0, openssh-server, binutils, python3]
CONFIG
if [[ "${ISSUE2414_SOURCE_PAIR:-0}" == 1 ]]; then
  printf '  - [apt-get, install, -y, ffmpeg]\n' > "$vm_root/recording-package.txt"
  # Cloud-init's supported runcmd installs the optional recorder normally.
  printf 'runcmd:\n' >> "$vm_root/user-data"
  cat "$vm_root/recording-package.txt" >> "$vm_root/user-data"
fi
cp "$vm_root/user-data" evidence/vm/cloud-config.txt
printf 'instance-id: issue2414-memory\nlocal-hostname: issue2414-memory-receiver\n' > "$vm_root/meta-data"
cloud-localds "$vm_disk_root/seed.iso" "$vm_root/user-data" "$vm_root/meta-data"
sudo ip tuntap add dev tap2414 mode tap
sudo nmcli device set tap2414 managed no
sudo ip addr add 172.30.24.1/24 dev tap2414
sudo ip link set tap2414 up
sudo ip route replace 224.0.0.0/4 dev tap2414
stage=guest-boot
touch "$vm_root/qemu.pid" evidence/vm/serial.log
chmod 600 "$vm_root/qemu.pid" evidence/vm/serial.log
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu Skylake-Client,vendor=GenuineIntel,-vmx,-hle,-rtm -smp 2 -m 1024 -drive file="$vm_disk_root/$image_name",if=virtio,format=qcow2 -drive file="$vm_disk_root/seed.iso",media=cdrom,readonly=on -device virtio-vga -netdev user,id=nat,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=nat,mac=52:54:00:24:14:01 -netdev tap,id=peer,ifname=tap2414,script=no,downscript=no -device virtio-net-pci,netdev=peer,mac=52:54:00:24:14:02 -display none -serial file:evidence/vm/serial.log -pidfile "$vm_root/qemu.pid" -daemonize
sudo chown "$(id -u):$(id -g)" "$vm_root/qemu.pid" evidence/vm/serial.log
ready=0
for n in $(seq 1 120); do
  if timeout 15 ssh "${opts[@]}" probe@127.0.0.1 'cloud-init status --wait && command -v scrot && command -v readelf' > evidence/vm/readiness.log 2>&1; then ready=1; break; fi
  sleep 5
done
test "$ready" = 1
stage=guest-runtime-preflight
ssh "${opts[@]}" probe@127.0.0.1 'mkdir -p /home/probe/released/base /home/probe/evidence'
scp "${copy_opts[@]}" released/baseline.tar.gz support/diagnostics/2414-memory-receiver-driver.py support/diagnostics/2414-memory-preflight.sh probe@127.0.0.1:/home/probe/
printf '%s\n' "$artifact_sha" > "$vm_root/artifact-sha"
printf '%s\n' "${ISSUE2414_SOURCE_PAIR:-0}" > "$vm_root/source-pair-mode"
scp "${copy_opts[@]}" "$vm_root/artifact-sha" "$vm_root/source-pair-mode" probe@127.0.0.1:/home/probe/
ssh "${opts[@]}" probe@127.0.0.1 'bash -s' <<'GUEST'
set -euo pipefail
export LC_ALL=C
cd /home/probe
printf '%s  %s\n' "$(cat artifact-sha)" baseline.tar.gz | sha256sum --check > evidence/artifact-hash-verification.txt
tar xf baseline.tar.gz -C released/base
sha256sum baseline.tar.gz > evidence/artifact-sha256.txt
bash /home/probe/2414-memory-preflight.sh vm
peer=$(for path in /sys/class/net/*; do if test "$(cat "$path/address")" = 52:54:00:24:14:02; then basename "$path"; fi; done)
test -n "$peer"
sudo systemctl start NetworkManager
sudo nmcli device set "$peer" managed no
sudo ip addr add 172.30.24.2/24 dev "$peer"
sudo ip link set "$peer" up
sudo ip route replace 224.0.0.0/4 dev "$peer"
{ ip addr; ip route; sudo journalctl -k -o short-monotonic --no-pager; } > evidence/kernel-before-app.txt
nohup dbus-run-session -- bash -c 'export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1; export -p > /home/probe/desktop-env.sh; Xvfb :99 -screen 0 1200x800x24 > /home/probe/evidence/xvfb.log 2>&1 & sleep 2; openbox > /home/probe/evidence/openbox.log 2>&1 & sleep 3600' > evidence/desktop.log 2>&1 < /dev/null &
GUEST
stage=guest-desktop
desktop_ready=0
for n in $(seq 1 20); do
  if timeout 10 ssh "${opts[@]}" probe@127.0.0.1 'source /home/probe/desktop-env.sh; xdotool getdisplaygeometry; wm=$(xprop -root _NET_SUPPORTING_WM_CHECK); printf "%s\n" "$wm"; [[ "$wm" =~ window\ id\ \#\ 0x[1-9a-fA-F][0-9a-fA-F]* ]]' > evidence/vm/desktop-readiness.log 2>&1; then desktop_ready=1; break; fi
  sleep 1
done
test "$desktop_ready" = 1
{ uname -a; lscpu; free -m; /sbin/swapon --show; ip addr; ip route; cat /etc/os-release; } > evidence/host-environment.txt
timeout 90 scp -r "${copy_opts[@]}" probe@127.0.0.1:/home/probe/evidence evidence/vm/preflight-guest
stage=real-app-memory-cases
# No process memory caps, pressure injection, synthetic metadata, or OOM tuning.
timeout 1800 dbus-run-session -- xvfb-run -a -s '-screen 0 1200x800x24' bash -c 'export LIBGL_ALWAYS_SOFTWARE=1; openbox > evidence/host-openbox.log 2>&1 & python3 support/diagnostics/2414-memory-host-ui.py' 2>&1 | tee evidence/scenario.log
