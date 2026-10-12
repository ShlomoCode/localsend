#!/bin/bash
set -euo pipefail
evidence="$GITHUB_WORKSPACE/evidence/2884-nested-kvm"
mkdir -p "$evidence"
exec > >(tee "$evidence/host-driver.txt") 2>&1
stage=host_initialization
work_dir=$(mktemp -d /tmp/2884-nested-kvm.XXXXXXXX)
cleanup() {
  status=$?
  printf '2884_HOST_FINAL stage=%s rc=%s\n' "$stage" "$status"
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
date -u --iso-8601=seconds
printf 'repository=%s head=%s run=%s attempt=%s runner=%s image=%s version=%s\n' "$GITHUB_REPOSITORY" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$RUNNER_NAME" "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
uname -a
cat /etc/os-release
id
lscpu
ls -l /dev/kvm
df -B1 "$work_dir"
free -b
sha256sum support/diagnostics/2884-nested-{host.sh,guest.sh,kvm-run.c} > "$evidence/source-sha256.txt"
stage=host_cpu_route_gate
cpu_vendor=$(awk -F: '/^vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)
if [ "$cpu_vendor" != AuthenticAMD ]; then
  printf 'host_cpu_route_not_covered vendor=%s; this_source_prepared_for_measured_AMD_route_only\n' "$cpu_vendor"
  exit 2
fi
stage=host_resource_gate
free_bytes=$(df -B1 --output=avail "$work_dir" | tail -n 1 | tr -d ' ')
available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
if [ "$free_bytes" -lt 10737418240 ] || [ "$available_kib" -lt 4194304 ] || [ "$(nproc)" -lt 2 ]; then
  printf 'resource_gate_failed disk_free=%s memory_available_kib=%s CPUs=%s\n' "$free_bytes" "$available_kib" "$(nproc)"
  exit 2
fi
stage=host_tool_install
sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 180s apt-get update
sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 180s env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils
qemu-system-x86_64 --version
qemu-img --version
cloud-localds --help > "$evidence/cloud-localds-help.txt"
stage=official_image_download
image_url=https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img
image_sha256=6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2
printf 'outer_image_url=%s\nouter_image_expected_sha256=%s\n' "$image_url" "$image_sha256" > "$evidence/image-identity.txt"
curl --fail --location --connect-timeout 15 --max-time 180 --output "$work_dir/base.img" "$image_url"
printf '%s  %s\n' "$image_sha256" "$work_dir/base.img" | sha256sum --check | tee "$evidence/image-verification.txt"
qemu-img info --output=json "$work_dir/base.img" > "$evidence/image-info.json"
stage=guest_seed_preparation
qemu-img create -f qcow2 -F qcow2 -b "$work_dir/base.img" "$work_dir/guest.qcow2" 8G
{
  printf '#cloud-config\nwrite_files:\n'
  for guest_file in 2884-nested-kvm-run.c 2884-nested-guest.sh; do
    printf '  - path: /root/%s\n    owner: root:root\n    permissions: "0600"\n    encoding: b64\n    content: ' "$guest_file"
    base64 -w0 "support/diagnostics/$guest_file"
    printf '\n'
  done
  printf 'runcmd:\n  - [bash, /root/2884-nested-guest.sh]\n'
} > "$work_dir/user-data"
printf 'instance-id: issue2884-%s-%s\nlocal-hostname: issue2884-nested-guest\n' "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" > "$work_dir/meta-data"
cloud-localds "$work_dir/seed.img" "$work_dir/user-data" "$work_dir/meta-data"
sha256sum "$work_dir/user-data" "$work_dir/meta-data" "$work_dir/seed.img" > "$evidence/seed-sha256.txt"
stage=outer_kvm_guest_boot
printf 'outer_QEMU_resources=2vCPU,2048MiB,8GiB_sparse_overlay; accelerator=KVM_only; cpu=host; network=QEMU_user_NAT_no_host_forwarding\n'
set +e
# Scoped runner sudo: execute the maintained QEMU binary under its own timeout.
# No host device permissions, groups, services or KVM modules are changed.
sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 600s /usr/bin/qemu-system-x86_64 \
  -accel kvm -cpu host -smp 2 -m 2048 \
  -drive "file=$work_dir/guest.qcow2,format=qcow2,if=virtio" \
  -drive "file=$work_dir/seed.img,format=raw,if=virtio,readonly=on" \
  -nic user,model=virtio-net-pci -display none -monitor none \
  -serial "file:$evidence/guest-serial.txt" -no-reboot \
  > "$evidence/qemu.txt" 2>&1
qemu_status=$?
set -e
printf '%s\n' "$qemu_status" > "$evidence/qemu-exit.txt"
if [ -f "$evidence/guest-serial.txt" ]; then
  tr -d '\r' < "$evidence/guest-serial.txt" > "$evidence/guest-serial-normalized.txt"
fi
stage=serial_result_gate
if [ "$qemu_status" -ne 0 ]; then exit "$qemu_status"; fi
if ! grep -Fxq '2884_GUEST_FINAL stage=inner_kvm_run rc=0' "$evidence/guest-serial-normalized.txt"; then
  printf 'missing_successful_guest_final_marker; inspect_original_serial_for_exact_failed_layer\n'
  exit 3
fi
if ! grep -Fxq '2884_INNER_RESULT=PASS; KVM_RUN_IO_and_HLT_observed=true' "$evidence/guest-serial-normalized.txt"; then
  printf 'missing_inner_KVM_RUN_marker\n'
  exit 3
fi
printf '2884_NESTED_EXECUTION_RESULT=PASS; Windows_HyperV_WSL2_Docker_LocalSend_unverified=true\n'
