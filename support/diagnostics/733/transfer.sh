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
  count=$(awk -F '\t' -v text="$label" '$12==text && $11>=30 {n++} END {print n+0}' "evidence/$name.tsv")
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
send_and_approve() {
  local filename=$1 label=$2 alias_word=$3 record_pid
  # Only a uniquely observed word from the real receiver alias is clicked.
  click_word "$sender_wid" "$alias_word" "$label-peer-selection"
  sleep 3
  capture_window "$receiver_wid" "$label-receive-pending"
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
}
