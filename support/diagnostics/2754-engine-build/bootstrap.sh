#!/usr/bin/env bash
# Resource/dependency gate only; no compilation or app execution.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 1 ]] || { echo "Usage: $0 OUTPUT_DIR" >&2; exit 2; }
start_stage "$1"
engine_root=$(temporary_path "${PROBE_ENGINE_ROOT:-$RUNNER_TEMP/issue2754-engine-source}")
depot_root=$(temporary_path "${PROBE_DEPOT_ROOT:-$RUNNER_TEMP/issue2754-depot-tools}")
minimum_kib=${PROBE_ENGINE_MIN_FREE_KIB:-52428800}
[[ $minimum_kib =~ ^[0-9]+$ && $minimum_kib -ge 52428800 ]]

# These are disposable SDK paths on a fresh GitHub-hosted runner, never a user checkout.
if [[ ${PROBE_RECLAIM_RUNNER_SDKS:-0} == 1 ]]; then
  for path in /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL; do
    [[ ! -L $path ]] || { echo "Refusing SDK symlink: $path" >&2; exit 2; }
    if [[ -d $path ]]; then
      sudo du -sk "$path" | tee -a "$output/reclaimed-sdk-paths.txt"
      sudo rm -rf -- "$path"
    fi
  done
fi
resources after-optional-sdk-reclaim
free_kib=$(df -Pk "$RUNNER_TEMP" | awk 'NR==2 {print $4}')
printf 'free_kib=%s\nminimum_kib=%s\n' "$free_kib" "$minimum_kib" > "$output/resource-gate.txt"
if (( free_kib < minimum_kib )); then
  echo 'RESOURCE_GATE_FAILED: full engine bootstrap needs the configured free-space budget.'
  exit 3
fi
memory_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
printf 'memory_kib=%s\n' "$memory_kib" >> "$output/resource-gate.txt"
(( memory_kib >= 15000000 )) || { echo 'RESOURCE_GATE_FAILED: expected public-runner memory budget.'; exit 3; }

sudo apt-get update
sudo apt-get install -y git curl xz-utils unzip zip python3 pkg-config libgtk-3-dev \
  libglu1-mesa-dev libegl1-mesa-dev libgl1-mesa-dev jq binutils file xvfb xauth clang cmake \
  libayatana-appindicator3-dev
clone_exact https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_SHA" "$depot_root"
clone_exact https://github.com/flutter/flutter.git "$ENGINE_SHA" "$engine_root"
export PATH="$depot_root:$PATH" DEPOT_TOOLS_UPDATE=0
printf '%s  %s\n' "$DEPS_SHA256" "$engine_root/DEPS" | sha256sum -c -
cp "$engine_root/engine/scripts/standard.gclient" "$output/standard.gclient"
cat > "$engine_root/.gclient" <<'GCLIENT'
solutions = [{
  "name": ".",
  "url": "https://github.com/flutter/flutter.git",
  "managed": False,
  "deps_file": "DEPS",
  "safesync_url": "",
  "custom_deps": {},
  "custom_vars": {
    "download_android_deps": False,
    "download_fuchsia_deps": False,
    "download_windows_deps": False,
    "download_emsdk": False,
    "download_jdk": False,
    "download_linux_deps": True,
    "download_dart_sdk": True,
    "use_rbe": False,
  },
}]
GCLIENT
cp "$engine_root/.gclient" "$output/actual.gclient"
cp "$engine_root/DEPS" "$output/DEPS"
resources before-sync
(cd "$engine_root" && timeout 1500 gclient sync --no-history --jobs=2) 2>&1 | tee "$output/gclient-sync.log"
resources after-sync
[[ $(git -C "$engine_root" rev-parse HEAD) == "$ENGINE_SHA" ]]
printf '%s  %s\n' "$DEPS_SHA256" "$engine_root/DEPS" | sha256sum -c -
git -C "$engine_root" diff --exit-code HEAD --
git -C "$engine_root" status --porcelain=v1 --untracked-files=all > "$output/source-status.txt"
(cd "$engine_root" && gclient revinfo -a) > "$output/gclient-revinfo.txt"
# Retain resolved CIPD metadata, which contains instance IDs rather than mutable tags.
find "$engine_root" -type d -name .cipd -prune -print0 | sort -z | \
  while IFS= read -r -d '' entry; do
    printf '\nROOT %s\n' "${entry#"$engine_root/"}"
    cipd installed -root "${entry%/.cipd}"
  done > "$output/cipd-resolved-packages.txt"
[[ -s "$output/cipd-resolved-packages.txt" ]]
{
  python3 --version
  "$engine_root/engine/src/flutter/buildtools/linux-x64/clang/bin/clang++" --version
  "$engine_root/engine/src/flutter/third_party/gn/gn" --version
  "$engine_root/third_party/ninja/ninja" --version
  "$engine_root/engine/src/flutter/prebuilts/linux-x64/dart-sdk/bin/dart" --version
  cipd version
} > "$output/toolchain-versions.txt" 2>&1
cp "$engine_root/engine/src/build/linux/sysroot_scripts/sysroots.json" "$output/sysroots.json"
sha256sum "$engine_root/engine/src/flutter/buildtools/linux-x64/clang/bin/clang++" \
  "$engine_root/engine/src/flutter/third_party/gn/gn" "$engine_root/third_party/ninja/ninja" \
  > "$output/toolchain-SHA256SUMS"
du -sk "$engine_root" "$depot_root" > "$output/source-disk-usage.txt"
resources bootstrap-complete
manifest bootstrap "$output/manifest.json"
bootstrap_provenance="$engine_root/issue2754-bootstrap-provenance"
mkdir -p "$bootstrap_provenance"
# Snapshot completed records so later build jobs can transport them with each variant.
# Do not hash the live stage.log/resources.txt, which the exit trap still appends to.
for record in standard.gclient actual.gclient DEPS source-status.txt gclient-sync.log \
  gclient-revinfo.txt cipd-resolved-packages.txt toolchain-versions.txt toolchain-SHA256SUMS \
  sysroots.json source-disk-usage.txt resource-gate.txt manifest.json; do
  cp "$output/$record" "$bootstrap_provenance/"
done
(cd "$bootstrap_provenance" && find . -maxdepth 1 -type f ! -name records-SHA256SUMS -print0 | \
  sort -z | xargs -0 sha256sum > records-SHA256SUMS)
cp -a "$bootstrap_provenance" "$output/bootstrap-provenance"
date -u +%FT%TZ > "$engine_root/issue2754-bootstrap-complete"
printf '%s\n' "$engine_root" > "$output/engine-root.txt"
