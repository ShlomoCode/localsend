#!/usr/bin/env bash
# Cloud-only GNOME sender. The workflow owns the Docker receiver lifecycle.
set -euo pipefail

mkdir -p "${EVIDENCE_ROOT:-evidence/cloud}"
evidence_root=$(realpath "${EVIDENCE_ROOT:-evidence/cloud}")
vm_root=${GNOME_VM_ROOT:-/home/runner/issue402-gnome-vm}
mkdir -p "$evidence_root/sender" "$vm_root"
scratch=$(mktemp -d /tmp/issue402-gnome.XXXXXX)
vm_pidfile="$scratch/qemu.pid"
relay_pid=
scenario_pid=
ssh_ready=0
ssh_opts=(-i "$scratch/id" -p 2402 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$scratch/known" -o ConnectTimeout=5)
scp_opts=(-i "$scratch/id" -P 2402 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$scratch/known" -o ConnectTimeout=5)

collect() {
  local status=$?
  trap - EXIT
  if [[ -n "$relay_pid" ]]; then kill "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true; fi
  if [[ -n "$scenario_pid" ]]; then kill "$scenario_pid" 2>/dev/null || true; wait "$scenario_pid" 2>/dev/null || true; fi
  # End receiver monitoring even when provisioning or SSH fails.
  touch "$evidence_root/sender/done"
  if timeout 12 ssh "${ssh_opts[@]}" probe@127.0.0.1 true >/dev/null 2>&1; then
    timeout 30 ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo journalctl -b --no-pager; sudo cat /var/log/cloud-init-output.log' > "$evidence_root/gnome-guest-journal.log" 2>&1 || true
    mkdir -p "$evidence_root/gnome-guest"
    timeout 60 scp "${scp_opts[@]}" -r probe@127.0.0.1:/home/probe/evidence/. "$evidence_root/gnome-guest/" >> "$evidence_root/gnome-collection.log" 2>&1 || true
  fi
  if [[ -f "$vm_pidfile" ]]; then sudo kill "$(cat "$vm_pidfile")" 2>/dev/null || true; fi
  printf '%s\n' "$status" > "$evidence_root/gnome-host-status.txt"
  exit "$status"
}
trap collect EXIT

df -Th /home/runner /tmp > "$evidence_root/gnome-host-resources.txt"
free -m >> "$evidence_root/gnome-host-resources.txt"
lscpu >> "$evidence_root/gnome-host-resources.txt"
test "$(df -Pk /home/runner | awk 'NR==2 {print $4}')" -ge 12582912
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client jq
curl -fL --retry 3 https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img -o "$vm_root/ubuntu.img"
sha256sum "$vm_root/ubuntu.img" > "$evidence_root/gnome-image-sha256.txt"
qemu-img resize "$vm_root/ubuntu.img" 28G
ssh-keygen -q -t ed25519 -N '' -f "$scratch/id"
probe_key=$(cat "$scratch/id.pub")
cat > "$scratch/user-data" <<CONFIG
#cloud-config
users:
  - name: probe
    uid: 1000
    groups: [adm, sudo, audio, video, render]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $probe_key
package_update: true
packages:
  - ubuntu-desktop-minimal
  - gdm3
  - xdotool
  - scrot
  - tesseract-ocr
  - imagemagick
  - python3-pyatspi
  - at-spi2-core
  - curl
  - openssh-server
  - fuse
  - libfuse2
  - libgtk-3-0
  - libglu1-mesa
  - libappindicator3-1
  - libayatana-appindicator3-1
  - libsecret-1-0
  - xdg-user-dirs
  - zenity
write_files:
  - path: /etc/gdm3/custom.conf
    content: |
      [daemon]
      WaylandEnable=false
      AutomaticLoginEnable=true
      AutomaticLogin=probe
  - path: /var/lib/AccountsService/users/probe
    content: |
      [User]
      Session=ubuntu
      XSession=ubuntu
      SystemAccount=false
runcmd:
  - [sh, -c, "install -d -o probe -g probe /home/probe/.config; touch /home/probe/.config/gnome-initial-setup-done; chown probe:probe /home/probe/.config/gnome-initial-setup-done"]
  - [sh, -c, "cat /proc/sys/kernel/random/boot_id > /var/lib/issue402-provision-boot-id"]
  - [systemctl, set-default, graphical.target]
  - [systemctl, enable, gdm3]
power_state:
  mode: reboot
  timeout: 30
  condition: true
CONFIG
printf 'instance-id: issue402-gnome\nlocal-hostname: issue402-gnome\n' > "$scratch/meta-data"
cp "$scratch/user-data" "$evidence_root/gnome-cloud-config.yaml"
cloud-localds "$vm_root/seed.iso" "$scratch/user-data" "$scratch/meta-data"
if [[ -c /dev/kvm ]]; then
  acceleration=(-machine accel=kvm -cpu host)
else
  acceleration=(-machine accel=tcg -cpu max)
fi
printf '%s\n' "${acceleration[*]}" > "$evidence_root/gnome-acceleration.txt"
sudo qemu-system-x86_64 "${acceleration[@]}" -smp 2 -m 4096 \
  -drive "file=$vm_root/ubuntu.img,if=virtio,format=qcow2" \
  -drive "file=$vm_root/seed.iso,media=cdrom,readonly=on" \
  -device virtio-vga -usb -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2402-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$evidence_root/gnome-serial.log" -pidfile "$vm_pidfile" -daemonize

deadline=$((SECONDS + 2100))
while (( SECONDS < deadline )); do
  # A completed cloud-init plus a user GNOME shell excludes the GDM greeter.
  if timeout 15 ssh "${ssh_opts[@]}" probe@127.0.0.1 \
    'set -e; cloud-init status --wait; test -e /var/lib/cloud/instance/boot-finished; test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat /var/lib/issue402-provision-boot-id)"; pgrep -u "$(id -u)" -x gnome-shell; test -S /run/user/$(id -u)/bus' \
    > "$evidence_root/gnome-readiness.log" 2>&1; then
    ssh_ready=1
    break
  fi
  sleep 15
done
test "$ssh_ready" = 1
touch "$evidence_root/gnome-ready"
ssh "${ssh_opts[@]}" probe@127.0.0.1 'mkdir -p /home/probe/evidence/receiver /home/probe/evidence/sender /home/probe/support/diagnostics'
scp "${scp_opts[@]}" support/diagnostics/402-ui.py support/diagnostics/402-gnome-guest.sh probe@127.0.0.1:/home/probe/support/diagnostics/

# Relay only coordination files; UI screenshots and logs are collected afterwards.
# Stage receipts atomically so the guest never reads a partially copied JSON file.
relay() {
  while [[ ! -e "$scratch/scenario-finished" ]]; do
    for file in "$evidence_root/receiver/ready" "$evidence_root/receiver/alias.txt" "$evidence_root/receiver/receipts.json" "$evidence_root"/receiver/cleared-*; do
      [[ -f "$file" ]] || continue
      base=$(basename "$file")
      cp "$file" "$scratch/$base"
      if [[ "$base" = receipts.json ]] && ! jq -e . "$scratch/$base" >/dev/null; then continue; fi
      if timeout 12 scp "${scp_opts[@]}" "$scratch/$base" "probe@127.0.0.1:/home/probe/evidence/receiver/$base.next"; then
        timeout 12 ssh "${ssh_opts[@]}" probe@127.0.0.1 "mv /home/probe/evidence/receiver/$base.next /home/probe/evidence/receiver/$base" || return 1
      else
        return 1
      fi
    done
    # ACK/done are empty marker files, so a tar stream preserves their names.
    timeout 12 ssh "${ssh_opts[@]}" probe@127.0.0.1 \
      'cd /home/probe/evidence/sender; find . -maxdepth 1 -type f \( -name "ack-*" -o -name done \) -print0 | tar --null -T - -cf -' \
      | tar -xf - -C "$evidence_root/sender" || return 1
    sleep 1
  done
}
relay > "$evidence_root/gnome-relay.log" 2>&1 &
relay_pid=$!
set +e
timeout 720 ssh "${ssh_opts[@]}" probe@127.0.0.1 \
  'bash /home/probe/support/diagnostics/402-gnome-guest.sh' > "$evidence_root/gnome-scenario.log" 2>&1 &
scenario_pid=$!
wait "$scenario_pid"
status=$?
scenario_pid=
set -e
touch "$scratch/scenario-finished"
wait "$relay_pid" || status=1
relay_pid=
exit "$status"
