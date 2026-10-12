#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
BASE=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
PATCH_SHA=a9b8ea52e24acbb4e1136332661313ac81de46d752b5a0e24a33ba45186726cf
LOCK_SHA=f00d703bc5a5f0b68ce6ca2d231cb14bd480d413bde3d8fc26bda3b67058f3df
mkdir -p evidence/source/provenance
OUT=$(realpath evidence/source)
INPUT=$(realpath evidence/immutable-source/source)
PATCH="$GITHUB_WORKSPACE/support/diagnostics/issue1927-product-source.patch"
SOURCE_ROOT="$RUNNER_TEMP/issue1927-product-source"
exec > >(tee "$OUT/provenance/source-stage.log") 2>&1
# The workflow owns one shared ceiling for bootstrap and both cold builds.
# No per-variant timeout may silently shorten that shared budget.
printf 'status=running\n' > "$OUT/provenance/source-stage-status.txt"
finish() {
  local code=$?
  trap - EXIT
  printf 'exit_code=%s\n' "$code" >> "$OUT/provenance/source-stage-status.txt"
  if ((code == 0)); then printf 'status=passed\n'; else printf 'status=failed\n'; fi >> "$OUT/provenance/source-stage-status.txt"
}
trap finish EXIT
trap 'exit 143' TERM
printf '%s  %s\n' "$PATCH_SHA" "$PATCH" | sha256sum -c -
printf '%s  %s\n' "$LOCK_SHA" "$INPUT/provenance/resolved-pubspec.lock" | sha256sum -c -
test "$(cat "$INPUT/provenance/base.txt")" = "$BASE"
cp "$PATCH" "$OUT/provenance/product-source.patch"
cp -a "$INPUT/provenance" "$OUT/provenance/immutable-source"
git rev-parse HEAD > "$OUT/provenance/diagnostic-head.txt"
: > "$OUT/SHA256SUMS"

# An interrupted command retains its running receipt and partial log.
stage() {
  local label=$1 code=0
  shift
  printf 'status=running\nstarted_at=%s\n' "$(date -u +%FT%TZ)" > "$PROVENANCE/$label.status"
  "$@" > "$PROVENANCE/$label.log" 2>&1 || code=$?
  printf 'exit_code=%s\nfinished_at=%s\n' "$code" "$(date -u +%FT%TZ)" >> "$PROVENANCE/$label.status"
  return "$code"
}

# Hash the whole Git-visible source tree, including new files and missing
# tracked files. Build/cache directories are excluded by the repo ignores.
# Each phase retains the complete diff and status against the exact base.
snapshot() {
  local phase=$1
  git -C "$SOURCE" add -N .
  git -C "$SOURCE" diff --binary HEAD > "$PROVENANCE/$phase.patch"
  git -C "$SOURCE" status --short > "$PROVENANCE/$phase.status"
  git -C "$SOURCE" ls-files -z --cached --others --exclude-standard > "$PROVENANCE/$phase.paths"
  ruby -rdigest -e 'root, paths, output = ARGV; files = File.binread(paths).split("\0").uniq.sort; File.open(output, "w") { |out| files.each { |path| full = File.join(root, path); value = if File.symlink?(full); "symlink:" + File.readlink(full); elsif File.file?(full); Digest::SHA256.file(full).hexdigest; else; "MISSING"; end; out.puts "#{value}\t#{path}" } }' "$SOURCE" "$PROVENANCE/$phase.paths" "$PROVENANCE/$phase.sha256"
}

# Diagnostic declared-part inventory, not a shipping file-count test.
parts_receipt() {
  ruby -rdigest -rpathname -e 'root, paths, output = ARGV; missing = false; File.open(output, "w") { |out| File.binread(paths).split("\0").uniq.sort.grep(/\.dart$/).each { |path| file = File.join(root, path); next unless File.file?(file); File.read(file).scan(/^[ \t]*part[ \t]+[\x27\x22]([^\x27\x22]+)[\x27\x22][ \t]*;/).flatten.each { |part| target = Pathname.new(File.join(File.dirname(file), part)).cleanpath.to_s; present = File.file?(target); missing ||= !present; out.puts [path, part, present ? "present" : "MISSING", present ? Digest::SHA256.file(target).hexdigest : "-"].join("\t") } } }; abort "Missing generated part; see receipt" if missing' "$SOURCE" "$PROVENANCE/formatted.paths" "$PROVENANCE/generated-parts.tsv"
}

# Shared regeneration and supported formatter changes must match in both
# complete manifests; only product files and the Settings VM mapper may differ.
compare_trees() {
  local phase=$1
  ruby -e 'phase, baseline, candidate, output = ARGV; read = ->(path) { File.readlines(path, chomp: true).to_h { |line| value, file = line.split("\t", 2); [file, value] } }; a = read.call(baseline); b = read.call(candidate); allowed = %w[app/lib/util/native/autostart_helper.dart app/lib/util/native/linux_autostart.dart app/lib/pages/tabs/settings_tab.dart app/lib/pages/tabs/settings_tab_controller.dart app/lib/pages/tabs/settings_tab_vm.dart app/test/unit/util/native/linux_autostart_test.dart app/lib/pages/tabs/settings_tab_vm.mapper.dart]; unexpected = []; File.open(output, "w") { |out| (a.keys | b.keys).sort.each { |file| next if a[file] == b[file]; permitted = allowed.include?(file); unexpected << file unless permitted; out.puts [phase, permitted ? "allowed" : "UNEXPECTED", file, a.fetch(file, "ABSENT"), b.fetch(file, "ABSENT")].join("\t") } }; abort "Unexpected #{phase} source differences: #{unexpected.join(", ")}" unless unexpected.empty?' "$phase" "$OUT/provenance/baseline/$phase.sha256" "$OUT/provenance/candidate/$phase.sha256" "$OUT/provenance/$phase-comparison.tsv"
}

for variant in baseline candidate; do
  SOURCE="$SOURCE_ROOT/$variant"
  PROVENANCE="$OUT/provenance/$variant"
  mkdir -p "$PROVENANCE"
  git worktree add --detach "$SOURCE" "$BASE"
  git -C "$SOURCE" rev-parse HEAD > "$PROVENANCE/base.txt"
  (
    cd "$SOURCE"
    sha256sum -c - <<'BASE_HASHES'
3605d86773dfc40bdc1685d830b601dbf8fd5952eefb4c93913b426a8523ea59  app/lib/util/native/autostart_helper.dart
780711ac7387e572cdd75008655200561f5be20262e422497a1545a9f5c4835d  app/lib/pages/tabs/settings_tab_controller.dart
ab1a2a6cfdac056f20cae1e40869cd0d1ea33e1a0ff39389882607b8ab8f129f  app/lib/pages/tabs/settings_tab_vm.dart
93d6dbd3cc83fa994ff75f207a473fffe7c358e31fa99d7dde0739192ce85894  app/lib/pages/tabs/settings_tab.dart
BASE_HASHES
    sha256sum app/lib/util/native/autostart_helper.dart app/lib/pages/tabs/settings_tab_controller.dart app/lib/pages/tabs/settings_tab_vm.dart app/lib/pages/tabs/settings_tab.dart
  ) > "$PROVENANCE/base-product-files.txt"
  printf 'status=not_started\n' > "$PROVENANCE/linux-release-build.status"
  # Apply only the exact archived unused pubspec dependency input equally.
  # The archived executable bundle and historical helper are never consumed.
  git -C "$SOURCE" apply --include=app/pubspec.yaml "$INPUT/provenance/candidate-source.patch"
  git -C "$SOURCE" show "$BASE:app/pubspec.yaml" > "$PROVENANCE/base-pubspec.yaml"
  ruby -e 'old=File.read(ARGV[0]); expected=old.sub("  shared_preferences: 2.5.5\n", "  shared_preferences: 2.5.5\n  xdg_desktop_portal: 0.1.14\n"); abort "Unexpected diagnostic dependency input" unless expected!=old && File.read(ARGV[1])==expected' "$PROVENANCE/base-pubspec.yaml" "$SOURCE/app/pubspec.yaml"
  cp "$INPUT/provenance/resolved-pubspec.lock" "$SOURCE/pubspec.lock"
  git -C "$SOURCE" diff --binary HEAD > "$PROVENANCE/common-dependency-input.patch"
  if [[ $variant == candidate ]]; then
    git -C "$SOURCE" apply "$PATCH"
    (
      cd "$SOURCE"
      sha256sum -c - <<'PRODUCT_HASHES'
6f75567db5cd1784bc275018f403bb135abaea552b39c09e0a71f412c6efb132  app/lib/util/native/autostart_helper.dart
eb1a5e1867adb337d6867681ecc52b3d88798738692d9682b44a6b10c698f632  app/lib/util/native/linux_autostart.dart
fbf93adff413cac644ea2ca7371408ce2a4ad8a6380b94c8fc1fa13d14d94692  app/lib/pages/tabs/settings_tab_controller.dart
7dba4e68e733dd9d119a096dc34d4c96ee1e97ce7062c02ee7096d7dcb2fcfc5  app/lib/pages/tabs/settings_tab_vm.dart
e0bcbb22eb4174dc8fb955c9ce5342a9de078c325731b8a1f81495ea42c439b2  app/lib/pages/tabs/settings_tab.dart
905903bc8b2d93e079dc1f808f985d7ea522930927b1ea5b2ac049a21cf79ceb  app/test/unit/util/native/linux_autostart_test.dart
PRODUCT_HASHES
    )
  fi
  snapshot before
done
compare_trees before

PROVENANCE="$OUT/provenance"
stage apt-update sudo apt-get update
stage apt-install sudo apt-get install -y clang cmake libgtk-3-dev ninja-build libayatana-appindicator3-dev libssl-dev ruby
mkdir -p "$RUNNER_TEMP/issue1927-flutter"
FLUTTER_REVISION=00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
FLUTTER_BOOTSTRAP="$RUNNER_TEMP/issue1927-flutter/flutter"
stage flutter-clone git clone --depth 1 --branch 3.41.9 https://github.com/flutter/flutter.git "$FLUTTER_BOOTSTRAP"
test "$(git -C "$FLUTTER_BOOTSTRAP" rev-parse HEAD)" = "$FLUTTER_REVISION"
test "$(git -C "$FLUTTER_BOOTSTRAP" rev-parse 'refs/tags/3.41.9^{commit}')" = "$FLUTTER_REVISION"
{
  git -C "$FLUTTER_BOOTSTRAP" remote get-url origin
  git -C "$FLUTTER_BOOTSTRAP" rev-parse HEAD 'refs/tags/3.41.9^{commit}'
  sha256sum "$FLUTTER_BOOTSTRAP/bin/dart" "$FLUTTER_BOOTSTRAP/bin/internal/shared.sh" "$FLUTTER_BOOTSTRAP/bin/internal/update_dart_sdk.sh"
} > "$OUT/provenance/flutter-bootstrap-source.txt"
export PATH="$RUNNER_TEMP/issue1927-flutter/flutter/bin:$HOME/.pub-cache/bin:$PATH"
stage bootstrap-dart-version dart --version
stage fvm-bootstrap dart pub global activate fvm 4.3.1
stage rust-bootstrap rustup toolchain install 1.97.1 --profile minimal
export RUSTUP_TOOLCHAIN=1.97.1
cd "$SOURCE_ROOT/baseline"
stage fvm-install fvm install 3.41.9

preparation_failed=0
for variant in baseline candidate; do
  SOURCE="$SOURCE_ROOT/$variant"
  PROVENANCE="$OUT/provenance/$variant"
  cd "$SOURCE/app"
  stage flutter-version fvm flutter --version --machine
  stage rust-version rustc -Vv
  if stage pub-get fvm flutter pub get --enforce-lockfile; then
    cmp ../pubspec.lock "$INPUT/provenance/resolved-pubspec.lock"
    if stage build-runner fvm dart run build_runner build; then
      snapshot raw-generation
      if stage format fvm dart format --line-length 150 lib test; then
        snapshot formatted
        if ! stage generated-part-completeness parts_receipt; then preparation_failed=1; fi
      else
        snapshot formatted
        preparation_failed=1
      fi
    else
      snapshot raw-generation
      preparation_failed=1
    fi
  else
    preparation_failed=1
  fi
  snapshot consumed
done
((preparation_failed == 0))
compare_trees formatted
compare_trees consumed

# Retain focused-check failures while still obtaining both real full-build
# statuses when generation and the complete source comparison passed.
SOURCE="$SOURCE_ROOT/candidate"
PROVENANCE="$OUT/provenance/candidate"
cd "$SOURCE/app"
checks_failed=0
stage focused-tests fvm flutter test test/unit/util/native/linux_autostart_test.dart || checks_failed=1
stage analyze fvm flutter analyze --no-pub --fatal-infos --fatal-warnings lib/util/native/autostart_helper.dart lib/util/native/linux_autostart.dart lib/pages/tabs/settings_tab.dart lib/pages/tabs/settings_tab_controller.dart lib/pages/tabs/settings_tab_vm.dart test/unit/util/native/linux_autostart_test.dart || checks_failed=1
snapshot consumed
cmp ../pubspec.lock "$INPUT/provenance/resolved-pubspec.lock"
compare_trees consumed

builds_failed=0
for variant in baseline candidate; do
  SOURCE="$SOURCE_ROOT/$variant"
  PROVENANCE="$OUT/provenance/$variant"
  cd "$SOURCE/app"
  # Hash exactly what each compile is about to consume and compare again.
  snapshot consumed
  compare_trees consumed
  cp lib/util/native/autostart_helper.dart "$PROVENANCE/consumed-autostart-helper.dart"
  cp ../pubspec.lock "$PROVENANCE/resolved-pubspec.lock"
  if stage linux-release-build fvm flutter build linux --release --no-pub; then
    cmp ../pubspec.lock "$INPUT/provenance/resolved-pubspec.lock"
    stage archive-bundle tar -czf "$OUT/$variant-source-bundle.tar.gz" -C build/linux/x64/release/bundle .
    (cd "$OUT" && sha256sum "$variant-source-bundle.tar.gz") >> "$OUT/SHA256SUMS"
  else
    builds_failed=1
  fi
  snapshot after-build
done
compare_trees after-build
cd "$OUT"
printf 'product_patch=%s\nresolved_lock=%s\nbase=%s\nfocused_checks_failed=%s\nfull_builds_failed=%s\n' "$PATCH_SHA" "$LOCK_SHA" "$BASE" "$checks_failed" "$builds_failed" > provenance/comparison.txt
((checks_failed == 0 && builds_failed == 0))
printf 'normal_generation_and_both_full_builds=passed\n' >> provenance/comparison.txt
