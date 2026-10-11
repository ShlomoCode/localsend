#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 2
task_root="$GITHUB_WORKSPACE"
mkdir -p "$task_root/evidence"
for variant in baseline candidate; do
  scratch="/tmp/issue1054-comparison-$variant"
  mkdir -p "$scratch"
  cp -a "$task_root/support" "$scratch/"
  cp -a "$task_root/source-evidence/$variant" "$scratch/source-artifact"
  # Owned profiles and receive directory only; each comparison starts fresh.
  rm -rf /tmp/Receiver /tmp/Sender /tmp/issue1054-received
  status=0
  (cd "$scratch" && ISSUE1054_CONTROLLED_VARIANT="$variant" bash support/diagnostics/1054-linux.sh) || status=$?
  if [[ -d $scratch/evidence ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$scratch/evidence"
    mv "$scratch/evidence" "$task_root/evidence/$variant"
  fi
  [[ $status == 0 ]] || exit "$status"
done
