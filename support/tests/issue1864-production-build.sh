#!/usr/bin/env bash
# Cloud-only normal builds of the reviewed, uninjected production source pair.
set -euo pipefail

base=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
candidate=${ISSUE1864_CANDIDATE_COMMIT:?A reviewed candidate commit SHA is required}
[[ "$candidate" =~ ^[0-9a-f]{40}$ ]]
root="$PWD"
evidence="$root/evidence-cloud/production-pair"
mkdir -p "$evidence"
git fetch --no-tags origin "$base" "$candidate"
test "$(git rev-parse "$candidate^{commit}")" = "$candidate"
test "$(git merge-base "$base" "$candidate")" = "$base"
git diff --name-status "$base" "$candidate" > "$evidence/candidate-paths.txt"
printf 'M\tapp/lib/util/native/file_picker.dart\nA\tapp/lib/util/ui/keyboard_asset_picker.dart\n' > "$evidence/expected-paths.txt"
cmp "$evidence/expected-paths.txt" "$evidence/candidate-paths.txt"
git diff --binary "$base" "$candidate" > "$evidence/candidate.patch"
printf 'base=%s\ncandidate=%s\n' "$base" "$candidate" > "$evidence/source-heads.txt"

flutter --version --machine > "$evidence/flutter.json"
jq -e '.frameworkVersion == "3.41.9" and .dartSdkVersion == "3.11.5"' "$evidence/flutter.json"
rustc --version | tee "$evidence/rust.txt"
grep -E '^rustc 1\.97\.1 ' "$evidence/rust.txt"
java -version 2> "$evidence/java.txt"
grep -E 'version "17\.' "$evidence/java.txt"

# Use the existing release signing configuration with shared ephemeral inputs.
# Private material stays outside evidence-cloud and is removed on every exit.
umask 077
signing_dir=$(mktemp -d "$RUNNER_TEMP/issue1864-signing.XXXXXXXX")
signing_store="$signing_dir/release-test.jks"
export ISSUE1864_SIGNING_PASSWORD
ISSUE1864_SIGNING_PASSWORD=$(openssl rand -hex 32)
cleanup_signing() {
  rm -f "$RUNNER_TEMP/issue1864-production-baseline/app/android/key.properties" \
    "$RUNNER_TEMP/issue1864-production-candidate/app/android/key.properties"
  rm -rf "$signing_dir"
  unset ISSUE1864_SIGNING_PASSWORD
}
trap cleanup_signing EXIT
keytool -genkeypair -keystore "$signing_store" -storetype JKS -alias issue1864-production-test \
  -storepass:env ISSUE1864_SIGNING_PASSWORD -keypass:env ISSUE1864_SIGNING_PASSWORD \
  -keyalg RSA -keysize 2048 -validity 30 -dname 'CN=Issue1864 ephemeral cloud test' \
  > "$signing_dir/keytool.log" 2>&1
keytool -exportcert -keystore "$signing_store" -alias issue1864-production-test \
  -storepass:env ISSUE1864_SIGNING_PASSWORD -file "$evidence/signing-public-cert.der" \
  > "$signing_dir/export.log" 2>&1
sha256sum "$evidence/signing-public-cert.der" > "$evidence/signing-cert-sha256.txt"
sha256sum "$signing_store" | cut -d ' ' -f 1 > "$evidence/signing-keystore-sha256.txt"
printf '%s\n' 'Shared ephemeral test release key; private JKS and passwords excluded from artifacts; Gradle release signingConfig unchanged.' > "$evidence/signing-contract.txt"

for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then source_commit=$base; else source_commit=$candidate; fi
  checkout="$RUNNER_TEMP/issue1864-production-$variant"
  destination="$evidence/$variant"
  mkdir -p "$destination"
  git worktree add --detach "$checkout" "$source_commit"
  (
    cd "$checkout"
    test -z "$(git status --porcelain)"
    git rev-parse HEAD > "$destination/head.txt"
    git ls-tree -r HEAD > "$destination/source-tree.txt"
    if git grep -n -E 'ISSUE1864|diagnostic_asset_picker|diagnostic_picker_focus_trace' HEAD -- app/lib > "$destination/forbidden-app-source.txt"; then
      echo 'Diagnostic source is forbidden in a production checkout' >&2
      exit 1
    fi
    cp pubspec.lock "$destination/pubspec-input.lock"
    cp Cargo.lock "$destination/Cargo-input.lock"
    if [ "$variant" = candidate ]; then
      printf '%s  %s\n' \
        023e7d532e2e24685bc30615811b034924f6e33dc2df3196baa525ec5b014cef app/lib/util/native/file_picker.dart \
        7e91be6855ba0fd3a495b7afb2a4c881a43e595addccc878d59776599f6d4f7c app/lib/util/ui/keyboard_asset_picker.dart \
        | tee "$destination/reviewed-source-sha256.txt" | sha256sum -c -
    else
      sha256sum app/lib/util/native/file_picker.dart > "$destination/reviewed-source-sha256.txt"
    fi
    # This ignored input is supported by the unchanged Gradle release block.
    if git ls-files --error-unmatch app/android/key.properties >/dev/null 2>&1; then
      echo 'Release key.properties must never be tracked' >&2
      exit 1
    fi
    git check-ignore -q app/android/key.properties
    printf 'storeFile=%s\nkeyAlias=issue1864-production-test\nstorePassword=%s\nkeyPassword=%s\n' \
      "$signing_store" "$ISSUE1864_SIGNING_PASSWORD" "$ISSUE1864_SIGNING_PASSWORD" > app/android/key.properties
    sha256sum app/android/key.properties | cut -d ' ' -f 1 > "$destination/signing-properties-sha256.txt"
    cd app
    flutter pub get 2>&1 | tee "$destination/pub-get.log"
    cp ../pubspec.lock "$destination/pubspec.lock"
    git -C .. diff --binary -- pubspec.lock > "$destination/pub-lock-resolution.patch"
    files=(lib/util/native/file_picker.dart)
    if [ "$variant" = candidate ]; then files+=(lib/util/ui/keyboard_asset_picker.dart); fi
    dart format --output=none --set-exit-if-changed "${files[@]}" 2>&1 | tee "$destination/format.log"
    flutter analyze "${files[@]}" 2>&1 | tee "$destination/analyze.log"
    if [ "$variant" = candidate ]; then
      cmp "$evidence/baseline/pubspec-input.lock" "$destination/pubspec-input.lock"
      cmp "$evidence/baseline/pubspec.lock" "$destination/pubspec.lock"
      cmp "$evidence/baseline/Cargo-input.lock" "$destination/Cargo-input.lock"
      cmp "$evidence/baseline/signing-properties-sha256.txt" "$destination/signing-properties-sha256.txt"
    fi
    timeout --kill-after=60s 1800s flutter build apk --release --target-platform android-arm64 2>&1 | tee "$destination/build.log"
    cp ../Cargo.lock "$destination/Cargo.lock"
    cmp "$destination/Cargo-input.lock" "$destination/Cargo.lock"
    cmp "$destination/pubspec.lock" ../pubspec.lock
    # Resolved pub locks are retained and compared; app source stays untouched.
    git -C .. diff --binary -- . ':!pubspec.lock' > "$destination/post-build.patch"
    test ! -s "$destination/post-build.patch"
    test -z "$(git -C .. ls-files --others --exclude-standard)"
    if [ "$variant" = baseline ]; then apk_name=source-baseline; else apk_name=source-focus; fi
    cp build/app/outputs/flutter-apk/app-release.apk "$root/evidence-cloud/$apk_name.apk"
    apk="$root/evidence-cloud/$apk_name.apk"
    sha256sum "$apk" > "$destination/apk-sha256.txt"
    unzip -Z1 "$apk" | grep '^lib/' > "$destination/apk-libraries.txt"
    build_tools=$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
    "$build_tools/aapt" dump badging "$apk" > "$destination/apk-package.txt"
    "$build_tools/apksigner" verify --print-certs "$apk" > "$destination/apk-signing.txt"
    cert_sha256=$(sha256sum "$evidence/signing-public-cert.der" | cut -d ' ' -f 1)
    grep -F "Signer #1 certificate SHA-256 digest: $cert_sha256" "$destination/apk-signing.txt"
  )
done
cmp "$evidence/baseline/Cargo.lock" "$evidence/candidate/Cargo.lock"
cmp "$evidence/baseline/apk-libraries.txt" "$evidence/candidate/apk-libraries.txt"
cmp "$evidence/baseline/apk-package.txt" "$evidence/candidate/apk-package.txt"
cmp "$evidence/baseline/apk-signing.txt" "$evidence/candidate/apk-signing.txt"
jq -n --arg base "$base" --arg candidate "$candidate" \
  --arg baseApk "$(sha256sum "$root/evidence-cloud/source-baseline.apk" | cut -d ' ' -f 1)" \
  --arg candidateApk "$(sha256sum "$root/evidence-cloud/source-focus.apk" | cut -d ' ' -f 1)" \
  '{baseCommit:$base,candidateCommit:$candidate,baseApkSha256:$baseApk,candidateApkSha256:$candidateApk,flutter:"3.41.9",dart:"3.11.5",rust:"1.97.1",java:"17",build:"flutter build apk --release --target-platform android-arm64",diagnosticDefines:false}' \
  > "$evidence/app-source-manifest.json"
printf '%s\n' 'Normal release ARM64 builds; reviewed source hashes; no diagnostic defines or injected app source; identical resolved locks and signing.' > "$evidence/build-contract.txt"
