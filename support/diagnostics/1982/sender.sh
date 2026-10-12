#!/usr/bin/env bash
set -euo pipefail
export NO_AT_BRIDGE=0 LIBGL_ALWAYS_SOFTWARE=1
declare -A owned_ticks owned_labels
register_owned() {
  local pid="$1" label="$2"
  owned_ticks[$pid]=$(awk '{print $22}' "/proc/$pid/stat")
  owned_labels[$pid]="$label"
  printf '%s\t%s\t%s\t%s\n' "$pid" "$label" "${owned_ticks[$pid]}" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> evidence/1982-owned-pids.tsv
  cat "/proc/$pid/stat" >> evidence/1982-owned-process-stat.txt
}
owned_state() {
  local pid="$1" fields ticks state
  if ! test -e "/proc/$pid/stat"; then printf 'absent'; return; fi
  fields=$(awk '{print $3, $22}' "/proc/$pid/stat") || { printf 'unavailable'; return; }
  read -r state ticks <<< "$fields"
  if test -z "$ticks" || test -z "$state"; then printf 'unavailable'; return; fi
  if test "$ticks" != "${owned_ticks[$pid]}"; then printf 'pid-reused'; return; fi
  if test "$state" = Z; then printf 'zombie'; else printf 'running'; fi
}
cleanup() {
  local original_exit=$?
  # Runs only after product outcome/abort, never between arms.
  local pid signal attempt before after status terminal completed=true comma='' wait_status
  printf '[' > evidence/1982-desktop-cleanup-processes.json
  for pid in "${!owned_ticks[@]}"; do
    before=$(owned_state "$pid")
    signal=TERM
    test "${owned_labels[$pid]}" != recorder || signal=INT
    status=not-needed
    wait_status=null
    if test "$before" = running; then
      # Re-read start ticks immediately before each signal, refusing PID reuse.
      if test "$(owned_state "$pid")" = running; then
        if kill -"$signal" "$pid" 2>/dev/null; then status=sent; else status=signal-error; completed=false; fi
      else
        status=identity-changed-before-signal
        completed=false
      fi
      for attempt in {1..50}; do
        test "$(owned_state "$pid")" = running || break
        sleep 0.1
      done
      if test "$(owned_state "$pid")" = running; then
        if test "$(owned_state "$pid")" = running; then
          if kill -KILL "$pid" 2>/dev/null; then
            status=sent-then-kill
            for attempt in {1..10}; do
              test "$(owned_state "$pid")" = running || break
              sleep 0.1
            done
          else status=kill-error; completed=false; fi
        else status=identity-changed-before-kill; completed=false; fi
      fi
    fi
    after=$(owned_state "$pid")
    if test "$after" = zombie || test "$after" = absent; then
      terminal=true
      if wait "$pid" 2>/dev/null; then wait_status=0; else wait_status=$?; fi
      after=$(owned_state "$pid")
      if test "$after" != zombie && test "$after" != absent; then terminal=false; completed=false; fi
    else terminal=false; completed=false; fi
    if test "$before" = unavailable || test "$before" = pid-reused; then completed=false; fi
    printf '%s{"pid":%s,"label":"%s","startTicks":"%s","before":"%s","after":"%s","signal":"%s","signalStatus":"%s","waitExit":%s,"terminal":%s}' "$comma" "$pid" "${owned_labels[$pid]}" "${owned_ticks[$pid]}" "$before" "$after" "$signal" "$status" "$wait_status" "$terminal" >> evidence/1982-desktop-cleanup-processes.json
    comma=,
  done
  printf ']\n' >> evidence/1982-desktop-cleanup-processes.json
  # A missing original-process registration is not successful cleanup.
  if test -z "${ISSUE_1982_SENDER_PID:-}" || test -z "${owned_ticks[${ISSUE_1982_SENDER_PID:-0}]:-}"; then completed=false; fi
  printf 'recording_end_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> evidence/1982-desktop-recording.txt
  cat /proc/uptime >> evidence/1982-desktop-recording.txt
  printf '{"ownedCleanupCompleted":%s,"originalDriverExit":%s,"processes":"1982-desktop-cleanup-processes.json","pidReceipt":"1982-owned-pids.tsv","phase":"final exit after product outcomes or abort"}\n' "$completed" "$original_exit" > evidence/1982-desktop-cleanup.json
  if test "$original_exit" -ne 0; then exit "$original_exit"; fi
  if test "$completed" != true; then exit 1; fi
}
trap cleanup EXIT
gsettings set org.gnome.desktop.interface toolkit-accessibility true
openbox > evidence/1982-openbox.log 2>&1 &
register_owned "$!" openbox
printf 'recording_start_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" > evidence/1982-desktop-recording.txt
cat /proc/uptime >> evidence/1982-desktop-recording.txt
ffmpeg -nostdin -y -f x11grab -framerate 15 -video_size 1200x800 -i "$DISPLAY" -c:v libx264 -preset ultrafast -crf 20 evidence/1982-desktop-original.mp4 > evidence/1982-desktop-recording.log 2>&1 &
register_owned "$!" recorder
kill -0 "$!"
released/localsend_app > evidence/1982-desktop.log 2>&1 &
export ISSUE_1982_SENDER_PID=$!
register_owned "$ISSUE_1982_SENDER_PID" original-localsend
export ISSUE_1982_SENDER_START_TICKS="${owned_ticks[$ISSUE_1982_SENDER_PID]}"
/usr/bin/python3 support/diagnostics/1982/sender.py > evidence/1982-desktop-input.log 2>&1
