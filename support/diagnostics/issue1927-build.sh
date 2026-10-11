#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p evidence/source/provenance
OUT=$(realpath evidence/source)
SOURCE="$RUNNER_TEMP/issue1927-source"
git worktree add --detach "$SOURCE" c1ce322fb3acf08e44f329b8b7208b8b0d91e244
git -C "$SOURCE" apply "$GITHUB_WORKSPACE/support/diagnostics/issue1927-portal-source.patch"
cp "$SOURCE/app/lib/util/native/autostart_helper.dart" "$RUNNER_TEMP/issue1927-candidate-helper.dart"
git -C "$SOURCE" show HEAD:app/lib/util/native/autostart_helper.dart > "$SOURCE/app/lib/util/native/autostart_helper.dart"
cd "$SOURCE"
fvm install 3.41.9
fvm flutter --version --machine > "$OUT/provenance/flutter.json"
rustc -Vv > "$OUT/provenance/rust.txt"
git rev-parse HEAD > "$OUT/provenance/base.txt"
cd app
fvm flutter pub get
fvm dart format lib/util/native/autostart_helper.dart
fvm flutter build linux --release > "$OUT/provenance/baseline-build.log" 2>&1
tar -czf "$OUT/baseline-source-bundle.tar.gz" -C build/linux/x64/release/bundle .
cp ../pubspec.lock "$OUT/provenance/resolved-pubspec.lock"
cp "$RUNNER_TEMP/issue1927-candidate-helper.dart" lib/util/native/autostart_helper.dart
fvm dart format lib/util/native/autostart_helper.dart
git diff --binary HEAD > "$OUT/provenance/candidate-source.patch"
fvm flutter analyze --no-pub lib/util/native/autostart_helper.dart > "$OUT/provenance/candidate-analyze.log" 2>&1
fvm flutter build linux --release > "$OUT/provenance/candidate-build.log" 2>&1
cmp ../pubspec.lock "$OUT/provenance/resolved-pubspec.lock"
tar -czf "$OUT/candidate-source-bundle.tar.gz" -C build/linux/x64/release/bundle .
cd "$OUT"
sha256sum *-source-bundle.tar.gz > SHA256SUMS
printf 'Baseline: original c1ce helper with unused portal dependency. Candidate: same source/dependencies/toolchain, portal helper only. These are source build artifacts, not packaged GUI validation.\n' > provenance/comparison.txt
