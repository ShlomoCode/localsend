#!/bin/bash
# Cloud-only normal Windows 24H2 setup and actual WSL2 capability gate.
set -euo pipefail
evidence="$GITHUB_WORKSPACE/evidence/2884-windows-wsl"
mkdir -p "$evidence"
exec > >(tee "$evidence/host-driver.txt") 2>&1
stage=host_initialization
work_dir=$(mktemp -d /tmp/2884-windows-wsl.XXXXXXXX)
bridge_pid=''
tpm_pid=''
cleanup() {
  status=$?
  printf '2884_WINDOWS_HOST_FINAL stage=%s rc=%s\n' "$stage" "$status"
  for owned_pid in "$bridge_pid" "$tpm_pid"; do
    if [ -n "$owned_pid" ]; then kill "$owned_pid" 2>/dev/null || true; fi
  done
  for cleanup_attempt in $(seq 1 5); do
    any_owned_alive=false
    for owned_pid in "$bridge_pid" "$tpm_pid"; do
      if [ -n "$owned_pid" ] && kill -0 "$owned_pid" 2>/dev/null; then any_owned_alive=true; fi
    done
    if [ "$any_owned_alive" = false ]; then break; fi
    sleep 1
  done
  for owned_pid in "$bridge_pid" "$tpm_pid"; do
    if [ -n "$owned_pid" ]; then kill -KILL "$owned_pid" 2>/dev/null || true; wait "$owned_pid" 2>/dev/null || true; fi
  done
  # Read-only guestfs collection may create root-owned private appliance files.
  # This exact directory was created by this driver; bound its final cleanup.
  sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=2s 15s /bin/rm -rf -- "$work_dir" || true
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
sha256sum support/diagnostics/2884-windows-{host.sh,bridge.cjs,unattend.xml,wsl.ps1,cpuid.c,recovery.sh,iso-download.sh} .github/workflows/diagnose-2884-windows-wsl.yml > "$evidence/source-sha256.txt"
stage=host_cpu_resource_gate
cpu_vendor=$(awk -F: '/^vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)
free_bytes=$(df -B1 --output=avail "$work_dir" | tail -n 1 | tr -d ' ')
available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
if [ "$cpu_vendor" != AuthenticAMD ] || [ "$free_bytes" -lt 85899345920 ] || [ "$available_kib" -lt 10485760 ] || [ "$(nproc)" -lt 4 ]; then
  printf 'specific_host_route_gate_failed vendor=%s disk_free=%s memory_available_kib=%s CPUs=%s\n' "$cpu_vendor" "$free_bytes" "$available_kib" "$(nproc)"
  exit 2
fi
for local_port in 8765 8766; do
  if [ -n "$(ss -H -ltn "sport = :$local_port")" ]; then printf 'owned_route_port_already_used=%s\n' "$local_port"; exit 2; fi
done
stage=host_tool_install
sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 180s apt-get update
sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 180s env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils ovmf swtpm genisoimage p7zip-full wimtools xmlstarlet gettext-base ffmpeg gcc-mingw-w64-x86-64-win32 guestfish linux-image-generic
qemu-system-x86_64 --version
qemu-img --version
swtpm --version
node --version
stage=firmware_source_gate
firmware_code=/usr/share/OVMF/OVMF_CODE_4M.ms.fd
firmware_vars=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
test -r "$firmware_code"
test -r "$firmware_vars"
cp "$firmware_vars" "$work_dir/OVMF_VARS.fd"
sha256sum "$firmware_code" "$firmware_vars" > "$evidence/firmware-source-sha256.txt"
cp /usr/share/qemu/firmware/40-edk2-x86_64-secure-enrolled.json "$evidence/firmware-definition.json"
stage=official_media_download
mkdir -p "$work_dir/payload"
stage=native_cpuid_helper_build
x86_64-w64-mingw32-gcc --version > "$evidence/cpuid-compiler.txt"
timeout --signal=TERM --kill-after=5s 30s x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror support/diagnostics/2884-windows-cpuid.c -o "$work_dir/payload/cpuid.exe"
sha256sum "$work_dir/payload/cpuid.exe" > "$evidence/cpuid-helper-sha256.txt"
cpuid_sha=$(sha256sum "$work_dir/payload/cpuid.exe" | cut -d ' ' -f 1)
stage=official_media_download
iso_url=https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso
wsl_url=https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi
wsl_sha=28b1a0d013640a2ac95898ea705fa186e5b4ff767a1c1b49257161bc106599c6
ubuntu_url=https://releases.ubuntu.com/24.04.5/ubuntu-24.04.5-wsl-amd64.wsl
ubuntu_sha=bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e
printf 'windows_iso_url=%s\nwindows_iso_expected_length=5387960320\nwindows_iso_publisher_sha256=unavailable_record_actual_hash_without_claiming_publisher_checksum\nwsl_url=%s\nwsl_sha256=%s\nubuntu_url=%s\nubuntu_sha256=%s\n' "$iso_url" "$wsl_url" "$wsl_sha" "$ubuntu_url" "$ubuntu_sha" > "$evidence/media-identity.txt"
timeout --signal=TERM --kill-after=5s 600s /bin/bash support/diagnostics/2884-windows-iso-download.sh "$iso_url" "$work_dir/windows.iso" "$evidence"
if [ "$(stat -c %s "$work_dir/windows.iso")" -ne 5387960320 ]; then printf 'official_windows_iso_length_mismatch\n'; exit 2; fi
sha256sum "$work_dir/windows.iso" > "$evidence/windows-iso-actual-sha256.txt"
# This is the previously observed complete official object, not a publisher digest.
printf '%s  %s\n' '755a90d43e826a74b9e1932a34788b898e028272439b777e5593dee8d53622ae' "$work_dir/windows.iso" | sha256sum --check > "$evidence/windows-iso-prior-object-verification.txt"
curl --fail --location --connect-timeout 15 --max-time 180 --output "$work_dir/payload/wsl.msi" "$wsl_url"
printf '%s  %s\n' "$wsl_sha" "$work_dir/payload/wsl.msi" | sha256sum --check > "$evidence/wsl-installer-verification.txt"
curl --fail --location --connect-timeout 15 --max-time 180 --output "$work_dir/payload/ubuntu.wsl" "$ubuntu_url"
printf '%s  %s\n' "$ubuntu_sha" "$work_dir/payload/ubuntu.wsl" | sha256sum --check > "$evidence/ubuntu-wsl-verification.txt"
stage=windows_image_identity_gate
7z x -y "-o$work_dir/iso-metadata" "$work_dir/windows.iso" sources/install.wim > "$evidence/iso-metadata-extraction.txt"
wimlib-imagex info "$work_dir/iso-metadata/sources/install.wim" --xml > "$evidence/install-wim.xml"
image_count=$(xmlstarlet sel -t -v "count(/WIM/IMAGE[WINDOWS/EDITIONID='EnterpriseEval' and WINDOWS/VERSION/BUILD='26100' and WINDOWS/ARCH='9'])" "$evidence/install-wim.xml")
if [ "$image_count" != 1 ]; then printf 'expected_single_24H2_EnterpriseEval_x64_image count=%s\n' "$image_count"; exit 2; fi
WIN_IMAGE_INDEX=$(xmlstarlet sel -t -v "/WIM/IMAGE[WINDOWS/EDITIONID='EnterpriseEval']/@INDEX" "$evidence/install-wim.xml")
export WIN_IMAGE_INDEX
stage=normal_unattended_seed
WIN_LOCAL_PASSWORD=$(openssl rand -hex 20)
export WIN_LOCAL_PASSWORD
bridge_token=$(openssl rand -hex 32)
mkdir -p "$work_dir/seed" "$work_dir/tpm"
# Secrets are used only in the temporary seed/config, never artifacts or argv.
WIN_BRIDGE_TOKEN="$bridge_token" WIN_WSL_SHA="$wsl_sha" WIN_UBUNTU_SHA="$ubuntu_sha" WIN_CPUID_SHA="$cpuid_sha" node - "$work_dir/config.json" <<'JS'
const fs = require('node:fs');
fs.writeFileSync(process.argv[2], JSON.stringify({ bridgeUrl: 'http://10.0.2.2:8765',
  bearerToken: process.env.WIN_BRIDGE_TOKEN, localPassword: process.env.WIN_LOCAL_PASSWORD,
  wslSha256: process.env.WIN_WSL_SHA, ubuntuSha256: process.env.WIN_UBUNTU_SHA,
  cpuidSha256: process.env.WIN_CPUID_SHA }));
JS
envsubst '${WIN_IMAGE_INDEX} ${WIN_LOCAL_PASSWORD}' < support/diagnostics/2884-windows-unattend.xml > "$work_dir/seed/autounattend.xml"
cp "$work_dir/config.json" "$work_dir/seed/config.json"
cp support/diagnostics/2884-windows-wsl.ps1 "$work_dir/seed/2884-windows-wsl.ps1"
unset WIN_LOCAL_PASSWORD
genisoimage -quiet -J -r -V ISSUE2884 -o "$work_dir/seed.iso" "$work_dir/seed"
sha256sum "$work_dir/seed.iso" > "$evidence/seed-identity.txt"
qemu-img create -f qcow2 "$work_dir/windows.qcow2" 64G
stage=owned_tpm_and_bridge_start
swtpm socket --tpmstate "dir=$work_dir/tpm" --ctrl "type=unixio,path=$work_dir/tpm/socket" --tpm2 --log "file=$evidence/tpm.txt,level=1" > "$evidence/swtpm.txt" 2>&1 &
tpm_pid=$!
node support/diagnostics/2884-windows-bridge.cjs "$work_dir" "$evidence" > "$evidence/bridge-process.txt" 2>&1 &
bridge_pid=$!
for readiness_attempt in $(seq 1 10); do
  if [ -S "$work_dir/tpm/socket" ] && [ -f "$work_dir/bridge-ready" ]; then break; fi
  sleep 1
done
test -S "$work_dir/tpm/socket"
test -f "$work_dir/bridge-ready"
stage=normal_windows_setup_and_wsl2_guest
printf 'QEMU=KVM_only,q35_SMM_on,host_AMD_CPU,4vCPU,8192MiB,64GiB_disk,Microsoft_enrolled_SecureBoot_OVMF,TPM2_swtpm,SATA_disk_and_DVD,e1000_userNAT_no_forwarding\n'
set +e
sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=10s 2400s /usr/bin/qemu-system-x86_64 \
  -accel kvm -machine q35,smm=on \
  -cpu host,hv-relaxed,hv-vapic,hv-spinlocks=0xfff,hv-vpindex,hv-runtime,hv-synic,hv-stimer,hv-stimer-direct,hv-time,hv-frequencies,hv-tlbflush,hv-ipi \
  -smp 4 -m 8192 -global driver=cfi.pflash01,property=secure,value=on \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$firmware_code" \
  -drive "if=pflash,format=raw,unit=1,file=$work_dir/OVMF_VARS.fd" \
  -chardev "socket,id=chrtpm,path=$work_dir/tpm/socket" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -drive "if=none,id=systemdisk,format=qcow2,file=$work_dir/windows.qcow2" -device ide-hd,drive=systemdisk,bus=ide.0,bootindex=2 \
  -drive "if=none,id=windowsdvd,format=raw,media=cdrom,readonly=on,file=$work_dir/windows.iso" -device ide-cd,drive=windowsdvd,bus=ide.1,bootindex=1 \
  -drive "if=none,id=seeddvd,format=raw,media=cdrom,readonly=on,file=$work_dir/seed.iso" -device ide-cd,drive=seeddvd,bus=ide.2 \
  -nic user,model=e1000 -vga std -display none -monitor none \
  -serial "file:$evidence/windows-serial.txt" -qmp tcp:127.0.0.1:8766,server=on,wait=off \
  > "$evidence/qemu.txt" 2>&1
qemu_status=$?
set -e
printf '%s\n' "$qemu_status" > "$evidence/qemu-exit.txt"
if [ -f "$evidence/recovery-observed.json" ] || [ "$qemu_status" -ne 0 ] || [ ! -f "$evidence/wsl-proof.json" ]; then
  stage=bounded_readonly_boot_recovery
  set +e
  sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 240s /bin/bash support/diagnostics/2884-windows-recovery.sh "$work_dir" "$evidence"
  recovery_status=$?
  set -e
  printf '%s\n' "$recovery_status" > "$evidence/recovery-exit.txt"
fi
stage=actual_windows_wsl2_result_gate
if [ "$qemu_status" -ne 0 ]; then exit "$qemu_status"; fi
if [ -f "$evidence/recovery-observed.json" ]; then printf 'native_AutomaticRepair_observed_and_retained\n'; exit 2; fi
node - "$evidence" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
for (const name of ['result.json', 'windows-identity.json', 'firmware.json', 'ordinary-reboot-control.json', 'capability-initial.json', 'capability-ordinary.json', 'wsl-proof.json']) {
  if (!fs.existsSync(path.join(dir, name))) throw new Error(`Missing exact Windows capability evidence: ${name}`);
}
const result = JSON.parse(fs.readFileSync(path.join(dir, 'result.json'), 'utf8'));
if (result.status !== 'PASS' || result.stage !== 'actual_wsl2_execution') throw new Error(`Windows stage result: ${JSON.stringify(result)}`);
const read = (name) => JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
const proof = read('wsl-proof.json');
const windows = read('windows-identity.json');
const firmware = read('firmware.json');
const execution = read('wsl-command.txt');
const version = read('wsl-version.txt');
const list = read('wsl-list.txt');
const requireGate = (condition, gate) => { if (!condition) throw new Error(`Actual Windows capability gate failed: ${gate}`); };
requireGate(windows.build === '26100' && windows.displayVersion === '24H2' && windows.edition === 'EnterpriseEval' &&
  windows.architecture === 'AMD64' && windows.sessionId > 0, 'native_Windows_24H2_x64_interactive_identity');
requireGate(firmware.secureBoot === true && firmware.tpmPresent === true && firmware.tpmReady === true &&
  /(^|,\s*)2\.0(,|$)/.test(firmware.tpmSpecVersion), 'native_SecureBoot_TPM2');
requireGate(proof.stage === 'actual_wsl2_execution' && proof.distribution === 'Issue2884Ubuntu' &&
  proof.distributionVersion === 2 && proof.wslVersion === '3.0.1.0', 'WSL_distribution_identity');
requireGate(proof.wslMsiSha256 === '28b1a0d013640a2ac95898ea705fa186e5b4ff767a1c1b49257161bc106599c6' &&
  proof.ubuntuPayloadSha256 === 'bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e' &&
  proof.wslMsiSignatureStatus === 'Valid' && /(^|,\s*)O=Microsoft Corporation(,|$)/.test(proof.wslMsiSigner), 'official_payload_identity');
const featureNames = ['VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux'];
requireGate(Array.isArray(proof.featureStates) && proof.featureStates.length === 3 && featureNames.every((name) =>
  proof.featureStates.filter((entry) => entry.name === name && entry.state === 'Enabled').length === 1) &&
  proof.featureStates.filter((entry) => entry.name === 'Microsoft-Hyper-V-All' && entry.state === 'Disabled').length === 1, 'supported_WSL_feature_pair_without_full_role');
const cpuidHash = fs.readFileSync(path.join(dir, 'cpuid-helper-sha256.txt'), 'utf8').trim().split(/\s+/)[0];
const initial = read('capability-initial.json');
const ordinary = read('capability-ordinary.json');
const control = read('ordinary-reboot-control.json');
requireGate(/^[a-f0-9]{64}$/.test(cpuidHash) && [initial, ordinary, proof].every((entry) =>
  entry.cpuidExecutableSha256 === cpuidHash && entry.cpuid.schemaVersion === 1 && entry.cpuid.cpuidAvailable === true &&
  entry.cpuid.cpuVendor === 'AuthenticAMD' && Array.isArray(entry.cpuid.rawLeaves) && entry.cpuid.rawLeaves.length >= 4) &&
  [initial, ordinary].every((entry) => entry.cpuid.flags.svm === true && entry.cpuid.flags.npt === true), 'pre_feature_native_Windows_CPUID_qualification');
requireGate(control.status === 'PASS' && control.stage === 'ordinary_reboot_control' &&
  control.beforeBootUtc === initial.lastBootUtc && control.afterBootUtc === ordinary.lastBootUtc &&
  control.beforeBootUtc !== control.afterBootUtc && Array.isArray(control.featureStates) && control.featureStates.length === 3 &&
  control.featureStates.every((entry) => entry.state === 'Disabled'), 'ordinary_feature_free_reboot');
requireGate([proof, execution, version, list].every((entry) => entry.exitCode === 0 && entry.timedOut === false), 'actual_native_exit_statuses');
requireGate(/^WSL version:\s*3\.0\.1\.0\s*$/m.test(version.stdout) &&
  /^\s*\*?\s*Issue2884Ubuntu\s+\S+\s+2\s*$/m.test(list.stdout), 'native_WSL_version_and_list');
requireGate(proof.linuxOutput === execution.stdout && proof.markerMatched === true && proof.kernelMatched === true &&
  proof.procVersionMatched === true && proof.ubuntuIdentityMatched === true, 'consistent_actual_Linux_output');
requireGate(/^ISSUE2884_ACTUAL_WSL2_EXECUTION\s*$/m.test(execution.stdout) &&
  /^\S*microsoft-standard-WSL2\S*\s*$/im.test(execution.stdout) && /^Linux version .*microsoft.*WSL2/im.test(execution.stdout) &&
  /^ID=ubuntu\s*$/m.test(execution.stdout) && /^VERSION_ID="24\.04"\s*$/m.test(execution.stdout), 'actual_WSL2_kernel_command');
console.log('2884_WINDOWS_INFRASTRUCTURE_RESULT=PASS; Docker_and_LocalSend_unverified=true');
JS
