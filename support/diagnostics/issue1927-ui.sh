#!/usr/bin/env bash
# Actual visible UI controls: wait for app initialization and identify rows by text.
stabilize_window() {
  sleep 8
  xdotool windowactivate --sync "$wid"
  xdotool windowmove "$wid" 0 0
  xdotool windowsize "$wid" 1000 700
  sleep 2
  xdotool getwindowgeometry --shell "$wid" > "$OUT/window-geometry.txt"
}
settings_row_y() {
  local phrase=$1 label=$2 y
  import -window "$wid" "$OUT/$label-locate.png"
  test "$(identify -format '%wx%h' "$OUT/$label-locate.png")" = 1000x700
  tesseract "$OUT/$label-locate.png" "$OUT/$label-locate" tsv > "$OUT/$label-ocr.log" 2>&1
  y=$(awk -F '\t' -v phrase="$phrase" '
    NR > 1 && $1 == 5 && $11 >= 0 {
      key=$2 "/" $3 "/" $4 "/" $5
      text[key]=text[key] " " $12
      if (!(key in top) || $7 < top[key]) top[key]=$7
      if (!(key in bottom) || $7+$9 > bottom[key]) bottom[key]=$7+$9
    }
    END {for (key in text) if (index(text[key], phrase)) print int((top[key]+bottom[key])/2)}
  ' "$OUT/$label-locate.tsv")
  [[ "$y" =~ ^[0-9]+$ ]]
  printf '%s\n' "$y"
}
observed_switch_state() {
  local y=$1 label=$2 image="$OUT/$2-locate.png" state
  # The retained source renders establish the switch at x=798..849 for
  # this checked 1000x700 layout. Preserve its entire row association/crop.
  convert "$image" -crop "64x40+790+$((y-20))" "$OUT/$label-switch.png"
  state=$(convert "$image" -crop "4x6+803+$((y-3))" -scale 1x1! -format '%[fx:r<0.3 && g-r>0.15 ? 1 : (g-r<0.08 ? 0 : 2)]' info:)
  case "$state" in 1) printf 'ON\n';; 0) printf 'OFF\n';; *) return 1;; esac
}
require_switch_state() {
  local phrase=$1 label=$2 expected=$3 y observed
  y=$(settings_row_y "$phrase" "$label")
  observed=$(observed_switch_state "$y" "$label")
  printf '%s label=%s row_y=%s observed=%s expected=%s\n' "$(date -u --iso-8601=ns)" "$phrase" "$y" "$observed" "$expected" >> "$OUT/observed-switch-states.txt"
  test "$observed" = "$expected"
  printf '%s\n' "$y"
}
