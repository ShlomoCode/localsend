#!/usr/bin/env bash
# Sequential control and B compilation; never run on a development host.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 1 ]] || { echo "Usage: $0 OUTPUT_DIR" >&2; exit 2; }
start_stage "$1"
engine_environment
cd "$assets"
sha256sum -c assets-SHA256SUMS
cd "$engine_root"
git diff --exit-code HEAD --
cp "$assets/B-with-tests.patch" "$output/"
cp "$assets/assets-SHA256SUMS" "$output/"
cp "$engine_root/DEPS" "$output/DEPS"
cp "$engine_root/.gclient" "$output/actual.gclient"
deadline=$(( SECONDS + 10800 ))

bounded() {
  local remaining=$(( deadline - SECONDS ))
  (( remaining > 0 )) || { echo 'BUILD_TIME_BUDGET_EXHAUSTED'; return 124; }
  timeout --foreground "$remaining" "$@"
}

release_build() {
  local variant=$1 directory="$output/$1" release="$engine_root/engine/src/out/host_release"
  mkdir -p "$directory/provenance"
  cp -a "$bootstrap_provenance" "$directory/provenance/bootstrap"
  resources "$variant-before-release"
  (cd "$engine_root/engine/src" && bounded flutter/tools/gn --runtime-mode release \
    --enable-fontconfig --prebuilt-dart-sdk --no-lto --no-enable-unittests) \
    2>&1 | tee "$directory/provenance/gn.log"
  cp "$release/args.gn" "$directory/provenance/args.gn"
  bounded "$ninja" -C "$release" -j2 -l2 \
    flutter/shell/platform/linux:flutter_gtk \
    flutter/sky flutter/build/dart:dart_sdk \
    flutter/flutter_frontend_server:frontend_server \
    flutter/tools/font_subset flutter/tools/const_finder flutter/impeller/compiler:impellerc \
    2>&1 | tee "$directory/provenance/ninja.log"
  resources "$variant-after-release"
  # These are the complete local-engine consumer inputs, not arbitrary object files.
  local required=(libflutter_linux_gtk.so flutter_linux gen_snapshot icudtl.dat dart-sdk \
    flutter_patched_sdk gen font-subset impellerc)
  for entry in "${required[@]}"; do [[ -e "$release/$entry" ]]; done
  [[ -e "$release/gen/dart-pkg/sky_engine/lib" ]]
  [[ -f "$release/flutter_patched_sdk/platform_strong.dill" ]]
  [[ -f "$release/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot" ]]
  [[ -x "$release/gen_snapshot" ]]
  # ELF inspection establishes artifact identity. GTK dependency resolution belongs to the guest gate.
  readelf -h -d -n "$release/libflutter_linux_gtk.so" > "$directory/provenance/engine-elf.txt"
  ldd "$release/libflutter_linux_gtk.so" > "$directory/provenance/engine-build-host-ldd.txt" 2>&1 || true
  sha256sum "$release/libflutter_linux_gtk.so" | awk '{print $1}' > "$directory/provenance/engine-sha256.txt"
  git -C "$engine_root" diff --binary HEAD -- > "$directory/provenance/source.patch"
  git -C "$engine_root" status --porcelain=v1 > "$directory/provenance/source-status.txt"
  (cd "$release" && find -L "${required[@]}" -type f -print0 | sort -z | xargs -0 sha256sum) \
    > "$directory/provenance/engine-files-SHA256SUMS"
  # Dereference generated links so no target refers outside the transported artifact.
  # The consumer restores this under engine/src/out/host_release.
  bounded tar --dereference -czf "$directory/host-release.tar.gz" -C "$release" "${required[@]}"
  (cd "$directory" && sha256sum host-release.tar.gz > host-release.tar.gz.sha256)
  manifest "$variant" "$directory/provenance/manifest.json"
  jq --arg engine_hash "$(cat "$directory/provenance/engine-sha256.txt")" \
    --arg patch_hash "$(sha256sum "$assets/B-with-tests.patch" | awk '{print $1}')" \
    --arg bootstrap_hash "$(sha256sum "$directory/provenance/bootstrap/records-SHA256SUMS" | awk '{print $1}')" \
    '. + {engine_so_sha256:$engine_hash,experiment_patch_sha256:$patch_hash,
      bootstrap_records_sha256:$bootstrap_hash}' \
    "$directory/provenance/manifest.json" > "$directory/provenance/manifest.tmp"
  mv "$directory/provenance/manifest.tmp" "$directory/provenance/manifest.json"
}

release_build control
git -C "$engine_root" apply --check "$assets/B-with-tests.patch"
git -C "$engine_root" apply "$assets/B-with-tests.patch"
git -C "$engine_root" diff --binary HEAD -- > "$output/B-applied.patch"
sha256sum "$output/B-applied.patch" > "$output/B-applied.patch.sha256"
resources B-before-native-tests
debug="$engine_root/engine/src/out/host_debug_unopt"
(cd "$engine_root/engine/src" && bounded flutter/tools/gn --runtime-mode debug --unoptimized \
  --prebuilt-dart-sdk --no-lto --enable-unittests) 2>&1 | tee "$output/native-gn.log"
cp "$debug/args.gn" "$output/native-args.gn"
bounded "$ninja" -C "$debug" -j2 -l2 flutter/shell/platform/linux:flutter_linux_unittests \
  2>&1 | tee "$output/native-ninja.log"
native_binary="$debug/flutter_linux_unittests"
[[ -x "$native_binary" ]]
sha256sum "$native_binary" > "$output/native-binary.sha256"
bounded xvfb-run -a timeout 180 "$native_binary" --gtest_filter=FlSocketAccessibleTest.* \
  "--gtest_output=xml:$output/native-B.xml" 2>&1 | tee "$output/native-B.log"
awk '/<testsuite name="FlSocketAccessibleTest"/ {
  if ($0 ~ /tests="5"/ && $0 ~ /failures="0"/ && $0 ~ /errors="0"/ && $0 ~ /skipped="0"/) found=1
} END { exit !found }' "$output/native-B.xml"
resources B-after-native-tests
release_build B
[[ $(cat "$output/control/provenance/engine-sha256.txt") != "$(cat "$output/B/provenance/engine-sha256.txt")" ]]
printf 'Exact source-built control and B engine artifacts completed; official B native target passed five tests.\n' > "$output/result.txt"
