#!/usr/bin/env bash
# Run only in the same fork Actions job after the measured capability gates.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]] || exit 2
BASE="$(cd "$(dirname "$0")" && pwd)"
OUT="${EVIDENCE_DIR:?Separate allowlisted evidence directory required}"
CAP="${CAPABILITY_DIR:?Original capability evidence required}"
ISO="${WINDOWS_ISO:?Verified original Microsoft ISO path required}"
[[ ${EVALUATION_TERMS_ACCEPTED:-} == true ]] || { echo 'Evaluation terms must be accepted before installation'; exit 2; }
[[ -f "$CAP/hvf-status.json" && -f "$CAP/frame-results.json" ]] || exit 2
# Require the already initialized HVF route. Do not spend an install on unmeasured TCG.
[[ "$(head -n 1 "$CAP/acceleration.txt")" == hvf ]] || exit 2
mkdir -p "$OUT"
FREE_KB="$(df -k "$OUT" | awk 'END {print $4}')"
df -k "$OUT" > "$OUT/disk-install-before.txt"
[[ "$FREE_KB" -ge 36700160 ]] || { echo 'Installation requires 35 GiB remaining free'; exit 1; }
printf '%s  %s\n' 'ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668' "$ISO" | shasum -a 256 -c - > "$OUT/iso-verification.txt"
[[ "$(stat -f '%z' "$ISO")" == 5550497792 ]] || exit 1
PRIVATE="$(mktemp -d "${RUNNER_TEMP:?}/issue1054-private.XXXXXX")"
chmod 700 "$PRIVATE"
trap 'rm -rf "$PRIVATE"' EXIT
mkdir "$PRIVATE/seed"
curl --fail --location --retry 2 --max-time 120 \
  'https://github.com/localsend/localsend/releases/download/v1.15.3/LocalSend-1.15.3-windows-x86-64.exe' \
  --output "$PRIVATE/seed/LocalSend-1.15.3-windows-x86-64.exe"
[[ "$(stat -f '%z' "$PRIVATE/seed/LocalSend-1.15.3-windows-x86-64.exe")" == 12788472 ]] || exit 1
shasum -a 256 "$PRIVATE/seed/LocalSend-1.15.3-windows-x86-64.exe" | awk '{print $1}' > "$OUT/installer-download.sha256"
cp "$BASE/Bootstrap.ps1" "$PRIVATE/seed/Bootstrap.ps1"
/usr/bin/ruby "$BASE/render-answer.rb" "$PRIVATE/seed/Autounattend.xml"
# Read-only auxiliary media is in Microsoft's implicit answer-file search order.
hdiutil makehybrid -iso -joliet -o "$PRIVATE/seed.iso" "$PRIVATE/seed" > "$OUT/seed-build.txt" 2>&1
qemu-img create -f qcow2 "$PRIVATE/windows.qcow2" 64G > "$OUT/disk-create.txt"
/usr/bin/ruby "$BASE/install.rb" "$OUT" "$PRIVATE" "$ISO"
df -k "$OUT" > "$OUT/disk-install-after.txt"
