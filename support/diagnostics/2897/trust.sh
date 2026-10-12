#!/bin/bash
# Cloud-only artifact/trust observations. Never launch the app or change trust.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]] || exit 2
out="$GITHUB_WORKSPACE/evidence/issue2897-trust"
scratch="$RUNNER_TEMP/issue2897-trust"
app=/Applications/LocalSend.app
mount="$scratch/mount"
owned=false
last_label=none
mkdir -p "$out" "$mount"
run() {
  local label=$1 limit=$2 child start code=0
  shift 2
  last_label=$label
  printf 'start=%s\n' "$(date -u +%FT%TZ)" > "$out/$label.time.txt"
  "$@" > "$out/$label.stdout.txt" 2> "$out/$label.stderr.txt" &
  child=$!; start=$SECONDS
  while kill -0 "$child" 2>/dev/null; do
    if (( SECONDS - start >= limit )); then
      kill "$child" 2>/dev/null || true
      sleep 1
      kill -9 "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      printf '124\n' > "$out/$label.exit-code.txt"
      printf 'end=%s\n' "$(date -u +%FT%TZ)" >> "$out/$label.time.txt"
      return 124
    fi
    sleep 1
  done
  wait "$child" || code=$?
  printf '%s\n' "$code" > "$out/$label.exit-code.txt"
  printf 'end=%s\n' "$(date -u +%FT%TZ)" >> "$out/$label.time.txt"
  return "$code"
}
cleanup() {
  local code=$? label=$last_label
  trap - EXIT
  printf 'exit=%s\nlast_command=%s\napp_launch_performed=false\n' "$code" "$label" > "$out/result.txt"
  if [[ $code != 0 ]]; then
    printf 'Trust qualification exit=%s last_command=%s\n' "$code" "$label"
    head -c 6000 "$out/$label.stderr.txt" || true
  fi
  if [[ $owned == true ]]; then run remove-owned-installation 20 sudo rm -rf "$app" || true; fi
  run detach 20 hdiutil detach "$mount" || true
  exit "$code"
}
trap cleanup EXIT
run os 10 sw_vers
run architecture 10 uname -a
[[ $(uname -m) == arm64 && $(sw_vers -productVersion) == 15.7.9 ]]
[[ ${ImageOS:-} == macos15 && ${ImageVersion:-} == 20260907.0337.1 ]]
[[ ! -e $app ]]
printf 'image=%s\nimageVersion=%s\ncommit=%s\nrun=%s\nattempt=%s\n' "$ImageOS" "$ImageVersion" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" > "$out/runner.txt"
run hardware 20 system_profiler SPHardwareDataType
url=https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2.dmg
printf '%s\n' "$url" > "$out/artifact-url.txt"
if ! run download 120 curl --fail --location --retry 2 --connect-timeout 15 --max-time 100 --write-out '%{http_code}' --dump-header "$out/download-headers.txt" "$url" -o "$scratch/release.dmg"; then
  [[ $(cat "$out/download.stdout.txt") == 418 ]] || exit 1
  run download-proxy 120 curl --fail --location --retry 2 --connect-timeout 15 --max-time 100 --proxy socks5h://100.108.223.54:38471 --write-out '%{http_code}' --dump-header "$out/download-proxy-headers.txt" "$url" -o "$scratch/release.dmg"
  [[ $(cat "$out/download-proxy.stdout.txt") == 200 ]]
else
  [[ $(cat "$out/download.stdout.txt") == 200 ]]
fi
run dmg-hash 10 shasum -a 256 "$scratch/release.dmg"
[[ $(cut -d ' ' -f1 "$out/dmg-hash.stdout.txt") == 126860d56f6f49b11845f601aac51de27a49b16d2b48102415da91e0e37e5155 ]]
[[ $(stat -f %z "$scratch/release.dmg") == 52700247 ]]
trust_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run ticket-dmg 30 xcrun stapler validate "$scratch/release.dmg" || true
run mount 30 hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$scratch/release.dmg"
[[ -d $mount/LocalSend.app ]]
run original-signature 20 codesign -dv --verbose=4 "$mount/LocalSend.app"
run original-verification 20 codesign --verify --deep --strict --verbose=2 "$mount/LocalSend.app"
run ticket-original-app 30 xcrun stapler validate "$mount/LocalSend.app" || true
run gatekeeper-original 30 spctl --assess --type execute --verbose=4 "$mount/LocalSend.app" || true
owned=true
run install 30 sudo ditto "$mount/LocalSend.app" "$app"
info="$app/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info") == 1.18.2 ]]
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")
run app-info 10 plutil -convert json -o "$out/app-info.json" "$info"
run installed-signature 20 codesign -dv --verbose=4 "$app"
run installed-verification 20 codesign --verify --deep --strict --verbose=2 "$app"
run installed-executable-hash 10 shasum -a 256 "$app/Contents/MacOS/$executable"
run original-executable-hash 10 shasum -a 256 "$mount/LocalSend.app/Contents/MacOS/$executable"
[[ $(cut -d ' ' -f1 "$out/installed-executable-hash.stdout.txt") == $(cut -d ' ' -f1 "$out/original-executable-hash.stdout.txt") ]]
run installed-architecture 10 lipo -archs "$app/Contents/MacOS/$executable"
run ticket-installed-app 30 xcrun stapler validate "$app" || true
assessment=0
if run gatekeeper-installed 30 spctl --assess --type execute --verbose=4 "$app"; then :; else assessment=$?; fi
trust_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'trust_interval_start=%s\ntrust_interval_end=%s\ninstalled_assessment_exit=%s\n' "$trust_start" "$trust_end" "$assessment" > "$out/assessment-summary.txt"
run trust-service-log 30 log show --last 10m --style compact --predicate '(process == "syspolicyd" OR process == "trustd") AND (eventMessage CONTAINS[c] "LocalSend" OR eventMessage CONTAINS[c] "issue2897" OR eventMessage CONTAINS[c] "notar" OR eventMessage CONTAINS[c] "ticket")' || true
if [[ $assessment != 0 ]]; then
  printf 'Installed ordinary Gatekeeper assessment failed: exit=%s\n' "$assessment"
  head -c 6000 "$out/gatekeeper-installed.stderr.txt" || true
fi
# Interpret ticket absence and lookup failures from raw receipts; never override assessment.
exit "$assessment"
