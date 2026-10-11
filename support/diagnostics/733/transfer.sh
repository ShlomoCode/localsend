#!/usr/bin/env bash
# Sourced in the cloud guest after prepared window identities are observed.
# All actions use real app controls. A missing control is a harness failure.
capture_window() {
  local wid=$1 name=$2
  xdotool windowactivate --sync "$wid"
  sleep 1
  import -window "$wid" "evidence/$name.png"
  tesseract "evidence/$name.png" "evidence/$name" tsv >/dev/null 2>&1
}
click_word() {
  local wid=$1 label=$2 name=$3 count point
  capture_window "$wid" "$name"
  if [[ "$label" == Done ]]; then
    # The file row also says Done. Identify the observed bottom action only.
    [[ $(identify -format '%wx%h' "evidence/$name.png") == 1000x700 ]]
    convert "evidence/$name.png" -crop 52x24+910+650 -resize 400% -negate "evidence/$name-label.png"
    tesseract "evidence/$name-label.png" "evidence/$name-label" --psm 7 >/dev/null 2>&1
    [[ $(tr -d '[:space:]' < "evidence/$name-label.txt") == Done ]] || return 1
    printf '%s window=%s click=935,661 exact-bottom-action=Done\n' "$(date --iso-8601=ns)" "$wid" >> evidence/input-timings.txt
    xdotool mousemove --window "$wid" 935 661 click 1
    sleep 2
    return
  fi
  count=$(awk -F '\t' -v text="$label" '$12==text && $11>=30 {n++} END {print n+0}' "evidence/$name.tsv")
  if [[ "$count" == 0 && "$label" == Accept ]]; then
    # Full-window OCR misses the actual white Accept label in the retained
    # 1.11.1 approval view. Use exact OCR of its observed label rectangle.
    [[ $(identify -format '%wx%h' "evidence/$name.png") == 1000x700 ]]
    convert "evidence/$name.png" -crop 62x24+555+638 -resize 400% -negate "evidence/$name-label.png"
    tesseract "evidence/$name-label.png" "evidence/$name-label" --psm 7 >/dev/null 2>&1
    if [[ $(tr -d '[:space:]' < "evidence/$name-label.txt") == Accept ]]; then
      printf '%s window=%s click=585,650 exact-cropped-label=Accept\n' "$(date --iso-8601=ns)" "$wid" >> evidence/input-timings.txt
      xdotool mousemove --window "$wid" 585 650 click 1
      sleep 2
      return
    fi
  fi
  if [[ "$count" != 1 ]]; then
    printf 'HARNESS_CONTROL_NOT_UNIQUE %s count=%s\n' "$label" "$count" >> evidence/harness-errors.txt
    return 1
  fi
  point=$(awk -F '\t' -v text="$label" '$12==text && $11>=30 {printf "%d %d",$7+$9/2,$8+$10/2}' "evidence/$name.tsv")
  printf '%s window=%s click=%s word=%s\n' "$(date --iso-8601=ns)" "$wid" "$point" "$label" >> evidence/input-timings.txt
  read -r point_x point_y <<< "$point"
  xdotool mousemove --window "$wid" "$point_x" "$point_y" click 1
  sleep 2
}
select_fixture() {
  local filename=$1 label=$2 picker_wid
  click_word "$sender_wid" Send "$label-send-tab"
  click_word "$sender_wid" File "$label-file-action"
  picker_wid=$(xdotool getactivewindow)
  capture_window "$picker_wid" "$label-picker-initial"
  xdotool key --clearmodifiers ctrl+l
  xdotool type --clearmodifiers "/home/sender/Downloads/$filename"
  capture_window "$picker_wid" "$label-picker-path"
  xdotool key --clearmodifiers Return
  sleep 4
  capture_window "$sender_wid" "$label-file-selected"
}
restart_receiver() {
  local label=$1
  flatpak kill org.localsend.localsend_app
  sleep 2
  flatpak run --system org.localsend.localsend_app >> evidence/receiver.log 2>&1 &
  sleep 8
  receiver_pid=$(pgrep -u mint -n -x localsend_app || pgrep -u mint -n -x localsend)
  receiver_wid=''
  for wid in $(xdotool search --onlyvisible --name '^LocalSend$'); do
    [[ "$wid" == "$sender_wid" ]] || receiver_wid=$wid
  done
  test -n "$receiver_wid"
  xdotool windowmove "$receiver_wid" 0 0
  xdotool windowsize "$receiver_wid" 1000 700
  sudo cat "/proc/$receiver_pid/root/.flatpak-info" > "evidence/$label-process-flatpak-info.txt"
  printf '%s\n' "$receiver_pid" > "evidence/$label-receiver-pid.txt"
}
send_and_approve() {
  local filename=$1 label=$2 alias_word=$3 record_pid
  # Only a uniquely observed word from the real receiver alias is clicked.
  click_word "$sender_wid" "$alias_word" "$label-peer-selection"
  sleep 3
  capture_window "$receiver_wid" "$label-receive-pending"
  actual_destination=$(awk '/Destination Directory: / {sub(/^.*Destination Directory: /,""); path=$0} END {print path}' evidence/receiver.log)
  [[ "$actual_destination" == /* ]]
  printf '%s\n' "$actual_destination" > "evidence/$label-actual-destination.txt"
  sudo cat "/proc/$receiver_pid/mountinfo" > "evidence/$label-receiver-mountinfo.txt"
  ffmpeg -nostdin -y -f x11grab -video_size "$(xdpyinfo | sed -n 's/.*dimensions:[[:space:]]*\([0-9]*x[0-9]*\).*/\1/p')" -framerate 15 -i "$DISPLAY" -t 10 -c:v libx264 -pix_fmt yuv420p "evidence/$label-accept.mp4" > "evidence/$label-recording.log" 2>&1 &
  record_pid=$!
  sleep 1
  click_word "$receiver_wid" Accept "$label-accept-action"
  sleep 5
  capture_window "$receiver_wid" "$label-receiver-result"
  wait "$record_pid"
  capture_window "$sender_wid" "$label-sender-result"
  # This observers' result never substitutes for the actual UI result.
  { sudo stat -Lc '%d:%i %s %n' "/proc/$receiver_pid/root/home/mint/Downloads" /home/mint/Downloads;
    sudo find "/proc/$receiver_pid/root/home/mint/Downloads" /home/mint/Downloads -maxdepth 2 -name "$filename" -exec sha256sum {} \; -exec stat -Lc '%d:%i %s %n' {} \;;
  } > "evidence/$label-destination-while-alive.txt" 2>&1 || true
  { sudo stat -Lc '%d:%i %s %n' "/proc/$receiver_pid/root$actual_destination" "$actual_destination";
    sudo find "/proc/$receiver_pid/root$actual_destination" "$actual_destination" -maxdepth 2 -name "$filename" -exec sha256sum {} \; -exec stat -Lc '%d:%i %s %n' {} \;;
  } > "evidence/$label-actual-destination-while-alive.txt" 2>&1 || true
}
restart_sender() {
  sudo pkill -u sender -x localsend_app || true
  sudo pkill -u sender -x localsend || true
  sleep 2
  nohup sudo ip netns exec issue733sender runuser -l sender -c "env DISPLAY=$DISPLAY XDG_RUNTIME_DIR=/run/user/$(id -u sender) dbus-run-session -- /home/sender/app/localsend_app" >> evidence/sender.log 2>&1 < /dev/null &
  sleep 8
  sender_wid=''
  for wid in $(xdotool search --onlyvisible --name '^LocalSend$'); do
    [[ "$wid" == "$receiver_wid" ]] || sender_wid=$wid
  done
  test -n "$sender_wid"
  xdotool windowmove "$sender_wid" 0 0
  xdotool windowsize "$sender_wid" 1000 700
}
observe_history() {
  local label=$1 history_filename=$2
  jq 'with_entries(select(.key|test("alias|destination|receive_history|quick_save")))' "$prefs" > "evidence/$label-receiver-settings.json"
  capture_window "$receiver_wid" "$label-home"
  assert_receive_home "$label-home"
  # Observed history icon in the original1.11.1 1000x700 receiver.
  xdotool mousemove --window "$receiver_wid" 920 40 click 1
  sleep 2
  capture_window "$receiver_wid" "$label-history"
  require_ocr_word "$label-history" History
  require_ocr_word "$label-history" "$history_filename"
  xdotool key --clearmodifiers Escape
  sleep 1
  capture_window "$receiver_wid" "$label-history-return"
  assert_receive_home "$label-history-return"
}
require_ocr_word() {
  local name=$1 word=$2
  awk -F '\t' -v word="$word" '$12==word && $11>=20 {found=1} END {exit !found}' "evidence/$name.tsv"
}
assert_receive_home() {
  local name=$1
  require_ocr_word "$name" Receive
  require_ocr_word "$name" "$receiver_alias_word"
  require_ocr_word "$name" Quick
  require_ocr_word "$name" Off
  if awk -F '\t' '$12=="Finished" || $12=="History" {found=1} END {exit !found}' "evidence/$name.tsv"; then
    printf 'HARNESS_EXPECTED_RECEIVE_HOME %s\n' "$name" >> evidence/harness-errors.txt
    return 1
  fi
}
