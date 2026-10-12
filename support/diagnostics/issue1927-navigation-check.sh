#!/usr/bin/env bash
# Run only in a future admitted cloud job, before starting the native replay.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
ORIGINAL=$1
OLD_TSV=$2
OUT=$3
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
printf '%s  %s\n' 46c232dacbd412a9fbefc83133cff23865400e4078e225c14b21eda5769d19eb "$ORIGINAL" | sha256sum -c -
printf '%s  %s\n' a3b0bb7fbe356e2a9c4964e4e9d117244d0b47d1163dc2abbb1f2ce9fd533b69 "$OLD_TSV" | sha256sum -c -
source support/diagnostics/issue1927-ui.sh
CHECK_DEADLINE=$((SECONDS+60))
run_ui_observer() {
  local left=$((CHECK_DEADLINE-SECONDS))
  ((left>0)) || return 124
  ((left<=8)) || left=8
  timeout --foreground --signal=TERM --kill-after=1 "$left" "$@"
}
run_ui_observer tesseract --version > "$OUT/tesseract-version.txt" 2>&1
run_ui_observer convert -version > "$OUT/imagemagick-version.txt"
# The old full-frame observation must still miss at least one source label.
run_ui_observer tesseract "$ORIGINAL" "$OUT/default-full-frame" tsv > "$OUT/default-full-frame-ocr.log" 2>&1
all_labels() {
  awk -F '\t' 'NR>1 && $1==5 && $11>=50 {label=tolower($12); if(label=="receive" || label=="send" || label=="settings") count[label]++} END {exit !(count["receive"]==1 && count["send"]==1 && count["settings"]==1)}' "$1"
}
if all_labels "$OLD_TSV" || all_labels "$OUT/default-full-frame.tsv"; then
  printf 'discriminator=FAIL old observation unexpectedly resolves all labels\n' > "$OUT/result.txt"
  exit 1
fi
observe_navigation_rail "$ORIGINAL" "$OUT/corrected" 1000 700
# The positive result comes from the same immutable frame and shared live code.
printf 'discriminator=PASS old full-frame misses labels; corrected rail resolves Receive, Send, Settings\n' > "$OUT/result.txt"
printf '%s  %s\n' 46c232dacbd412a9fbefc83133cff23865400e4078e225c14b21eda5769d19eb "$ORIGINAL" | sha256sum -c -
printf '%s  %s\n' a3b0bb7fbe356e2a9c4964e4e9d117244d0b47d1163dc2abbb1f2ce9fd533b69 "$OLD_TSV" | sha256sum -c -
