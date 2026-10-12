#!/usr/bin/env bash
# Every invocation is through host wsl.exe (out-of-band from the TCP transfer).
# ROOT: prepare/start, arm, network-proof, down, up, terminal, collect, quit.
# Fixture contract: arm <control|failed> <bytes> <sha256> <basename>.
# Host may restore early ONLY after recording genuine native sender terminal
# error. A bounded guardian restores on infrastructure deadline; that fallback
# is not a qualifying native-error observation.
set -Eeuo pipefail
evidence=${1:?evidence}; action=${2:?action}; shift 2
scripts=$(cd "$(dirname "$0")" && pwd)
if [[ "$action" == prepare || "$action" == start ]]; then exec bash "$scripts/wsl_prepare.sh" "$evidence" "${1:?pinned DEB sha256}"; fi
if [[ "$action" == receiver-trace ]]; then
  exec timeout --kill-after=1s 15s bash "$0" "$evidence" receiver-trace-bounded
fi
if [[ "$action" == receiver-liveness ]]; then
  # The whole observation, including receipt collection, is guest-bounded.
  # GNU timeout owns only the observer group and attempts TERM at 8s, KILL
  # after 1s grace. Uninterruptible tasks/I/O can exceed the intended bound.
  exec timeout --kill-after=1s 8s bash "$0" "$evidence" receiver-liveness-bounded "${1:?label}"
fi
evidence=$(realpath "$evidence")
source "$evidence/receiver/session.env"
stamp() { date -u --iso-8601=ns; }
case_dir() { [[ "$1" == control || "$1" == failed ]]; out="$evidence/cases/$1/receiver"; mkdir -p "$out"; }
identity() {
  [[ $(readlink -f "/proc/$APP_PID/exe") == "$EXE" ]]
  [[ $(awk '{print $22}' "/proc/$APP_PID/stat") == "$(cat "$evidence/receiver/app.start-tick")" ]]
}
root() { [[ $(id -u) == 0 ]] || { echo 'Host must invoke wsl.exe -u root'; exit 1; }; }
receipt() {
  local label=$1
  date -u --iso-8601=ns > "$out/$label.utc"
  ip -j link show dev eth0 > "$out/$label-link.json"
  ip -j -4 addr show dev eth0 > "$out/$label-address.json"
  ip -j -4 route show > "$out/$label-routes.json"
  ip -4 -o addr show dev eth0 > "$out/$label-address.txt"
  ip -4 route get "$peer" > "$out/$label-route-get.txt"
  ss -tnp > "$out/$label-sockets.txt"
  if [[ -r "/proc/$APP_PID/stat" ]]; then
    readlink -f "/proc/$APP_PID/exe" > "$out/$label-executable.txt" || true
    cat "/proc/$APP_PID/stat" > "$out/$label-process-stat.txt" || true
  else
    printf 'Recorded LocalSend PID absent at %s\n' "$(stamp)" > "$out/$label-process-absent.txt"
  fi
}
partial() {
  source "$out/fixture.env" || return 1
  [[ -f "$DEST/$filename" ]] || return 1
  bytes=$(stat -c %s "$DEST/$filename") || return 1
  (( bytes > 0 && bytes < expected_bytes )) || return 1
  printf 'partial\t%s\t%s\t%s\t%s\n' "$(stamp)" "$bytes" "$expected_bytes" "$DEST/$filename" > "$out/partial.tsv"
}
proof() {
  identity; partial
  [[ "$peer" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$peer" != 127.* && "$peer" != 0.* ]]
  ip -o link show dev eth0 | grep -Eq '<([^>]*,)?UP(,[^>]*)?>'
  ip -4 route get "$peer" > "$out/route-check.txt"
  grep -Eq ' dev eth0( |$)' "$out/route-check.txt"
  # Full -H output retains STATE at $1, local at $4 and peer at $5.
  ss -Htnp > "$out/established-check.txt"
  # Exact local receiver port, peer IP, and the recorded live LocalSend PID.
  awk -v peer="$peer" -v pid="$APP_PID" '$1=="ESTAB" && $4 ~ /:41631$/ && index($5,peer ":")==1 && index($0,"pid=" pid ",") {found=1; print} END{exit !found}' \
    "$out/established-check.txt" > "$out/owned-peer-socket.txt"
  receipt network-proof
  printf 'proved\t%s\teth0\t%s\t%s\n' "$(stamp)" "$peer" "$APP_PID" > "$out/network-proof.tsv"
}
restore() {
  [[ -s "$out/down.tsv" && -s "$out/peer.txt" ]]
  peer=$(cat "$out/peer.txt")
  ip link set dev eth0 up
  for ((attempt=0; attempt<40; attempt++)); do
    if ip -4 route get "$peer" > "$out/restore-route-check.txt" 2>/dev/null && grep -Eq ' dev eth0( |$)' "$out/restore-route-check.txt"; then break; fi
    sleep 0.25
  done
  ip -o link show dev eth0 | grep -Eq '<([^>]*,)?UP(,[^>]*)?>'
  ip -4 -o addr show dev eth0 > "$out/restored-address.txt"
  cmp "$out/before-down-address.txt" "$out/restored-address.txt"
  ip -4 route get "$peer" > "$out/restored-route-get.txt"
  cmp "$out/before-down-route-get.txt" "$out/restored-route-get.txt"
  receipt restored
  printf 'restored\t%s\t%s\n' "$(stamp)" "${1:-host}" > "$out/up.tsv"
  rm -f "$out/guardian.active"
}
case "$action" in
  receiver-trace-bounded)
    root
    trace="$evidence/receiver/lifetime/trace"
    [[ -s "$trace/attached.tsv" ]]
    # Host waited 12s after normal return. The 20s observer started earlier,
    # leaving at most 8s nominal trace time; all collection shares this 15s
    # outer bound. Missing completion is infrastructure, never a fresh attach.
    deadline=$((SECONDS+8))
    initial_status=0
    timeout --kill-after=1s 2s bash "$scripts/wsl_lifetime_snapshot.sh" "$evidence" snapshot post-return-trace-before-wait || initial_status=$?
    printf '%s\n' "$initial_status" > "$trace/collection-initial-snapshot.exit"
    while [[ ! -s "$trace/completed.tsv" ]] && (( SECONDS < deadline )); do sleep 0.1; done
    result=0
    (( initial_status == 0 )) || result=1
    if [[ ! -s "$trace/completed.tsv" ]]; then
      printf 'trace completion missing at collection deadline\n' > "$trace/collection-failure.txt"; result=1
    elif [[ $(cat "$trace/strace.exit") != 0 && $(cat "$trace/strace.exit") != 130 ]]; then
      printf 'unexpected trace timeout/exit; inspect native output\n' > "$trace/collection-failure.txt"; result=1
    fi
    detach_status=0
    timeout --kill-after=1s 2s bash "$scripts/wsl_lifetime_snapshot.sh" "$evidence" trace-state detached || detach_status=$?
    printf '%s\n' "$detach_status" > "$trace/collection-detach.exit"
    (( detach_status == 0 )) || result=1
    snapshot_status=0
    timeout --kill-after=1s 3s bash "$scripts/wsl_lifetime_snapshot.sh" "$evidence" snapshot post-return-trace || snapshot_status=$?
    printf '%s\n' "$snapshot_status" > "$trace/collection-snapshot.exit"
    (( snapshot_status == 0 )) || result=1
    # A surviving original TID must have detached. Absent TIDs are recorded
    # by raw receipts, not interpreted as an identity-equivalent replacement.
    while IFS=$'\t' read -r name pid tid tick executable; do
      [[ "$name" != role ]] || continue
      path="$trace/detached/$name-$tid.status"
      qualified=no
      if [[ -s "$path" && -r "$path.exit" && $(cat "$path.exit") == 0 ]]; then
        prefix="$trace/detached/$name-$tid"
        if [[ -s "$prefix.stat" && -s "$prefix.after.stat" && -s "$prefix.exe" ]]; then
          raw=$(cat "$prefix.stat"); fields=${raw##*) }; read -r -a before_parts <<< "$fields"
          raw=$(cat "$prefix.after.stat"); fields=${raw##*) }; read -r -a after_parts <<< "$fields"
          if [[ ${before_parts[19]} == "$tick" && ${after_parts[19]} == "$tick" && $(cat "$prefix.exe") == "$executable" ]] &&
             grep -Eq '^TracerPid:[[:space:]]+0$' "$path"; then qualified=original-detached; fi
        fi
      elif [[ -r "$path.exit" && $(cat "$path.exit") == 1 && ! -d "/proc/$pid/task/$tid" ]] &&
           grep -Fq 'No such file or directory' "$path.stderr"; then
        qualified=original-task-absent
      fi
      printf '%s\t%s\t%s\n' "$name" "$tid" "$qualified" >> "$trace/detach-qualification.tsv"
      if [[ "$qualified" == no ]]; then
        printf '%s\t%s\tdetach-unqualified-read-failure-reuse-or-attached\n' "$name" "$tid" >> "$trace/collection-failure.txt"; result=1
      fi
    done < "$trace/tids.tsv"
    if [[ -s "$trace/strace.exit" && $(cat "$trace/strace.exit") == 130 ]]; then
      # Bookkeeping only: never classify130 as routine without the observed
      # bounded INT marker and all actual native detach receipts qualifying.
      if (( result == 0 )) && [[ -r "$trace/deadline.txt" ]] &&
         grep -Fxq 'observer-deadline-INT' "$trace/deadline.txt" &&
         grep -Fq 'observed_shell_interrupt=yes' "$trace/completed.tsv"; then
        printf '130\tobserved-bounded-INT-and-qualified-detach\n' > "$trace/strace-exit-classification.tsv"
      else
        printf '130\tunqualified-native-exit\n' > "$trace/strace-exit-classification.tsv"; result=1
      fi
    fi
    # Both actual postreturn snapshots must retain the same original stable
    # desktop. HUP removal or app survival alone never qualifies this result.
    raw=$(cat "$evidence/receiver/lifetime/receiver.registration.stat"); fields=${raw##*) }; read -r -a original_parent_parts <<< "$fields"
    for phase in post-return-trace-before-wait post-return-trace; do
      live="$evidence/receiver/lifetime/$phase"
      for role in app wm xvfb; do
        read -r pid tick executable < "$evidence/receiver/lifetime/$role.ref"
        qualified=no
        receipts_ok=yes
        for probe in before.stat after.stat exe status; do
          if [[ ! -s "$live/$role.$probe" || ! -r "$live/$role.$probe.exit" || $(cat "$live/$role.$probe.exit") != 0 ]]; then receipts_ok=no; fi
        done
        if [[ "$receipts_ok" == yes ]]; then
          raw=$(cat "$live/$role.before.stat"); fields=${raw##*) }; read -r -a before_parts <<< "$fields"
          raw=$(cat "$live/$role.after.stat"); fields=${raw##*) }; read -r -a after_parts <<< "$fields"
          if [[ ${before_parts[19]} == "$tick" && ${after_parts[19]} == "$tick" && $(cat "$live/$role.exe") == "$executable" &&
                ${before_parts[0]} != Z && ${before_parts[0]} != X && ${before_parts[0]} != x &&
                ${after_parts[0]} != Z && ${after_parts[0]} != X && ${after_parts[0]} != x ]]; then qualified=yes; fi
          if [[ "$role" == xvfb && ( ${after_parts[2]} != "$pid" || ${after_parts[3]} != "$pid" || ${after_parts[4]} != 0 || ${after_parts[5]} != -1 ) ]]; then qualified=no; fi
          if [[ "$role" != xvfb && ( ${before_parts[2]} != "${original_parent_parts[2]}" || ${after_parts[2]} != "${original_parent_parts[2]}" ||
               ${before_parts[3]} != "${original_parent_parts[3]}" || ${after_parts[3]} != "${original_parent_parts[3]}" ) ]]; then qualified=no; fi
          if [[ "$phase" == post-return-trace ]] && ! grep -Eq '^TracerPid:[[:space:]]+0$' "$live/$role.status"; then qualified=no; fi
        fi
        printf '%s\t%s\toriginal-live=%s\n' "$phase" "$role" "$qualified" >> "$trace/stable-desktop-qualification.tsv"
        if [[ "$qualified" != yes ]]; then result=1; fi
      done
      for receipt in listeners.txt window-pid.txt visible-windows.txt; do
        if [[ ! -s "$live/$receipt" || ! -r "$live/$receipt.exit" || $(cat "$live/$receipt.exit") != 0 ]]; then result=1; fi
      done
      if [[ $(cat "$live/window-pid.txt") != "$APP_PID" ]] || ! grep -Fxq "$WINDOW" "$live/visible-windows.txt" ||
         ! grep -E ':41631[[:space:]].*pid='"$APP_PID"',' "$live/listeners.txt" >/dev/null; then
        printf '%s\toriginal-owned-window-or-listener-missing\n' "$phase" >> "$trace/collection-failure.txt"; result=1
      fi
    done
    # Parse only cloud native records for exact original enumerated TIDs.
    # Retain matching raw lines and per-role counts; lack of controls fails.
    [[ -s "$trace/events.txt" ]]
    awk -F '\t' 'NR>1 {print $1, $3}' "$trace/tids.tsv" > "$trace/native-role-tids.txt"
    awk 'FNR==NR {role[$2]=$1; next} /--- SIGHUP / && $1 in role {print role[$1] "\t" $0}' \
      "$trace/native-role-tids.txt" "$trace/events.txt" > "$trace/native-hup-records.tsv"
    # Match E21's kernel-origin controls; any Xvfb HUP fails the absence gate.
    awk -F '\t' '$1=="xvfb" || index($0,"si_code=SI_KERNEL"){n[$1]++} END{printf "app\t%d\nwm\t%d\nxvfb\t%d\n",n["app"],n["wm"],n["xvfb"]}' \
      "$trace/native-hup-records.tsv" > "$trace/native-hup-counts.tsv"
    if ! awk -F '\t' '$1=="app"{app=$2} $1=="wm"{wm=$2} $1=="xvfb"{xvfb=$2} END{exit !(app>0 && wm>0 && xvfb==0)}' "$trace/native-hup-counts.tsv"; then
      printf 'native-HUP-comparison-controls-unqualified\n' >> "$trace/collection-failure.txt"; result=1
    fi
    printf 'collected\t%s\tfailed=%s\n' "$(stamp)" "$result" > "$trace/collection-result.tsv"
    exit "$result"
    ;;
  receiver-liveness-bounded)
    root; label=${1:?label}; [[ "$label" =~ ^post-return-[12]$ ]]
    live="$evidence/receiver/lifetime/$label"; mkdir "$live"
    failure=0
    probe_capture() {
      local name=$1 result=0; shift
      "$@" > "$live/$name.txt" 2> "$live/$name.stderr" || result=$?
      printf '%s\n' "$result" > "$live/$name.exit" || true
      if (( result != 0 )); then printf '%s\texit=%s\n' "$name" "$result" >> "$live/failures.tsv"; failure=1; fi
      return 0
    }
    probe_capture snapshot-before bash "$scripts/wsl_lifetime_snapshot.sh" "$evidence" snapshot "$label-before"
    original_live() {
      local name=$1 pid tick executable raw fields; local -a parts
      read -r pid tick executable < "$evidence/receiver/lifetime/$name.ref" || return 1
      raw=$(cat "/proc/$pid/stat") || return 1; fields=${raw##*) }; read -r -a parts <<< "$fields"
      [[ ${parts[19]} == "$tick" && ${parts[0]} != Z && ${parts[0]} != X && ${parts[0]} != x && $(readlink -f "/proc/$pid/exe") == "$executable" ]] || return 1
    }
    for name in app xvfb; do
      if original_live "$name"; then printf 'original-live\n' > "$live/$name.gate"; else printf '%s\toriginal-identity-or-state-failed\n' "$name" >> "$live/failures.tsv"; failure=1; fi
    done
    probe_capture listeners ss -ltnp
    if ! grep -E ':41631[[:space:]].*pid='"$APP_PID"',' "$live/listeners.txt" >/dev/null; then printf 'original-app-listener-missing\n' >> "$live/failures.tsv"; failure=1; fi
    # Xvfb was launched without an authorization file; query its original
    # display directly, avoiding another PAM/session launcher in the observer.
    probe_capture window-pid env DISPLAY="$DISPLAY" xdotool getwindowpid "$WINDOW"
    probe_capture visible-windows env DISPLAY="$DISPLAY" xdotool search --onlyvisible --pid "$APP_PID"
    if [[ $(cat "$live/window-pid.txt") != "$APP_PID" ]] || ! grep -Fxq "$WINDOW" "$live/visible-windows.txt"; then printf 'original-visible-owned-window-missing\n' >> "$live/failures.tsv"; failure=1; fi
    # Recheck identities after socket/window observations to reject PID reuse.
    for name in app xvfb; do
      if ! original_live "$name"; then printf '%s\tfinal-original-identity-or-state-failed\n' "$name" >> "$live/failures.tsv"; failure=1; fi
    done
    # Primary result survives a failed secondary snapshot/write.
    printf 'observed\t%s\tfailed=%s\n' "$(stamp)" "$failure" > "$live/validation-result.tsv" || true
    probe_capture snapshot-after bash "$scripts/wsl_lifetime_snapshot.sh" "$evidence" snapshot "$label-after"
    if (( failure )); then exit 1; fi
    before="$evidence/receiver/lifetime/prepare-before-normal-return"; after="$evidence/receiver/lifetime/$label-after"
    if [[ ! -s "$before/boot-id.txt" || ! -s "$after/boot-id.txt" || ! -s "$before/pid1.stat" || ! -s "$after/pid1.stat" ]] ||
       [[ $(cat "$before/boot-id.txt") != $(cat "$after/boot-id.txt") ]]; then printf 'guest-boot-continuity-failed\n' >> "$live/failures.tsv"; exit 1; fi
    raw=$(cat "$before/pid1.stat"); fields=${raw##*) }; read -r -a before_parts <<< "$fields"
    raw=$(cat "$after/pid1.stat"); fields=${raw##*) }; read -r -a after_parts <<< "$fields"
    [[ ${before_parts[19]} == "${after_parts[19]}" ]] || { printf 'pid1-continuity-failed\n' >> "$live/failures.tsv"; exit 1; }
    printf 'passed\t%s\t%s\n' "$(stamp)" "$APP_PID" > "$live/passed.tsv"
    ;;
  arm)
    root; case_id=${1:?case}; case_dir "$case_id"; expected_bytes=${2:?bytes}; expected_sha=${3:?sha256}; filename=${4:?basename}
    [[ "$expected_bytes" =~ ^[1-9][0-9]*$ && "$expected_sha" =~ ^[a-fA-F0-9]{64}$ && "$filename" =~ ^[A-Za-z0-9_.-]+$ && "$filename" != .* ]]
    [[ ! -e "$out/fixture.env" && ! -e "$DEST/$filename" ]]; identity
    printf 'expected_bytes=%q\nexpected_sha=%q\nfilename=%q\n' "$expected_bytes" "$expected_sha" "$filename" > "$out/fixture.env"
    chown -R tester:tester "$out"
    printf -v launch 'bash %q %q watch %q' "$scripts/wsl_control.sh" "$evidence" "$case_id"
    nohup runuser -u tester -- bash -c "$launch" > "$out/supervisor.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$out/supervisor.pid"
    ;;
  network-proof) root; case_dir "${1:?case}"; peer=${2:?actual host peer IPv4}; proof ;;
  down)
    root; case_dir "${1:?case}"; peer=${2:?peer}; bound=${3:?restoration deadline seconds}
    [[ "$bound" =~ ^[0-9]+$ ]] && (( bound >= 30 && bound <= 1800 ))
    exec 8>"$evidence/network-control.lock"; flock -n 8
    [[ ! -e "$out/down.tsv" ]]; proof; receipt before-down
    printf '%s\n' "$peer" > "$out/peer.txt"
    token=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$token" > "$out/guardian.active"
    printf -v guard 'bash %q %q guard %q %q %q' "$scripts/wsl_control.sh" "$evidence" "${1}" "$token" "$bound"
    # Guardian is armed BEFORE down; it never touches the host main NIC.
    nohup bash -c "$guard" 8>&- > "$out/guardian.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$out/guardian.pid"
    printf 'down-request\t%s\teth0\tdeadline_seconds=%s\n' "$(stamp)" "$bound" > "$out/down.tsv"
    trap 'trap - ERR; restore down_command_failure' ERR
    ip link set dev eth0 down
    ip -j link show dev eth0 > "$out/observed-down-link.json"
    ip -o link show dev eth0 > "$out/observed-down-link.txt"
    if grep -Eq '<([^>]*,)?UP(,[^>]*)?>' "$out/observed-down-link.txt"; then
      echo 'Guest interface is still UP after native down input'; exit 1
    fi
    printf 'down-observed\t%s\teth0\n' "$(stamp)" >> "$out/down.tsv"
    trap - ERR
    ;;
  up) root; case_dir "${1:?case}"; exec 8>"$evidence/network-control.lock"; flock 8; restore host_out_of_band ;;
  down-state)
    root; case_dir "${1:?case}"
    [[ -s "$out/down.tsv" && -s "$out/guardian.active" && ! -e "$out/guardian-fired.tsv" ]]
    ip -j link show dev eth0 > "$out/native-terminal-link.json"
    ip -o link show dev eth0 > "$out/native-terminal-link.txt"
    if grep -Eq '<([^>]*,)?UP(,[^>]*)?>' "$out/native-terminal-link.txt"; then
      echo 'Guest interface is UP at native terminal receipt'; exit 1
    fi
    printf 'down-at-native-terminal\t%s\teth0\n' "$(stamp)" > "$out/native-terminal-link.tsv"
    ;;
  guard)
    root; case_dir "${1:?case}"; token=${2:?token}; bound=${3:?seconds}; sleep "$bound"
    exec 8>"$evidence/network-control.lock"; flock 8
    if [[ -f "$out/guardian.active" && $(cat "$out/guardian.active") == "$token" ]]; then
      printf 'deadline-restoration\t%s\tnative-terminal-gate-unmet\n' "$(stamp)" > "$out/guardian-fired.tsv"
      trap 'printf "restoration-failed\t%s\n" "$(stamp)" > "$out/guardian-restoration-failed.tsv"' ERR
      restore guardian_deadline_infrastructure_failure
      trap - ERR
    fi
    ;;
  terminal)
    root; case_dir "${1:?case}"; receipt_path=${2:?existing native sender terminal evidence path}
    [[ -s "$receipt_path" && -s "$out/up.tsv" && ! -e "$out/guardian-fired.tsv" ]]
    cp "$receipt_path" "$out/host-native-terminal-receipt.json"
    # Controller owns validation of the actual sender native error. This signal
    # closes recording only; no app state/protocol/error is manufactured here.
    printf 'host-native-terminal\t%s\t%s\n' "$(stamp)" "$receipt_path" > "$out/native-terminal.tsv"
    ;;
  control-result) case_dir control; cat "$out/result.env"; [[ -s "$out/complete.tsv" ]] ;;
  accept)
    case_dir "${1:?case}"; cat "$out/accepted.tsv"
    if [[ "$1" == failed ]]; then partial; cat "$out/partial.tsv"; fi
    ;;
  partial) case_dir "${1:?case}"; partial; cat "$out/partial.tsv" ;;
  collect)
    root; case_dir "${1:?case}"; identity; peer=$(cat "$out/peer.txt"); receipt collected
    find "$DEST" -maxdepth 1 -type f -printf '%p\t%s\n' > "$out/preserved-files.tsv"
    cp "$SETTINGS" "$out/settings-current.json"
    ;;
  quit)
    root; identity; [[ ! -e "$evidence/cases/failed/receiver/guardian.active" ]]
    runuser -u tester -- env DISPLAY="$DISPLAY" xdotool windowactivate --sync "$WINDOW" key alt+F4
    for ((attempt=0; attempt<40; attempt++)); do [[ -e "/proc/$APP_PID" ]] || break; sleep 0.25; done
    [[ ! -e "/proc/$APP_PID" ]] || { echo 'Normal window Quit did not exit; preserve live app'; exit 1; }
    printf 'normal-alt-f4\t%s\t%s\n' "$(stamp)" "$APP_PID" > "$evidence/receiver/quit.tsv"
    ;;
  watch)
    [[ $(id -un) == tester && $(id -u) != 0 ]]; case_id=${1:?case}; case_dir "$case_id"; source "$out/fixture.env"
    export DISPLAY LANG=C.UTF-8; identity
    exec 9>"$evidence/receiver-controller.lock"; flock -n 9
    exec > >(tee -a "$out/control.log") 2>&1
    frame=0; video_pid=''
    event() { printf '%s\t%s\t%s\n' "$(stamp)" "$1" "${2:-}" >> "$out/events.tsv"; }
    snapshot() {
      frame=$((frame+1)); base="$out/$(printf '%04d' "$frame")-$1"
      timeout 6 ffmpeg -nostdin -y -loglevel error -f x11grab -video_size 1280x900 -i "$DISPLAY" -frames:v 1 "$base.png"
      timeout 6 tesseract "$base.png" "$base" --psm 11 tsv txt >/dev/null 2>&1
      control_tsv="$base.tsv"
    }
    coords() { awk -F '\t' -v w="$1" 'NR>1&&$1==5&&$11>=50&&tolower($12)==tolower(w){n++;x=$7+$9/2;y=$8+$10/2} END{if(n==1)printf "%d %d",x,y;else exit 1}' "$control_tsv"; }
    click_word() {
      local xy; xy=$(coords "$1") || return 1
      # Owned window and fresh, uniquely recognized rendered label required.
      [[ $(xdotool getwindowpid "$WINDOW") == "$APP_PID" ]]; identity
      event click "$1 $xy $control_tsv"; read -r x y <<< "$xy"
      timeout 3 xdotool windowactivate --sync "$WINDOW"
      timeout 3 xdotool mousemove --sync "$x" "$y" click 1
    }
    approval_ocr() {
      # White button text sometimes needs contrast inversion; retain original.
      timeout 6 ffmpeg -nostdin -y -loglevel error -i "$base.png" -vf "format=gray,lut=y='if(gt(val,180),0,255)'" -frames:v 1 "$base-inverse.png"
      timeout 6 tesseract "$base-inverse.png" "$base-inverse" --psm 11 -c tessedit_do_invert=0 tsv txt >/dev/null 2>&1
      control_tsv="$base-inverse.tsv"
    }
    approval_crop() {
      # v1.14 ReceivePage renders Options above the approval row. Its actual
      # OCR anchor scopes the white-label crop; mapped coordinates remain
      # full-screen coordinates, and Accept+Decline must both be unique.
      local anchor cx cy transformed
      anchor=$(awk -F '\t' 'NR>1&&$1==5&&$11>=50&&tolower($12)=="options"{n++;x=$7+$9/2;y=$8+$10} END{if(n==1)printf "%d %d",x,y;else exit 1}' "$base.tsv") || return 0
      read -r cx cy <<< "$anchor"; cx=$((cx-220)); cy=$((cy+15))
      (( cx >= 0 && cy >= 0 && cx+440 <= 1280 && cy+90 <= 900 )) || return 0
      transformed="$base-approval-crop"
      printf 'crop_x\tcrop_y\twidth\theight\tscale\n%s\t%s\t440\t90\t3\n' "$cx" "$cy" > "$transformed.transform.tsv"
      timeout 6 ffmpeg -nostdin -y -loglevel error -i "$base.png" \
        -vf "crop=440:90:$cx:$cy,scale=iw*3:ih*3:flags=lanczos,format=gray,lut=y='if(gt(val,250),0,255)'" -frames:v 1 "$transformed.png"
      timeout 6 tesseract "$transformed.png" "$transformed" --psm 7 -c tessedit_do_invert=0 tsv txt >/dev/null 2>&1
      awk -F '\t' -v OFS='\t' -v x="$cx" -v y="$cy" 'NR==1{print;next} NF>=12{$7=$7/3+x;$8=$8/3+y;$9=$9/3;$10=$10/3;print}' \
        "$transformed.tsv" > "$transformed.screen.tsv"
      control_tsv="$transformed.screen.tsv"
    }
    stop_video() {
      [[ -n "$video_pid" ]] || return 0
      kill -INT "$video_pid" 2>/dev/null || true
      # Only the recorder may be stopped; LocalSend and partial data persist.
      for ((n=0; n<100; n++)); do
        [[ -r "/proc/$video_pid/stat" ]] || break
        [[ $(awk '{print $3}' "/proc/$video_pid/stat") != Z ]] || break
        sleep 0.1
      done
      if [[ -r "/proc/$video_pid/stat" && $(awk '{print $3}' "/proc/$video_pid/stat") != Z ]]; then event recorder_stop_incomplete; return 1; fi
      local rc=0; wait "$video_pid" || rc=$?; video_pid=''
      ffprobe -v error -show_entries format=duration,size -of json "$out/continuous.mp4" > "$out/video-probe.json"
      printf 'recorder-closed\t%s\texit=%s\n' "$(stamp)" "$rc" > "$out/recording-closed.tsv"
    }
    trap stop_video EXIT
    ffmpeg -nostdin -y -loglevel warning -f x11grab -framerate 15 -video_size 1280x900 -i "$DISPLAY" -c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p "$out/continuous.mp4" > "$out/recording.log" 2>&1 & video_pid=$!
    sleep 0.5; kill -0 "$video_pid"
    printf 'armed\t%s\n' "$(stamp)" > "$out/armed.tsv"
    deadline=$((SECONDS+90)); accepted=0
    while (( SECONDS < deadline )); do
      snapshot approval
      if ! coords Accept >/dev/null || ! coords Decline >/dev/null; then approval_ocr; fi
      if ! coords Accept >/dev/null || ! coords Decline >/dev/null; then approval_crop; fi
      if coords Accept >/dev/null && coords Decline >/dev/null; then
        click_word Accept; accepted=1
        printf 'accepted\t%s\treal-ui-manual-save\n' "$(stamp)" > "$out/accepted.tsv"; break
      fi
      sleep 0.2
    done
    [[ "$accepted" == 1 ]] || { event approval_not_observed; exit 1; }
    if [[ "$case_id" == control ]]; then
      deadline=$((SECONDS+120)); finished=0; hash_match=0
      while (( SECONDS < deadline )); do
        snapshot transfer
        if grep -Eiq '\bFinished\b' "$base.txt" && ! grep -Eiq '\b(error|failed)\b' "$base.txt"; then finished=1; fi
        if [[ -f "$DEST/$filename" && $(stat -c %s "$DEST/$filename") == "$expected_bytes" ]]; then
          sha256sum "$DEST/$filename" > "$out/saved.sha256"
          read -r sha _ < "$out/saved.sha256"; [[ "${sha,,}" != "${expected_sha,,}" ]] || hash_match=1
        fi
        if (( finished && hash_match )); then
          cp "$base.png" "$out/ui-finished.png"; cp "$base.txt" "$out/ui-finished.txt"
          # Done returns the real receiver to home for the large request.
          if ! coords Done >/dev/null; then approval_ocr; fi
          click_word Done; sleep 0.5; snapshot home
          grep -q WSL1461 "$base.txt"; grep -q Receive "$base.txt"
          stop_video
          printf 'status=finished_and_hash_verified\nfinished=1\nhash_match=1\napp_pid=%s\n' "$APP_PID" > "$out/result.env"
          printf 'complete\t%s\n' "$(stamp)" > "$out/complete.tsv"; exit 0
        fi
        sleep 0.2
      done
      event control_not_finished_and_verified; exit 1
    fi
    # Poll size quickly; hashing/screenshotting the large growing file would
    # consume the small window before the host can observe its source handle.
    deadline=$((SECONDS+1800)); observed=0; last_frame=$SECONDS
    while (( SECONDS < deadline )); do
      identity
      if (( ! observed )) && partial; then observed=1; event partial_observed; fi
      if [[ -s "$out/native-terminal.tsv" ]]; then
        snapshot native-terminal; stop_video
        printf 'status=host_native_terminal_observed\npartial_observed=%s\napp_pid=%s\n' "$observed" "$APP_PID" > "$out/result.env"
        printf 'complete\t%s\n' "$(stamp)" > "$out/complete.tsv"; exit 0
      fi
      if [[ -f "$DEST/$filename" ]] && (( $(stat -c %s "$DEST/$filename") >= expected_bytes )) && [[ ! -s "$out/down.tsv" ]]; then
        printf 'rejected-eof-before-interruption\t%s\n' "$(stamp)" > "$out/rejected-eof.tsv"
        event rejected_eof_before_interruption; exit 1
      fi
      if (( SECONDS-last_frame >= 15 )); then snapshot ongoing; last_frame=$SECONDS; fi
      sleep 0.05
    done
    event observation_deadline_no_native_terminal
    printf 'status=observation_deadline_no_native_terminal\npartial_observed=%s\n' "$observed" > "$out/result.env"
    exit 1
    ;;
  *) echo "Unknown action: $action" >&2; exit 2 ;;
esac
