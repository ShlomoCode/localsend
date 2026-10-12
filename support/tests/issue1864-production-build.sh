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

# Every ephemeral pair runner must independently qualify its required NDK.
bash "$root/support/tests/issue1864-ndk-toolchain.sh"

verify_candidate_source() {
  printf '%s  %s\n' \
    023e7d532e2e24685bc30615811b034924f6e33dc2df3196baa525ec5b014cef app/lib/util/native/file_picker.dart \
    9e6530f929986d7b10be48726ecb9c5a0d4d4aa48dc32e60836bb339dbda2d6d app/lib/util/ui/keyboard_asset_picker.dart \
    | tee "$1" | sha256sum -c -
}

# Reject candidate source/format/analysis failures before compiling either APK.
for variant in candidate baseline; do
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
      verify_candidate_source "$destination/reviewed-source-sha256.txt"
    else
      sha256sum app/lib/util/native/file_picker.dart > "$destination/reviewed-source-sha256.txt"
    fi
    cd app
    flutter pub get 2>&1 | tee "$destination/pub-get.log"
    cp ../pubspec.lock "$destination/pubspec.lock"
    git -C .. diff --binary -- pubspec.lock > "$destination/pub-lock-resolution.patch"
    files=(lib/util/native/file_picker.dart)
    if [ "$variant" = candidate ]; then files+=(lib/util/ui/keyboard_asset_picker.dart); fi
    dart format --output=none --set-exit-if-changed "${files[@]}" 2>&1 | tee "$destination/format.log"
    flutter analyze "${files[@]}" 2>&1 | tee "$destination/analyze.log"
    git -C .. diff --binary -- . ':!pubspec.lock' > "$destination/preflight-source.patch"
    test ! -s "$destination/preflight-source.patch"
    test -z "$(git -C .. ls-files --others --exclude-standard)"
  )
done
cmp "$evidence/baseline/pubspec-input.lock" "$evidence/candidate/pubspec-input.lock"
cmp "$evidence/baseline/pubspec.lock" "$evidence/candidate/pubspec.lock"
cmp "$evidence/baseline/Cargo-input.lock" "$evidence/candidate/Cargo-input.lock"

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
  checkout="$RUNNER_TEMP/issue1864-production-$variant"
  destination="$evidence/$variant"
  (
    cd "$checkout"
    if [ "$variant" = candidate ]; then
      verify_candidate_source "$destination/pre-build-reviewed-source-sha256.txt"
    fi
    cmp "$destination/pubspec.lock" pubspec.lock
    cmp "$destination/Cargo-input.lock" Cargo.lock
    git diff --binary -- . ':!pubspec.lock' > "$destination/pre-build-source.patch"
    test ! -s "$destination/pre-build-source.patch"
    # This ignored input is supported by the unchanged Gradle release block.
    if git ls-files --error-unmatch app/android/key.properties >/dev/null 2>&1; then
      echo 'Release key.properties must never be tracked' >&2
      exit 1
    fi
    git check-ignore -q app/android/key.properties
    printf 'storeFile=%s\nkeyAlias=issue1864-production-test\nstorePassword=%s\nkeyPassword=%s\n' \
      "$signing_store" "$ISSUE1864_SIGNING_PASSWORD" "$ISSUE1864_SIGNING_PASSWORD" > app/android/key.properties
    sha256sum app/android/key.properties | cut -d ' ' -f 1 > "$destination/signing-properties-sha256.txt"
    if [ "$variant" = candidate ]; then
      cmp "$evidence/baseline/signing-properties-sha256.txt" "$destination/signing-properties-sha256.txt"
    fi
    cd app
    set +e
    timeout --kill-after=60s 1800s flutter build apk --release --target-platform android-arm64 2>&1 | tee "$destination/build.log"
    build_pipeline_status=("${PIPESTATUS[@]}")
    set -e
    pipeline_status=0
    for status in "${build_pipeline_status[@]}"; do
      if [ "$status" -ne 0 ]; then pipeline_status=$status; fi
    done
    if ! printf 'build_exit=%s\nlog_exit=%s\npipeline_exit=%s\n' \
      "${build_pipeline_status[0]}" "${build_pipeline_status[1]}" "$pipeline_status" > "$destination/build-status.txt"; then
      if [ "$pipeline_status" -eq 0 ]; then exit 1; fi
    fi
    runner="$checkout/app/build/rust_lib_localsend_app/build/build_tool"
    if [ "$pipeline_status" -ne 0 ]; then
      # Collection is best effort and must never replace the original failure.
      for filename in pubspec.yaml pubspec.lock; do
        if [ -f "$runner/$filename" ] && [ ! -L "$runner/$filename" ]; then
          if cp "$runner/$filename" "$destination/cargokit-runner-$filename"; then
            printf '%s=copied\n' "$filename" >> "$destination/failed-runner-collection.txt" || true
          else
            printf '%s=copy-failed\n' "$filename" >> "$destination/failed-runner-collection.txt" || true
          fi
        else
          printf '%s=missing-or-nonregular-or-symlink\n' "$filename" >> "$destination/failed-runner-collection.txt" || true
        fi
      done
      exit "$pipeline_status"
    fi
    test -f "$runner/pubspec.yaml" && test ! -L "$runner/pubspec.yaml"
    test -f "$runner/pubspec.lock" && test ! -L "$runner/pubspec.lock"
    cp "$runner/pubspec.yaml" "$destination/cargokit-runner-pubspec.yaml"
    cp "$runner/pubspec.lock" "$destination/cargokit-runner-pubspec.lock"
    node "$root/support/tests/issue1864-cargokit-lock.mjs" "$checkout" "$destination" "$variant"
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
    # Preserve raw output and accept only the two exact signer label formats.
    sed -nE 's/^(V2 Signer:|Signer #[1-9][0-9]*) certificate SHA-256 digest: ([[:xdigit:]]{64})$/\2/p' \
      "$destination/apk-signing.txt" | tr 'A-F' 'a-f' > "$destination/apk-signer-sha256.txt"
    test -s "$destination/apk-signer-sha256.txt"
    # Reject unparsed extra certificate lines, including malformed digest labels.
    test "$(wc -l < "$destination/apk-signer-sha256.txt")" -eq \
      "$(grep -c 'certificate SHA-256 digest:' "$destination/apk-signing.txt")"
    while IFS= read -r signer_sha256; do
      test "$signer_sha256" = "$cert_sha256"
    done < "$destination/apk-signer-sha256.txt"
  )
done
cmp "$evidence/baseline/cargokit-runner-normalized.lock" "$evidence/candidate/cargokit-runner-normalized.lock"
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
