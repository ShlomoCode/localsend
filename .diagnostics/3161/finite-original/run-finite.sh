#!/bin/bash
# Synchronous immutable finite episode; no fetched command JSON or round polling.
set -Eeuo pipefail
export DISPLAY=:99
source_dir=${1:?checked-out finite source directory}
target="$GITHUB_WORKSPACE/evidence/vm/finite-original"
mkdir -p "$target"
ssh_opts=(-n -i /tmp/localsend-vm/id_ed25519 -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/localsend-vm/known_hosts -o ConnectTimeout=3)
now() { cut -d' ' -f1 /proc/uptime; }
started=$(now)
job_started=$(cat /tmp/3161-job-start)
[[ "$job_started" =~ ^[0-9]+([.][0-9]+)?$ ]]
# Do not start a guardian if the job cannot leave its full finite join reserve.
awk -v t="$started" -v j="$job_started" 'BEGIN {exit !(t+430+720+120 < j+5400)}'
# Every action must fit before this fixed absolute host stop. Fallback is later.
input_stop=$(awk -v t="$started" -v j="$job_started" 'BEGIN {printf "%.2f", (t+210 < j+4340 ? t+210 : j+4340)}')
cleanup_stop=$(awk -v t="$started" -v j="$job_started" 'BEGIN {printf "%.2f", (t+430 < j+4560 ? t+430 : j+4560)}')
printf 'START=%s INPUT_STOP=%s CLEANUP_STOP=%s UTC=%s\n' "$started" "$input_stop" "$cleanup_stop" "$(date -u +%FT%T.%N)" > "$target/controller.txt"
index=0
closed=0
budget() {
  # Admission immediately precedes timeout/exec; duration includes kill grace.
  awk -v t="$(now)" -v stop="$input_stop" -v need="$1" 'BEGIN {exit !(t+need < stop)}'
}
step() {
  local bound=$1 label=$2
  shift 2
  test "$closed" = 0
  budget "$((bound+1))" || { printf 'ADMISSION_CLOSED label=%s uptime=%s\n' "$label" "$(now)" >> "$target/controller.txt"; return 124; }
  printf 'ACTION_START index=%s label=%s uptime=%s UTC=%s\n' "$index" "$label" "$(now)" "$(date -u +%FT%T.%N)" >> "$target/controller.txt"
  # Recheck after writing the receipt and immediately before starting the action.
  budget "$((bound+1))" || return 124
  timeout --signal=TERM --kill-after=1s "${bound}s" "$@"
  printf 'ACTION_JOINED index=%s label=%s uptime=%s\n' "$index" "$label" "$(now)" >> "$target/controller.txt"
  index=$((index+1))
}
guest() { step "$1" "$2" ssh "${ssh_opts[@]}" probe@127.0.0.1 "$3"; }
capture() { step 5 "$1-image" /tmp/localsend-vm/capture "$target/$1.png"; }
input() {
  step 2 "$1" xdotool "${@:2}"
  step 1 "$1-settle" sleep 0.5
  capture "$1"
}
observe() { guest 18 "$1-observe" 'timeout --signal=TERM --kill-after=1s 16s bash /home/probe/finite-source/observe-guest.sh' > "$target/$1-observe.txt"; }
recording() {
  local label=$1
  # Failure leaves this receipt incomplete and exits through ordinary cleanup.
  printf 'RECORDING_STATUS=incomplete\n' > "$target/$label-recording-status.txt"
  step 4 "$label-recording" bash -c '
    set -euo pipefail
    out=$1; label=$2; progress=$3
    pid=$(cat /tmp/localsend-vm/video.pid)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]]
    kill -0 "$pid"
    raw=$(cat "/proc/$pid/stat")
    ticks=$(printf "%s\n" "$raw" | awk '\''{sub(/^.*\) /, ""); print $20}'\'')
    state=$(printf "%s\n" "$raw" | awk '\''{sub(/^.*\) /, ""); print $1}'\'')
    case "$state" in Z|X|T|t) exit 1 ;; esac
    exe=$(readlink "/proc/$pid/exe")
    test "${exe##*/}" = ffmpeg
    identity="$pid $ticks $exe"
    if test -f "$out/video-identity.txt"; then
      test "$identity" = "$(cat "$out/video-identity.txt")"
    fi
    if test -f "$out/$label-capture-completed"; then sleep 1; fi
    # Bind the copied completed batch to one stable file metadata sample.
    # A later partial write must not freshen an older accepted completed frame.
    metadata=$(stat -c "%d:%i:%s:%y:%z|%y" "$progress")
    cp "$progress" "$out/$label-video-progress.txt"
    test "$metadata" = "$(stat -c "%d:%i:%s:%y:%z|%y" "$progress")"
    test "$(tail -n 1 "$out/$label-video-progress.txt")" = progress=continue
    test "$(tail -c 1 "$out/$label-video-progress.txt" | od -An -tu1 | tr -d " ")" = 10
    sample_ns=$(date -d "${metadata##*|}" +%s%N)
    now_ns=$(date +%s%N)
    age_ns=$((now_ns-sample_ns))
    test "$age_ns" -ge 0 && test "$age_ns" -le 2000000000
    printf "PROGRESS_METADATA=%s SAMPLE_NS=%s AGE_NS=%s\n" "$metadata" "$sample_ns" "$age_ns"
    if test -f "$out/$label-capture-completed"; then
      marker_ns=$(date -d "$(stat -c %y "$out/$label-capture-completed")" +%s%N)
      test "$sample_ns" -gt "$marker_ns"
      printf "CAPTURE_MARKER_NS=%s\n" "$marker_ns"
    fi
    frame=$(awk -F= '\''$1=="frame" {f=$2} $1=="progress" {if($2=="end") exit 2; completed=f} END {if(completed !~ /^[0-9]+$/ || completed<=0) exit 1; print completed}'\'' "$out/$label-video-progress.txt")
    previous=0
    if test -f "$out/video-last-frame.txt"; then previous=$(cat "$out/video-last-frame.txt"); fi
    test "$frame" -gt "$previous"
    # Bracket the progress read with the original recorder process identity.
    final_raw=$(cat "/proc/$pid/stat")
    test "$ticks" = "$(printf "%s\n" "$final_raw" | awk '\''{sub(/^.*\) /, ""); print $20}'\'')"
    final_state=$(printf "%s\n" "$final_raw" | awk '\''{sub(/^.*\) /, ""); print $1}'\'')
    case "$final_state" in Z|X|T|t) exit 1 ;; esac
    kill -0 "$pid"
    printf "%s\n" "$identity" > "$out/video-identity.txt"
    printf "%s\n" "$frame" > "$out/video-last-frame.txt"
    printf "VIDEO_PID=%s START_TICKS=%s STATE=%s FINAL_STATE=%s FRAME=%s PREVIOUS_FRAME=%s UTC=%s UPTIME=%s\n" "$pid" "$ticks" "$state" "$final_state" "$frame" "$previous" "$(date -u +%FT%T.%N)" "$(cut -d" " -f1 /proc/uptime)"
  ' bash "$target" "$label" "$GITHUB_WORKSPACE/evidence/vm/video-progress.txt" > "$target/$label-recording.txt"
  printf 'RECORDING_STATUS=advancing\n' > "$target/$label-recording-status.txt"
}
zoom_state() {
  local expected=$1 actual
  actual=$(guest 5 "zoom-require-$expected" '. /home/probe/session-env; timeout --kill-after=1s 3s gsettings get org.gnome.desktop.a11y.applications screen-magnifier-enabled')
  test "$actual" = "$expected"
}
locate() {
  local label=$1 name=$2
  guest 12 "$name-geometry-before" '. /home/probe/session-env; timeout --kill-after=1s 10s python3 /home/probe/finite-source/display-session.py app-check /home/probe/evidence/finite-original' > "$target/$name-geometry-before.txt"
  step 3 "$name-app-before-json" jq -s '[.[] | select(.event == "fresh-app-identity-checked") | .actual] | if length == 1 then .[0] else error("Missing unique actual app geometry") end' "$target/$name-geometry-before.txt" > "$target/$name-app-before.json"
  step 3 "$name-host-geometry-before" xdotool getwindowgeometry --shell "$qemu_window" > "$target/$name-host-before.txt"
  capture "$name-acquire"
  step 3 "$name-image-size" identify -format '%w %h\n' "$target/$name-acquire.png" > "$target/$name-image-size.txt"
  # X client geometry proposes only a bounded search region. This does not
  # certify SDL backing framebuffer/stage centering or an unscaled viewport.
  step 3 "$name-host-before-json" jq -Rn '[inputs | select(length > 0) | capture("^(?<key>WINDOW|X|Y|WIDTH|HEIGHT|SCREEN)=(?<value>-?[0-9]+)$") | {key, value:(.value|tonumber)}] | if length == 6 and (group_by(.key)|all(length==1)) then from_entries else error("Ambiguous host geometry") end' "$target/$name-host-before.txt" > "$target/$name-host-before.json"
  step 3 "$name-search-region" jq -nr --arg window "$qemu_window" --slurpfile a "$target/$name-app-before.json" --slurpfile host "$target/$name-host-before.json" '
    def integer: type == "number" and . == floor;
    $a[0] as $a | $host[0] as $h | $a.window.frameStage as $observed |
    if $a.stageSize != {width:800,height:600} or $observed.error != null then error("Stage/frame unavailable") else $observed.value end as $f |
    if ([$f.x,$f.y,$f.width,$f.height,$h.X,$h.Y,$h.WIDTH,$h.HEIGHT] | all(integer)) and
       $f.x >= 0 and $f.y >= 0 and $f.width > 0 and $f.height >= 80 and
       $f.x+$f.width <= 800 and $f.y+$f.height <= 600 and
       $h.WINDOW == ($window|tonumber) and $h.SCREEN == 0 and $h.WIDTH >= 800 and $h.HEIGHT >= 600 and
       (($h.WIDTH-800)%2 == 0) and (($h.HEIGHT-600)%2 == 0)
    then [($h.X+($h.WIDTH-800)/2+$f.x),($h.Y+($h.HEIGHT-600)/2+$f.y+$f.height-80),$f.width,80] | @tsv
    else error("Search-region geometry rejected") end' > "$target/$name-region.txt"
  printf 'ROI_ROLE=bounded-acquisition-search SDL_STAGE_TRANSFORM=unqualified POINTER_HIT=pending-observed-page\n' > "$target/$name-region-status.txt"
  local cx cy cw ch imagew imageh
  read -r cx cy cw ch < "$target/$name-region.txt"
  read -r imagew imageh < "$target/$name-image-size.txt"
  test "$imagew" = 1280 && test "$imageh" = 800
  test "$cx" -ge 0 && test "$cy" -ge 0 && test "$((cx+cw))" -le "$imagew" && test "$((cy+ch))" -le "$imageh"
  step 5 "$name-search-crop" convert "$target/$name-acquire.png" -crop "${cw}x${ch}+${cx}+${cy}" +repage "$target/$name-crop.png"
  step 5 "$name-ocr-input" convert "$target/$name-crop.png" -resize 200% -colorspace Gray -threshold 75% "$target/$name-ocr-input.png"
  step 7 "$name-ocr" tesseract "$target/$name-ocr-input.png" "$target/$name-acquire" --psm 11 tsv > "$target/$name-ocr.log" 2>&1
  # Coordinates invert actual PNG crop pixels; they do not rely on the search
  # projection being a proven guest-to-host transform or certify a product hit.
  awk -F '\t' -v label="$label" -v cx="$cx" -v cy="$cy" 'NR>1 && $12==label && $11>=50 {n++; x=cx+($7+$9/2)/2; y=cy+($8+$10/2)/2} END {if(n!=1) exit 2; printf "%d %d\n",x,y}' "$target/$name-acquire.tsv" > "$target/$name-coordinate.txt"
  guest 12 "$name-geometry-after" '. /home/probe/session-env; timeout --kill-after=1s 10s python3 /home/probe/finite-source/display-session.py app-check /home/probe/evidence/finite-original' > "$target/$name-geometry-after.txt"
  step 3 "$name-app-after-json" jq -s '[.[] | select(.event == "fresh-app-identity-checked") | .actual] | if length == 1 then .[0] else error("Missing unique actual app geometry") end' "$target/$name-geometry-after.txt" > "$target/$name-app-after.json"
  step 3 "$name-host-geometry-after" xdotool getwindowgeometry --shell "$qemu_window" > "$target/$name-host-after.txt"
  step 3 "$name-host-bracket" cmp "$target/$name-host-before.txt" "$target/$name-host-after.txt"
  step 3 "$name-app-bracket" jq -e --slurpfile b "$target/$name-app-before.json" '
    .stageSize == $b[0].stageSize and .process.pid == $b[0].process.pid and .process.startTicks == $b[0].process.startTicks and
    .instanceId == $b[0].instanceId and .exeSHA256 == $b[0].exeSHA256 and
    .window.stableSequence == $b[0].window.stableSequence and .window.pid == $b[0].window.pid and
    .window.frameStage == $b[0].window.frameStage and .window.compositorFocused == {value:true,error:null}
  ' "$target/$name-app-after.json" > "$target/$name-bracket.json"
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  closed=1
  # This marker closes admission before any collector can start.
  printf 'INPUT_ADMISSION_CLOSED uptime=%s status=%s\n' "$(now)" "$status" >> "$target/controller.txt" || true
  if test -e "$target/fallback-armed"; then
    timeout --kill-after=1s 6s ssh "${ssh_opts[@]}" probe@127.0.0.1 'touch /home/probe/evidence/finite-original/cleanup-request' >> "$target/cleanup.txt" 2>&1 || true
    # Read-only wait is independently bounded by the absolute cleanup stop.
    while awk -v t="$(now)" -v stop="$cleanup_stop" 'BEGIN {exit !(t+6 < stop)}'; do
      if timeout --kill-after=1s 5s ssh "${ssh_opts[@]}" probe@127.0.0.1 'set -e; out=/home/probe/evidence/finite-original; test -f "$out/fallback-finished"; cat "$out/fallback-finished" "$out/restore-completed.json"; grep -q "FALLBACK_JOINED exit=0 " "$out/fallback-finished"; jq -e --slurpfile b "$out/baseline.json" '\''.zoomRestoration == "complete" and .monitorRestoration == "complete" and .baselineIdentity == $b[0].identity and .cleanupLoggingErrors == []'\'' "$out/restore-completed.json"' > "$target/cleanup-receipt.txt" 2>&1; then
        touch "$target/cleanup-joined"
        break
      fi
      sleep 1
    done
  else
    # No display or Zoom mutation precedes fallback arming.
    printf 'NO_MUTATION_ADMITTED\n' > "$target/cleanup-receipt.txt"
    touch "$target/cleanup-joined"
  fi
  printf 'SCENARIO_JOINED uptime=%s\n' "$(now)" >> "$target/controller.txt" || true
  touch "$target/scenario-joined"
  test -e "$target/cleanup-joined" || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
step 8 stage-source scp -i /tmp/localsend-vm/id_ed25519 -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/localsend-vm/known_hosts -r "$source_dir" probe@127.0.0.1:/home/probe/finite-source
guest 35 save-baseline '. /home/probe/session-env; timeout --kill-after=1s 32s python3 /home/probe/finite-source/display-session.py prepare /home/probe/evidence/finite-original' > "$target/prepare.txt"
# Arming failure blocks all mutations. Record intent before remote launch so
# lost SSH replies cannot be mistaken for an absent guardian.
touch "$target/fallback-armed"
guest 8 arm-fallback 'nohup bash /home/probe/finite-source/supervise-fallback.sh > /home/probe/evidence/finite-original/fallback.log 2>&1 < /dev/null & for i in 1 2 3 4; do test -f /home/probe/evidence/finite-original/fallback-ready && cat /home/probe/evidence/finite-original/fallback-ready && exit 0; sleep 1; done; exit 1' > "$target/arm.txt"
guest 25 apply-native800 '. /home/probe/session-env; timeout --kill-after=1s 22s python3 /home/probe/finite-source/display-session.py apply /home/probe/evidence/finite-original' > "$target/apply.txt"
qemu_window=$(step 3 qemu-window xdotool search --onlyvisible --name QEMU | head -1)
step 2 qemu-focus xdotool windowfocus "$qemu_window"
capture native800-before-apps
binding=$(guest 5 binding '. /home/probe/session-env; timeout --kill-after=1s 3s gsettings get org.gnome.settings-daemon.plugins.media-keys magnifier')
printf '%s\n' "$binding" > "$target/zoom-binding.txt"
test "$binding" = "['<Alt><Super>8']"
guest 5 gtk-launch '. /home/probe/session-env; printf "GTK caret control.\n" > /home/probe/evidence/gtk-control.txt; nohup gnome-text-editor /home/probe/evidence/gtk-control.txt > /home/probe/evidence/gtk-editor.log 2>&1 < /dev/null &' > "$target/gtk-launch.txt"
step 3 gtk-render sleep 2
guest 12 gtk-focused '. /home/probe/session-env; timeout --kill-after=1s 10s python3 /home/probe/finite-source/display-session.py editor /home/probe/evidence/finite-original' > "$target/gtk-focus.txt"
input gtk-end key ctrl+End
zoom_state false
recording gtk-before-on-ready
step 2 recording-readiness-interval sleep 1
recording gtk-before-on-advancing
input gtk-zoom-on key alt+Super_L+8
zoom_state true
input gtk-left key Left
input gtk-right key Right
observe gtk-on
input gtk-zoom-off key alt+Super_L+8
zoom_state false
guest 5 original-launch '. /home/probe/session-env; nohup flatpak run org.localsend.localsend_app > /home/probe/evidence/localsend.log 2>&1 < /dev/null &' > "$target/original-launch.txt"
step 4 app-render sleep 3
guest 12 original-focused '. /home/probe/session-env; timeout --kill-after=1s 10s python3 /home/probe/finite-source/display-session.py app /home/probe/evidence/finite-original' > "$target/app-focus.txt"
observe app-off
# Receive is selected OFF before attempting the Send transition ON.
locate Receive receive-initial
read -r ix iy < "$target/receive-initial-coordinate.txt"
input receive-initial-position mousemove "$ix" "$iy"
input receive-initial-off click 1
locate Send send
read -r sx sy < "$target/send-coordinate.txt"
input send-position mousemove "$sx" "$sy"
recording send-before-on
input send-zoom-on key alt+Super_L+8
zoom_state true
input send-zoom-click click 1
guest 12 original-still-focused '. /home/probe/session-env; timeout --kill-after=1s 10s python3 /home/probe/finite-source/display-session.py app-check /home/probe/evidence/finite-original' > "$target/app-send-identity.txt"
observe send-on
input send-zoom-off key alt+Super_L+8
zoom_state false
locate Receive receive
read -r rx ry < "$target/receive-coordinate.txt"
input receive-position mousemove "$rx" "$ry"
# Admit the complete selected terminal sequence before enabling Zoom. The
# unchanged absolute input stop still gates every individual operation.
budget 145
printf 'HELD_OBSERVATION=incomplete PRODUCT_RESULT=requires-raw-review\n' > "$target/held-observation-status.txt"
recording receive-before-on
input receive-zoom-on key alt+Super_L+8
zoom_state true
step 2 receive-zoom-click xdotool click 1
step 13 receive-on-hold sleep 12
# Capture precedes passive SSH observations so the terminal image is timed
# from the actual click, before any cleanup or potential prompt focus change.
capture receive-on-terminal
step 1 receive-on-terminal-marker touch "$target/receive-on-terminal-capture-completed"
zoom_state true
observe receive-on-terminal
step 2 receive-on-passive-complete grep -qx 'OBSERVATION_FAILURES=0 INFERENCE=inconclusive' "$target/receive-on-terminal-observe.txt"
recording receive-on-terminal
step 2 receive-zoom-off xdotool key alt+Super_L+8
step 6 receive-off-recovery-hold sleep 5
capture receive-off-terminal
step 1 receive-off-terminal-marker touch "$target/receive-off-terminal-capture-completed"
zoom_state false
observe receive-off-terminal
step 2 receive-off-passive-complete grep -qx 'OBSERVATION_FAILURES=0 INFERENCE=inconclusive' "$target/receive-off-terminal-observe.txt"
recording receive-off-terminal
printf 'HELD_OBSERVATION=complete PRODUCT_RESULT=requires-raw-review\n' > "$target/held-observation-status.txt"
# EXIT closes input and immediately requests saved-baseline restoration.
