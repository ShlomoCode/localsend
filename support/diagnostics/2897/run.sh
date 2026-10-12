#!/bin/bash
# Run only in the admitted fork Actions job. The signed application stays intact.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]] || exit 2
out="$GITHUB_WORKSPACE/evidence/issue2897"
scratch="$RUNNER_TEMP/issue2897"
mkdir -p "$out" "$scratch/mount"
app=/Applications/LocalSend.app
mount="$scratch/mount"
ax="$scratch/ax"
bundle=""
executable=""
recorder=""
video_case=""
capture_qualified=false
video_start=0
logger=""
installed=false
stage=environment
classification=infrastructure_failure
candidate_failure=false
last_failed_label=""
last_failed_code=""
printf "stage\tresult\n" > "$out/ledger.tsv"
# Bound long-running operations and retain stdout, stderr, and exit status.
run() {
  local label=$1 limit=$2 child start code=0
  shift 2
  # Artifact services reject colons and other reserved filename characters.
  # Preserve the original label inside the evidence, with a portable filename key.
  local original_label=$label
  label=$(printf '%s' "$label" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_')
  printf '%s\n' "$original_label" > "$out/$label.command-label.txt"
  "$@" > "$out/$label.stdout.txt" 2> "$out/$label.stderr.txt" &
  child=$!; start=$SECONDS
  while kill -0 "$child" 2>/dev/null; do
    if (( SECONDS - start >= limit )); then
      kill "$child" 2>/dev/null || true
      sleep 1
      kill -9 "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      printf "124\n" > "$out/$label.exit-code.txt"
      last_failed_label=$label
      last_failed_code=124
      return 124
    fi
    sleep 1
  done
  wait "$child" || code=$?
  printf "%s\n" "$code" > "$out/$label.exit-code.txt"
  if [[ $code != 0 ]]; then last_failed_label=$label; last_failed_code=$code; fi
  return "$code"
}
cleanup() {
  local code=$?
  local failure_label=$last_failed_label failure_code=$last_failed_code
  trap - EXIT
  printf "stage=%s\nclassification=%s\nexit=%s\nlast_failed_subcommand=%s\nlast_failed_subcommand_exit=%s\n" "$stage" "$classification" "$code" "$failure_label" "$failure_code" > "$out/result.txt"
  if [[ $code != 0 ]]; then
    printf 'Diagnostic stage=%s exit=%s last_failed_subcommand=%s subcommand_exit=%s\n' "$stage" "$code" "$failure_label" "$failure_code"
    if [[ -n $failure_label ]]; then
      printf 'Last failed subcommand stdout (first 6000 bytes):\n'
      head -c 6000 "$out/$failure_label.stdout.txt" || true
      printf '\nLast failed subcommand stderr (first 6000 bytes):\n'
      head -c 6000 "$out/$failure_label.stderr.txt" || true
      printf '\n'
    fi
  fi
  if [[ -x $ax && -n $bundle ]]; then run final-ax 10 "$ax" "$bundle" dump || true; fi
  run final-screen 10 screencapture -x "$out/final.png" || true
  if [[ -n $recorder ]]; then
    # Preserve the original failure status, but finalize and inspect its continuous
    # recording after the failure snapshot instead of killing it before that snapshot.
    if ! end_video "$video_case"; then
      printf 'Failure-path recording finalization failed; inspect retained video status and stderr.\n'
    fi
  fi
  if [[ -n $logger ]]; then kill "$logger" 2>/dev/null || true; stop_owned "$logger"; fi
  if [[ $installed == true ]]; then
    run signature-after 20 codesign --verify --deep --strict --verbose=2 "$app" || true
    run app-info-after 10 shasum -a 256 "$app/Contents/Info.plist" || true
    run executable-after 10 shasum -a 256 "$app/Contents/MacOS/$executable" || true
    run preferences-after 10 defaults read "$bundle" || true
    # Terminate only this diagnostic application. The ephemeral runner owns the installation.
    run terminate-app 15 osascript -e "tell application id \"$bundle\" to quit" || true
    run remove-installation 20 sudo rm -rf "$app" || true
  fi
  run detach 15 hdiutil detach "$mount" || true
  exit "$code"
}
stop_owned() {
  local pid=$1 start=$SECONDS
  while kill -0 "$pid" 2>/dev/null && (( SECONDS - start < 5 )); do sleep 1; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap cleanup EXIT
snapshot() {
  run "$1-ax" 10 "$ax" "$2" dump
  run "$1-screen" 10 screencapture -x "$out/$1.png"
}
wait_label() {
  local label=$1 start=$SECONDS attempt=0
  while (( SECONDS - start < 20 )); do
    attempt=$((attempt + 1))
    if run "$stage-wait-$label-$attempt" 5 "$ax" "$bundle" contains "$label"; then return 0; fi
    sleep 1
  done
  return 1
}
wait_picker() {
  local mode=$1 label=$2 start=$SECONDS attempt=0
  shift 2
  while (( SECONDS - start < 20 )); do
    attempt=$((attempt + 1))
    if run "$label-$attempt" 5 "$ax" "$bundle" "$mode" "$@"; then return 0; fi
    sleep 1
  done
  return 1
}
quit_app() {
  run "$1-quit" 15 osascript -e "tell application id \"$bundle\" to quit"
  local start=$SECONDS
  while pgrep -x "$executable" >/dev/null; do
    (( SECONDS - start < 15 )) || return 1
    sleep 1
  done
  printf "process_absent=true\n" > "$out/$1-process-state.txt"
}
ready_app() {
  local label=$1 start=$SECONDS attempt=0 enhanced=false permission_attempts=1
  # Native process/window qualification precedes Flutter semantics. A missing
  # tree at startup remains a harness/environment failure, never an app failure.
  while (( SECONDS - start < 20 )); do
    attempt=$((attempt + 1))
    if run "$label-native-window-$attempt" 5 "$ax" "$bundle" windows; then break; fi
    sleep 1
  done
  (( SECONDS - start < 20 )) || return 1
  for attempt in 1 2 3; do
    if run "$label-enhanced-interface-$attempt" 6 "$ax" "$bundle" enhance; then enhanced=true; break; fi
    sleep 1
  done
  [[ $enhanced == true ]]
  # The first launch can show the system prompt after the app window appears.
  # All retries preserve exact contextual matching; other permission prompts remain untouched.
  if [[ $label == control-startup ]]; then permission_attempts=3; fi
  for (( attempt=1; attempt<=permission_attempts; attempt++ )); do
    run "$label-before-network-prompt-$attempt" 5 screencapture -x "$out/$label-before-network-prompt-$attempt.png"
    run "$label-network-prompt-tree-$attempt" 5 "$ax" com.apple.UserNotificationCenter dump || true
    run "$label-native-network-allow-$attempt" 8 "$ax" com.apple.UserNotificationCenter allow-network
    if grep -Eq '"observed"[[:space:]]*:[[:space:]]*true' "$out/$label-native-network-allow-$attempt.stdout.txt"; then break; fi
    if (( attempt < permission_attempts )); then sleep 2; fi
  done
  wait_label Send
}
video() {
  local start=$SECONDS
  [[ $capture_qualified == true ]]
  # Keep the original continuous capture through the case result, with a native hard cap.
  video_start=$SECONDS
  video_case=$1
  printf "event\tscript_seconds\tutc\nrecord_start\t%s\t%s\n" "$SECONDS" "$(date -u +%FT%TZ)" > "$out/$1-timeline.tsv"
  # Bash background commands can inherit ignored SIGINT. Reset it before exec,
  # so the unchanged native capture command can finalize on the later SIGINT.
  /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die $!;' /usr/sbin/screencapture -v -V 240 -D 1 "$out/$1.mov" > "$out/$1-video.stdout.txt" 2> "$out/$1-video.stderr.txt" &
  recorder=$!
  sleep 2
  kill -0 "$recorder"
  # Normal-completion qualification proves this native main-display mechanism
  # can yield playable video. A live MOV can remain empty before finalization;
  # its size is an observation, while final playback remains mandatory.
  while (( SECONDS - start < 12 )); do
    if ! kill -0 "$recorder" 2>/dev/null; then
      printf 'recorder_alive=false\nmovie_bytes=%s\n' "$(stat -f %z "$out/$1.mov" 2>/dev/null || printf 0)" > "$out/$1-video-health.txt"
      return 1
    fi
    sleep 1
  done
  kill -0 "$recorder"
  printf 'recorder_pid=%s\nrecorder_alive=true\nmain_display_normal_completion_qualified=true\nmovie_bytes=%s\n' "$recorder" "$(stat -f %z "$out/$1.mov" 2>/dev/null || printf 0)" > "$out/$1-video-health.txt"
  printf "action_start\t%s\t%s\n" "$SECONDS" "$(date -u +%FT%TZ)" >> "$out/$1-timeline.tsv"
}
qualify_capture() {
  local kind capture_code metadata_code bytes explicit_pass=false
  printf 'case\tcapture_exit\tmovie_bytes\tmetadata_exit\n' > "$out/capture-qualification.tsv"
  run native-active-displays 10 "$ax" com.apple.finder displays
  # Hold the native capture command, duration, and signal disposition constant.
  # Only explicit selection of the documented main display differs between trials.
  for kind in implicit main-display; do
    capture_code=0; metadata_code=missing_movie
    if [[ $kind == implicit ]]; then
      if run "capture-qualification-$kind" 30 /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die $!;' /usr/sbin/screencapture -v -V 8 "$out/capture-qualification-$kind.mov"; then :; else capture_code=$?; fi
    else
      if run "capture-qualification-$kind" 30 /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die $!;' /usr/sbin/screencapture -v -V 8 -D 1 "$out/capture-qualification-$kind.mov"; then :; else capture_code=$?; fi
    fi
    bytes=$(stat -f %z "$out/capture-qualification-$kind.mov" 2>/dev/null || printf 0)
    if [[ -s $out/capture-qualification-$kind.mov ]]; then
      if run "capture-qualification-$kind-metadata" 30 "$scratch/media" "$out/capture-qualification-$kind.mov" 7; then metadata_code=0; else metadata_code=$?; fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$kind" "$capture_code" "$bytes" "$metadata_code" >> "$out/capture-qualification.tsv"
    if [[ $kind == main-display && $capture_code == 0 && $metadata_code == 0 ]]; then explicit_pass=true; fi
  done
  # Both raw trials survive a failure. No app case begins without a playable,
  # normally completed main-display movie and its decoded inspection frames.
  [[ $explicit_pass == true ]] || return 1
  capture_qualified=true
}
end_video() {
  local code=0 final=$SECONDS stop_start
  # The final UI snapshot must occur while the original recording is still live.
  # If an operation exceeds the recording budget, retain partial evidence as infrastructure failure.
  if ! kill -0 "$recorder" 2>/dev/null; then
    wait "$recorder" || code=$?
    printf '%s\n' "$code" > "$out/$1-video.exit-code.txt"
    recorder=""
    return 1
  fi
  printf "final_snapshot\t%s\t%s\n" "$final" "$(date -u +%FT%TZ)" >> "$out/$1-timeline.tsv"
  # Retain a short tail, then let native screencapture finalize the movie on SIGINT.
  sleep 3
  if ! kill -0 "$recorder" 2>/dev/null; then
    wait "$recorder" || code=$?
    printf '%s\n' "$code" > "$out/$1-video.exit-code.txt"
    recorder=""
    return 1
  fi
  kill -INT "$recorder" || return 1
  stop_start=$SECONDS
  while kill -0 "$recorder" 2>/dev/null; do
    if (( SECONDS - stop_start >= 15 )); then
      kill -9 "$recorder" 2>/dev/null || true
      wait "$recorder" 2>/dev/null || true
      printf "124\n" > "$out/$1-video.exit-code.txt"
      recorder=""
      return 1
    fi
    sleep 1
  done
  wait "$recorder" || code=$?
  recorder=""
  printf "%s\n" "$code" > "$out/$1-video.exit-code.txt"
  [[ ( $code == 0 || $code == 130 ) && -s $out/$1.mov ]] || return 1
  run "$1-video-metadata" 30 "$scratch/media" "$out/$1.mov" "$((final - video_start))"
}
empty_selection() {
  run "$1-empty-file-picker" 5 "$ax" "$bundle" contains File
  run "$1-empty-no-edit" 5 "$ax" "$bundle" absent Edit
  run "$1-empty-no-count" 5 "$ax" "$bundle" count-absent
}
named_selection() {
  run "$1-selection-one" 5 "$ax" "$bundle" contains 'Files: 1'
  run "$1-selection-edit" 10 "$ax" "$bundle" press Edit
  wait_label "$2"
  run "$1-selected-row" 5 "$ax" "$bundle" contains "$2"
  snapshot "$1-selected-named-row" "$bundle"
}
run os 10 sw_vers
run architecture 10 uname -a
[[ $(uname -m) == arm64 && $(sw_vers -productVersion | cut -d . -f1) == 15 ]]
run hardware 20 system_profiler SPHardwareDataType SPDisplaysDataType
run gui-session 10 launchctl print "gui/$(id -u)"
[[ $(stat -f %Su /dev/console) == $(id -un) ]]
run processes-before 10 ps -axo pid,ppid,uid,comm
printf "image=%s\nimageVersion=%s\ncommit=%s\nrun=%s\nattempt=%s\n" "${ImageOS:-unknown}" "${ImageVersion:-unknown}" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" > "$out/runner.txt"
run initial-screen 10 screencapture -x "$out/initial.png" || true
run capture-help 10 screencapture -h || true
run compile-ax 120 swiftc support/diagnostics/2897/ax.swift -o "$ax"
run compile-media 120 swiftc support/diagnostics/2897/media.swift -o "$scratch/media"
stage=installation
[[ ! -e $app ]]
url=https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2.dmg
printf "%s\n" "$url" > "$out/artifact-url.txt"
if ! run download 240 curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 --write-out '%{http_code}' --dump-header "$out/download-headers.txt" "$url" -o "$scratch/release.dmg"; then
  [[ $(cat "$out/download.stdout.txt") == 418 ]] || exit 1
  run download-proxy 240 curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 --proxy socks5h://100.108.223.54:38471 --write-out '%{http_code}' --dump-header "$out/download-proxy-headers.txt" "$url" -o "$scratch/release.dmg"
  [[ $(cat "$out/download-proxy.stdout.txt") == 200 ]]
else
  [[ $(cat "$out/download.stdout.txt") == 200 ]]
fi
run dmg-hash 10 shasum -a 256 "$scratch/release.dmg"
[[ $(cut -d " " -f1 "$out/dmg-hash.stdout.txt") == 126860d56f6f49b11845f601aac51de27a49b16d2b48102415da91e0e37e5155 ]]
# The historical release asset metadata records this byte size. Retain the hash for exact identity.
[[ $(stat -f %z "$scratch/release.dmg") == 52700247 ]]
run mount 30 hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$scratch/release.dmg"
[[ -d $mount/LocalSend.app ]]
run original-signature 20 codesign -dv --verbose=4 "$mount/LocalSend.app"
run original-verification 20 codesign --verify --deep --strict --verbose=2 "$mount/LocalSend.app"
installed=true
run install 30 sudo ditto "$mount/LocalSend.app" "$app"
info="$app/Contents/Info.plist"
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info")
executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info")
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info") == 1.18.2 ]]
run app-info 10 plutil -convert json -o "$out/app-info.json" "$info"
run installed-signature 20 codesign -dv --verbose=4 "$app"
run installed-verification 20 codesign --verify --deep --strict --verbose=2 "$app"
grep -q "Authority=Developer ID Application:" "$out/installed-signature.stderr.txt"
grep -Eq "TeamIdentifier=[A-Z0-9]+" "$out/installed-signature.stderr.txt"
run gatekeeper 30 spctl --assess --type execute --verbose=4 "$app"
run executable-architecture 10 lipo -archs "$app/Contents/MacOS/$executable"
grep -q arm64 "$out/executable-architecture.stdout.txt"
run app-info-before 10 shasum -a 256 "$info"
run executable-before 10 shasum -a 256 "$app/Contents/MacOS/$executable"
run executable-original 10 shasum -a 256 "$mount/LocalSend.app/Contents/MacOS/$executable"
[[ $(cut -d " " -f1 "$out/executable-before.stdout.txt") == $(cut -d " " -f1 "$out/executable-original.stdout.txt") ]]
[[ ! -e $app/Contents/MacOS/settings.json ]]
if defaults read "$bundle" > "$out/preferences-before.txt" 2>&1; then
  printf "Existing preferences; fresh-profile qualification failed.\n" >&2
  exit 1
fi
find "$HOME/Library/Application Support" -maxdepth 2 -iname '*localsend*' -print > "$out/app-support-before.txt"
[[ ! -s $out/app-support-before.txt ]]
printf "bundle=%s\nexecutable=%s\ninstallation=%s\n" "$bundle" "$executable" "$app" > "$out/app-identity.txt"
mkdir -p "$HOME/Downloads/LocalSend-2897"
fixture_dir="$HOME/Downloads/LocalSend-2897"
for kind in control cold warm; do printf "issue2897 %s fixture\n" "$kind" > "$fixture_dir/2897-$kind.txt"; done
run fixture-hashes 10 shasum -a 256 "$fixture_dir/2897-control.txt" "$fixture_dir/2897-cold.txt" "$fixture_dir/2897-warm.txt"
log stream --style compact --level debug --predicate "process == \"$executable\" OR process == \"Finder\"" > "$out/unified.log" 2>&1 &
logger=$!
stage=native_gui_qualification
run native-permissions 10 "$ax" com.apple.finder capability
stage=native_capture_qualification
qualify_capture
stage=picker_control
run launch-control 20 open -a "$app"
ready_app control-startup
run control-frontmost 10 "$ax" "$bundle" active
snapshot control-start "$bundle"
video control
run control-send 10 "$ax" "$bundle" press Send
run control-file 10 "$ax" "$bundle" press File
wait_picker picker-ready control-native-picker-ready
snapshot control-picker "$bundle"
run control-go 10 "$ax" "$bundle" picker-go
wait_picker picker-editor control-native-go-editor
snapshot control-go-editor "$bundle"
run control-path 10 "$ax" "$bundle" picker-path "$fixture_dir/2897-control.txt"
snapshot control-go-path-readback "$bundle"
run control-go-confirm 10 "$ax" "$bundle" picker-confirm "$fixture_dir/2897-control.txt"
wait_picker picker-selected control-native-fixture-selected 2897-control.txt
snapshot control-picker-selected "$bundle"
run control-open 10 "$ax" "$bundle" picker-open 2897-control.txt
wait_picker picker-closed control-native-picker-closed
wait_label 'Files: 1'
named_selection control 2897-control.txt
snapshot control-staged "$bundle"
end_video control
printf "picker_control\tvisible_named_file\n" >> "$out/ledger.tsv"
quit_app after-control
finder_case() {
  local kind=$1
  stage="finder_$kind"
  # Finder reveal selects the real file; AXShowMenu invokes its native context menu.
  # It does not call open -a LocalSend with a path or dispatch an app event directly.
  run "$kind-reveal" 15 osascript -e "tell application \"Finder\" to reveal POSIX file \"$fixture_dir/2897-$kind.txt\"" -e "tell application \"Finder\" to activate"
  sleep 1
  snapshot "$kind-finder-selected" com.apple.finder
  video "$kind"
  run "$kind-context" 10 "$ax" com.apple.finder menu "2897-$kind.txt"
  snapshot "$kind-context" com.apple.finder
  run "$kind-open-with" 10 "$ax" com.apple.finder press "Open With"
  sleep 1
  snapshot "$kind-open-with" com.apple.finder
  run "$kind-localsend" 10 "$ax" com.apple.finder press LocalSend
  ready_app "$kind-startup"
  run "$kind-frontmost" 10 "$ax" "$bundle" active
  run "$kind-process-after" 10 pgrep -x "$executable"
  if [[ $kind == warm ]]; then cmp "$out/warm-process.stdout.txt" "$out/warm-process-after.stdout.txt"; fi
  snapshot "$kind-app-after" "$bundle"
  run "$kind-send-tab" 10 "$ax" "$bundle" press Send
  if wait_label 'Files: 1'; then
    named_selection "$kind" "2897-$kind.txt"
    printf "finder_%s\tvisible_named_file\n" "$kind" >> "$out/ledger.tsv"
  else
    # The card exposes count and Edit, while filenames appear on the Edit page.
    # Accept a candidate failure only in the strictly empty picker branch.
    empty_selection "$kind"
    printf "finder_%s\tapp_opened_named_file_absent_candidate_failure\n" "$kind" >> "$out/ledger.tsv"
    candidate_failure=true
  fi
  snapshot "$kind-app-final" "$bundle"
  end_video "$kind"
}
# Each case starts with empty selection. The warm process is launched without a file.
finder_case cold
quit_app after-cold
run launch-warm 20 open -a "$app"
ready_app warm-empty-startup
run warm-frontmost 10 "$ax" "$bundle" active
run warm-empty-send-tab 10 "$ax" "$bundle" press Send
empty_selection warm-before-finder
snapshot warm-empty-send "$bundle"
run warm-process 10 pgrep -x "$executable"
finder_case warm
stage=installation_postconditions
run signature-postconditions 20 codesign --verify --deep --strict --verbose=2 "$app"
run app-info-postconditions 10 shasum -a 256 "$info"
run executable-postconditions 10 shasum -a 256 "$app/Contents/MacOS/$executable"
cmp "$out/app-info-before.stdout.txt" "$out/app-info-postconditions.stdout.txt"
cmp "$out/executable-before.stdout.txt" "$out/executable-postconditions.stdout.txt"
stage=complete
if [[ $candidate_failure == true ]]; then classification=candidate_reported_failure; else classification=control_and_handover_observed; fi
printf "Review screenshots, AX trees, and original continuous videos before accepting a reproduction claim. One cold and one warm observation do not establish repeatability.\n" > "$out/review-required.txt"
