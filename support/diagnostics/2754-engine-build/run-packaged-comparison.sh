#!/usr/bin/env bash
# Cloud-only sequential normal-install comparisons; no shared test VM remains.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cloud_only
[[ $# == 4 ]] || { echo "Usage: $0 CONTROL_BUNDLE B_BUNDLE A_PACKAGE_CANDIDATE APP_RUN_ID" >&2; exit 2; }
control=$(realpath "$1")
candidate=$(realpath "$2")
package=$(realpath "$3")
app_run=$4
[[ $app_run =~ ^[0-9]+$ ]]
mkdir -p evidence/comparison
for artifact in "$control" "$candidate"; do
  (cd "$artifact" && sha256sum -c source-bundle.tar.gz.sha256)
  jq -e --arg run "$app_run" '.app_build_run_id == $run and .run_id == "38153341418" and
    .build_validation_status == "pass" and .localsend_sha == "c1ce322fb3acf08e44f329b8b7208b8b0d91e244"' "$artifact/provenance/manifest.json"
  jq -e '.compilation_completed and .validation_status == "pass"' "$artifact/provenance/bundle-validation.json"
  grep -qx 'flutter_exit_status=0' "$artifact/provenance/app-compilation-result.txt"
  grep -qx 'exit_status=0' "$artifact/provenance/build-result.txt"
done
jq -e '.variant == "control"' "$control/provenance/manifest.json"
jq -e '.variant == "B"' "$candidate/provenance/manifest.json"
(cd "$package" && sha256sum -c SHA256SUMS)
suite_status=0
for label in control-system B-system AB-package; do
  # Each variant receives a fresh Mint 22.2 live login with the same ISO and
  # UI actions. Keyboard off/on/off and File/Folder/Paste share its app PID.
  [[ ! -d evidence/cloud ]]
  rm -rf /tmp/issue2754-mint
  bundle=$candidate
  variant=B
  bridge=system
  delivery=diagnostic
  if [[ $label == control-system ]]; then bundle=$control; variant=control; fi
  if [[ $label == AB-package ]]; then bridge=A; delivery=package; fi
  mkdir -p evidence/cloud
  jq -n --arg label "$label" --arg app_run "$app_run" --arg variant "$variant" \
    --arg bridge "$bridge" --arg delivery "$delivery" \
    '{case:$label,app_run_id:$app_run,engine_variant:$variant,bridge_variant:$bridge,bridge_delivery:$delivery,
      session:"fresh Mint 22.2 Cinnamon login per variant; real controls share each app process"}' \
    > evidence/cloud/comparison-selection.json
  if PROBE_ENVIRONMENT=mint PROBE_APP_SOURCE=c1ce PROBE_BUNDLE_TAR="$bundle/source-bundle.tar.gz" \
     PROBE_ENGINE_VARIANT="$variant" PROBE_BUNDLE_RUN_ID="$app_run" PROBE_BRIDGE_VARIANT="$bridge" \
     PROBE_BRIDGE_DELIVERY="$delivery" PROBE_BRIDGE_PACKAGE_DIR="$package" PROBE_CAPTURE_GEOMETRY=1 \
     bash support/diagnostics/2754-mint-vm.sh; then
    status=0
  else
    status=$?
    suite_status=1
  fi
  sudo chown -R "$(id -u):$(id -g)" evidence/cloud
  printf 'scenario_exit_status=%s\n' "$status" > evidence/cloud/comparison-process-result.txt
  if grep -qx 'owned_vm_still_alive=true' evidence/cloud/vm-stop.log 2>/dev/null; then
    mv evidence/cloud "evidence/comparison/$label"
    echo 'Owned VM did not stop; remaining comparisons are not run.' >&2
    exit 1
  fi
  mv evidence/cloud "evidence/comparison/$label"
done
printf 'scenario_processes_exit_status=%s\ngeometry_and_ui_verdicts_require_raw_evidence_review=true\n' "$suite_status" \
  > evidence/comparison/result.txt
exit "$suite_status"
