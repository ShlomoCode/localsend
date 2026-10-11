#!/usr/bin/env bash
set -Eeuo pipefail

OUT="${OUT:-${GITHUB_WORKSPACE:-$PWD}/evidence-mint-vm}"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK="$(mktemp -d "$TEMP_ROOT/mint-vm.XXXXXX")"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
exec > >(tee -a "$OUT/host.log") 2>&1
QEMU_PID=""
cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ -d "$WORK/evidence" ]]; then cp -a "$WORK/evidence/." "$OUT/" 2>/dev/null || true; fi
  [[ -d "$WORK" ]] && rm -rf -- "$WORK"
}
trap cleanup EXIT
fail() { echo "ERROR: $*" | tee -a "$OUT/infrastructure-failures.txt"; exit 1; }

for tool in curl sha256sum 7z qemu-system-x86_64 expect socat truncate mkfs.ext4 timeout awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing host tool: $tool"
done
[[ -c /dev/kvm ]] || fail 'KVM device is unavailable on this runner.'
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  sudo setfacl -m "u:$(id -un):rw" /dev/kvm || fail 'Cannot grant the runner user access to KVM.'
fi
[[ -r /dev/kvm && -w /dev/kvm ]] || fail 'Runner user cannot access KVM.'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ISO="$WORK/linuxmint-22.3-cinnamon-64bit.iso"
ISO_URL='https://pub.linuxmint.io/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso'
ISO_SHA='a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4'
echo 'Downloading the official Linux Mint 22.3 Cinnamon ISO.'
timeout 15m curl --fail --location --retry 2 --retry-delay 2 "$ISO_URL" -o "$ISO" || fail 'Mint ISO download failed.'
actual_sha=$(sha256sum "$ISO" | awk '{print $1}')
printf 'iso_url=%s\niso_sha256=%s\n' "$ISO_URL" "$actual_sha" > "$OUT/iso-provenance.txt"
[[ "$actual_sha" == "$ISO_SHA" ]] || fail "Mint ISO SHA256 mismatch: $actual_sha"

ISO_FILES="$WORK/iso-files"
mkdir -p "$ISO_FILES"
timeout 5m 7z x -y "$ISO" 'casper/vmlinuz' 'casper/initrd*' "-o$ISO_FILES" > "$OUT/iso-extraction.log" 2>&1 || fail 'Could not extract Casper kernel/initrd.'
KERNEL="$ISO_FILES/casper/vmlinuz"
INITRD=$(find "$ISO_FILES/casper" -maxdepth 1 -type f -name 'initrd*' -print -quit)
[[ -s "$KERNEL" && -n "$INITRD" && -s "$INITRD" ]] || fail 'ISO lacks Casper kernel or initrd.'
printf 'kernel=%s\ninitrd=%s\n' "$(sha256sum "$KERNEL" | awk '{print $1}')" "$(sha256sum "$INITRD" | awk '{print $1}')" >> "$OUT/iso-provenance.txt"

mkdir -p "$WORK/input" "$WORK/evidence"
chmod 0777 "$WORK/evidence"
HARNESS="$ROOT/reproduce.sh"
[[ -f "$ROOT/repro-flatpak-3553.sh" ]] && HARNESS="$ROOT/repro-flatpak-3553.sh"
cp "$HARNESS" "$WORK/input/reproduce.sh"
cp "$ROOT/mint-vm-guest.sh" "$WORK/input/"
chmod 0444 "$WORK/input/"*
truncate -s 8G "$WORK/flatpak-data.img"
mkfs.ext4 -F -q -L MINTDATA "$WORK/flatpak-data.img"
SERIAL="$WORK/serial.sock"
HMP="$WORK/hmp.sock"
export SERIAL
qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 4 -m 4096 -machine q35,accel=kvm \
  -cdrom "$ISO" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append 'boot=casper username=mint hostname=localsend-mint systemd.debug_shell=ttyS0 systemd.mask=serial-getty@ttyS0.service console=ttyS0,115200n8 quiet splash' \
  -vga std -display none -serial "unix:$SERIAL,server=on,wait=off" \
  -monitor "unix:$HMP,server=on,wait=off" \
  -drive "file=$WORK/flatpak-data.img,format=raw,if=virtio,cache=none" \
  -virtfs "local,path=$WORK/input,mount_tag=localsend_input,security_model=none,readonly=on" \
  -virtfs "local,path=$WORK/evidence,mount_tag=localsend_evidence,security_model=none" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -no-reboot > "$OUT/qemu.log" 2>&1 &
QEMU_PID=$!

for ((i=0; i<90; i++)); do
  [[ -S "$SERIAL" ]] && break
  kill -0 "$QEMU_PID" 2>/dev/null || fail 'QEMU exited before creating the serial socket.'
  sleep 1
done
[[ -S "$SERIAL" ]] || fail 'QEMU serial socket did not appear within 90 seconds.'

set +e
expect <<'EXPECT' > "$OUT/serial.log" 2>&1
set timeout 1500
log_user 1
spawn socat -,raw,echo=0 UNIX-CONNECT:$env(SERIAL)
expect {
  -re {root@[^#]*# ?} {}
  -re {# ?$} {}
  timeout { puts "Timed out waiting for Mint debug shell"; exit 21 }
  eof { puts "Serial console closed before debug shell"; exit 22 }
}
send -- {stty -echo; mkdir -p /mnt/input /mnt/evidence /mnt/flatpak-data; mount -t 9p -o trans=virtio,version=9p2000.L,ro localsend_input /mnt/input; mount -t 9p -o trans=virtio,version=9p2000.L localsend_evidence /mnt/evidence; mount -t ext4 /dev/vda /mnt/flatpak-data; bash /mnt/input/mint-vm-guest.sh /mnt/input /mnt/evidence /mnt/flatpak-data; guest_status=$?; echo MINT_VM_DONE:$guest_status}
send -- "\r"
expect {
  -re {\r\nMINT_VM_DONE:0\r} { exit 0 }
  -re {\r\nMINT_VM_DONE:[1-9][0-9]*\r} { puts "Guest returned a nonzero status"; exit 25 }
  timeout { puts "Timed out waiting for guest completion marker"; exit 23 }
  eof { puts "Serial console closed before guest completion"; exit 24 }
}
EXPECT
expect_status=$?
set -e
if [[ $expect_status -ne 0 ]]; then
  echo "expect_status=$expect_status" > "$OUT/guest-status.txt"
  echo 'Guest failed to boot or complete within the time limit.' | tee -a "$OUT/infrastructure-failures.txt"
  exit 1
fi
echo 'result=completed' > "$OUT/guest-status.txt"
