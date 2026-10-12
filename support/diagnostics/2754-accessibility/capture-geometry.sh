#!/usr/bin/env bash
# Cloud Mint session only. Run after opening the real Text dialog.
set -euo pipefail
# This script compiles and queries an app; reject execution outside the staged
# Mint guest even if somebody accidentally invokes it from a local checkout.
[[ ${PROBE_CLOUD_GEOMETRY:-0} == 1 ]] || { printf "Cloud UI integration authorization flag missing\n" >&2; exit 8; }
[[ $(uname -s) == Linux && $(id -un) == mint && -d /home/mint && -d /proc ]] || { printf "Requires the Mint cloud guest user and filesystem\n" >&2; exit 8; }
[[ -r /etc/os-release ]] || exit 8
. /etc/os-release
[[ ${ID:-} == linuxmint ]] || { printf "Requires Linux Mint cloud guest\n" >&2; exit 8; }
[[ -f /home/mint/evidence/bootstrap-complete ]] || { printf "Cloud Mint bootstrap marker missing\n" >&2; exit 8; }
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ $here == /home/mint/support/diagnostics/2754-accessibility ]] || { printf "Requires the fixture staged in /home/mint\n" >&2; exit 8; }
pid=${1:?PID required}
label=${2:?label required}
out=${3:?output directory required}
[[ $pid =~ ^[1-9][0-9]*$ ]] || exit 2
mkdir -p "$out"
# Even setup failures have an explicit global result; raw files remain beside it.
printf '{"probe_status":"incomplete","reason":"capture did not finish"}\n' > "$out/geometry-comparison.json"
version=$(pkg-config --modversion atspi-2)
[[ $version == 2.52.* ]] || { printf "Expected libatspi 2.52.x, found %s\n" "$version" >&2; exit 3; }
printf "%s\n" "$version" > "$out/libatspi-version.txt"
dpkg-query -W libatspi2.0-0 libatspi2.0-dev libglib2.0-0 libglib2.0-dev libx11-6 libx11-dev > "$out/package-versions.txt" 2>&1 || true
pkg-config --modversion x11 > "$out/x11-version.txt"
pkg-config --cflags --libs x11 > "$out/x11-build-flags.txt"
cc -std=c11 -Wall -Wextra -O0 -g "$here/x11-window.c" -o "$out/x11-window" $(pkg-config --cflags --libs x11) 2> "$out/x11-build.log"
pkg-config --cflags --libs atspi-2 glib-2.0 gobject-2.0 > "$out/build-flags.txt"
# Intentional word splitting for the pkg-config compiler flags.
cc -std=c11 -Wall -Wextra -O0 -g "$here/geometry-client.c" -o "$out/geometry-client" $(pkg-config --cflags --libs atspi-2 glib-2.0 gobject-2.0) 2> "$out/build.log"
sha256sum "$here/geometry-client.c" "$out/geometry-client" "$here/x11-window.c" "$out/x11-window" > "$out/fixture-sha256.txt"
if [[ -n ${4:-} ]]; then
  window=$4
else
  xdotool search --onlyvisible --pid "$pid" > "$out/window-candidates.txt" || true
  mapfile -t candidates < "$out/window-candidates.txt"
  [[ ${#candidates[@]} == 1 ]] || { printf "Ambiguous window; supply actual Text dialog window ID explicitly\n" >&2; exit 6; }
  window=${candidates[0]}
fi
[[ $window =~ ^[0-9]+$ ]] || exit 2
xdotool getwindowpid "$window" > "$out/window-pid.txt"
[[ $(cat "$out/window-pid.txt") == "$pid" ]] || { printf "Window PID mismatch\n" >&2; exit 7; }
printf "%s\n" "$window" > "$out/window-id.txt"
xdotool getwindowname "$window" > "$out/window-name.txt"
host_geometry() {
  local phase=$1 rc=0
  timeout --kill-after=2s 10s "$out/x11-window" "$window" > "$out/x11-$phase.raw.json" 2> "$out/x11-$phase.stderr" || rc=$?
  # Never discard malformed/partial raw output or treat an observer failure as 0.
  if [[ $rc == 0 ]] && jq -e . "$out/x11-$phase.raw.json" > /dev/null 2> "$out/x11-$phase.parse.stderr"; then
    cp "$out/x11-$phase.raw.json" "$out/x11-$phase.json"
  else
    printf 'null\n' > "$out/x11-$phase.json"
    [[ $rc != 0 ]] || rc=9
  fi
  printf '{"status":%d}\n' "$rc" > "$out/x11-$phase.status.json"
  xdotool getwindowgeometry --shell "$window" > "$out/host-$phase.env"
  # Parse the observed output without executing it.
  awk -F= '$1=="X"{x=$2} $1=="Y"{y=$2} $1=="WIDTH"{w=$2} $1=="HEIGHT"{h=$2} END {if(x==""||y==""||w==""||h=="")exit 1; printf "{\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}\n",x,y,w,h}' "$out/host-$phase.env" > "$out/host-$phase.json"
}
evidence_watcher_pid=
evidence_watcher_start=
evidence_watcher_exe=
evidence_watcher_out=
geometry_launcher_pid=
geometry_launcher_start=
geometry_launcher_exe=
geometry_launcher_out=
pending_background_role=
pending_previous_child=
pending_jsonl=
pending_geometry_label=
proc_starttime() {
  local process=$1 stat_line
  local -a stat_fields
  [[ -r /proc/$process/stat ]] || return 1
  stat_line=$(cat "/proc/$process/stat") || return 1
  # comm can contain spaces and parentheses; fields after its final ')' start
  # with state (field 3), making starttime (field 22) array index 19.
  read -r -a stat_fields <<< "${stat_line##*) }"
  [[ ${stat_fields[19]:-} =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${stat_fields[19]}"
}
owned_timeout_matches() {
  local process=$1 expected_start=$2 expected_exe=$3 stat_line
  local -a stat_fields
  [[ -n $expected_start && -n $expected_exe ]] || return 1
  stat_line=$(cat "/proc/$process/stat" 2>/dev/null) || return 1
  read -r -a stat_fields <<< "${stat_line##*) }"
  [[ ${stat_fields[19]:-} == "$expected_start" && ${stat_fields[2]:-} == "$process" ]] || return 1
  [[ $(readlink "/proc/$process/exe" 2>/dev/null || true) == "$expected_exe" ]] || return 1
  # Re-read identity after the executable lookup, immediately before the
  # caller signals the owned group. Never signal on an absent/reused PID.
  stat_line=$(cat "/proc/$process/stat" 2>/dev/null) || return 1
  read -r -a stat_fields <<< "${stat_line##*) }"
  [[ ${stat_fields[19]:-} == "$expected_start" && ${stat_fields[2]:-} == "$process" ]]
}
recover_pending_launch() {
  local latest=$1 attempt recovered_start recovered_exe stat_line retained_pid retained_start matched=false
  local -a stat_fields launch_args
  [[ -n $pending_background_role && $latest =~ ^[1-9][0-9]*$ && $latest != "$pending_previous_child" ]] || return 0
  if [[ $pending_background_role == watcher ]]; then
    retained_pid=$evidence_watcher_pid; retained_start=$evidence_watcher_start
  else
    retained_pid=$geometry_launcher_pid; retained_start=$geometry_launcher_start
  fi
  [[ -z $retained_pid || $retained_pid == "$latest" ]] || return 0
  # Preserve a previously observed identity. Recovery only supplies a tuple
  # missing because EXIT interrupted the assignment immediately after '&'.
  recovered_exe=$(readlink -f "$(command -v timeout)") || return 0
  for ((attempt=0; attempt<20; attempt++)); do
    recovered_start=$(proc_starttime "$latest") || break
    [[ -z $retained_start || $recovered_start == "$retained_start" ]] || break
    stat_line=$(cat "/proc/$latest/stat" 2>/dev/null) || break
    read -r -a stat_fields <<< "${stat_line##*) }"
    launch_args=()
    matched=false
    mapfile -d '' -t launch_args < "/proc/$latest/cmdline" || break
    if [[ $pending_background_role == watcher ]]; then
      [[ ${launch_args[1]:-} == --kill-after=16s && ${launch_args[2]:-} == 70s &&
         ${launch_args[3]:-} == bash && ${launch_args[4]:-} == "$here/capture-root-name-evidence.sh" &&
         ${launch_args[5]:-} == "$pid" && ${launch_args[6]:-} == "$out/geometry-client" &&
         ${launch_args[7]:-} == "$pending_jsonl" && ${launch_args[8]:-} == "$evidence_watcher_out" ]] && matched=true
    elif (( ${#launch_args[@]} >= 3 )); then
      [[ ${launch_args[1]:-} == --kill-after=5s && ${launch_args[2]:-} == 180s &&
         ${launch_args[3]:-} == "$(readlink -f "$(command -v strace)")" &&
         ${launch_args[4]:-} == -DD && ${launch_args[5]:-} == -I2 &&
         ${launch_args[-3]:-} == "$out/geometry-client" && ${launch_args[-2]:-} == "$pid" &&
         ${launch_args[-1]:-} == "$pending_geometry_label" ]] && matched=true
    fi
    if [[ $matched == true && ${stat_fields[1]:-} == "$$" &&
          $(awk '/^Uid:/ {print $2}' "/proc/$latest/status" 2>/dev/null) == "$(id -u)" ]] &&
       owned_timeout_matches "$latest" "$recovered_start" "$recovered_exe"; then
      if [[ $pending_background_role == watcher ]]; then
        evidence_watcher_pid=$latest; evidence_watcher_start=${retained_start:-$recovered_start}; evidence_watcher_exe=$recovered_exe
      else
        geometry_launcher_pid=$latest; geometry_launcher_start=${retained_start:-$recovered_start}
        geometry_launcher_exe=$recovered_exe; geometry_launcher_out=$evidence_watcher_out
      fi
      return 0
    fi
    sleep 0.05
  done
  printf '{"status":"partial","reason":"pending background launcher identity unverified"}\n' > "$evidence_watcher_out/launch-recovery.json"
}
stop_evidence_watcher() {
  local watcher_rc=0 attempt current_start
  [[ -n $evidence_watcher_pid ]] || return 0
  # Publish ownership even if cancellation interrupted normal handoff after
  # launch. The independent watcher must own the daemon before it exits.
  if [[ -n $geometry_launcher_pid && ! -f $evidence_watcher_out/launcher.tsv ]]; then
    if [[ -n $geometry_launcher_start ]]; then
      # A previously retained starttime is immutable even if the PID exited.
      printf '%s\t%s\n' "$geometry_launcher_pid" "$geometry_launcher_start" > "$evidence_watcher_out/launcher.tmp"
      mv "$evidence_watcher_out/launcher.tmp" "$evidence_watcher_out/launcher.tsv"
    fi
  fi
  current_start=$(proc_starttime "$evidence_watcher_pid") || current_start=
  if owned_timeout_matches "$evidence_watcher_pid" "$evidence_watcher_start" "$evidence_watcher_exe"; then
    # GNU timeout forwards TERM to its helper process group. The helper owns
    # cleanup of its separately bounded observer subprocess groups.
    kill -TERM "$evidence_watcher_pid" 2>> "$evidence_watcher_out/cleanup.stderr" || true
    # Allow the helper's aggregate TERM/KILL/reap cleanup to finish before
    # stopping its group. This shutdown grace never extends the client query.
    for ((attempt=0; attempt<160; attempt++)); do
      current_start=$(proc_starttime "$evidence_watcher_pid") || current_start=
      [[ $current_start == "$evidence_watcher_start" ]] || break
      sleep 0.1
    done
    if owned_timeout_matches "$evidence_watcher_pid" "$evidence_watcher_start" "$evidence_watcher_exe"; then
      # Never signal an unrelated process group. timeout is the group leader
      # without --foreground; check that fact before the final bounded stop.
      kill -KILL -- "-$evidence_watcher_pid" 2>> "$evidence_watcher_out/cleanup.stderr" || true
    fi
  fi
  wait "$evidence_watcher_pid" || watcher_rc=$?
  printf '{"status":%d}\n' "$watcher_rc" > "$evidence_watcher_out/watcher-exit.json"
  evidence_watcher_pid=
  evidence_watcher_start=
  evidence_watcher_exe=
}
stop_geometry_launcher() {
  local attempt current_start stat_line launcher_rc=0
  local -a stat_fields
  [[ -n $geometry_launcher_pid ]] || return 0
  current_start=$(proc_starttime "$geometry_launcher_pid") || current_start=
  if [[ -n $geometry_launcher_start && $current_start == "$geometry_launcher_start" &&
        $(readlink "/proc/$geometry_launcher_pid/exe" 2>/dev/null || true) == "$geometry_launcher_exe" ]]; then
    stat_line=$(cat "/proc/$geometry_launcher_pid/stat") || stat_line=
    read -r -a stat_fields <<< "${stat_line##*) }"
    if owned_timeout_matches "$geometry_launcher_pid" "$geometry_launcher_start" "$geometry_launcher_exe"; then
      kill -TERM -- "-$geometry_launcher_pid" 2>> "$geometry_launcher_out/launcher-cleanup.stderr" || true
      for ((attempt=0; attempt<20; attempt++)); do
        current_start=$(proc_starttime "$geometry_launcher_pid") || current_start=
        [[ $current_start == "$geometry_launcher_start" ]] || break
        sleep 0.1
      done
      if [[ $current_start == "$geometry_launcher_start" &&
            $(readlink "/proc/$geometry_launcher_pid/exe" 2>/dev/null || true) == "$geometry_launcher_exe" ]]; then
        stat_line=$(cat "/proc/$geometry_launcher_pid/stat") || stat_line=
        read -r -a stat_fields <<< "${stat_line##*) }"
        if owned_timeout_matches "$geometry_launcher_pid" "$geometry_launcher_start" "$geometry_launcher_exe"; then
          kill -KILL -- "-$geometry_launcher_pid" 2>> "$geometry_launcher_out/launcher-cleanup.stderr" || true
        fi
      fi
      wait "$geometry_launcher_pid" || launcher_rc=$?
      printf '{"status":%d}\n' "$launcher_rc" > "$geometry_launcher_out/launcher-cleanup-exit.json"
    else
      printf '{"status":"identity_not_verified","reason":"launcher process group mismatch"}\n' > "$geometry_launcher_out/launcher-cleanup-exit.json"
    fi
  else
    printf '{"status":"identity_not_verified","reason":"launcher starttime or executable mismatch"}\n' > "$geometry_launcher_out/launcher-cleanup-exit.json"
  fi
  geometry_launcher_pid=
}
probe() {
  local phase=$1 rc=0
  # Preserve partial JSONL on deadline. A separate process may still hang despite
  # the public per-call timeout, so the entire session is externally bounded.
  if [[ ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 ]]; then
    local wrapper_pid wrapper_start attempt launch_time
    [[ -z $evidence_watcher_pid && -z $geometry_launcher_pid ]] || return 3
    evidence_watcher_pid= evidence_watcher_start= evidence_watcher_exe=
    evidence_watcher_out="$out/root-name-evidence-$phase"
    mkdir -p "$evidence_watcher_out"
    [[ ! -e $evidence_watcher_out/watcher-ready && ! -e $evidence_watcher_out/launcher.tsv &&
       ! -e $evidence_watcher_out/result.json ]] || return 3
    # Independent owner is ready before client birth. Its group is distinct
    # from GNU timeout's client group; its outer bound covers capture, detach,
    # and the parallel 12s + 2s debugger snapshots.
    pending_previous_child=${!:-}
    pending_jsonl="$out/$phase.jsonl"
    pending_background_role=watcher
    timeout --kill-after=16s 70s bash "$here/capture-root-name-evidence.sh" "$pid" "$out/geometry-client" "$out/$phase.jsonl" "$evidence_watcher_out" \
      > "$evidence_watcher_out/watcher.stdout" 2> "$evidence_watcher_out/watcher.stderr" &
    evidence_watcher_pid=$!
    evidence_watcher_start=$(proc_starttime "$evidence_watcher_pid") || evidence_watcher_start=
    evidence_watcher_exe=$(readlink -f "$(command -v timeout)") || evidence_watcher_exe=
    pending_background_role=
    for ((attempt=0; attempt<40; attempt++)); do
      [[ -f $evidence_watcher_out/watcher-ready ]] && break
      [[ $(proc_starttime "$evidence_watcher_pid" 2>/dev/null || true) == "$evidence_watcher_start" ]] || break
      sleep 0.05
    done
    [[ -f $evidence_watcher_out/watcher-ready ]] || { stop_evidence_watcher; return 3; }
    read -r launch_time _ < /proc/uptime
    printf '%s\n' "$launch_time" > "$evidence_watcher_out/launch-monotonic.tmp"
    mv "$evidence_watcher_out/launch-monotonic.tmp" "$evidence_watcher_out/launch-monotonic"
    geometry_launcher_pid= geometry_launcher_start= geometry_launcher_exe= geometry_launcher_out=$evidence_watcher_out
    pending_previous_child=${!:-}
    pending_geometry_label="$label-$phase"
    pending_background_role=geometry
    timeout --kill-after=5s 180s "$(readlink -f "$(command -v strace)")" -DD -I2 -f -ttt -T -yy -xx -s1048576 \
      -o "$evidence_watcher_out/transport.strace" \
      -e trace=socket,socketpair,connect,accept,accept4,bind,listen,getsockname,getpeername,sendto,sendmsg,sendmmsg,recvfrom,recvmsg,recvmmsg,read,readv,write,writev,splice,tee,vmsplice,sendfile,copy_file_range,io_uring_setup,io_uring_register,io_uring_enter,pidfd_getfd,unshare,dup,dup2,dup3,fcntl,close,close_range,shutdown,poll,ppoll,select,pselect6,futex,clone,clone3,fork,vfork,execve,execveat,exit,exit_group \
      "$out/geometry-client" "$pid" "$label-$phase" > "$out/$phase.jsonl" 2> "$out/$phase.stderr" &
    geometry_launcher_pid=$!
    wrapper_pid=$geometry_launcher_pid
    wrapper_start=$(proc_starttime "$wrapper_pid") || wrapper_start=
    geometry_launcher_start=$wrapper_start
    geometry_launcher_exe=$(readlink -f "$(command -v timeout)") || geometry_launcher_exe=
    geometry_launcher_out=$evidence_watcher_out
    pending_background_role=
    printf '%s\t%s\n' "$wrapper_pid" "$wrapper_start" > "$evidence_watcher_out/launcher.tmp"
    mv "$evidence_watcher_out/launcher.tmp" "$evidence_watcher_out/launcher.tsv"
    wait "$wrapper_pid" || rc=$?
    geometry_launcher_pid= geometry_launcher_start= geometry_launcher_exe= geometry_launcher_out=
    stop_evidence_watcher
  else
    timeout --kill-after=5s 180s "$out/geometry-client" "$pid" "$label-$phase" > "$out/$phase.jsonl" 2> "$out/$phase.stderr" || rc=$?
  fi
  printf "{\"kind\":\"process_exit\",\"phase\":\"%s\",\"status\":%d,\"deadline_hit\":%s}\n" "$phase" "$rc" "$([[ $rc == 124 || $rc == 137 ]] && printf true || printf false)" >> "$out/$phase.jsonl"
}
host_geometry before
x=$(jq -r .x "$out/host-before.json")
y=$(jq -r .y "$out/host-before.json")
restore_on_exit() {
  local rc=$? latest_child=${!:-} restore_rc=0
  trap - EXIT
  recover_pending_launch "$latest_child"
  stop_evidence_watcher
  stop_geometry_launcher
  timeout --kill-after=2s 15s xdotool windowmove --sync "$window" "$x" "$y" > "$out/restore.stdout" 2> "$out/restore.stderr" || restore_rc=$?
  printf '{"status":%d}\n' "$restore_rc" > "$out/restore-status.json"
  host_geometry restored || true
  exit "$rc"
}
trap restore_on_exit EXIT
if [[ ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 ]]; then
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi
probe before
host_geometry before-end
# Request an actual move, retain requested and observed values independently.
jq -n --argjson x "$((x+80))" --argjson y "$((y+60))" '{x:$x,y:$y}' > "$out/move-request.json"
move_rc=0
timeout --kill-after=2s 15s xdotool windowmove --sync "$window" "$((x+80))" "$((y+60))" > "$out/move.stdout" 2> "$out/move.stderr" || move_rc=$?
printf '{"status":%d}\n' "$move_rc" > "$out/move-status.json"
host_geometry after
probe after
host_geometry after-end
jq -s --argjson pid "$pid" --slurpfile hb "$out/host-before.json" --slurpfile ha "$out/host-after.json" \
  --slurpfile xb "$out/x11-before.json" --slurpfile xa "$out/x11-after.json" \
  --slurpfile xbs "$out/x11-before.status.json" --slurpfile xas "$out/x11-after.status.json" \
  --slurpfile xbe "$out/x11-before-end.json" --slurpfile xae "$out/x11-after-end.json" \
  --slurpfile xbes "$out/x11-before-end.status.json" --slurpfile xaes "$out/x11-after-end.status.json" \
  --slurpfile move "$out/move-status.json" -f "$here/validate-geometry.jq" "$out/before.jsonl" "$out/after.jsonl" \
  > "$out/geometry-comparison.tmp.json" 2> "$out/validation.stderr"
mv "$out/geometry-comparison.tmp.json" "$out/geometry-comparison.json"
jq -e '.probe_status == "pass"' "$out/geometry-comparison.json" > /dev/null || exit 9
# EXIT trap restores position even if validation fails on partial JSONL.
