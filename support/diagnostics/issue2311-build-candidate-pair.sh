#!/usr/bin/env bash
# Resolve candidate locks first; build only after those locks are committed.
set -euo pipefail
workspace="$(realpath "${1:?workspace required}")"
evidence="$(realpath -m "${2:?evidence required}")"
baseline_ref=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
gal_base_ref=5a36aff5b0669690cd94a9443a6eed64d4c7cc78
mkdir -p "$evidence"
exec > >(tee "$evidence/run.log") 2>&1
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == ShlomoCode/localsend ]]
[[ "${CANDIDATE_REF:?}" =~ ^[0-9a-f]{40}$ && "${GAL_REF:?}" =~ ^[0-9a-f]{40}$ ]]
[[ "${CANDIDATE_STAGE:?}" == resolve-lock || "$CANDIDATE_STAGE" == build-pair ]]
[[ "$(git -C "$workspace/baseline" rev-parse HEAD)" == "$baseline_ref" ]]
[[ "$(git -C "$workspace/candidate" rev-parse HEAD)" == "$CANDIDATE_REF" ]]
[[ "$(git -C "$workspace/gal-reviewed" rev-parse HEAD)" == "$GAL_REF" ]]
for name in baseline candidate gal-reviewed; do
  [[ -z "$(git -C "$workspace/$name" status --porcelain --untracked-files=no)" ]]
done
git -C "$workspace/candidate" diff "$baseline_ref" "$CANDIDATE_REF" > "$evidence/localsend-source.diff"
git -C "$workspace/gal-reviewed" diff "$gal_base_ref" "$GAL_REF" > "$evidence/gal-source.diff"
sha256sum "$evidence/"*-source.diff > "$evidence/source-diffs.sha256"
printf 'stage=%s\nbaseline_source=%s\ncandidate_source=%s\ngal_base_source=%s\ngal_candidate_source=%s\nrun=https://github.com/ShlomoCode/localsend/actions/runs/%s\n' \
  "$CANDIDATE_STAGE" "$baseline_ref" "$CANDIDATE_REF" "$gal_base_ref" "$GAL_REF" "$GITHUB_RUN_ID" > "$evidence/identity.txt"

cd "$workspace/candidate"
fvm --version > "$evidence/fvm-version.txt"
fvm flutter --version --machine > "$evidence/flutter-version.json"
rustc --version --verbose > "$evidence/rust-version.txt"
java -version > "$evidence/java-version.txt" 2>&1
rustup target list --toolchain 1.97.1 --installed > "$evidence/rust-targets.txt"
grep -Fxq aarch64-linux-android "$evidence/rust-targets.txt"
for name in baseline candidate; do
  node - "$workspace/$name/.fvmrc" <<'NODE'
const fs = require('fs');
if (JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).flutter !== '3.41.9') throw new Error('Source Flutter pin differs');
NODE
  [[ "$(sed -n 's/^channel = "\([^"]*\)"$/\1/p' "$workspace/$name/packages/localsend_isolates/rust-toolchain.toml")" == 1.97.1 ]]
done
node - "$evidence/flutter-version.json" <<'NODE'
const fs = require('fs');
if (JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).frameworkVersion !== '3.41.9') throw new Error('Resolved FVM SDK differs');
NODE

retain_locks() {
  local dir="$1" out="$2" lock
  mkdir -p "$out"
  git -C "$dir" ls-files '*pubspec.lock' '*Cargo.lock' > "$out/tracked-locks.txt"
  while IFS= read -r lock; do
    mkdir -p "$out/$(dirname "$lock")"
    cp "$dir/$lock" "$out/$lock"
    (cd "$dir" && sha256sum "$lock") >> "$out/SHA256SUMS"
  done < "$out/tracked-locks.txt"
}
assert_locks() {
  local dir="$1" saved="$2" lock
  while IFS= read -r lock; do cmp "$dir/$lock" "$saved/$lock"; done < "$saved/tracked-locks.txt"
}
resolve_gal() {
  local dir="$1"
  node - "$dir/.dart_tool/package_config.json" <<'NODE'
const fs = require('fs');
const {pathToFileURL, fileURLToPath} = require('url');
const configPath = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(configPath, 'utf8')).packages.find(p => p.name === 'gal');
if (!pkg) throw new Error('Gal missing from normal resolved package configuration');
process.stdout.write(fileURLToPath(new URL(pkg.rootUri, pathToFileURL(configPath))));
NODE
}
verify_candidate_gal() {
  local dir="$1" out="$2" gal_dir
  gal_dir="$(resolve_gal "$dir")"
  [[ "$(git -C "$gal_dir" rev-parse HEAD)" == "$GAL_REF" ]]
  node - "$dir/pubspec.lock" "$GAL_REF" <<'NODE'
const fs = require('fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
const gal = text.match(/^  gal:\n([\s\S]*?)(?=^  [a-zA-Z_][\w]*:\n|^sdks:)/m)?.[1];
const sha = process.argv[3];
const pinned = gal && new RegExp(`^      ref: ["']?${sha}["']?\\s*$`, 'm').test(gal)
  && new RegExp(`^      resolved-ref: ["']?${sha}["']?\\s*$`, 'm').test(gal);
if (!pinned || !gal.includes('source: git') || !/url: ["']?https:\/\/github\.com\/ShlomoCode\/gal(?:\.git)?["']?\s*$/m.test(gal)) throw new Error('Gal lock is not the supplied immutable owned fork');
NODE
  mkdir -p "$out"
  git -C "$gal_dir" rev-parse HEAD > "$out/resolved-gal-source.txt"
  [[ -z "$(git -C "$gal_dir" status --porcelain --untracked-files=no)" ]]
  cp "$gal_dir/android/build.gradle" "$out/gal-android-build.gradle"
  tar -C "$gal_dir" -czf "$out/resolved-gal-source.tar.gz" lib android pubspec.yaml LICENSE
  sha256sum "$out/resolved-gal-source.tar.gz" > "$out/resolved-gal-source.sha256"
}

retain_locks "$workspace/candidate" "$evidence/candidate-original-locks"
if [[ "$CANDIDATE_STAGE" == resolve-lock ]]; then
  # This is the only stage that may update dependency locks. It produces no APK.
  fvm flutter pub get 2>&1 | tee "$evidence/candidate-pub-get.log"
  (cd packages/localsend_isolates/rust_builder/cargokit/build_tool && fvm dart pub get) 2>&1 | tee "$evidence/cargokit-pub-get.log"
  verify_candidate_gal "$workspace/candidate" "$evidence/candidate-gal"
  retain_locks "$workspace/candidate" "$evidence/locks-to-commit"
  git diff -- '*pubspec.lock' '*Cargo.lock' > "$evidence/locks-to-commit.diff"
  git diff -- . ':(exclude)*pubspec.lock' ':(exclude)*Cargo.lock' > "$evidence/unexpected-resolution-source.diff"
  [[ ! -s "$evidence/unexpected-resolution-source.diff" ]]
  [[ -z "$(git -C "$workspace/gal-reviewed" status --porcelain --untracked-files=no)" ]]

  # Preparatory formatting edits belong to owned source checkouts, never the
  # normally resolved package cache. Retain them for a separate source commit.
  format_out="$evidence/source-format-to-commit"
  callsite=packages/localsend_isolates/lib/src/task/server/file_saver.dart
  gal_files=(lib/src/gal.dart lib/src/gal_method_channel.dart lib/src/gal_platform_interface.dart)
  mkdir -p "$format_out/gal-original/lib/src" "$format_out/gal-formatted/lib/src"
  mkdir -p "$format_out/localsend-original/$(dirname "$callsite")" "$format_out/localsend-formatted/$(dirname "$callsite")"
  cp "$callsite" "$format_out/localsend-original/$callsite"
  for file in "${gal_files[@]}"; do
    cp "$workspace/gal-reviewed/$file" "$format_out/gal-original/$file"
  done
  fvm dart format "$callsite" 2>&1 | tee "$format_out/localsend-format.log"
  # Gal 2.3.3 declares Dart 3.0. Match its normal resolved language version
  # even though this independent owned checkout has no package_config yet.
  fvm dart format --language-version=3.0 "${gal_files[@]/#/$workspace/gal-reviewed/}" 2>&1 | tee "$format_out/gal-format.log"
  cp "$callsite" "$format_out/localsend-formatted/$callsite"
  for file in "${gal_files[@]}"; do
    cp "$workspace/gal-reviewed/$file" "$format_out/gal-formatted/$file"
  done
  git diff -- "$callsite" > "$format_out/localsend-format.diff"
  git -C "$workspace/gal-reviewed" diff -- "${gal_files[@]}" > "$format_out/gal-format.diff"
  git diff -- . ':(exclude)*pubspec.lock' ':(exclude)*Cargo.lock' ":(exclude)$callsite" > "$format_out/unexpected-localsend-source.diff"
  git -C "$workspace/gal-reviewed" diff -- . ":(exclude)${gal_files[0]}" ":(exclude)${gal_files[1]}" ":(exclude)${gal_files[2]}" > "$format_out/unexpected-gal-source.diff"
  [[ ! -s "$format_out/unexpected-localsend-source.diff" && ! -s "$format_out/unexpected-gal-source.diff" ]]
  assert_locks "$workspace/candidate" "$evidence/locks-to-commit"
  (cd "$format_out" && find gal-original gal-formatted localsend-original localsend-formatted -type f -print0 | sort -z | xargs -0 sha256sum) > "$format_out/source-files.sha256"
  printf 'purpose=preparatory source formatting; no APK built from these edits\noriginal_localsend_source=%s\noriginal_gal_source=%s\nnext_step=commit formatted source; repin immutable Gal ref if changed; resolve locks again before build-pair\n' \
    "$CANDIDATE_REF" "$GAL_REF" > "$format_out/identity.txt"
  printf 'result=locks and preparatory formatted source retained for commit; no APK built\n' >> "$evidence/identity.txt"
  exit 0
fi

# One disposable signing key is shared by the immutable pair. Never retain it.
signing_dir="$(mktemp -d)"
trap 'rm -rf "$signing_dir"' EXIT
export SIGNING_PASSWORD="$(node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))')"
keytool -genkeypair -keystore "$signing_dir/diagnostic.jks" -alias issue2311 \
  -storepass:env SIGNING_PASSWORD -keypass:env SIGNING_PASSWORD -keyalg RSA -keysize 2048 \
  -validity 30 -dname 'CN=LocalSend issue 2311 immutable diagnostic pair' -noprompt
printf 'signing=one disposable key for both APKs\n' >> "$evidence/identity.txt"
for name in baseline candidate; do
  dir="$workspace/$name"
  out="$evidence/$name"
  mkdir -p "$out"
  cd "$dir"
  retain_locks "$dir" "$out/source-locks"
  printf 'storePassword=%s\nkeyPassword=%s\nkeyAlias=issue2311\nstoreFile=%s\n' \
    "$SIGNING_PASSWORD" "$SIGNING_PASSWORD" "$signing_dir/diagnostic.jks" > app/android/key.properties
  fvm flutter pub get --enforce-lockfile 2>&1 | tee "$out/pub-get.log"
  (cd packages/localsend_isolates/rust_builder/cargokit/build_tool && fvm dart pub get --enforce-lockfile) 2>&1 | tee "$out/cargokit-pub-get.log"
  assert_locks "$dir" "$out/source-locks"
  gal_dir="$(resolve_gal "$dir")"
  if [[ "$name" == candidate ]]; then
    verify_candidate_gal "$dir" "$out"
    # Focused API compatibility and formatting checks; no code generation/edits.
    fvm dart format --output=none --set-exit-if-changed packages/localsend_isolates/lib/src/task/server/file_saver.dart 2>&1 | tee "$out/dart-format.log"
    fvm dart analyze packages/localsend_isolates/lib/src/task/server/file_saver.dart 2>&1 | tee "$out/dart-analyze.log"
    fvm dart format --language-version=3.0 --output=none --set-exit-if-changed "$gal_dir/lib/src/gal.dart" "$gal_dir/lib/src/gal_method_channel.dart" "$gal_dir/lib/src/gal_platform_interface.dart" 2>&1 | tee "$out/gal-format.log"
    # The baseline's normal build provisioned the Gradle wrapper. Use it for
    # sequential controlled-provider checks before building the candidate APK.
    cmp "$workspace/baseline/app/android/gradle/wrapper/gradle-wrapper.properties" "$dir/app/android/gradle/wrapper/gradle-wrapper.properties"
    plugin_path=android/src/main/java/studio/midoridesign/gal/GalPlugin.java
    plugin_hash="$(git -C "$workspace/gal-reviewed" show "$GAL_REF:$plugin_path" | sha256sum | cut -d ' ' -f 1)"
    bash "$workspace/diagnostics/support/diagnostics/gal2311-component/run-cloud.sh" \
      "$workspace/gal-reviewed" "$GAL_REF" "$plugin_hash" \
      "$workspace/baseline/app/android/gradlew" "$out/component"
  else
    tar -C "$gal_dir" -czf "$out/resolved-gal-source.tar.gz" lib android pubspec.yaml LICENSE
    cp "$gal_dir/android/build.gradle" "$out/gal-android-build.gradle"
    sha256sum "$out/resolved-gal-source.tar.gz" > "$out/resolved-gal-source.sha256"
  fi
  fvm flutter pub deps --style=compact > "$out/resolved-dependencies.txt"
  cp app/android/app/build.gradle "$out/app-android-build.gradle"
  node - "$gal_dir/android/build.gradle" "$out/gal-min-sdk.json" <<'NODE'
const fs = require('fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
const minSdk = Number(text.match(/\bminSdk(?:Version)?\s+(\d+)/)?.[1]);
if (!Number.isInteger(minSdk) || minSdk < 1 || minSdk > 21) throw new Error('Gal no longer has an explicit Android minSdk compatible with API 21');
fs.writeFileSync(process.argv[3], JSON.stringify({declared_plugin_min_sdk: minSdk, declared_min_sdk_allows_api21: true, runtime_validated: false}, null, 2) + '\n');
NODE
  # This normal release task compiles Gal Java through its existing Android
  # minSdk configuration. Android 21/29/35 runtime coverage is separate evidence.
  (cd app && fvm flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub) 2>&1 | tee "$out/release-build.log"
  assert_locks "$dir" "$out/source-locks"
  if [[ "$name" == candidate ]]; then
    [[ -z "$(git -C "$gal_dir" status --porcelain --untracked-files=no)" ]]
  fi
  git diff -- . > "$out/unexpected-source.diff"
  [[ ! -s "$out/unexpected-source.diff" ]]
  apk="$evidence/localsend-candidate-pair-$name-arm64.apk"
  cp app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$apk"
  sha256sum "$apk" > "$out/apk.sha256"
  build_tools="$(find "${ANDROID_HOME:?}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
  "$build_tools/aapt" dump badging "$apk" > "$out/apk-identity.txt"
  "$build_tools/apksigner" verify --print-certs "$apk" > "$out/apk-signature.txt"
done
unset SIGNING_PASSWORD
cmp "$evidence/baseline/apk-signature.txt" "$evidence/candidate/apk-signature.txt"
node - "$evidence" <<'NODE'
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const dir = process.argv[2];
const artifacts = ['baseline', 'candidate'].map(kind => {
  const filename = `localsend-candidate-pair-${kind}-arm64.apk`;
  return {kind, filename, sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, filename))).digest('hex')};
});
fs.writeFileSync(path.join(dir, 'artifact-contract.json'), JSON.stringify({schema_version: 1,
  source_family: 'candidate', baseline_source: 'c1ce322fb3acf08e44f329b8b7208b8b0d91e244',
  candidate_source: process.env.CANDIDATE_REF, gal_source: process.env.GAL_REF,
  target: 'android-arm64', mode: 'release', runtime_validated: false, artifacts}, null, 2) + '\n');
NODE
printf 'result=immutable pair built and signatures match; runtime validation remains separate\n' >> "$evidence/identity.txt"
