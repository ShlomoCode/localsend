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
zoom_state() {
  local expected=$1 actual
  actual=$(guest 5 "zoom-require-$expected" '. /home/probe/session-env; timeout --kill-after=1s 3s gsettings get org.gnome.desktop.a11y.applications screen-magnifier-enabled')
  test "$actual" = "$expected"
}
locate() {
  local label=$1 name=$2
  capture "$name-acquire"
  step 7 "$name-ocr" tesseract "$target/$name-acquire.png" "$target/$name-acquire" --psm 11 tsv > "$target/$name-ocr.log" 2>&1
  # Unique exact visible label; TSV/image remain the acquisition evidence.
  awk -F '\t' -v label="$label" 'NR>1 && $12==label && $11>=50 {n++; x=$7+$9/2; y=$8+$10/2} END {if(n!=1) exit 2; printf "%d %d\n",x,y}' "$target/$name-acquire.tsv" > "$target/$name-coordinate.txt"
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
input receive-zoom-on key alt+Super_L+8
zoom_state true
input receive-zoom-click click 1
guest 12 original-receive-focused '. /home/probe/session-env; timeout --kill-after=1s 10s python3 /home/probe/finite-source/display-session.py app-check /home/probe/evidence/finite-original' > "$target/app-receive-identity.txt"
observe receive-on
# EXIT closes input and immediately requests saved-baseline restoration.
