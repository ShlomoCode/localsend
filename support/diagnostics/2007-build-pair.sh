#!/usr/bin/env bash
# Normal source builds only. This runner never starts a BrowserStack device.
set -euo pipefail
umask 077

: "${PAIR_OUTPUT:?}"
mkdir -p "$PAIR_OUTPUT"

upload_pair() {
  : "${BS_SPRINT_USERNAME:?}" "${BS_SPRINT_ACCESS_KEY:?}"
  local label output response app_url baseline_cert candidate_cert
  baseline_cert=$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$PAIR_OUTPUT/baseline/apk-signature.txt")
  candidate_cert=$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$PAIR_OUTPUT/candidate/apk-signature.txt")
  [[ -n "$baseline_cert" && "$candidate_cert" == "$baseline_cert" ]]
  for label in baseline candidate; do
    output="$PAIR_OUTPUT/$label"
    response="$output/browserstack-upload.json"
    # Credentials are passed via stdin, not printed or saved with the artifact.
    # No custom_id: an existing upload must not be silently replaced.
    printf 'user = "%s:%s"\n' "$BS_SPRINT_USERNAME" "$BS_SPRINT_ACCESS_KEY" |
      curl --config - --silent --show-error --fail-with-body \
        --connect-timeout 30 --max-time 300 \
        -X POST https://api-cloud.browserstack.com/app-automate/upload \
        -F "file=@$output/app-arm64-v8a-release.apk" > "$response"
    app_url=$(jq -er '.app_url | select(startswith("bs://"))' "$response")
    jq --arg url "$app_url" '. + {browserstack_app_url: $url}' \
      "$output/provenance.json" > "$output/provenance.next.json"
    mv "$output/provenance.next.json" "$output/provenance.json"
  done
  jq -s '{baseline: .[0], candidate: .[1], device_sessions_started: false,
    helper_scanner_required: false, comparison: "Use real app UI with helper scanner OFF"}' \
    "$PAIR_OUTPUT/baseline/provenance.json" "$PAIR_OUTPUT/candidate/provenance.json" > "$PAIR_OUTPUT/build-pair.json"
}

build_source() (
  local label=$1 source=$2 expected_sha=$3 phase=${4:-build} output sdk_tools rust_pin source_sha status file formatter_failed=0
  [[ "$label" == baseline || "$label" == candidate ]]
  [[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]]
  source=$(realpath "$source")
  output="$PAIR_OUTPUT/$label"
  mkdir -p "$output"
  cd "$source"
  source_sha=$(git rev-parse HEAD)
  [[ "$source_sha" == "$expected_sha" ]]
  git diff --exit-code HEAD
  [[ -z "$(git status --porcelain)" ]]
  printf '%s\n' "$source_sha" > "$output/source-sha.txt"
  # Capture source integrity even when a dependency, check or build fails.
  trap 'status=$?; git diff --binary HEAD > "$output/post-build-tracked-source.diff";
    git status --porcelain > "$output/post-build-status.txt";
    printf "%s\n" "$status" > "$output/exit-status.txt";
    if [[ -s "$output/post-build-tracked-source.diff" ]]; then
      echo "Tracked source changed during build; see preserved diff." >&2; status=1;
    fi; exit "$status"' EXIT

  log_run() { local log=$1; shift; "$@" 2>&1 | tee "$output/$log.log"; }
  [[ "$(jq -er '.flutter' .fvmrc)" == 3.41.9 ]]
  log_run fvm-install fvm install --skip-pub-get
  rust_pin=$(sed -n 's/^channel = "\([^"]*\)"/\1/p' rust-toolchain.toml)
  [[ "$rust_pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ "$rust_pin" == "$(sed -n 's/^channel = "\([^"]*\)"/\1/p' packages/localsend_isolates/rust-toolchain.toml)" ]]
  log_run rust-install rustup toolchain install "$rust_pin" --profile minimal
  fvm flutter --version --machine > "$output/flutter-version.json"
  fvm dart --version > "$output/dart-version.txt" 2>&1
  rustc --version --verbose > "$output/rust-version.txt"
  java -version > "$output/java-version.txt" 2>&1
  fvm --version > "$output/fvm-version.txt"
  sdkmanager --list_installed > "$output/android-sdk.txt"
  cp .fvmrc rust-toolchain.toml "$output/"
  cp app/android/app/build.gradle "$output/android-app-build.gradle"
  (cd app && log_run pub-get fvm flutter pub get)
  (cd packages/localsend_isolates/rust_builder/cargokit/build_tool && log_run cargokit-pub-get fvm flutter pub get)

  if [[ "$phase" == check ]]; then
    [[ "$label" == candidate ]]
    git diff --name-only --diff-filter=ACMR -z "$BASELINE_REF" "$source_sha" -- '*.dart' > "$output/changed-dart-files.bin"
    while IFS= read -r -d '' file; do
      [[ -f "$file" ]] || continue
      if ! fvm dart format --output=none --set-exit-if-changed "$file" >> "$output/format-check.log" 2>&1; then
        formatter_failed=1
        mkdir -p "$output/formatted/$(dirname "$file")"
        fvm dart format --output=show --summary=none "$file" > "$output/formatted/$file"
        diff -u "$file" "$output/formatted/$file" >> "$output/formatter.diff" || [[ $? == 1 ]]
      fi
    done < "$output/changed-dart-files.bin"
    # Check both affected layers; preserve logs and formatter diff on failure.
    (cd packages/localsend_isolates && log_run package-analyze fvm flutter analyze)
    (cd app && log_run app-analyze fvm flutter analyze)
    (cd packages/localsend_isolates && log_run file-saver-test fvm flutter test test/task/server/file_saver_test.dart)
    [[ "$formatter_failed" == 0 ]] || { echo 'Format gate failed; see formatter.diff.' >&2; return 1; }
    return 0
  fi

  : "${PAIR_SIGNER:?}" "${PAIR_SIGNER_PASSWORD:?}"
  # Supported Gradle signing input, using the same signer for both builds.
  # storeFile is absolute because build.gradle resolves it from android/app.
  [[ ! -e app/android/key.properties ]]
  printf 'storeFile=%s\nstorePassword=%s\nkeyPassword=%s\nkeyAlias=diagnostics\n' \
    "$PAIR_SIGNER" "$PAIR_SIGNER_PASSWORD" "$PAIR_SIGNER_PASSWORD" > app/android/key.properties
  (cd app && log_run build-apk timeout --signal=TERM --kill-after=60s 90m \
    fvm flutter build apk --release --split-per-abi --target-platform android-arm64)
  cp app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$output/"
  sdk_tools="${ANDROID_HOME:?}/build-tools/36.0.0"
  "$sdk_tools/apksigner" verify --verbose --print-certs "$output/app-arm64-v8a-release.apk" > "$output/apk-signature.txt"
  "$sdk_tools/aapt2" dump badging "$output/app-arm64-v8a-release.apk" > "$output/apk-badging.txt"
  "$sdk_tools/aapt2" dump xmltree "$output/app-arm64-v8a-release.apk" --file AndroidManifest.xml > "$output/apk-manifest.txt"
  unzip -l "$output/app-arm64-v8a-release.apk" > "$output/apk-contents.txt"
  sha256sum "$output/app-arm64-v8a-release.apk" > "$output/apk-sha256.txt"
  git diff --exit-code HEAD
  jq -n --arg label "$label" --arg sha "$source_sha" \
    --arg apk_sha "$(cut -d ' ' -f1 "$output/apk-sha256.txt")" \
    --arg rust "$rust_pin" --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg runner_sha "${GITHUB_SHA:-}" --slurpfile flutter "$output/flutter-version.json" \
    '{label: $label, source_sha: $sha, diagnostic_runner_sha: $runner_sha,
      github_run_id: $run_id, apk: "app-arm64-v8a-release.apk", apk_sha256: $apk_sha,
      flutter: $flutter[0], rust: $rust, java_major: 17, fvm: "4.0.0",
      build_command: "fvm flutter build apk --release --split-per-abi --target-platform android-arm64",
      signing: "shared ephemeral diagnostic key via normal key.properties",
      tracked_source_unchanged: true, post_build_source_or_bytecode_modification: false,
      helper_scanner_required: false}' > "$output/provenance.json"
)

case "${1:-}" in
  build) [[ $# == 4 ]]; build_source "$2" "$3" "$4" ;;
  check) [[ $# == 4 ]]; build_source "$2" "$3" "$4" check ;;
  upload) [[ $# == 1 ]]; upload_pair ;;
  *) echo 'Usage: 2007-build-pair.sh build|check LABEL SOURCE IMMUTABLE_SHA | upload' >&2; exit 2 ;;
esac
