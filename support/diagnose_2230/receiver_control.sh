#!/usr/bin/env bash
# Arm before Windows sends. One case at a time; receiver stays in the same process.
set -Eeuo pipefail
evidence=${1:?Usage: receiver_control.sh evidenceDir caseId expectedBytes expectedSha256}
case_id=${2:?caseId}; expected_bytes=${3:?expectedBytes}; expected_sha=${4:?expectedSha256}
[[ "$case_id" =~ ^[A-Za-z0-9_-]+$ && "$expected_bytes" =~ ^[0-9]+$ && "$expected_sha" =~ ^[a-fA-F0-9]{64}$ ]]
evidence=$(realpath "$evidence")
source "$evidence/receiver/session.env"
export DISPLAY LANG=C.UTF-8
out="$evidence/cases/$case_id/receiver"
mkdir -p "$out"
exec > >(tee -a "$out/control.log") 2>&1
exec 9>/tmp/localsend-2230-controller.lock
flock -n 9 || { echo 'Another case controller is active'; exit 1; }
rm -f "$out/armed.tsv" "$out/accepted.tsv" "$out/complete.tsv" "$out/result.env" "$out/recording-closed.tsv"
[[ "$$" =~ ^[1-9][0-9]*$ && -r "/proc/$$/cmdline" ]]
# Parent validates the PID's /proc command line against this script and case
# before signaling it. The start tick distinguishes a later reused PID.
printf '%s\n' "$$" > "$out/controller.pid"
awk '{print $22}' "/proc/$$/stat" > "$out/controller.start-tick"
[[ -s "$evidence/receiver/ready.tsv" ]]
kill -0 "$APP_PID"
[[ -z $(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
  echo 'Destination must be empty before each case; preserve previous files outside it'; exit 1;
}
printf 'utc\tmonotonic_ms\tevent\tdetail\n' > "$out/events.tsv"
stamp() { date -u --iso-8601=ns; }
mono() { awk '{printf "%.0f", $1*1000}' /proc/uptime; }
event() { printf '%s\t%s\t%s\t%s\n' "$(stamp)" "$(mono)" "$1" "${2:-}" >> "$out/events.tsv"; }
frame=0
snapshot() {
  frame=$((frame+1)); base="$out/$(printf '%04d' "$frame")-$1"
  event screenshot "$base.png"
  timeout 5 ffmpeg -nostdin -y -loglevel error -f x11grab -video_size 1280x900 -i "$DISPLAY" -frames:v 1 "$base.png"
  timeout 5 tesseract "$base.png" "$base" --psm 11 tsv txt > "$base.ocr.log" 2>&1
}
# Only exact, confident, unique OCR words are actionable. Full-screen coordinates.
coords() {
  awk -F '\t' -v word="$1" 'NR>1 && $1==5 && $11>=50 && tolower($12)==tolower(word) {n++; x=$7+$9/2; y=$8+$10/2} END {if(n==1) printf "%d %d",x,y; else exit 1}' "$base.tsv"
}
has() { grep -Eiq "$1" "$base.txt"; }
click_word() {
  local xy; xy=$(coords "$1") || return 1
  event click "$1 at $xy using $base.tsv"
  read -r x y <<< "$xy"
  timeout 3 xdotool windowactivate --sync "$WINDOW"
  timeout 3 xdotool mousemove --sync "$x" "$y" click 1
}
confirm_cancel() {
  # Background Cancel and the dialog title may also be visible. The dialog's
  # affirmative Cancel is right of Continue on the same button row.
  local continue_xy cancel_xy
  continue_xy=$(coords Continue) || return 1
  read -r continue_x continue_y <<< "$continue_xy"
  cancel_xy=$(awk -F '\t' -v cx="$continue_x" -v cy="$continue_y" \
    'NR>1 && $1==5 && $11>=50 && tolower($12)=="cancel" {x=$7+$9/2;y=$8+$10/2;if(x>cx && y>cy-25 && y<cy+25){n++;px=x;py=y}} END{if(n==1)printf "%d %d",px,py;else exit 1}' "$base.tsv") || return 1
  read -r x y <<< "$cancel_xy"
  event click "dialog Cancel at $cancel_xy using $base.tsv"
  timeout 3 xdotool mousemove --sync "$x" "$y" click 1
}
video_pid=''
recorder_alive() {
  [[ -r "/proc/$video_pid/stat" ]] || return 1
  # A zombie has exited and can be reaped immediately by wait.
  [[ $(awk '{print $3}' "/proc/$video_pid/stat" 2>/dev/null) != Z ]]
}
wait_recorder() {
  local until_ms=$(( $(mono)+$1*1000 ))
  while recorder_alive; do
    (( $(mono) < until_ms )) || return 1
    sleep 0.1
  done
}
stop_video() {
  if [[ -n "$video_pid" ]]; then
    local method=already_exited recorder_status=0
    if recorder_alive; then
      method=INT
      kill -INT "$video_pid" 2>/dev/null || true
      if ! wait_recorder 10; then
        method=TERM
        kill -TERM "$video_pid" 2>/dev/null || true
        if ! wait_recorder 5; then
          method=KILL
          kill -KILL "$video_pid" 2>/dev/null || true
          if ! wait_recorder 2; then
            method=KILL_not_reaped
          fi
        fi
      fi
    fi
    if ! recorder_alive; then
      wait "$video_pid" || recorder_status=$?
    else
      # Never block indefinitely on an uninterruptible process.
      recorder_status=124
    fi
    event recording_closed "method=$method exit=$recorder_status pid=$video_pid"
    printf 'utc\tshutdown_method\texit_code\trecorder_pid\n%s\t%s\t%s\t%s\n' \
      "$(stamp)" "$method" "$recorder_status" "$video_pid" > "$out/recording-closed.tsv"
    video_pid=''
  fi
}
trap stop_video EXIT
trap 'event controller_signal TERM; exit 143' TERM
trap 'event controller_signal INT; exit 130' INT
ffmpeg -nostdin -y -loglevel warning -f x11grab -framerate 15 -video_size 1280x900 -i "$DISPLAY" \
  -c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p "$out/continuous.mp4" > "$out/recording.log" 2>&1 & video_pid=$!
event recording_start "pid=$video_pid"
printf 'armed\t%s\n' "$(stamp)" > "$out/armed.tsv"
wait_deadline=$(( $(mono)+60000 )); accepted=0
while (( $(mono) < wait_deadline )); do
  snapshot approval
  if coords Accept >/dev/null && coords Decline >/dev/null; then
    click_word Accept
    accepted=1; accept_ms=$(mono); event accepted
    printf 'accepted\t%s\n' "$(stamp)" > "$out/accepted.tsv"
    break
  fi
  sleep 0.5
done
status=approval_not_observed
hash_match=0; finished=0; explicit_error=0
printf 'utc\tpath_shell_quoted\tbytes\tsha256\n' > "$out/files.tsv"
if (( accepted )); then
  deadline=$((accept_ms+60000)); status=deadline_without_finished
  while (( $(mono) < deadline )); do
    snapshot transfer
    kill -0 "$APP_PID" 2>/dev/null || { status=receiver_exited; break; }
    while IFS= read -r -d '' file; do
      bytes=$(stat -c %s "$file")
      sha=$(sha256sum "$file"); sha=${sha%% *}
      printf '%s\t%q\t%s\t%s\n' "$(stamp)" "$file" "$bytes" "$sha" >> "$out/files.tsv"
      if [[ "$bytes" == "$expected_bytes" && "${sha,,}" == "${expected_sha,,}" ]]; then hash_match=1; fi
    done < <(find "$DEST" -maxdepth 1 -type f -print0)
    if has '\b(error|failed|failure)\b'; then explicit_error=1; status=explicit_error; fi
    if has '\bFinished\b' && ! has '\b(error|errors)\b'; then finished=1; fi
    if (( finished && hash_match && ! explicit_error )); then status=finished_and_hash_verified; break; fi
    if (( explicit_error )); then break; fi
    sleep 0.5
  done
fi
event observation_end "$status"
# Probe actual app interaction only after the observation period. Rendering Hide
# after Advanced proves an app response; a failed OCR probe does not prove a hang.
responsive=unproven
snapshot before_probe
if click_word Advanced; then
  sleep 0.5; snapshot after_probe
  if coords Hide >/dev/null; then responsive=advanced_rendered_hide; click_word Hide || true; fi
fi
event responsiveness "$responsive"
# Cancel invokes the release's real confirmation dialog. Done closes terminal
# progress. Decline/Close cover pre-accept and sender-canceled pages.
recovery=not_observed
for attempt in $(seq 1 8); do
  snapshot recovery
  if has Ubuntu2230 && has '\bReceive\b' && has '\bSend\b' && has '\bSettings\b' && ! coords Accept >/dev/null; then
    recovery=home_rendered; break
  fi
  if coords Continue >/dev/null; then
    confirm_cancel || true
  elif click_word Done || click_word Close || click_word Decline; then :
  elif click_word Cancel; then :
  else
    event back_key Escape
    timeout 3 xdotool key --window "$WINDOW" Escape
  fi
  sleep 0.5
done
event recovery "$recovery"
stop_video
printf 'status=%s\naccepted=%s\nfinished=%s\nhash_match=%s\nexplicit_error=%s\nresponsiveness=%s\nrecovery=%s\napp_pid=%s\n' \
  "$status" "$accepted" "$finished" "$hash_match" "$explicit_error" "$responsive" "$recovery" "$APP_PID" > "$out/result.env"
printf 'complete\t%s\t%s\n' "$(stamp)" "$status" > "$out/complete.tsv"
# Product failures are evidence, not infrastructure success. Parent reads result.
[[ "$status" == finished_and_hash_verified && "$recovery" == home_rendered ]]
