#!/usr/bin/env bash
# Cloud-only diagnostic source build. Both APKs keep the historical app behavior.
set -euo pipefail

source_dir="$(realpath "${1:?historical checkout required}")"
evidence_dir="$(realpath -m "${2:?evidence directory required}")"
expected_commit=7f21d1f9082a43803e05c37f021912e012145aa5
mkdir -p "$evidence_dir"
exec > >(tee "$evidence_dir/build.log") 2>&1
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == ShlomoCode/localsend ]]
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$expected_commit" ]]
[[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]
cd "$source_dir"
[[ "$(node -p "JSON.parse(require('fs').readFileSync('.fvmrc', 'utf8')).flutter")" == 3.24.5 ]]
[[ "$(flutter --version --machine | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).frameworkVersion))')" == 3.24.5 ]]

cat > "$evidence_dir/identity.txt" <<EOF
purpose=diagnostic source-build control and tagged cache/gallery boundary APKs
historical_tag=v1.17.0
historical_source=$expected_commit
diagnostic_infrastructure_commit=${GITHUB_SHA:?}
workflow_run=https://github.com/ShlomoCode/localsend/actions/runs/${GITHUB_RUN_ID:?}
workflow_attempt=${GITHUB_RUN_ATTEMPT:?}
target=android-arm64
mode=release
original_release_baseline=separate original v1.17.0 APK; these source builds do not replace it
EOF
git rev-parse HEAD^{tree} > "$evidence_dir/source-tree.txt"
cp .fvmrc "$evidence_dir/historical.fvmrc"
cp app/pubspec.yaml "$evidence_dir/historical-pubspec.yaml"
cp app/pubspec.lock "$evidence_dir/historical-pubspec.lock"
cp app/lib/util/native/file_saver.dart "$evidence_dir/file_saver.original.dart"
sha256sum app/pubspec.lock app/lib/util/native/file_saver.dart > "$evidence_dir/historical-source.sha256"
flutter --version --machine > "$evidence_dir/flutter-version.json"
dart --version > "$evidence_dir/dart-version.txt" 2>&1
java -version > "$evidence_dir/java-version.txt" 2>&1
rustc --version --verbose > "$evidence_dir/rust-version.txt"
flutter doctor -v > "$evidence_dir/flutter-doctor.txt" 2>&1

# Use supported release-signing inputs; create a disposable identity if absent.
# Never upload the keystore, signing properties, or passwords.
mkdir -p secrets
if [[ -n "${ANDROID_KEY_PROPERTIES:-}" && -n "${ANDROID_KEY_STORE:-}" ]]; then
  printf '%s' "$ANDROID_KEY_PROPERTIES" | base64 --decode > app/android/key.properties
  printf '%s' "$ANDROID_KEY_STORE" | base64 --decode > secrets/android-keystore.jks
  printf 'signing=existing fork release secrets\n' >> "$evidence_dir/identity.txt"
else
  export SIGNING_PASSWORD="$(node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))')"
  keytool -genkeypair -keystore "$source_dir/secrets/android-keystore.jks" \
    -storepass:env SIGNING_PASSWORD -keypass:env SIGNING_PASSWORD -alias issue2311 \
    -keyalg RSA -keysize 2048 -validity 30 -dname 'CN=LocalSend issue 2311 diagnostic' -noprompt
  printf 'storePassword=%s\nkeyPassword=%s\nkeyAlias=issue2311\nstoreFile=%s\n' \
    "$SIGNING_PASSWORD" "$SIGNING_PASSWORD" "$source_dir/secrets/android-keystore.jks" > app/android/key.properties
  unset SIGNING_PASSWORD
  printf 'signing=disposable diagnostic key shared by control and tagged APKs\n' >> "$evidence_dir/identity.txt"
fi
unset ANDROID_KEY_PROPERTIES ANDROID_KEY_STORE

cd app
flutter pub get 2>&1 | tee "$evidence_dir/pub-get.log"
cp pubspec.lock "$evidence_dir/resolved-pubspec.lock"
sha256sum pubspec.lock > "$evidence_dir/resolved-lock.sha256"
git diff -- pubspec.lock > "$evidence_dir/dependency-lock.diff"
flutter pub deps --style=compact > "$evidence_dir/resolved-dependencies.txt"
flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub 2>&1 | tee "$evidence_dir/control-build.log"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$evidence_dir/localsend-1.17.0-source-control-arm64.apk"
sha256sum "$evidence_dir/localsend-1.17.0-source-control-arm64.apk" > "$evidence_dir/control-apk.sha256"
cmp pubspec.lock "$evidence_dir/resolved-pubspec.lock"
git -C "$source_dir" diff -- . ':(exclude)app/pubspec.lock' > "$evidence_dir/control-source.diff"
[[ ! -s "$evidence_dir/control-source.diff" ]]

# Apply fail-closed source observations only in this separate cloud checkout.
node <<'NODE'
const fs = require('fs');
const path = 'lib/util/native/file_saver.dart';
let source = fs.readFileSync(path, 'utf8');
function replaceOnce(before, after) {
  if (source.split(before).length !== 2) throw new Error('Historical source boundary does not match: ' + before.slice(0, 80));
  source = source.replace(before, after);
}
replaceOnce('final _saf = SafStream();', `final _saf = SafStream();

// Diagnostic observation must not change save errors or timestamp values.
void _debug2311File(String stage, String path) {
  try {
    final stat = File(path).statSync();
    print('[DEBUG-2311] $stage path=$path type=\${stat.type} size=\${stat.size} mtimeUtc=\${stat.modified.toUtc().toIso8601String()} mtimeEpochMs=\${stat.modified.millisecondsSinceEpoch}');
  } catch (e) {
    print('[DEBUG-2311] $stage path=$path observationError=$e');
  }
}`);
replaceOnce('}) async {\n  if (!saveToGallery', `}) async {
  print('[DEBUG-2311] saveFile incoming path=$destinationPath gallery=$saveToGallery isImage=$isImage androidSdkInt=$androidSdkInt lastModifiedUtc=\${lastModified?.toUtc().toIso8601String()} lastModifiedEpochMs=\${lastModified?.millisecondsSinceEpoch}');
  if (!saveToGallery`);
replaceOnce('      await sink.close();', `      await sink.close();
      _debug2311File('sink-closed-before-setLastModified', destinationPath);`);
replaceOnce('          await file.setLastModified(lastModified);\n        } catch (_) {}', `          await file.setLastModified(lastModified);
          _debug2311File('setLastModified-success', destinationPath);
        } catch (e) {
          print('[DEBUG-2311] setLastModified-failed path=$destinationPath error=$e');
          _debug2311File('setLastModified-failure-stat', destinationPath);
        }`);
replaceOnce('    if (saveToGallery) {\n      isImage ? await Gal.putImage(destinationPath) : await Gal.putVideo(destinationPath);\n      await File(destinationPath).delete();\n    }', `    if (saveToGallery) {
      _debug2311File(isImage ? 'before-Gal.putImage' : 'before-Gal.putVideo', destinationPath);
      isImage ? await Gal.putImage(destinationPath) : await Gal.putVideo(destinationPath);
      _debug2311File('after-gallery-import-before-cache-delete', destinationPath);
      await File(destinationPath).delete();
      _debug2311File('after-cache-delete', destinationPath);
    }`);
replaceOnce('  } catch (_) {\n    try {\n      await close();', `  } catch (_) {
    _debug2311File('save-failed-before-original-cleanup', destinationPath);
    try {
      await close();`);
fs.writeFileSync(path, source);
NODE
cp lib/util/native/file_saver.dart "$evidence_dir/file_saver.tagged.dart"
git diff -- lib/util/native/file_saver.dart > "$evidence_dir/diagnostic-source.diff"
sha256sum lib/util/native/file_saver.dart "$evidence_dir/diagnostic-source.diff" > "$evidence_dir/diagnostic-source.sha256"
flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub 2>&1 | tee "$evidence_dir/tagged-build.log"
cmp pubspec.lock "$evidence_dir/resolved-pubspec.lock"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$evidence_dir/localsend-1.17.0-source-tagged-arm64.apk"
sha256sum "$evidence_dir/localsend-1.17.0-source-tagged-arm64.apk" > "$evidence_dir/tagged-apk.sha256"

android_build_tools="$(find "${ANDROID_HOME:?}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
for kind in control tagged; do
  apk="$evidence_dir/localsend-1.17.0-source-$kind-arm64.apk"
  "$android_build_tools/aapt" dump badging "$apk" > "$evidence_dir/$kind-apk-identity.txt"
  "$android_build_tools/apksigner" verify --print-certs "$apk" > "$evidence_dir/$kind-signature.txt"
done
cmp "$evidence_dir/control-signature.txt" "$evidence_dir/tagged-signature.txt"
cd "$evidence_dir"
sha256sum ./*.apk > APK-SHA256SUMS
printf 'result=both source APKs built; runtime behavior has not been validated by this job\n' >> identity.txt
