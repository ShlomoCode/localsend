#!/usr/bin/env bash
# Workflow wraps this entire package/download/seed/admission stage in 840s.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]] || exit 2
OUT="${GITHUB_WORKSPACE:?}/evidence/1054-linux-kvm"
PRIVATE="${PRIVATE_DIR:?}"
[[ "$PRIVATE" == "${RUNNER_TEMP:?}/issue1054-linux-private" && ! -e "$PRIVATE" ]] || exit 2
BASE="${GITHUB_WORKSPACE}/support/diagnostics/1054-win10-install"
HOST="${GITHUB_WORKSPACE}/support/diagnostics/1054-linux-kvm"
mkdir -p "$OUT/firmware" "$OUT/install"
mkdir -m 700 "$PRIVATE"
exec > >(tee "$OUT/preparation.txt") 2>&1
PREPARATION_STARTED=$SECONDS
PREPARATION_EPOCH=$(date +%s)
export ISSUE1054_PREPARATION_EPOCH="$PREPARATION_EPOCH"
stage() { printf '%s\t%s\t%s\n' "$(date -u --iso-8601=seconds)" "$((SECONDS - PREPARATION_STARTED))" "$*" | tee -a "$OUT/stages.tsv"; }
remaining() { local value=$((840 - (SECONDS - PREPARATION_STARTED))); [[ "$value" -gt 0 ]] || return 2; printf '%s\n' "$value"; }
bounded() { /usr/bin/timeout --signal=TERM --kill-after=5s "$(remaining)s" "$@"; }
trap 'rc=$?; stage "preparation_exit=$rc"; exit "$rc"' EXIT
stage host_initialization
printf 'preparation_epoch=%s repository=%s head=%s run=%s attempt=%s runner=%s image=%s version=%s\n' "$PREPARATION_EPOCH" "$GITHUB_REPOSITORY" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$RUNNER_NAME" "${ImageOS:-unknown}" "${ImageVersion:-unknown}" > "$OUT/host-identity.txt"
uname -a >> "$OUT/host-identity.txt"
cat /etc/os-release >> "$OUT/host-identity.txt"
id >> "$OUT/host-identity.txt"
lscpu > "$OUT/lscpu.txt"
ls -l /dev/kvm > "$OUT/kvm-device.txt"
df -B1 "$PRIVATE" > "$OUT/disk-before.txt"
free -b > "$OUT/memory-before.txt"
cpu_vendor=$(awk -F: '/^vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)
free_bytes=$(df -B1 --output=avail "$PRIVATE" | tail -n 1 | tr -d ' ')
available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
printf 'cpu_vendor=%s cpus=%s disk_free_bytes=%s memory_available_kib=%s\n' "$cpu_vendor" "$(nproc)" "$free_bytes" "$available_kib" > "$OUT/resource-gate.txt"
[[ "$cpu_vendor" == AuthenticAMD && "$(nproc)" -ge 4 && "$free_bytes" -ge 85899345920 && "$available_kib" -ge 10485760 ]] || { stage resource_gate_failed; exit 2; }
stage distro_packages
bounded sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 180s apt-get update
bounded sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 240s env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils ruby genisoimage ffmpeg tesseract-ocr tesseract-ocr-eng xvfb xauth xdotool x11-utils openbox tigervnc-viewer gcc
packages=(qemu-system-x86 qemu-utils ruby genisoimage ffmpeg tesseract-ocr tesseract-ocr-eng xvfb xauth xdotool x11-utils openbox tigervnc-viewer gcc)
dpkg-query -W -f='${Package}\t${Version}\n' "${packages[@]}" > "$OUT/package-versions.txt"
qemu-system-x86_64 --version > "$OUT/qemu-version.txt"
qemu-img --version > "$OUT/qemu-img-version.txt"
[[ "$(head -n 1 "$OUT/qemu-version.txt")" == 'QEMU emulator version 8.2.2 '* && "$(head -n 1 "$OUT/qemu-img-version.txt")" == 'qemu-img version 8.2.2 '* ]] || { stage unselected_QEMU_version; exit 2; }
for tool in qemu-system-x86_64 qemu-img ruby genisoimage ffmpeg ffprobe tesseract Xvfb xvfb-run xauth xdotool xprop xwininfo openbox vncviewer gcc; do command -v "$tool"; done > "$OUT/tool-paths.txt"
gcc --version > "$OUT/compiler-version.txt"
ffmpeg -version > "$OUT/ffmpeg-version.txt"
tesseract --version > "$OUT/tesseract-version.txt" 2>&1
sha256sum /usr/share/seabios/bios-256k.bin /usr/share/qemu/vgabios-stdvga.bin > "$OUT/firmware-sha256.txt"
sha256sum "$HOST"/* "$BASE/Bootstrap.ps1" "$BASE/render-answer.rb" "$BASE/install.rb" "$BASE/qmp.rb" "$BASE/vnc.rb" > "$OUT/source-sha256.txt"
stage fresh_KVM_API_VM_vCPU_admission
bounded gcc -O2 -Wall -Wextra "$HOST/kvm-probe.c" -o "$PRIVATE/kvm-probe" > "$OUT/compiler.txt" 2>&1
probe_rc=0
bounded "$PRIVATE/kvm-probe" > "$OUT/kvm-unprivileged.txt" 2>&1 || probe_rc=$?
printf '%s\n' "$probe_rc" > "$OUT/kvm-unprivileged-exit.txt"
[[ "$probe_rc" == 0 || "$probe_rc" == 4 ]] || exit "$probe_rc"
bounded sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 15s "$PRIVATE/kvm-probe" > "$OUT/kvm-privileged.txt" 2>&1
stage fresh_firmware_input_capture_gate
EVIDENCE_DIR="$OUT/firmware" bounded /usr/bin/ruby "$HOST/firmware.rb" "$OUT/firmware" "$PRIVATE"
stage original_Windows_10_ISO
ISO="$PRIVATE/windows.iso"
URL='https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
printf 'url=%s\nbytes=5550497792\nsha256=ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668\n' "$URL" > "$OUT/iso-identity.txt"
curl --version > "$OUT/curl-version.txt"
curl --help all > "$OUT/curl-help.txt"
grep -q -- '--continue-at' "$OUT/curl-help.txt" || exit 2
complete=0
for attempt in 1 2 3; do
  allowance=$((720 - (SECONDS - PREPARATION_STARTED)))
  [[ "$allowance" -gt 0 ]] || exit 2
  before=0; [[ ! -f "$ISO" ]] || before=$(stat -c %s "$ISO")
  stage "iso_attempt=$attempt before_bytes=$before remaining_seconds=$allowance"
  rc=0
  curl --fail --location --connect-timeout 15 --continue-at - --retry 0 --max-time "$allowance" --dump-header "$OUT/iso-attempt-$attempt-headers.txt" --write-out '%{json}\n' "$URL" --output "$ISO" > "$OUT/iso-attempt-$attempt-transfer.json" || rc=$?
  after=0; [[ ! -f "$ISO" ]] || after=$(stat -c %s "$ISO")
  stage "iso_attempt=$attempt exit=$rc after_bytes=$after"
  if [[ "$rc" == 0 ]]; then complete=1; break; fi
  case "$rc" in 18|28|52|55|56) ;; *) exit "$rc" ;; esac
  [[ "$after" -gt "$before" && "$after" -lt 5550497792 ]] || exit "$rc"
done
[[ "$complete" == 1 && "$(stat -c %s "$ISO")" == 5550497792 ]] || exit 2
printf '%s  %s\n' ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668 "$ISO" | bounded sha256sum --check > "$OUT/iso-verification.txt"
stage private_seed_and_disk
mkdir -m 700 "$PRIVATE/seed"
bounded curl --fail --location --connect-timeout 15 --retry 0 --max-time 90 'https://github.com/localsend/localsend/releases/download/v1.15.3/LocalSend-1.15.3-windows-x86-64.exe' --output "$PRIVATE/seed/LocalSend-1.15.3-windows-x86-64.exe"
[[ "$(stat -c %s "$PRIVATE/seed/LocalSend-1.15.3-windows-x86-64.exe")" == 12788472 ]] || exit 2
sha256sum "$PRIVATE/seed/LocalSend-1.15.3-windows-x86-64.exe" | awk '{print $1}' > "$OUT/installer-download.sha256"
cp "$BASE/Bootstrap.ps1" "$PRIVATE/seed/Bootstrap.ps1"
bounded /usr/bin/ruby "$BASE/render-answer.rb" "$PRIVATE/seed/Autounattend.xml"
bounded genisoimage -J -r -o "$PRIVATE/seed.iso" "$PRIVATE/seed" > "$OUT/seed-build.txt" 2>&1
bounded qemu-img create -f qcow2 "$PRIVATE/windows.qcow2" 64G > "$OUT/disk-create.txt"
qemu-img info --output=json "$PRIVATE/windows.qcow2" > "$OUT/disk-info.json"
remaining > "$OUT/preparation-remaining-seconds.txt"
stage preparation_ready
