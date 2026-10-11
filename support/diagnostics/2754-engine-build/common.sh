#!/usr/bin/env bash
# Shared mechanics for cloud-only engine diagnostics.
set -euo pipefail
ENGINE_SHA=42d3d75a56efe1a2e9902f52dc8006099c45d937
FRAMEWORK_SHA=00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
LOCALSEND_SHA=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
DEPOT_SHA=a03dfbf7f2d1cefa2795d81d59ca4f16c8616a8f
DEPS_SHA256=0d0b2b9c4b103613bb242635328497bc8a47d64f31309f2dfa93e66abb20d4f3
assets=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cloud_only() {
  [[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
  [[ ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]]
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]
  . /etc/os-release
  [[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
}

temporary_path() {
  local resolved
  resolved=$(realpath -m "$1")
  case "$resolved" in
    "$(realpath "$RUNNER_TEMP")"/*) printf '%s\n' "$resolved" ;;
    *) echo "Refusing a source/build path outside RUNNER_TEMP: $resolved" >&2; return 2 ;;
  esac
}

start_stage() {
  cloud_only
  mkdir -p "$1"
  output=$(realpath "$1")
  [[ ! -e "$output/stage-started" ]]
  date -u +%FT%TZ > "$output/stage-started"
  exec > >(tee "$output/stage.log") 2>&1
  trap finish_stage EXIT
  resources start
}

finish_stage() {
  local status=$?
  trap - EXIT
  set +e
  if [[ -d ${engine_root:-}/.git ]]; then
    git -C "$engine_root" diff --binary HEAD -- > "$output/engine-source-after.patch"
    git -C "$engine_root" status --porcelain=v1 > "$output/engine-source-after-status.txt"
  fi
  if [[ -d ${app_source:-}/.git ]]; then
    mkdir -p "$output/provenance"
    git -C "$app_source" diff --binary HEAD -- > "$output/provenance/source-diff-after.patch"
    git -C "$app_source" status --porcelain=v1 > "$output/provenance/source-status-after.txt"
    (cd "$app_source" && sha256sum pubspec.lock Cargo.lock \
      packages/localsend_isolates/rust_builder/cargokit/build_tool/pubspec.lock) \
      > "$output/provenance/lock-hashes-after.txt"
    if [[ -f "$output/provenance/lock-hashes-before.txt" ]]; then
      cmp -s "$output/provenance/lock-hashes-before.txt" "$output/provenance/lock-hashes-after.txt" || status=1
    fi
    git -C "$app_source" diff --quiet HEAD -- || status=1
    printf 'exit_status=%s\n' "$status" > "$output/provenance/build-result.txt"
  fi
  printf 'exit_status=%s\ncompleted_at=%s\n' "$status" "$(date -u +%FT%TZ)" > "$output/stage-result.txt"
  resources exit
  exit "$status"
}

resources() {
  {
    printf '\nPHASE %s %s\n' "$1" "$(date -u +%FT%TZ)"
    free -m
    df -Pk "$RUNNER_TEMP" "$GITHUB_WORKSPACE"
    if [[ -d ${engine_root:-}/engine/src/out ]]; then du -sk "$engine_root/engine/src/out"; fi
  } >> "$output/resources.txt" 2>&1
}

clone_exact() {
  local url=$1 revision=$2 destination=$3
  [[ ! -e "$destination" ]]
  mkdir -p "$destination"
  git -C "$destination" init
  git -C "$destination" remote add origin "$url"
  git -C "$destination" fetch --depth=1 origin "$revision"
  git -C "$destination" checkout --detach FETCH_HEAD
  [[ $(git -C "$destination" rev-parse HEAD) == "$revision" ]]
  [[ -z $(git -C "$destination" status --porcelain=v1) ]]
}

engine_environment() {
  engine_root=$(temporary_path "${PROBE_ENGINE_ROOT:-$RUNNER_TEMP/issue2754-engine-source}")
  depot_root=$(temporary_path "${PROBE_DEPOT_ROOT:-$RUNNER_TEMP/issue2754-depot-tools}")
  export DEPOT_TOOLS_UPDATE=0
  export PATH="$depot_root:$PATH"
  [[ $(git -C "$engine_root" rev-parse HEAD) == "$ENGINE_SHA" ]]
  [[ $(git -C "$depot_root" rev-parse HEAD) == "$DEPOT_SHA" ]]
  printf '%s  %s\n' "$DEPS_SHA256" "$engine_root/DEPS" | sha256sum -c -
  [[ -f "$engine_root/issue2754-bootstrap-complete" ]]
  bootstrap_provenance="$engine_root/issue2754-bootstrap-provenance"
  for record in gclient-revinfo.txt cipd-resolved-packages.txt toolchain-versions.txt toolchain-SHA256SUMS records-SHA256SUMS; do
    [[ -s "$bootstrap_provenance/$record" ]]
  done
  (cd "$bootstrap_provenance" && sha256sum -c records-SHA256SUMS)
  sha256sum -c "$bootstrap_provenance/toolchain-SHA256SUMS"
  ninja="$engine_root/third_party/ninja/ninja"
  gn="$engine_root/engine/src/flutter/third_party/gn/gn"
  [[ -x $ninja && -x $gn ]]
}

manifest() {
  local variant=$1 destination=$2
  jq -n --arg variant "$variant" --arg engine "$ENGINE_SHA" --arg framework "$FRAMEWORK_SHA" \
    --arg source "$LOCALSEND_SHA" --arg depot "$DEPOT_SHA" --arg deps "$DEPS_SHA256" \
    --arg run_id "$GITHUB_RUN_ID" --arg run_url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
    '{variant:$variant,engine_sha:$engine,framework_sha:$framework,localsend_sha:$source,
      depot_tools_sha:$depot,deps_sha256:$deps,run_id:$run_id,run_url:$run_url,
      runtime_mode:"release",gn_flags:["--runtime-mode","release","--enable-fontconfig",
        "--prebuilt-dart-sdk","--no-lto","--no-enable-unittests"],
      note:"Diagnostic source build. Loaded engine identity and UI behavior require the guest gate."}' \
    > "$destination"
}
