#!/usr/bin/env bash
# Run only after the original timing and strict geometry phases finish.
set -euo pipefail
[[ ${PROBE_CLOUD_INTERACTIONS:-0} == 1 && $(id -un) == mint && $(uname -s) == Linux ]] || exit 8
source /etc/os-release
[[ $ID == linuxmint && -f /home/mint/evidence/bootstrap-complete ]] || exit 8
here=$(cd "$(dirname "$0")" && pwd -P)
[[ $here == /home/mint/support/diagnostics/2754-accessibility ]] || exit 8
[[ $# == 4 ]] || { echo 'Usage: capture-interactions.sh PID WINDOW_ID OUTPUT_DIR NORMAL_VERIFIED_LAUNCHER' >&2; exit 2; }
pid=$1 window=$2 out=$(realpath -m "$3") launcher=$(realpath "$4")
[[ $pid =~ ^[1-9][0-9]*$ && $window =~ ^[0-9]+$ && $launcher == /home/mint/support/diagnostics/2754-bridge-app ]] || exit 8
case "$out" in /home/mint/evidence/*) ;; *) exit 8 ;; esac
[[ ! -e $out/phase-started && -x $launcher && -z ${LD_LIBRARY_PATH:-} && -z ${LD_PRELOAD:-} ]] || exit 8
mkdir -p "$out"
date -u +%FT%TZ > "$out/phase-started"
printf '{"status":"incomplete","speech_status":"unknown","audio_status":"unknown"}\n' > "$out/result.json"
exec > >(tee "$out/harness.log") 2>&1
orca_pid= recorder_pid= events_pid= new_pid= sink_module= speechd_pid=
status=1
declare -A child_start
remember_child() {
 local child=$1
 child_start[$child]=$(awk '{print $22}' "/proc/$child/stat" 2>/dev/null || true)
 [[ -z ${child_start[$child]} ]] || cat "/proc/$child/cmdline" > "$out/owned-child-$child.cmdline" 2>/dev/null || true
}
live_child() {
 local child=$1
 [[ -n ${child_start[$child]:-} && -r /proc/$child/stat ]] || return 1
 [[ $(awk '{print $22}' "/proc/$child/stat" 2>/dev/null) == "${child_start[$child]}" &&
    $(awk '{print $3}' "/proc/$child/stat" 2>/dev/null) != Z ]] || return 1
 # A direct child may exec between $! and the first /proc snapshot. Its
 # process start time establishes ownership across that expected exec.
 return 0
}
stop_child() {
 local child=$1 first_signal=$2 attempt wait_status=0
 [[ -n $child ]] || return 0
 if live_child "$child"; then kill -"$first_signal" "$child" 2>/dev/null; fi
 for attempt in $(seq 1 50); do live_child "$child" || break; sleep 0.1; done
 if live_child "$child"; then kill -KILL "$child" 2>/dev/null; fi
 for attempt in $(seq 1 50); do live_child "$child" || break; sleep 0.1; done
 if live_child "$child"; then
  printf 'owned_child_still_alive=%s\n' "$child" >> "$out/cleanup-status.txt"
  return 1
 fi
 if [[ -z ${child_start[$child]:-} && -r /proc/$child/stat && $(awk '{print $3}' "/proc/$child/stat") != Z ]]; then
  printf 'child_ownership_not_recorded=%s\n' "$child" >> "$out/cleanup-status.txt"
  return 1
 fi
 # Once the owned child is gone or a zombie, wait only reaps its shell status.
 wait "$child" 2>/dev/null || wait_status=$?
 printf 'owned_child=%s wait_exit_status=%s\n' "$child" "$wait_status" >> "$out/cleanup-status.txt"
 return 0
}
app_start=$(awk '{print $22}' "/proc/$pid/stat")
app_exe=$(readlink "/proc/$pid/exe")
app_cmdline=$out/app-startup1-cmdline.bin
cat "/proc/$pid/cmdline" > "$app_cmdline"
owned_app() {
 [[ -r /proc/$pid/stat && $(awk '{print $22}' "/proc/$pid/stat") == "$app_start" && $(readlink "/proc/$pid/exe") == "$app_exe" ]] &&
   cmp -s "/proc/$pid/cmdline" "$app_cmdline"
}
cleanup() {
 local rc=$? item
 trap - EXIT
 set +e
 for item in "$events_pid" "$orca_pid"; do stop_child "$item" TERM || rc=1; done
 if [[ -n $recorder_pid ]]; then
  stop_child "$recorder_pid" INT || rc=1
 fi
 if [[ -s $out/audio-default-sink-before.txt ]]; then
  if pactl set-default-sink "$(cat "$out/audio-default-sink-before.txt")" > "$out/audio-default-sink-restore.log" 2>&1; then
   printf 'audio_default_sink_restore_status=0\n' >> "$out/cleanup-status.txt"
  else
   printf 'audio_default_sink_restore_status=%s\n' "$?" >> "$out/cleanup-status.txt"
   rc=1
  fi
 fi
 if [[ -n $sink_module ]]; then
  if pactl unload-module "$sink_module" > "$out/audio-sink-remove.log" 2>&1; then
   printf 'audio_sink_unload_status=0\n' >> "$out/cleanup-status.txt"
  else
   printf 'audio_sink_unload_status=%s\n' "$?" >> "$out/cleanup-status.txt"
   rc=1
  fi
 fi
 # The daemon is not waitable (wait returns 127), but the same bounded
 # identity checks apply to its termination and the recorded result.
 stop_child "$speechd_pid" TERM || rc=1
 printf 'harness_exit_status=%s\n' "$rc" > "$out/process-result.txt"
 if [[ -n $new_pid ]]; then printf '%s\n' "$new_pid" > "$out/restarted-app-pid.txt"; fi
 # Audio and real speech logs require correlation/review. Do not promote an
 # utterance request, recorder exit, or nonempty WAV to a speech pass.
 jq -n --argjson exit_status "$rc" \
  '{status:(if $exit_status == 0 then "completed" else "failed" end),exit_status:$exit_status,
    speech_status:"unknown",audio_status:"unknown",speech_and_audio_require_raw_evidence_review:true}' > "$out/result.json"
 exit "$rc"
}
trap cleanup EXIT
[[ $(xdotool getwindowpid "$window") == "$pid" ]]
pkg-config --modversion atspi-2 > "$out/libatspi-version.txt"
[[ $(cat "$out/libatspi-version.txt") == 2.52.* ]]
dpkg-query -W orca speech-dispatcher speech-dispatcher-espeak-ng python3-speechd libatspi2.0-0t64 libatspi2.0-dev \
  > "$out/package-versions.txt" 2>&1
pkg-config --cflags --libs atspi-2 glib-2.0 gobject-2.0 > "$out/build-flags.txt"
cc -std=gnu11 -Wall -Wextra -O0 -g "$here/interaction-client.c" -o "$out/interaction-client" \
  $(pkg-config --cflags --libs atspi-2 glib-2.0 gobject-2.0) 2> "$out/build.log"
sha256sum "$here/interaction-client.c" "$here/capture-interactions.sh" "$out/interaction-client" > "$out/fixture-sha256.txt"
run_client() {
 local mode=$1 label=$2 target=$3 rc=0
 date -u +%FT%TZ > "$out/$label.started.txt"
 timeout --kill-after=3s 90s "$out/interaction-client" "$target" "$mode" "$label" > "$out/$label.jsonl" 2> "$out/$label.stderr" || rc=$?
 jq -n --arg mode "$mode" --argjson status "$rc" '{mode:$mode,exit_status:$status,deadline_hit:($status == 124 or $status == 137)}' > "$out/$label.status.json"
 return "$rc"
}
wait_tree() {
 local mode=$1 label=$2 target=$3 attempt
 for attempt in $(seq 1 10); do
  if run_client "$mode" "$label-$attempt" "$target"; then return 0; fi
  sleep 1
 done
 return 1
}
snapshot_ui() {
 local label=$1 target=$2 expectation=$3
 timeout --kill-after=2s 10s xdotool search --onlyvisible --pid "$target" > "$out/$label.window-candidates.txt"
 mapfile -t windows < "$out/$label.window-candidates.txt"
 [[ ${#windows[@]} == 1 ]]
 local actual_window=${windows[0]} actual_pid
 actual_pid=$(xdotool getwindowpid "$actual_window")
 [[ $actual_pid == "$target" ]]
 xdotool getwindowname "$actual_window" > "$out/$label.window-name.txt"
 timeout --kill-after=2s 10s scrot "$out/$label.png"
 if command -v tesseract >/dev/null; then
  timeout --kill-after=2s 15s tesseract "$out/$label.png" stdout > "$out/$label.ocr.txt" 2> "$out/$label.ocr.stderr" || true
 fi
 jq -n --arg label "$label" --arg expectation "$expectation" --argjson pid "$actual_pid" --argjson window "$actual_window" \
  '{label:$label,expected_rendered_labels:$expectation,actual_window_pid:$pid,window_id:$window,visual_evidence_requires_review:true}' \
  > "$out/$label.window.json"
}
save_loader() {
 local destination=$1 f
 mkdir -p "$destination"
 for f in /home/mint/evidence/bridge-process* /home/mint/evidence/engine-process* /home/mint/evidence/engine-loader* \
   /home/mint/evidence/bridge-launch.txt /home/mint/evidence/bridge-app-pid.txt /home/mint/evidence/engine-loaded; do
  [[ ! -e $f ]] || cp -a "$f" "$destination/"
 done
}
save_loader "$out/startup1-loader"
run_client snapshot initial-dialog "$pid"
snapshot_ui initial-dialog "$pid" 'Type message'
run_client edit edit-readback "$pid"
"$out/interaction-client" "$pid" events interaction-events > "$out/events.jsonl" 2> "$out/events.stderr" &
events_pid=$!
remember_child "$events_pid"
for attempt in $(seq 1 100); do
 grep -q '"kind":"events_ready"' "$out/events.jsonl" && break
 kill -0 "$events_pid" 2>/dev/null || break
 sleep 0.1
done
grep -q '"kind":"events_ready"' "$out/events.jsonl"

# Orca and Speech Dispatcher use the normal user-session backend. Do not use
# spd-say, a test speech server, or fixture-generated utterance records.
orca --version > "$out/orca-version.txt"
orca --help > "$out/orca-help.txt"
for option in --debug --debug-file --speech-system --enable; do grep -q -- "$option" "$out/orca-help.txt"; done
[[ -z $(pgrep -u "$(id -u)" -x orca || true) ]] || { echo 'Existing Orca process: preserve it and stop this phase.' >&2; exit 9; }
speech-dispatcher --help > "$out/speech-dispatcher-help.txt"
pgrep -u "$(id -u)" -x speech-dispatch > "$out/speech-dispatcher-before.txt" || true
if [[ ! -s $out/speech-dispatcher-before.txt ]]; then
 grep -q -- --daemon "$out/speech-dispatcher-help.txt"
 speech-dispatcher --daemon > "$out/speech-dispatcher-start.log" 2>&1
 sleep 2
 pgrep -u "$(id -u)" -x speech-dispatch > "$out/speech-dispatcher-started-pids.txt"
 [[ $(wc -l < "$out/speech-dispatcher-started-pids.txt") == 1 ]]
 speechd_pid=$(cat "$out/speech-dispatcher-started-pids.txt")
 remember_child "$speechd_pid"
fi
# A PulseAudio null sink accepts real synthesized audio in a QEMU guest with
# no physical audio device. Its monitor recording remains raw review evidence.
if command -v pactl >/dev/null && command -v ffmpeg >/dev/null && pactl info > "$out/audio-server.txt" 2>&1; then
 sink_name=issue2754_orca_$$
 sink_module=$(pactl load-module module-null-sink "sink_name=$sink_name" 2> "$out/audio-sink.stderr") || sink_module=
 if [[ $sink_module =~ ^[0-9]+$ ]]; then
  pactl list short sinks > "$out/audio-sinks.txt"
  pactl list short sources > "$out/audio-sources.txt"
  ffmpeg -nostdin -y -f pulse -i "$sink_name.monitor" -ac 1 -ar 24000 "$out/orca-output.wav" > "$out/audio-recorder.log" 2>&1 &
  recorder_pid=$!
  remember_child "$recorder_pid"
  # Route this new Speech Dispatcher process's real output streams to the
  # monitor. Preserve original default sink and restore it on EXIT.
  pactl get-default-sink > "$out/audio-default-sink-before.txt"
  pactl set-default-sink "$sink_name"
 fi
fi
printf '%s\n' 'orca --enable=speech --speech-system=speechdispatcherfactory --debug --debug-file orca-debug.log' > "$out/orca-command.txt"
orca --enable=speech --speech-system=speechdispatcherfactory --debug --debug-file "$out/orca-debug.log" \
  > "$out/orca.stdout" 2> "$out/orca.stderr" &
orca_pid=$!
remember_child "$orca_pid"
printf '%s\n' "$orca_pid" > "$out/orca-pid.txt"
sleep 5
kill -0 "$orca_pid"
tr '\0' '\n' < "/proc/$orca_pid/environ" > "$out/orca-environment.txt"
run_client speech-text speech-nonce-readback "$pid"
xdotool windowactivate --sync "$window"
for keys in Tab shift+Tab ctrl+a; do
 date -u +%FT%TZ >> "$out/speech-ui-input.txt"
 printf 'keys=%s\n' "$keys" >> "$out/speech-ui-input.txt"
 timeout --kill-after=2s 10s xdotool key --clearmodifiers "$keys"
 sleep 2
done
sleep 5
if command -v pactl >/dev/null; then pactl list sink-inputs > "$out/audio-sink-inputs.txt" 2>&1 || true; fi
grep -n 'SPEECH DISPATCHER: Speaking' "$out/orca-debug.log" > "$out/orca-utterance-requests.txt" || true
grep -nE 'Speech Dispatcher.*(failed|not available)|Traceback|SSIP.*Error' "$out/orca-debug.log" "$out/orca.stderr" \
 > "$out/orca-backend-errors.txt" || true
nonce_request=false
if grep -Fq 'LocalSend accessibility 2754' "$out/orca-utterance-requests.txt"; then nonce_request=true; fi
jq -n --arg nonce 'LocalSend accessibility 2754' --argjson nonce_request "$nonce_request" \
 --argjson backend_error_lines "$(wc -l < "$out/orca-backend-errors.txt")" \
 '{nonce:$nonce,status:"unknown",observed_nonce_utterance_request:$nonce_request,backend_error_lines:$backend_error_lines,
   utterance_requests_are_not_proof_of_delivery:true,audio_requires_listening_and_event_correlation:true}' \
 > "$out/speech-result.json"
run_client cancel cancel-action "$pid"
wait_tree closed after-cancel "$pid"
snapshot_ui after-cancel "$pid" Selection
run_client open text-action "$pid"
wait_tree snapshot reopened-dialog "$pid"
snapshot_ui reopened-dialog "$pid" 'Type message'
run_client edit reopened-edit "$pid"
run_client cancel second-cancel-action "$pid"
wait_tree closed second-close "$pid"
snapshot_ui second-close "$pid" Selection

# The C client does not control app lifetime. The shell owns this known PID
# and requires actual process exit plus fresh desktop discovery on restart.
save_loader "$out/startup1-loader-final"
live_child "$events_pid"
owned_app
kill -TERM "$pid"
for attempt in $(seq 1 50); do owned_app || break; sleep 0.1; done
! owned_app
if [[ -r /proc/$pid/stat && $(awk '{print $22}' "/proc/$pid/stat") == "$app_start" ]]; then
 cat "/proc/$pid/stat" > "$out/old-app-final-stat.txt"
 [[ $(awk '{print $3}' "/proc/$pid/stat") == Z ]]
fi
wait_tree absent app-exit "$pid"
live_child "$events_pid"
date -u +%FT%TZ > "$out/restart-request.txt"
touch "$out/restart-boundary"
"$launcher" > "$out/restarted-app.stdout" 2> "$out/restarted-app.stderr" &
new_pid=$!
printf '%s\n' "$new_pid" > "$out/restarted-app-pid.txt"
awk '{print $22}' "/proc/$new_pid/stat" > "$out/restarted-app-starttime.txt"
printf 'old_pid=%s\nnew_pid=%s\n' "$pid" "$new_pid" > "$out/pid-transitions.txt"
[[ $new_pid != "$pid" ]]
sleep 15
kill -0 "$new_pid"
[[ $(readlink "/proc/$new_pid/exe") == "$app_exe" ]]
awk '{print $22}' "/proc/$new_pid/stat" > "$out/restarted-app-starttime.txt"
cat "/proc/$new_pid/cmdline" > "$out/restarted-app-cmdline.bin"
readlink "/proc/$new_pid/exe" > "$out/restarted-app-exe.txt"
for gate in bridge-process-map-check.txt engine-process-map-check.txt engine-loader-deadline.txt; do
 [[ /home/mint/evidence/$gate -nt $out/restart-boundary ]]
done
grep -qx 'mapped_selected_bridge=true' /home/mint/evidence/bridge-process-map-check.txt
grep -qx 'mapped_selected_engine=true' /home/mint/evidence/engine-process-map-check.txt
grep -qx 'mapped_selected_aot=true' /home/mint/evidence/engine-process-map-check.txt
grep -qx 'loader_gate_before_ui=true' /home/mint/evidence/engine-loader-deadline.txt
grep -qx "actual_app_pid=$new_pid" /home/mint/evidence/bridge-process-map-check.txt
grep -qx "actual_app_pid=$new_pid" /home/mint/evidence/engine-process-map-check.txt
save_loader "$out/startup2-loader"
# The pinned app starts on Receive. Navigate using the actual rendered Send label.
snapshot_ui restarted-window "$new_pid" 'Receive with Send navigation'
restart_window=$(jq -er .window_id "$out/restarted-window.window.json")
timeout --kill-after=2s 10s xdotool windowactivate --sync "$restart_window"
snapshot_ui restarted-before-send "$new_pid" 'Receive with Send navigation'
[[ $(jq -er .window_id "$out/restarted-before-send.window.json") == "$restart_window" ]]
timeout --kill-after=2s 15s tesseract "$out/restarted-before-send.png" "$out/restarted-before-send" tsv \
 > "$out/restarted-send-ocr.stdout" 2> "$out/restarted-send-ocr.stderr"
awk -F '\t' '$1 == 5 && $12 == "Send" && $11 >= 0 {printf "%d %d\n", $7+$9/2, $8+$10/2}' \
 "$out/restarted-before-send.tsv" > "$out/restarted-send-centers.txt"
[[ $(wc -l < "$out/restarted-send-centers.txt") == 1 ]]
read -r send_x send_y < "$out/restarted-send-centers.txt"
date -u +%FT%TZ > "$out/restarted-send-click-time.txt"
jq -n --argjson pid "$new_pid" --argjson window "$restart_window" --argjson x "$send_x" --argjson y "$send_y" \
 '{app_pid:$pid,window_id:$window,observed_unique_label:"Send",click_x:$x,click_y:$y}' > "$out/restarted-send-click.json"
timeout --kill-after=2s 10s xdotool mousemove --sync "$send_x" "$send_y" click 1
sleep 2
snapshot_ui restarted-after-send "$new_pid" Selection
wait_tree closed restarted-closed "$new_pid"
snapshot_ui restarted-closed "$new_pid" Selection
stop_child "$events_pid" TERM
"$out/interaction-client" "$new_pid" events restarted-events > "$out/restarted-events.jsonl" 2> "$out/restarted-events.stderr" &
events_pid=$!
remember_child "$events_pid"
for attempt in $(seq 1 100); do
 grep -q '"kind":"events_ready"' "$out/restarted-events.jsonl" && break
 kill -0 "$events_pid" 2>/dev/null || break
 sleep 0.1
done
grep -q '"kind":"events_ready"' "$out/restarted-events.jsonl"
run_client open restarted-text-action "$new_pid"
wait_tree snapshot restarted-dialog "$new_pid"
snapshot_ui restarted-dialog "$new_pid" 'Type message'
run_client edit restarted-edit "$new_pid"
run_client cancel restarted-cancel "$new_pid"
wait_tree closed restarted-close "$new_pid"
snapshot_ui restarted-close "$new_pid" Selection
# Result remains completed with independent speech/audio unknown. Integration
# must retain the original strict geometry verdict and review speech evidence.
status=0
exit "$status"
