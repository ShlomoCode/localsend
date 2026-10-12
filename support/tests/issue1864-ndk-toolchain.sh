#!/usr/bin/env bash
# Cloud-only qualification; this does not compile or establish app behavior.
set -euo pipefail
export LC_ALL=C
root="$PWD"
destination="$root/evidence-cloud/ndk-toolchain"
mkdir -p "$destination"
test "${GITHUB_ACTIONS:-}" = true
test "${GITHUB_REPOSITORY:-}" = ShlomoCode/localsend
ndk_revision=28.2.13676358
sdk_root=$(realpath -e "${ANDROID_HOME:?Required existing Android SDK root}")
sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
test -x "$sdkmanager"
printf 'sdk_root=%s\nsdkmanager=%s\nsdkmanager_canonical=%s\nrequired_package=ndk;%s\n' \
  "$sdk_root" "$sdkmanager" "$(realpath -e "$sdkmanager")" "$ndk_revision" > "$destination/paths.txt"
timeout --kill-after=10s 60s flutter --version --machine > "$destination/flutter.json"
jq -e '.frameworkVersion == "3.41.9" and .dartSdkVersion == "3.11.5"' "$destination/flutter.json"
java -version 2> "$destination/java.txt"
grep -E 'version "17\.' "$destination/java.txt"
flutter_binary=$(realpath -e "$(command -v flutter)")
flutter_root=$(dirname "$(dirname "$flutter_binary")")
extension="$flutter_root/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt"
test -f "$extension" && test ! -L "$extension"
cp "$extension" "$destination/FlutterExtension.kt"
test "$(grep -Fc 'val ndkVersion:' "$extension")" -eq 1
grep -Fx '    val ndkVersion: String = "28.2.13676358"' "$extension" > "$destination/flutter-ndk-declaration.txt"
sha256sum "$extension" > "$destination/flutter-extension-sha256.txt"
timeout --kill-after=10s 60s "$sdkmanager" --version </dev/null > "$destination/sdkmanager-version.txt" 2>&1

# Shared reservations keep both collection phases under the same byte/file caps.
budget=$(mktemp "$RUNNER_TEMP/issue1864-ndk-budget.XXXXXXXX")
printf '0 0\n' > "$budget"
trap 'rm -f "$budget" "$budget.next"' EXIT
collect_phase() {
  local phase=$1 status
  mkdir -p "$destination/$phase" || return 1
  if timeout --kill-after=10s 120s bash "$root/support/tests/issue1864-ndk-collect.sh" \
    "$sdk_root" "$destination/$phase" "$budget" > "$destination/$phase/collector.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  printf 'collection_exit=%s\ntimeout_seconds=120\nkill_grace_seconds=10\n' "$status" \
    > "$destination/$phase/collection-status.txt" || return 1
  if [ "$status" -ne 0 ]; then
    printf '%s\n' 'Collection incomplete; inspect retained partial evidence. Exit 124/137 indicates timeout/kill.' \
      >> "$destination/$phase/collection-status.txt" || return 1
  fi
  return 0
}
diagnostics_status=0
collect_phase before || diagnostics_status=1
set +e
timeout --kill-after=30s 600s "$sdkmanager" --sdk_root="$sdk_root" \
  --verbose --install "ndk;$ndk_revision" </dev/null 2>&1 | tee "$destination/sdkmanager-install.log"
acquisition_status=("${PIPESTATUS[@]}")
set -e
pipeline_status=0
for status in "${acquisition_status[@]}"; do
  if [ "$status" -ne 0 ]; then pipeline_status=$status; fi
done
qualification_status=${acquisition_status[0]}
if [ "$qualification_status" -eq 0 ]; then qualification_status=${acquisition_status[1]}; fi
receipt_status=0
if ! printf 'sdkmanager_or_timeout_exit=%s\nlog_exit=%s\noriginal_pipefail_exit=%s\nqualification_exit=%s\n' \
  "${acquisition_status[0]}" "${acquisition_status[1]}" "$pipeline_status" "$qualification_status" \
  > "$destination/acquisition-status.txt"; then receipt_status=1; fi
if [ "$qualification_status" -ne 0 ]; then phase=after-failure; else phase=after; fi
collect_phase "$phase" || diagnostics_status=1
if [ "$qualification_status" -ne 0 ]; then exit "$qualification_status"; fi
test "$receipt_status" -eq 0
test "$diagnostics_status" -eq 0
test -s "$destination/sdkmanager-install.log"
installed="$sdk_root/ndk/$ndk_revision"
properties="$installed/source.properties"
test ! -L "$sdk_root/ndk" && test ! -L "$installed"
test -f "$properties" && test ! -L "$properties"
cp "$properties" "$destination/installed-source.properties"
test "$(grep -Fc 'Pkg.Revision' "$properties")" -eq 1
grep -Fx 'Pkg.Revision = 28.2.13676358' "$properties" > "$destination/installed-revision.txt"
test -x "$installed/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
sha256sum "$properties" > "$destination/installed-properties-sha256.txt"
printf '%s\n' 'Supported sdkmanager operation succeeded; exact required NDK revision is installed on this runner.' \
  > "$destination/qualification.txt"
