#!/bin/bash
# Runs through supported cloud-init runcmd inside the official Linux guest.
set -uo pipefail
exec > >(tee -a /var/log/2884-guest.log /dev/ttyS0) 2>&1
finish() {
  printf '2884_GUEST_FINAL stage=%s rc=%s\n' "$1" "$2"
  sync
  poweroff
  exit "$2"
}
printf '2884_GUEST_BOOTED utc=%s\n' "$(date -u --iso-8601=seconds)"
uname -a
cat /etc/os-release
id
lscpu
ls -l /dev/kvm
printf 'guest_probe_source_sha256='; sha256sum /root/2884-nested-kvm-run.c
printf 'guest_driver_source_sha256='; sha256sum /root/2884-nested-guest.sh
if ! timeout --signal=TERM --kill-after=5s 180s apt-get update; then finish guest_package_index 2; fi
if ! timeout --signal=TERM --kill-after=5s 180s env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev linux-libc-dev; then finish guest_compiler_install 2; fi
gcc --version
if ! gcc -O2 -Wall -Wextra -Werror /root/2884-nested-kvm-run.c -o /root/2884-nested-kvm-run; then finish guest_compile 2; fi
timeout --signal=TERM --kill-after=2s 10s /root/2884-nested-kvm-run
probe_status=$?
finish inner_kvm_run "$probe_status"
