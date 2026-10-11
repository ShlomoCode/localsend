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
  control_tsv="$base.tsv"
  event screenshot "$base.png"
  timeout 5 ffmpeg -nostdin -y -loglevel error -f x11grab -video_size 1280x900 -i "$DISPLAY" -frames:v 1 "$base.png"
  timeout 5 tesseract "$base.png" "$base" --psm 11 tsv txt > "$base.ocr.log" 2>&1
}
# Only exact, confident, unique OCR words are actionable. Full-screen coordinates.
coords() {
  awk -F '\t' -v word="$1" 'NR>1 && $1==5 && $11>=50 && tolower($12)==tolower(word) {n++; x=$7+$9/2; y=$8+$10/2} END {if(n==1) printf "%d %d",x,y; else exit 1}' "$control_tsv"
}
inverse_ocr_fallback() {
  # The original release renders white labels on colored buttons. Keep full
  # screenshot dimensions so OCR coordinates remain screen coordinates.
  local processed="$base-inverse-threshold"
  event ocr_fallback "$processed.png"
  if timeout 5 ffmpeg -nostdin -y -loglevel error -i "$base.png" \
    -vf "format=gray,lut=y='if(gt(val,180),0,255)'" -frames:v 1 "$processed.png" \
    > "$processed.preprocess.log" 2>&1 && \
    timeout 5 tesseract "$processed.png" "$processed" --psm 11 \
      -c tessedit_do_invert=0 tsv txt > "$processed.ocr.log" 2>&1; then
    control_tsv="$processed.tsv"
  fi
}
approval_crop_ocr() {
  # Options is a rendered semantic anchor above the approval button row.
  # Crop geometry only limits OCR; button clicks still require recognized text.
  local anchor crop_x crop_y crop_w=440 crop_h=90 scale=3
  local processed threshold previous_tsv="$control_tsv"
  anchor=$(awk -F '\t' 'NR>1 && $1==5 && $11>=50 && tolower($12)=="options" {n++;x=$7+$9/2;y=$8+$10} END{if(n==1)printf "%d %d",x,y;else exit 1}' "$base.tsv") || return 0
  read -r crop_x crop_y <<< "$anchor"
  crop_x=$((crop_x-220)); crop_y=$((crop_y+15))
  if (( crop_x<0 || crop_y<0 || crop_x+crop_w>1280 || crop_y+crop_h>900 )); then
    event ocr_crop_rejected "Options anchor would exceed screenshot bounds"
    return 0
  fi
  # Isolate near-white label pixels from the original RGB crop. Unlike the
  # full-frame threshold, this removes both the colored pills and pale page.
  for threshold in 250 252; do
    (( $(mono) < wait_deadline )) || break
    processed="$base-approval-crop-t$threshold-psm7"
    printf 'source_png\tcrop_x\tcrop_y\tcrop_width\tcrop_height\tscale\tthreshold\tpsm\n%s\t%s\t%s\t%s\t%s\t%s\t%s\t7\n' \
      "$base.png" "$crop_x" "$crop_y" "$crop_w" "$crop_h" "$scale" "$threshold" > "$processed.transform.tsv"
    event ocr_fallback "$processed.png using Options anchor"
    if timeout 5 ffmpeg -nostdin -y -loglevel error -i "$base.png" \
      -vf "crop=$crop_w:$crop_h:$crop_x:$crop_y,scale=iw*$scale:ih*$scale:flags=lanczos,format=gray,lut=y='if(gt(val,$threshold),0,255)'" \
      -frames:v 1 "$processed.png" > "$processed.preprocess.log" 2>&1 && \
      timeout 5 tesseract "$processed.png" "$processed" --psm 7 \
        -c tessedit_do_invert=0 tsv txt > "$processed.ocr.log" 2>&1; then
      awk -F '\t' -v OFS='\t' -v x="$crop_x" -v y="$crop_y" -v scale="$scale" \
        'NR==1{print;next} NF>=12{$7=$7/scale+x;$8=$8/scale+y;$9=$9/scale;$10=$10/scale;print}' \
        "$processed.tsv" > "$processed.screen.tsv"
      control_tsv="$processed.screen.tsv"
      if coords Accept >/dev/null && coords Decline >/dev/null; then
        event ocr_variant_selected "$control_tsv"
        return 0
      fi
    fi
    control_tsv="$previous_tsv"
  done
}
has() { grep -Eiq "$1" "$base.txt"; }
click_word() {
  local xy; xy=$(coords "$1") || return 1
  event click "$1 at $xy using $control_tsv"
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
    'NR>1 && $1==5 && $11>=50 && tolower($12)=="cancel" {x=$7+$9/2;y=$8+$10/2;if(x>cx && y>cy-25 && y<cy+25){n++;px=x;py=y}} END{if(n==1)printf "%d %d",px,py;else exit 1}' "$control_tsv") || return 1
  read -r x y <<< "$cancel_xy"
  event click "dialog Cancel at $cancel_xy using $base.tsv"
  timeout 3 xdotool mousemove --sync "$x" "$y" click 1
}
video_pid=''
video_validation_ok=0
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
    # Also runs through EXIT on aborted controllers. Validation failure stays
    # separate from the observed app result and never becomes product success.
    if [[ "$method" == KILL_not_reaped ]]; then
      printf 'utc_started\tutc_finished\tstatus\treason\n%s\t%s\tfailed\trecorder_still_alive\n' \
        "$(stamp)" "$(stamp)" > "$out/video-validation.tsv"
      video_validation_ok=0
      event video_validation failed
    elif bash "$(dirname "${BASH_SOURCE[0]}")/validate_video.sh" "$out"; then
      video_validation_ok=1
      event video_validation passed
    else
      video_validation_ok=0
      event video_validation failed
    fi
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
  if ! coords Accept >/dev/null || ! coords Decline >/dev/null; then
    inverse_ocr_fallback
  fi
  if ! coords Accept >/dev/null || ! coords Decline >/dev/null; then
    approval_crop_ocr
  fi
  if (( $(mono) < wait_deadline )) && coords Accept >/dev/null && coords Decline >/dev/null; then
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
  if ! coords Continue >/dev/null && ! coords Done >/dev/null && ! coords Close >/dev/null && ! coords Decline >/dev/null && ! coords Cancel >/dev/null; then
    inverse_ocr_fallback
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
printf 'status=%s\naccepted=%s\nfinished=%s\nhash_match=%s\nexplicit_error=%s\nresponsiveness=%s\nrecovery=%s\napp_pid=%s\nvideo_validation_ok=%s\n' \
  "$status" "$accepted" "$finished" "$hash_match" "$explicit_error" "$responsive" "$recovery" "$APP_PID" "$video_validation_ok" > "$out/result.env"
printf 'complete\t%s\t%s\n' "$(stamp)" "$status" > "$out/complete.tsv"
# Product failures are evidence, not infrastructure success. Parent reads result.
[[ "$status" == finished_and_hash_verified && "$recovery" == home_rendered && "$video_validation_ok" == 1 ]]
