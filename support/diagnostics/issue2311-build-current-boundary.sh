#!/usr/bin/env bash
# Cloud-only build of current source, with an uninstrumented control first.
set -euo pipefail

source_dir="$(realpath "${1:?current checkout required}")"
evidence_dir="$(realpath -m "${2:?evidence directory required}")"
expected_commit=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
gallery_source=packages/localsend_isolates/lib/src/task/server/file_saver.dart
upload_source=packages/localsend_isolates/lib/src/isolate/child/server_isolate.dart
mkdir -p "$evidence_dir"
exec > >(tee "$evidence_dir/build.log") 2>&1
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == ShlomoCode/localsend ]]
[[ "${BUILD_TAGGED:-true}" == true || "${BUILD_TAGGED:-true}" == false ]]
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$expected_commit" ]]
[[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]
cd "$source_dir"
[[ "$(node -p "JSON.parse(require('fs').readFileSync('.fvmrc', 'utf8')).flutter")" == 3.41.9 ]]
[[ "$(flutter --version --machine | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).frameworkVersion))')" == 3.41.9 ]]
[[ "$(sed -n 's/^channel = "\([^"]*\)"$/\1/p' packages/localsend_isolates/rust-toolchain.toml)" == 1.97.1 ]]
[[ "${RUSTUP_TOOLCHAIN:?}" == 1.97.1 ]]

cat > "$evidence_dir/identity.txt" <<EOF
purpose=current source APK control and optional tagged cache/gallery observations
source_family=current
current_source=$expected_commit
diagnostic_infrastructure_commit=${GITHUB_SHA:?}
workflow_run=https://github.com/ShlomoCode/localsend/actions/runs/${GITHUB_RUN_ID:?}
workflow_attempt=${GITHUB_RUN_ATTEMPT:?}
target=android-arm64
mode=release
build_tagged=${BUILD_TAGGED:-true}
control_scope=exact tracked app source; SDK and signing identity recorded separately
historical_baseline=separate original v1.17.0 APK and historical source builds
EOF
git rev-parse HEAD^{tree} > "$evidence_dir/source-tree.txt"
cp .fvmrc "$evidence_dir/source.fvmrc"
cp packages/localsend_isolates/rust-toolchain.toml "$evidence_dir/source-rust-toolchain.toml"
cp app/pubspec.yaml "$evidence_dir/source-app-pubspec.yaml"
cp "$gallery_source" "$evidence_dir/file_saver.original.dart"
cp "$upload_source" "$evidence_dir/server_isolate.original.dart"
sha256sum "$gallery_source" "$upload_source" > "$evidence_dir/original-source.sha256"
flutter --version --machine > "$evidence_dir/flutter-version.json"
dart --version > "$evidence_dir/dart-version.txt" 2>&1
java -version > "$evidence_dir/java-version.txt" 2>&1
rustc --version --verbose > "$evidence_dir/rust-version.txt"
rustup target list --toolchain 1.97.1 --installed > "$evidence_dir/rust-installed-targets.txt"
grep -Fxq aarch64-linux-android "$evidence_dir/rust-installed-targets.txt"
flutter doctor -v > "$evidence_dir/flutter-doctor.txt" 2>&1

# Retain every tracked dependency lock, including the separate Cargokit tool.
git ls-files '*pubspec.lock' '*Cargo.lock' > "$evidence_dir/tracked-locks.txt"
while IFS= read -r lock; do
  mkdir -p "$evidence_dir/original-locks/$(dirname "$lock")"
  cp "$lock" "$evidence_dir/original-locks/$lock"
done < "$evidence_dir/tracked-locks.txt"
sha256sum pubspec.lock Cargo.lock > "$evidence_dir/original-lock.sha256"

# Keep both builds on the same supported signing inputs without source changes.
# Signing files and passwords must not enter the evidence directory.
mkdir -p secrets
if [[ -n "${ANDROID_KEY_PROPERTIES:-}" && -n "${ANDROID_KEY_STORE:-}" ]]; then
  printf '%s' "$ANDROID_KEY_PROPERTIES" | base64 --decode > app/android/key.properties
  printf '%s' "$ANDROID_KEY_STORE" | base64 --decode > secrets/android-keystore.jks
  printf 'signing=existing fork release secrets\n' >> "$evidence_dir/identity.txt"
else
  export SIGNING_PASSWORD="$(node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))')"
  keytool -genkeypair -keystore "$source_dir/secrets/android-keystore.jks" \
    -storepass:env SIGNING_PASSWORD -keypass:env SIGNING_PASSWORD -alias issue2311 \
    -keyalg RSA -keysize 2048 -validity 30 -dname 'CN=LocalSend issue 2311 current diagnostic' -noprompt
  printf 'storePassword=%s\nkeyPassword=%s\nkeyAlias=issue2311\nstoreFile=%s\n' \
    "$SIGNING_PASSWORD" "$SIGNING_PASSWORD" "$source_dir/secrets/android-keystore.jks" > app/android/key.properties
  unset SIGNING_PASSWORD
  printf 'signing=disposable diagnostic key shared by current control and tagged APKs\n' >> "$evidence_dir/identity.txt"
fi
unset ANDROID_KEY_PROPERTIES ANDROID_KEY_STORE

flutter pub get --enforce-lockfile 2>&1 | tee "$evidence_dir/pub-get.log"
(
  cd packages/localsend_isolates/rust_builder/cargokit/build_tool
  dart pub get --enforce-lockfile
) 2>&1 | tee "$evidence_dir/cargokit-pub-get.log"
cp pubspec.lock "$evidence_dir/resolved-pubspec.lock"
cp Cargo.lock "$evidence_dir/resolved-Cargo.lock"
sha256sum pubspec.lock Cargo.lock > "$evidence_dir/resolved-lock.sha256"
git diff -- '*pubspec.lock' '*Cargo.lock' > "$evidence_dir/dependency-lock.diff"
[[ ! -s "$evidence_dir/dependency-lock.diff" ]]
flutter pub deps --style=compact > "$evidence_dir/resolved-dependencies.txt"

assert_locks_unchanged() {
  local lock
  while IFS= read -r lock; do
    cmp "$source_dir/$lock" "$evidence_dir/original-locks/$lock"
  done < "$evidence_dir/tracked-locks.txt"
}

retain_apk() {
  local kind="$1"
  local apk="$evidence_dir/localsend-current-source-$kind-arm64.apk"
  local build_tools
  cp app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$apk"
  sha256sum "$apk" > "$evidence_dir/$kind-apk.sha256"
  build_tools="$(find "${ANDROID_HOME:?}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
  "$build_tools/aapt" dump badging "$apk" > "$evidence_dir/$kind-apk-identity.txt"
  "$build_tools/apksigner" verify --print-certs "$apk" > "$evidence_dir/$kind-signature.txt"
}

assert_locks_unchanged
(
  cd app
  flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
) 2>&1 | tee "$evidence_dir/control-build.log"
retain_apk control
assert_locks_unchanged
git diff -- . > "$evidence_dir/control-source.diff"
[[ ! -s "$evidence_dir/control-source.diff" ]]

if [[ "${BUILD_TAGGED:-true}" == true ]]; then
  # Source-level observation only. Original calls, error handling and timestamps stay intact.
  node <<'NODE'
const fs = require('fs');
function instrument(path, pairs) {
  let source = fs.readFileSync(path, 'utf8');
  for (const [before, after] of pairs) {
    if (source.split(before).length !== 2) throw new Error('Current source boundary does not match in ' + path + ': ' + before.slice(0, 80));
    source = source.replace(before, after);
  }
  fs.writeFileSync(path, source);
}
instrument('packages/localsend_isolates/lib/src/task/server/file_saver.dart', [
  ["final _logger = Logger('FileSaver');", `final _logger = Logger('FileSaver');

// Diagnostic reads must not alter gallery errors or filesystem metadata.
void _debug2311File(String stage, String path) {
  try {
    final stat = File(path).statSync();
    print('[DEBUG-2311] current $stage path=$path type=\${stat.type} size=\${stat.size} mtimeUtc=\${stat.modified.toUtc().toIso8601String()} mtimeEpochMs=\${stat.modified.millisecondsSinceEpoch}');
  } catch (e) {
    print('[DEBUG-2311] current $stage path=$path observationError=$e');
  }
}`],
  ['    isImage ? await Gal.putImage(cachedPath) : await Gal.putVideo(cachedPath);', `    _debug2311File(isImage ? 'before-Gal.putImage' : 'before-Gal.putVideo', cachedPath);
    isImage ? await Gal.putImage(cachedPath) : await Gal.putVideo(cachedPath);
    _debug2311File('after-gallery-import-before-cache-delete', cachedPath);`],
  ['    await File(cachedPath).delete();', `    await File(cachedPath).delete();
    _debug2311File('after-cache-delete', cachedPath);`],
]);
instrument('packages/localsend_isolates/lib/src/isolate/child/server_isolate.dart', [
  ['  final shouldSaveToGallery = config.saveToGallery && (isImage || dartFile.fileType == FileType.video);', `  final shouldSaveToGallery = config.saveToGallery && (isImage || dartFile.fileType == FileType.video);
  print('[DEBUG-2311] current incoming session=$sessionId fileId=$fileId fileName=$desiredName gallery=$shouldSaveToGallery modified=\${file.metadata?.modified} accessed=\${file.metadata?.accessed}');`],
]);
NODE
  cp "$gallery_source" "$evidence_dir/file_saver.tagged.dart"
  cp "$upload_source" "$evidence_dir/server_isolate.tagged.dart"
  git diff -- "$gallery_source" "$upload_source" > "$evidence_dir/diagnostic-source.diff"
  sha256sum "$gallery_source" "$upload_source" "$evidence_dir/diagnostic-source.diff" > "$evidence_dir/diagnostic-source.sha256"
  (
    cd app
    flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
  ) 2>&1 | tee "$evidence_dir/tagged-build.log"
  retain_apk tagged
  assert_locks_unchanged
  cmp "$evidence_dir/control-signature.txt" "$evidence_dir/tagged-signature.txt"
  git diff -- . ":(exclude)$gallery_source" ":(exclude)$upload_source" > "$evidence_dir/unexpected-source.diff"
  [[ ! -s "$evidence_dir/unexpected-source.diff" ]]
fi

# The replay validates the actual APK hash against this source identity contract.
node - "$evidence_dir" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const dir = process.argv[2];
const artifacts = ['control', 'tagged'].flatMap(kind => {
  const name = `localsend-current-source-${kind}-arm64.apk`;
  const filename = path.join(dir, name);
  return fs.existsSync(filename) ? [{kind, filename: name, sha256: crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex')}] : [];
});
fs.writeFileSync(path.join(dir, 'artifact-contract.json'), JSON.stringify({
  schema_version: 1,
  source_family: 'current',
  current_source: 'c1ce322fb3acf08e44f329b8b7208b8b0d91e244',
  artifact_name: `issue2311-current-boundary-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}`,
  app_version: '1.18.2+64',
  target: 'android-arm64',
  mode: 'release',
  runtime_validated: false,
  artifacts,
}, null, 2) + '\n');
NODE
cd "$evidence_dir"
sha256sum ./*.apk > APK-SHA256SUMS
printf 'result=requested APKs built; runtime behavior has not been validated by this job\n' >> identity.txt
