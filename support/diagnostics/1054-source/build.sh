#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 2
task_root="$GITHUB_WORKSPACE"
source_dir="$task_root/source"
output_dir="$task_root/source-evidence"
mkdir -p "$output_dir"
cd "$source_dir"
test "$(git rev-parse HEAD)" = c1ce322fb3acf08e44f329b8b7208b8b0d91e244
test -z "$(git status --porcelain)"
fvm install 3.41.9
fvm flutter --version --machine > "$output_dir/flutter.json"
jq -e '.frameworkVersion == "3.41.9" and .frameworkRevision == "00b0c91f06209d9e4a41f71b7a512d6eb3b9c694"' "$output_dir/flutter.json"
rustc -Vv > "$output_dir/rustc.txt"
test "$(rustc --version | awk '{print $2}')" = 1.97.1
locks=(pubspec.lock Cargo.lock packages/localsend_isolates/rust_builder/cargokit/build_tool/pubspec.lock)
sha256sum "${locks[@]}" > "$output_dir/locks-before.txt"
(cd app && fvm flutter pub get --enforce-lockfile)
(cd packages/localsend_isolates/rust_builder/cargokit/build_tool && fvm flutter pub get --enforce-lockfile)
for variant in baseline candidate; do
  mkdir -p "$output_dir/$variant/provenance"
  if [[ $variant == candidate ]]; then
    git apply "$task_root/diagnostic/support/diagnostics/1054-source/refresh-size.patch"
    mkdir -p app/test/unit/model
    cp "$task_root/diagnostic/app/test/unit/model/cross_file_test.dart" app/test/unit/model/
    (cd app && fvm dart format --set-exit-if-changed lib/model/cross_file.dart lib/provider/network/send_provider.dart test/unit/model/cross_file_test.dart)
    (cd app && fvm flutter analyze lib/model/cross_file.dart lib/provider/network/send_provider.dart test/unit/model/cross_file_test.dart)
    (cd app && fvm flutter test test/unit/model/cross_file_test.dart)
  fi
  git diff --binary HEAD > "$output_dir/$variant/provenance/source-diff-before.patch"
  git status --porcelain --untracked-files=all > "$output_dir/$variant/provenance/status-before.txt"
  sha256sum -c "$output_dir/locks-before.txt"
  (cd app && fvm flutter build linux --release) 2>&1 | tee "$output_dir/$variant/provenance/build.log"
  sha256sum -c "$output_dir/locks-before.txt"
  git diff --binary HEAD > "$output_dir/$variant/provenance/source-diff-after.patch"
  cmp "$output_dir/$variant/provenance/source-diff-before.patch" "$output_dir/$variant/provenance/source-diff-after.patch"
  bundle="$source_dir/app/build/linux/x64/release/bundle"
  test -x "$bundle/localsend_app"
  (cd "$bundle" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$output_dir/$variant/provenance/bundle-hashes.txt"
  tar -czf "$output_dir/$variant/source-bundle.tar.gz" -C "$bundle" .
  (cd "$output_dir/$variant" && sha256sum source-bundle.tar.gz > source-bundle.tar.gz.sha256)
  jq -n --arg variant "$variant" --arg run "https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
    '{source_sha:"c1ce322fb3acf08e44f329b8b7208b8b0d91e244",variant:$variant,flutter_version:"3.41.9",rust_version:"1.97.1",run_url:$run}' \
    > "$output_dir/$variant/provenance/build-inputs.json"
done
