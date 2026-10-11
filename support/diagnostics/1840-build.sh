#!/usr/bin/env bash
# Diagnostic build only: preserve the accepted immutable source and committed codegen.
set -euo pipefail

source_dir=$(realpath "${PROBE_SOURCE_DIR:?Set PROBE_SOURCE_DIR to the separate candidate checkout}")
output_dir=$(realpath -m "${PROBE_BUILD_DIR:?Set PROBE_BUILD_DIR to the artifact directory}")
flutter=$(realpath "${PROBE_FLUTTER:?Set PROBE_FLUTTER to the pinned Flutter executable}")
dart=$(realpath "$(dirname "$flutter")/dart")
expected_source=${PROBE_SOURCE_SHA:?Set immutable candidate source SHA}
expected_flutter=00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
export RUSTUP_TOOLCHAIN=1.97.1
mkdir -p "$output_dir/provenance"
exec > >(tee "$output_dir/provenance/build.log") 2>&1
cd "$source_dir"
locks=(pubspec.lock Cargo.lock packages/localsend_isolates/rust_builder/cargokit/build_tool/pubspec.lock)

finish() {
  status=$?
  trap - EXIT
  set +e
  sha256sum "${locks[@]}" > "$output_dir/provenance/lock-hashes-after.txt"
  git status --porcelain=v1 --untracked-files=all > "$output_dir/provenance/source-status-after.txt"
  git diff --binary HEAD > "$output_dir/provenance/source-diff-after.patch"
  if ! cmp -s "$output_dir/provenance/lock-hashes-before.txt" "$output_dir/provenance/lock-hashes-after.txt"; then
    echo 'FAIL: a committed dependency lock changed.'
    status=1
  fi
  if ! git diff --quiet HEAD --; then
    echo 'FAIL: the build changed tracked source files.'
    status=1
  fi
  printf 'exit_status=%s\ncompleted_at=%s\n' "$status" "$(date -u +%FT%TZ)" > "$output_dir/provenance/build-result.txt"
  exit "$status"
}
sha256sum "${locks[@]}" > "$output_dir/provenance/lock-hashes-before.txt"
trap finish EXIT

git rev-parse HEAD > "$output_dir/provenance/source-sha.txt"
git status --porcelain=v1 --untracked-files=all > "$output_dir/provenance/source-status-before.txt"
test "$(cat "$output_dir/provenance/source-sha.txt")" = "$expected_source"
test ! -s "$output_dir/provenance/source-status-before.txt"
git ls-tree HEAD support/submodules/flutter > "$output_dir/provenance/flutter-gitlink.txt"
test "$(awk '{print $3}' "$output_dir/provenance/flutter-gitlink.txt")" = "$expected_flutter"
"$flutter" --version --machine > "$output_dir/provenance/flutter-version.json"
jq -e --arg revision "$expected_flutter" '.frameworkVersion == "3.41.9" and .frameworkRevision == $revision' "$output_dir/provenance/flutter-version.json"
"$dart" --version 2>&1 | tee "$output_dir/provenance/dart-version.txt"
rustc -Vv > "$output_dir/provenance/rustc-version.txt"
cargo -V > "$output_dir/provenance/cargo-version.txt"
test "$(rustc --version | awk '{print $2}')" = 1.97.1
{
  uname -a
  cat /etc/os-release
  clang --version
  ld --version
  cmake --version
  ninja --version
  pkg-config --version
  dpkg-query -W clang cmake libgtk-3-dev ninja-build libayatana-appindicator3-dev pkg-config binutils
} > "$output_dir/provenance/build-host.txt" 2>&1
jq -n --arg source "$expected_source" --arg flutter "$expected_flutter" \
  --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  '{source_sha: $source, flutter_version: "3.41.9", flutter_framework_revision: $flutter,
    rust_version: "1.97.1", build_command: "flutter build linux --release", run_url: $run,
    note: "Pinned-input provenance; bit-for-bit reproducibility has not been established."}' \
  > "$output_dir/provenance/build-inputs.json"

# Resolve both the pub workspace and vendored standalone cargokit without lock updates.
(cd app && "$flutter" pub get --enforce-lockfile)
(cd packages/localsend_isolates/rust_builder/cargokit/build_tool && "$flutter" pub get --enforce-lockfile)
sha256sum -c "$output_dir/provenance/lock-hashes-before.txt"
(cd app && "$flutter" build linux --release)
sha256sum -c "$output_dir/provenance/lock-hashes-before.txt"
git diff --exit-code HEAD --

bundle="$source_dir/app/build/linux/x64/release/bundle"
test -x "$bundle/localsend_app"
for library in libflutter_linux_gtk.so libapp.so librust_lib_localsend_app.so; do
  test -f "$bundle/lib/$library"
done
(cd "$bundle" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$output_dir/provenance/bundle-file-sha256.txt"
for binary in "$bundle/localsend_app" "$bundle"/lib/*.so; do
  {
    printf '\nFILE %s\n' "${binary#"$bundle/"}"
    file "$binary"
    readelf -h -d "$binary"
    ldd "$binary"
  } >> "$output_dir/provenance/bundle-elf-ldd.txt" 2>&1
done
tar -czf "$output_dir/source-bundle.tar.gz" -C "$bundle" .
(cd "$output_dir" && sha256sum source-bundle.tar.gz > source-bundle.tar.gz.sha256)
