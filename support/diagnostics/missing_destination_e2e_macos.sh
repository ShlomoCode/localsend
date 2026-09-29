#!/usr/bin/env bash
set -euo pipefail

version="${1:?version is required}"
expected_missing_outcome="${2:?expected missing outcome is required}"
output_dir="${LS_MISSING_DESTINATION_OUTPUT:?LS_MISSING_DESTINATION_OUTPUT is required}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

dmg_name="LocalSend-${version}.dmg"
dmg_url="https://github.com/localsend/localsend/releases/download/v${version}/${dmg_name}"
dmg_path="$output_dir/$dmg_name"
mount_dir="$output_dir/mount"
app_dir="$output_dir/LocalSend-${version}.app"
cli_executable="${LS_CLI_PATH:?LS_CLI_PATH is required}"
cli_executable="$(cd "$(dirname "$cli_executable")" && pwd)/$(basename "$cli_executable")"
[[ -x "$cli_executable" ]]
report="$output_dir/report.txt"
receiver_pid=''

cleanup() {
  if [[ -n "$receiver_pid" ]]; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
    receiver_pid=''
  fi
  pkill -x localsend_app 2>/dev/null || true
  hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

write_settings() {
  local executable_dir="$1"
  local destination="$2"
  if [[ "$version" == '1.17.0' ]]; then
    python3 - "$executable_dir/settings.json" "$destination" <<'PY'
import json, sys
path, destination = sys.argv[1:]
with open(path, 'w', encoding='utf-8') as f:
    json.dump({
        'flutter.ls_version': 2,
        'flutter.ls_alias': 'E2E Receiver 1.17.0',
        'flutter.ls_port': 53317,
        'flutter.ls_destination': destination,
        'flutter.ls_quick_save': True,
        'flutter.ls_quick_save_from_favorites': False,
        'flutter.ls_https': True,
    }, f)
PY
  else
    python3 - "$executable_dir/settings.json" "$destination" <<'PY'
import json, sys
path, destination = sys.argv[1:]
with open(path, 'w', encoding='utf-8') as f:
    json.dump({
        'flutter.ls_version': 3,
        'flutter.ls_alias': 'E2E Receiver 1.18.2',
        'flutter.ls_port': 53317,
        'flutter.ls_destination': destination,
        'flutter.ls_quick_save': 'on',
        'flutter.ls_https': True,
    }, f)
PY
  fi
}

wait_for_port() {
  for _ in $(seq 1 160); do
    if nc -z 127.0.0.1 53317 >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  return 1
}

stop_receiver() {
  if [[ -n "$receiver_pid" ]]; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
    receiver_pid=''
  fi
  pkill -x localsend_app 2>/dev/null || true
  sleep 2
}

start_receiver() {
  local case_name="$1"
  if nc -z 127.0.0.1 53317 >/dev/null 2>&1; then
    echo "Port 53317 was already occupied before $case_name" >&2
    return 1
  fi
  "$app_executable" >"$output_dir/${case_name}-receiver.stdout.log" 2>"$output_dir/${case_name}-receiver.stderr.log" &
  receiver_pid=$!
  if ! wait_for_port; then
    echo "Receiver $version did not listen for $case_name" >&2
    return 1
  fi
  kill -0 "$receiver_pid" 2>/dev/null
}

send_file() {
  local fixture="$1"
  local case_name="$2"
  local stdout="$output_dir/${case_name}-sender.stdout.log"
  local stderr="$output_dir/${case_name}-sender.stderr.log"
  "$cli_executable" --port 53318 --alias E2E-Sender send --to 127.0.0.1 "$fixture" >"$stdout" 2>"$stderr" &
  local sender_pid=$!
  local timed_out=1
  for _ in $(seq 1 180); do
    if ! kill -0 "$sender_pid" 2>/dev/null; then
      timed_out=0
      break
    fi
    sleep 0.25
  done
  if [[ "$timed_out" == 1 ]]; then
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
    echo 'timeout'
    return 0
  fi
  set +e
  wait "$sender_pid"
  local status=$?
  set -e
  echo "$status"
}

curl -fL "$dmg_url" -o "$dmg_path"
rm -rf "$mount_dir" "$app_dir"
mkdir -p "$mount_dir"
hdiutil attach "$dmg_path" -mountpoint "$mount_dir" -nobrowse -readonly
source_app="$(find "$mount_dir" -maxdepth 2 -name '*.app' -print -quit)"
[[ -n "$source_app" ]]
ditto "$source_app" "$app_dir"
hdiutil detach "$mount_dir"
app_executable="$(find "$app_dir/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print -quit)"
[[ -x "$app_executable" && -x "$cli_executable" ]]

# The sandboxed app cannot rewrite resources inside its signed bundle. Portable
# mode still gives us deterministic settings if the in-bundle file is a symlink
# to the app's writable sandbox container.
portable_settings_dir="$HOME/Library/Containers/org.localsend.localsendApp/Data/Documents"
portable_settings="$portable_settings_dir/localsend-e2e-settings-$version.json"
receiver_destination_root="$portable_settings_dir/receive-e2e-$version"
mkdir -p "$portable_settings_dir"
rm -f "$portable_settings" "$(dirname "$app_executable")/settings.json"
rm -rf "$receiver_destination_root"
mkdir -p "$receiver_destination_root"
touch "$portable_settings"
ln -s "$portable_settings" "$(dirname "$app_executable")/settings.json"

fixture="$output_dir/flat-file-16MiB.bin"
mkfile -n 16m "$fixture"
fixture_hash="$(sha256 "$fixture")"
{
  echo "platform=macos"
  echo "os=$(sw_vers -productVersion)"
  echo "arch=$(uname -m)"
  echo "version=$version"
  echo "expected_missing_outcome=$expected_missing_outcome"
  echo "release_url=$dmg_url"
  echo "release_sha256=$(sha256 "$dmg_path")"
  echo "app_executable_sha256=$(sha256 "$app_executable")"
  echo "cli_source_commit=${GITHUB_SHA:-unknown}"
  echo "cli_path=$cli_executable"
  echo "cli_sha256=$(sha256 "$cli_executable")"
  echo "fixture_sha256=$fixture_hash"
} >"$report"

control_destination="$receiver_destination_root/control-destination"
mkdir -p "$control_destination"
write_settings "$(dirname "$app_executable")" "$control_destination"
start_receiver control
control_status="$(send_file "$fixture" control)"
sleep 2
control_receiver_alive=false
if kill -0 "$receiver_pid" 2>/dev/null && nc -z 127.0.0.1 53317 >/dev/null 2>&1; then control_receiver_alive=true; fi
control_received="$control_destination/$(basename "$fixture")"
control_hash='missing'
[[ -f "$control_received" ]] && control_hash="$(sha256 "$control_received")"
screencapture -x "$output_dir/control-after-send.png" 2>/dev/null || true
{
  echo "control_sender_status=$control_status"
  echo "control_receiver_alive=$control_receiver_alive"
  echo "control_received_hash=$control_hash"
} >>"$report"
stop_receiver
if [[ "$control_status" != 0 || "$control_hash" != "$fixture_hash" || "$control_receiver_alive" != true ]]; then
  echo 'Positive control failed; environment is invalid.' >&2
  exit 1
fi

matching_missing_runs=0
for iteration in 1 2; do
  case_name="missing-$iteration"
  destination="$receiver_destination_root/deleted-destination-$iteration"
  mkdir -p "$destination"
  write_settings "$(dirname "$app_executable")" "$destination"
  start_receiver "$case_name"
  rm -rf "$destination"
  [[ ! -e "$destination" ]]
  sender_status="$(send_file "$fixture" "$case_name")"
  sleep 2
  receiver_alive=false
  if kill -0 "$receiver_pid" 2>/dev/null && nc -z 127.0.0.1 53317 >/dev/null 2>&1; then receiver_alive=true; fi
  received="$destination/$(basename "$fixture")"
  received_hash='missing'
  [[ -f "$received" ]] && received_hash="$(sha256 "$received")"
  screencapture -x "$output_dir/${case_name}-after-send.png" 2>/dev/null || true
  destination_created=false
  [[ -d "$destination" ]] && destination_created=true
  transfer_succeeded=false
  [[ "$sender_status" == 0 && "$received_hash" == "$fixture_hash" && "$receiver_alive" == true ]] && transfer_succeeded=true
  {
    echo "missing_${iteration}_sender_status=$sender_status"
    echo "missing_${iteration}_receiver_alive=$receiver_alive"
    echo "missing_${iteration}_destination_created=$destination_created"
    echo "missing_${iteration}_received_hash=$received_hash"
    echo "missing_${iteration}_transfer_succeeded=$transfer_succeeded"
  } >>"$report"
  if [[ "$expected_missing_outcome" == success && "$transfer_succeeded" == true ]]; then
    matching_missing_runs=$((matching_missing_runs + 1))
  elif [[ "$expected_missing_outcome" == failure && "$transfer_succeeded" == false && "$received_hash" == missing && "$receiver_alive" == true ]]; then
    matching_missing_runs=$((matching_missing_runs + 1))
  fi
  stop_receiver
done

if [[ "$matching_missing_runs" != 2 ]]; then
  echo "Only $matching_missing_runs/2 missing-destination runs matched the expected outcome." >&2
  exit 1
fi

if [[ "$expected_missing_outcome" == success ]]; then
  echo 'verdict=pass-missing-destination-recreated' >>"$report"
else
  echo 'verdict=reproduced-missing-destination-failure' >>"$report"
fi
cat "$report"
