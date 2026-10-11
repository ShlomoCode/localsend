#!/usr/bin/env bash
set -euxo pipefail
mkdir -p evidence/cloud /home/runner/tray3484 /tmp/tray3484/input
collect_evidence() {
  host_status=$?
  trap - EXIT
  set +e
  printf '%s\n' "$host_status" > evidence/cloud/host-original-exit-status.txt
  collection_status=1
  collection_method=scp
  if [ -s evidence/cloud/session-trace.log ]; then collection_status=0; collection_method=9p; fi
  if declare -p ssh_opts >/dev/null 2>&1; then
    timeout 40 ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo journalctl -b --no-pager' > evidence/cloud/guest-journal.log 2>&1
    if [ "$collection_status" != 0 ]; then
      mkdir -p /tmp/tray3484/collected
      timeout 60 scp -r -i /tmp/tray3484/key -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 probe@127.0.0.1:/work/evidence/cloud/. /tmp/tray3484/collected/ > evidence/cloud/collection.log 2>&1
      collection_status=$?
      if [ "$collection_status" = 0 ]; then cp -a /tmp/tray3484/collected/. evidence/cloud/; collection_status=$?; fi
    fi
  fi
  printf '%s\n' "$collection_method" > evidence/cloud/collection-method.txt
  if [ "$host_status" = 0 ]; then
    for required_file in session.done release/capture-manifest.json current-base/capture-manifest.json; do
      if [ ! -s "evidence/cloud/$required_file" ]; then collection_status=1; fi
    done
  fi
  printf '%s\n' "$collection_status" > evidence/cloud/collection-status.txt
  if [ "$host_status" = 0 ] && [ "$collection_status" != 0 ]; then host_status=1; fi
  printf '%s\n' "$host_status" > evidence/cloud/host-exit-status.txt
  if [ -S /tmp/tray3484/monitor ]; then
    printf 'screendump %s\n' "$PWD/evidence/cloud/guest-final.ppm" | timeout 10 sudo socat - UNIX-CONNECT:/tmp/tray3484/monitor > evidence/cloud/monitor-collection.log 2>&1
    sudo chown -R "$(id -u):$(id -g)" evidence/cloud
    convert evidence/cloud/guest-final.ppm evidence/cloud/guest-final.png 2>> evidence/cloud/collection.log
  fi
  exit "$host_status"
}
trap collect_evidence EXIT
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils socat openssh-client imagemagick unzip jq
gh api repos/ShlomoCode/localsend/actions/artifacts/11700370485/zip > /tmp/tray3484/baseline.zip
unzip -q /tmp/tray3484/baseline.zip -d /tmp/tray3484/baseline
printf '98f6e749c0eb470b7d2bb4a365f704328ae7dc4bbc6d78ddf2d574dfb63cc20b  /tmp/tray3484/baseline/source-bundle.tar.gz\n' | sha256sum -c -
grep -qx c1ce322fb3acf08e44f329b8b7208b8b0d91e244 /tmp/tray3484/baseline/provenance/source-sha.txt
test ! -s /tmp/tray3484/baseline/provenance/source-status-before.txt
test ! -s /tmp/tray3484/baseline/provenance/source-status-after.txt
cp -a /tmp/tray3484/baseline/provenance evidence/cloud/current-base-provenance
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
  -virtfs local,path="$PWD/evidence/cloud",mount_tag=evidence3484,security_model=passthrough \
  -virtfs local,path=/tmp/tray3484/input,mount_tag=input3484,security_model=passthrough \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
  -monitor unix:/tmp/tray3484/monitor,server,nowait -qmp unix:/tmp/tray3484/qmp,server,nowait -serial file:evidence/cloud/serial.log -daemonize
ssh_opts=(-i /tmp/tray3484/key -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/tray3484/known_hosts -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
for i in $(seq 1 90); do
  if ssh "${ssh_opts[@]}" probe@127.0.0.1 'cloud-init status --wait' > evidence/cloud/cloud-init.log 2>&1; then break; fi
  sleep 5
done
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo mkdir -p /work/support/diagnostics/3484 /work/evidence/cloud; sudo chown -R probe:probe /work'
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo bash -s' <<'MOUNTS'
set -euxo pipefail
mkdir -p /work/input
mount -t 9p -o trans=virtio,version=9p2000.L,cache=none evidence3484 /work/evidence/cloud
mount -t 9p -o trans=virtio,version=9p2000.L,cache=none input3484 /work/input
test "$(findmnt -n -o FSTYPE --mountpoint /work/evidence/cloud)" = 9p
test "$(findmnt -n -o SOURCE --mountpoint /work/evidence/cloud)" = evidence3484
test "$(findmnt -n -o FSTYPE --mountpoint /work/input)" = 9p
test "$(findmnt -n -o SOURCE --mountpoint /work/input)" = input3484
printf 'evidence3484 /work/evidence/cloud 9p trans=virtio,version=9p2000.L,cache=none,msize=262144 0 0\ninput3484 /work/input 9p trans=virtio,version=9p2000.L,cache=none,msize=262144 0 0\n' >> /etc/fstab
printf 'guest-evidence-share\n' > /work/evidence/cloud/share-guest-sentinel.txt
printf 'guest-input-share\n' > /work/input/share-guest-sentinel.txt
MOUNTS
grep -qx guest-evidence-share evidence/cloud/share-guest-sentinel.txt
grep -qx guest-input-share /tmp/tray3484/input/share-guest-sentinel.txt
scp -i /tmp/tray3484/key -P 2222 -o StrictHostKeyChecking=no support/diagnostics/3484/guest.sh support/diagnostics/3484/wayland-session.sh probe@127.0.0.1:/work/support/diagnostics/3484/
scp -i /tmp/tray3484/key -P 2222 -o StrictHostKeyChecking=no /tmp/tray3484/baseline/source-bundle.tar.gz probe@127.0.0.1:/work/source-bundle.tar.gz
ssh "${ssh_opts[@]}" probe@127.0.0.1 "sudo bash /work/support/diagnostics/3484/guest.sh '${ARCH_DATE:-latest}'" > evidence/cloud/provision.log 2>&1
guest_uid=$(ssh "${ssh_opts[@]}" probe@127.0.0.1 'id -u investigator')
printf 'runner-uid=%s\nrunner-gid=%s\nguest-investigator-uid=%s\n' "$(id -u)" "$(id -g)" "$guest_uid" > evidence/cloud/share-user-identity.txt
ssh "${ssh_opts[@]}" probe@127.0.0.1 'id investigator; sudo -u investigator bash -e -c "printf guest-user-evidence > /work/evidence/cloud/share-user-sentinel.txt; printf guest-user-input > /work/input/share-user-sentinel.txt"' >> evidence/cloud/share-user-identity.txt
grep -qx guest-user-evidence evidence/cloud/share-user-sentinel.txt
grep -qx guest-user-input /tmp/tray3484/input/share-user-sentinel.txt
printf 'host-input-share\n' > /tmp/tray3484/input/share-host-sentinel.txt
ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo -u investigator grep -qx host-input-share /work/input/share-host-sentinel.txt'
test "$guest_uid" = "$(id -u)"
boot_id_before=$(timeout 5 ssh "${ssh_opts[@]}" probe@127.0.0.1 'cat /proc/sys/kernel/random/boot_id')
printf '%s\n' "$boot_id_before" > evidence/cloud/boot-id-before.txt
timeout 10 ssh "${ssh_opts[@]}" probe@127.0.0.1 'sudo reboot' || true
boot_ready=0
for i in $(seq 1 60); do
  boot_id_after=$(cat evidence/cloud/boot-id-after.txt 2>/dev/null || true)
  if [[ "$boot_id_after" =~ ^[0-9a-f-]{36}$ ]] && [ "$boot_id_after" != "$boot_id_before" ]; then boot_ready=1; break; fi
  sleep 1
done
test "$boot_ready" = 1
ready=0
last_seq=0
scenario_deadline=$((SECONDS + 900))
while [ "$SECONDS" -lt "$scenario_deadline" ]; do
  request=$(cat /tmp/tray3484/input/request 2>/dev/null || true)
  if [[ "$request" =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]]; then
    event_seq=${BASH_REMATCH[1]}
    pointer_x=${BASH_REMATCH[2]}
    pointer_y=${BASH_REMATCH[3]}
    if [ "$event_seq" -gt "$last_seq" ]; then
      abs_x=$((pointer_x * 32767 / 1279))
      abs_y=$((pointer_y * 32767 / 799))
      printf '{"execute":"qmp_capabilities"}\n{"execute":"input-send-event","id":"pointer-%s","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":%s}},{"type":"abs","data":{"axis":"y","value":%s}}]}}\n' "$event_seq" "$abs_x" "$abs_y" | timeout 5 sudo socat -t 1 - UNIX-CONNECT:/tmp/tray3484/qmp > /tmp/tray3484/qmp-response.jsonl
      cat /tmp/tray3484/qmp-response.jsonl >> evidence/cloud/input-qmp.log
      jq -s -e --arg event "pointer-$event_seq" 'any(.[]; .id == $event and has("return") and (has("error") | not))' /tmp/tray3484/qmp-response.jsonl > /dev/null
      printf '%s\n' "$event_seq" > /tmp/tray3484/input/ack
      printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$event_seq" "$pointer_x" "$pointer_y" >> evidence/cloud/input-events.tsv
      last_seq=$event_seq
    fi
  fi
  if [ -f evidence/cloud/session.done ]; then ready=1; break; fi
  sleep 1
done
test "$ready" = 1
test "$(cat evidence/cloud/session.done)" = 0
