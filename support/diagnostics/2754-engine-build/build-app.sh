#!/usr/bin/env bash
# Build unmodified c1ce against one verified source-built local engine artifact.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 2 ]] || { echo "Usage: $0 ENGINE_VARIANT_ARTIFACT_DIR OUTPUT_DIR" >&2; exit 2; }
variant_artifact=$(realpath "$1")
start_stage "$2"
[[ ${PROBE_VARIANT:-} == control || ${PROBE_VARIANT:-} == B ]]
framework_root=$(temporary_path "$RUNNER_TEMP/issue2754-framework-$GITHUB_RUN_ID-${PROBE_VARIANT:?Set PROBE_VARIANT to control or B}")
app_source=$(temporary_path "$RUNNER_TEMP/issue2754-app-$GITHUB_RUN_ID-$PROBE_VARIANT")
local_engine=$(temporary_path "$RUNNER_TEMP/issue2754-local-engine-$GITHUB_RUN_ID-$PROBE_VARIANT")
[[ $PROBE_VARIANT == control || $PROBE_VARIANT == B ]]
jq -e --arg variant "$PROBE_VARIANT" --arg engine "$ENGINE_SHA" --arg framework "$FRAMEWORK_SHA" \
  --arg source "$LOCALSEND_SHA" --arg deps "$DEPS_SHA256" \
  '.variant == $variant and .engine_sha == $engine and .framework_sha == $framework and
    .localsend_sha == $source and .deps_sha256 == $deps and .runtime_mode == "release"' \
  "$variant_artifact/provenance/manifest.json"
bootstrap_records="$variant_artifact/provenance/bootstrap/records-SHA256SUMS"
[[ $(sha256sum "$bootstrap_records" | awk '{print $1}') == \
  "$(jq -er .bootstrap_records_sha256 "$variant_artifact/provenance/manifest.json")" ]]
(cd "$variant_artifact/provenance/bootstrap" && sha256sum -c records-SHA256SUMS)
(cd "$variant_artifact" && sha256sum -c host-release.tar.gz.sha256)
mkdir -p "$local_engine/engine/src/out/host_release" "$output/provenance"
tar -xzf "$variant_artifact/host-release.tar.gz" -C "$local_engine/engine/src/out/host_release"
release="$local_engine/engine/src/out/host_release"
(cd "$release" && sha256sum -c "$variant_artifact/provenance/engine-files-SHA256SUMS")
clone_exact https://github.com/flutter/flutter.git "$FRAMEWORK_SHA" "$framework_root"
# Flutter's version detection also needs its official release tag in a shallow checkout.
git -C "$framework_root" fetch --depth=1 origin refs/tags/3.41.9:refs/tags/3.41.9
[[ $(git -C "$framework_root" rev-parse '3.41.9^{commit}') == "$FRAMEWORK_SHA" ]]
[[ $(cat "$framework_root/bin/internal/engine.version") == "$ENGINE_SHA" ]]
if [[ ! -e "$release/shader_lib" ]]; then
  [[ $(jq -er .run_id "$variant_artifact/provenance/manifest.json") == 38153341418 ]]
  bash "$assets/restore-shader-inputs.sh" "$framework_root" "$release" "$output/provenance/shader-inputs"
  cp "$variant_artifact/provenance/manifest.json" "$output/provenance/shader-inputs/original-engine-manifest.json"
  cp "$variant_artifact/host-release.tar.gz.sha256" "$output/provenance/shader-inputs/original-engine-archive.sha256"
  jq --arg variant "$PROBE_VARIANT" --arg original_run "38153341418" \
    --arg archive_hash "$(awk 'NR==1 {print $1}' "$variant_artifact/host-release.tar.gz.sha256")" \
    --arg original_manifest_hash "$(sha256sum "$variant_artifact/provenance/manifest.json" | awk '{print $1}')" \
    '. + {variant:$variant,original_engine_run_id:$original_run,original_engine_archive_sha256:$archive_hash,
      original_engine_manifest_sha256:$original_manifest_hash}' \
    "$output/provenance/shader-inputs/manifest.json" > "$output/provenance/shader-inputs/manifest.tmp"
  mv "$output/provenance/shader-inputs/manifest.tmp" "$output/provenance/shader-inputs/manifest.json"
  # The additive source inputs must leave every original transported byte intact.
  (cd "$release" && sha256sum -c "$variant_artifact/provenance/engine-files-SHA256SUMS") \
    > "$output/provenance/shader-inputs/original-inputs-reverified.log"
fi
[[ ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]]
clone_exact "https://github.com/$GITHUB_REPOSITORY.git" "$LOCALSEND_SHA" "$app_source"
# Explicit SDK paths and pinned Rust; no codegen or source repair.
flutter="$framework_root/bin/flutter"
# The first supported invocation bootstraps the SDK and can write curl progress
# to stdout. Retain that output separately before asking for strict JSON.
set +e
"$flutter" --version > "$output/provenance/flutter-bootstrap.log" 2>&1
bootstrap_status=$?
set -e
printf '%s\n' "$bootstrap_status" > "$output/provenance/flutter-bootstrap-exit-code.txt"
[[ $bootstrap_status == 0 ]]
"$flutter" --version --machine > "$output/provenance/flutter-version.json"
jq -e --arg revision "$FRAMEWORK_SHA" --arg engine "$ENGINE_SHA" \
  '.frameworkVersion == "3.41.9" and .frameworkRevision == $revision and .engineRevision == $engine' \
  "$output/provenance/flutter-version.json"
rustup toolchain install 1.97.1 --profile minimal
export RUSTUP_TOOLCHAIN=1.97.1
rustc -Vv > "$output/provenance/rustc-version.txt"
cd "$app_source"
git rev-parse HEAD > "$output/provenance/source-sha.txt"
git status --porcelain=v1 > "$output/provenance/source-status-before.txt"
locks=(pubspec.lock Cargo.lock packages/localsend_isolates/rust_builder/cargokit/build_tool/pubspec.lock)
sha256sum "${locks[@]}" > "$output/provenance/lock-hashes-before.txt"
(cd app && "$flutter" pub get --enforce-lockfile)
(cd packages/localsend_isolates/rust_builder/cargokit/build_tool && "$flutter" pub get --enforce-lockfile)
sha256sum -c "$output/provenance/lock-hashes-before.txt"
(cd app && timeout --foreground 3600 "$flutter" --local-engine-src-path="$local_engine/engine/src" \
  --local-engine=host_release --local-engine-host=host_release build linux --release -v) \
  2>&1 | tee "$output/provenance/app-build.log"
sha256sum "${locks[@]}" > "$output/provenance/lock-hashes-after.txt"
cmp "$output/provenance/lock-hashes-before.txt" "$output/provenance/lock-hashes-after.txt"
git diff --binary HEAD -- > "$output/provenance/app-source.patch"
git diff --exit-code HEAD --
git status --porcelain=v1 > "$output/provenance/app-source-status.txt"
cp app/linux/flutter/ephemeral/generated_config.cmake "$output/provenance/generated_config.cmake"
grep -F "$release" "$output/provenance/generated_config.cmake"
bundle="$app_source/app/build/linux/x64/release/bundle"
[[ -x "$bundle/localsend_app" && -f "$bundle/lib/libapp.so" && -f "$bundle/lib/librust_lib_localsend_app.so" ]]
engine_hash=$(sha256sum "$bundle/lib/libflutter_linux_gtk.so" | awk '{print $1}')
[[ $engine_hash == "$(cat "$variant_artifact/provenance/engine-sha256.txt")" ]]
[[ $engine_hash == "$(jq -r .engine_so_sha256 "$variant_artifact/provenance/manifest.json")" ]]
cp -a "$variant_artifact/provenance" "$output/provenance/engine"
readelf -h -d -n "$bundle/lib/libflutter_linux_gtk.so" > "$output/provenance/engine-elf.txt"
readelf -h -d -n "$bundle/localsend_app" > "$output/provenance/app-elf.txt"
ldd "$bundle/localsend_app" > "$output/provenance/app-build-host-ldd.txt"
(cd "$bundle" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$output/provenance/bundle-files-SHA256SUMS"
tar -czf "$output/source-bundle.tar.gz" -C "$bundle" .
(cd "$output" && sha256sum source-bundle.tar.gz > source-bundle.tar.gz.sha256)
jq --arg bundle_hash "$(sha256sum "$output/source-bundle.tar.gz" | awk '{print $1}')" \
  --arg app_hash "$(sha256sum "$bundle/lib/libapp.so" | awk '{print $1}')" \
  --arg app_run "$GITHUB_RUN_ID" '. + {bundle_sha256:$bundle_hash,libapp_sha256:$app_hash,app_build_run_id:$app_run}' \
  "$variant_artifact/provenance/manifest.json" > "$output/provenance/manifest.json"
printf 'Complete c1ce release bundle links the verified %s source-built engine. Guest loading/UI remain unverified.\n' "$PROBE_VARIANT" > "$output/result.txt"
