#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
BASE=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
PATCH_SHA=e52ab393a247b3dd0b854fc067628ea4d7df4ec91fa238de8b572831955a6891
LOCK_SHA=f00d703bc5a5f0b68ce6ca2d231cb14bd480d413bde3d8fc26bda3b67058f3df
BASELINE_SHA=d76437b6effdbcd8e0835f353c95b0fa7affeac123dcc853e7dd5b25107e9e5c
mkdir -p evidence/source/provenance
OUT=$(realpath evidence/source)
INPUT=$(realpath evidence/immutable-source/source)
SOURCE="$RUNNER_TEMP/issue1927-product-source"
PATCH="$GITHUB_WORKSPACE/support/diagnostics/issue1927-product-source.patch"
exec > >(tee "$OUT/provenance/source-stage.log") 2>&1
printf '%s  %s\n' "$PATCH_SHA" "$PATCH" | sha256sum -c -
printf '%s  %s\n' "$BASELINE_SHA" "$INPUT/baseline-source-bundle.tar.gz" | sha256sum -c -
printf '%s  %s\n' "$LOCK_SHA" "$INPUT/provenance/resolved-pubspec.lock" | sha256sum -c -
test "$(cat "$INPUT/provenance/base.txt")" = "$BASE"
cp "$INPUT/baseline-source-bundle.tar.gz" "$OUT/"
cp "$PATCH" "$OUT/provenance/product-source.patch"
cp -a "$INPUT/provenance" "$OUT/provenance/immutable-source"
git worktree add --detach "$SOURCE" "$BASE"
git -C "$SOURCE" rev-parse HEAD > "$OUT/provenance/base.txt"
git rev-parse HEAD > "$OUT/provenance/diagnostic-head.txt"
for file in app/lib/util/native/autostart_helper.dart app/lib/pages/tabs/settings_tab.dart app/lib/pages/tabs/settings_tab_controller.dart app/lib/pages/tabs/settings_tab_vm.dart; do
  sha256sum "$SOURCE/$file" >> "$OUT/provenance/base-product-files.sha256"
done
(
  cd "$SOURCE"
  sha256sum -c - <<'BASE_HASHES'
3605d86773dfc40bdc1685d830b601dbf8fd5952eefb4c93913b426a8523ea59  app/lib/util/native/autostart_helper.dart
780711ac7387e572cdd75008655200561f5be20262e422497a1545a9f5c4835d  app/lib/pages/tabs/settings_tab_controller.dart
ab1a2a6cfdac056f20cae1e40869cd0d1ea33e1a0ff39389882607b8ab8f129f  app/lib/pages/tabs/settings_tab_vm.dart
93d6dbd3cc83fa994ff75f207a473fffe7c358e31fa99d7dde0739192ce85894  app/lib/pages/tabs/settings_tab.dart
BASE_HASHES
)
# The historical source pair retained this unused diagnostic dependency. Apply
# only its pubspec input, never the historical portal helper or lock patch.
git -C "$SOURCE" apply --include=app/pubspec.yaml "$INPUT/provenance/candidate-source.patch"
git -C "$SOURCE" show "$BASE:app/pubspec.yaml" > "$OUT/provenance/base-pubspec.yaml"
ruby -e 'old=File.read(ARGV[0]); expected=old.sub("  shared_preferences: 2.5.5\n", "  shared_preferences: 2.5.5\n  xdg_desktop_portal: 0.1.14\n"); abort "Unexpected diagnostic dependency input" unless expected!=old && File.read(ARGV[1])==expected' "$OUT/provenance/base-pubspec.yaml" "$SOURCE/app/pubspec.yaml"
cp "$INPUT/provenance/resolved-pubspec.lock" "$SOURCE/pubspec.lock"
git -C "$SOURCE" diff --binary HEAD > "$OUT/provenance/baseline-dependency-input.patch"
git -C "$SOURCE" apply "$PATCH"
git -C "$SOURCE" add -N app/lib/util/native/linux_autostart.dart app/test/unit/util/native/linux_autostart_test.dart
(
  cd "$SOURCE"
  sha256sum -c - <<'PRODUCT_HASHES'
6f75567db5cd1784bc275018f403bb135abaea552b39c09e0a71f412c6efb132  app/lib/util/native/autostart_helper.dart
30f19e2bfe184055d018c630a08eaf5b96b3d891b12538eaf56e484b66930e33  app/lib/util/native/linux_autostart.dart
fbf93adff413cac644ea2ca7371408ce2a4ad8a6380b94c8fc1fa13d14d94692  app/lib/pages/tabs/settings_tab_controller.dart
7dba4e68e733dd9d119a096dc34d4c96ee1e97ce7062c02ee7096d7dcb2fcfc5  app/lib/pages/tabs/settings_tab_vm.dart
e0bcbb22eb4174dc8fb955c9ce5342a9de078c325731b8a1f81495ea42c439b2  app/lib/pages/tabs/settings_tab.dart
905903bc8b2d93e079dc1f808f985d7ea522930927b1ea5b2ac049a21cf79ceb  app/test/unit/util/native/linux_autostart_test.dart
PRODUCT_HASHES
)
git -C "$SOURCE" diff --binary HEAD > "$OUT/provenance/applied-source-before-generation.patch"
cp "$SOURCE/app/lib/util/native/autostart_helper.dart" "$OUT/provenance/consumed-autostart-helper.dart"
sudo apt-get update
sudo apt-get install -y clang cmake libgtk-3-dev ninja-build libayatana-appindicator3-dev libssl-dev ruby
mkdir -p "$RUNNER_TEMP/issue1927-flutter"
FLUTTER_REVISION=00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
FLUTTER_BOOTSTRAP="$RUNNER_TEMP/issue1927-flutter/flutter"
git clone --depth 1 --branch 3.41.9 https://github.com/flutter/flutter.git "$FLUTTER_BOOTSTRAP"
test "$(git -C "$FLUTTER_BOOTSTRAP" rev-parse HEAD)" = "$FLUTTER_REVISION"
test "$(git -C "$FLUTTER_BOOTSTRAP" rev-parse 'refs/tags/3.41.9^{commit}')" = "$FLUTTER_REVISION"
{
  git -C "$FLUTTER_BOOTSTRAP" remote get-url origin
  git -C "$FLUTTER_BOOTSTRAP" rev-parse HEAD 'refs/tags/3.41.9^{commit}'
  sha256sum "$FLUTTER_BOOTSTRAP/bin/dart" "$FLUTTER_BOOTSTRAP/bin/internal/shared.sh" "$FLUTTER_BOOTSTRAP/bin/internal/update_dart_sdk.sh"
} > "$OUT/provenance/flutter-bootstrap-source.txt"
export PATH="$RUNNER_TEMP/issue1927-flutter/flutter/bin:$HOME/.pub-cache/bin:$PATH"
dart --version > "$OUT/provenance/bootstrap-dart-version.txt" 2>&1
dart pub global activate fvm 4.3.1
rustup toolchain install 1.97.1 --profile minimal
export RUSTUP_TOOLCHAIN=1.97.1
cd "$SOURCE"
fvm install 3.41.9
fvm flutter --version --machine > "$OUT/provenance/flutter.json"
rustc -Vv > "$OUT/provenance/rust.txt"
cd app
fvm flutter pub get --enforce-lockfile > "$OUT/provenance/pub-get.log" 2>&1
cmp ../pubspec.lock "$INPUT/provenance/resolved-pubspec.lock"
fvm dart run build_runner build > "$OUT/provenance/build-runner.log" 2>&1
git diff --binary HEAD > "$OUT/provenance/raw-generation.patch"
# Normal generation may reformat unrelated mocks. Preserve the raw diff, then
# retain only the expected Settings VM mapper from this generation.
while IFS= read -r generated; do
  case "$generated" in
    app/lib/pages/tabs/settings_tab_vm.mapper.dart) ;;
    *.mapper.dart|*.freezed.dart|*.g.dart|*.mocks.dart) git -C "$SOURCE" restore -- "$generated" ;;
  esac
done < <(git diff --name-only HEAD)
fvm dart format lib/util/native/autostart_helper.dart lib/util/native/linux_autostart.dart lib/pages/tabs/settings_tab.dart lib/pages/tabs/settings_tab_controller.dart lib/pages/tabs/settings_tab_vm.dart lib/pages/tabs/settings_tab_vm.mapper.dart test/unit/util/native/linux_autostart_test.dart > "$OUT/provenance/format.log" 2>&1
git diff --binary HEAD > "$OUT/provenance/consumed-source-after-generation.patch"
git status --short > "$OUT/provenance/generated-source-status.txt"
fvm flutter test test/unit/util/native/linux_autostart_test.dart > "$OUT/provenance/focused-tests.log" 2>&1
fvm flutter analyze --no-pub lib/util/native/autostart_helper.dart lib/util/native/linux_autostart.dart lib/pages/tabs/settings_tab.dart lib/pages/tabs/settings_tab_controller.dart lib/pages/tabs/settings_tab_vm.dart test/unit/util/native/linux_autostart_test.dart > "$OUT/provenance/analyze.log" 2>&1
fvm flutter build linux --release --no-pub > "$OUT/provenance/candidate-build.log" 2>&1
cmp ../pubspec.lock "$INPUT/provenance/resolved-pubspec.lock"
cp ../pubspec.lock "$OUT/provenance/resolved-pubspec.lock"
for file in lib/util/native/autostart_helper.dart lib/util/native/linux_autostart.dart lib/pages/tabs/settings_tab.dart lib/pages/tabs/settings_tab_controller.dart lib/pages/tabs/settings_tab_vm.dart lib/pages/tabs/settings_tab_vm.mapper.dart test/unit/util/native/linux_autostart_test.dart; do
  sha256sum "$file" >> "$OUT/provenance/consumed-product-files.sha256"
done
tar -czf "$OUT/candidate-source-bundle.tar.gz" -C build/linux/x64/release/bundle .
cd "$OUT"
sha256sum baseline-source-bundle.tar.gz candidate-source-bundle.tar.gz > SHA256SUMS
printf 'unchanged_source=%s\nproduct_patch=%s\nresolved_lock=%s\nbase=%s\nnormal_generation_and_build=passed\n' "$BASELINE_SHA" "$PATCH_SHA" "$LOCK_SHA" "$BASE" > provenance/comparison.txt
