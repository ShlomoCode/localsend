#!/usr/bin/env bash
# Passive original-process receipts. No app launch, signal or session repair.
set -Eeuo pipefail
evidence=${1:?evidence}; action=${2:?action}; label=${3:?label}
[[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]]
base="$evidence/receiver/lifetime"; mkdir -p "$base"
capture() {
  local path=$1 result=0; shift
  "$@" > "$path" 2> "$path.stderr" || result=$?
  printf '%s\n' "$result" > "$path.exit" || true
  return 0
}
case "$action" in
  trace-attach)
    [[ $(id -u) == 0 ]]
    trace="$base/trace"; mkdir "$trace"
    strace_exe=$(readlink -f "$(command -v strace)")
    strace --version > "$trace/version.txt"
    grep -Fxq 'strace -- version 6.8' "$trace/version.txt"
    printf '%s\n' "$strace_exe" > "$trace/executable.txt"
    capture "$trace/enumeration-before.utc" date -u --iso-8601=ns
    capture "$trace/enumeration-before.uptime" cat /proc/uptime
    printf 'role\ttgid\ttid\tstart_tick\texecutable\n' > "$trace/tids.tsv"
    count=0
    for name in app wm xvfb; do
      read -r pid tick executable < "$base/$name.ref"
      raw=$(cat "/proc/$pid/stat"); fields=${raw##*) }; read -r -a parts <<< "$fields"
      [[ ${parts[19]} == "$tick" && $(readlink -f "/proc/$pid/exe") == "$executable" ]]
      for task in /proc/"$pid"/task/[0-9]*; do
        tid=${task##*/}; [[ "$tid" =~ ^[1-9][0-9]*$ ]]
        raw=$(cat "$task/stat"); fields=${raw##*) }; read -r -a parts <<< "$fields"
        [[ $(readlink -f "$task/exe") == "$executable" ]]
        ((count+=1)); ((count <= 128))
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$pid" "$tid" "${parts[19]}" "$executable" >> "$trace/tids.tsv"
      done
    done
    # A separate observer process group is the only timeout target. No -f,
    # injection, kill-on-exit, app launch under strace, or traced descendants.
    nohup setsid timeout --signal=INT --kill-after=1s 20s bash "$0" "$evidence" trace-supervise original > "$trace/supervisor.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$trace/timeout-launch.pid"
    attached=no
    for ((attempt=0; attempt<60; attempt++)); do
      tracer=''; complete=yes
      while IFS=$'\t' read -r name pid tid tick executable; do
        [[ "$name" != role ]] || continue
        if [[ ! -r "/proc/$pid/task/$tid/status" ]]; then complete=no; break; fi
        current=$(awk '$1=="TracerPid:"{print $2}' "/proc/$pid/task/$tid/status")
        if [[ ! "$current" =~ ^[1-9][0-9]*$ ]]; then complete=no; break; fi
        if [[ -z "$tracer" ]]; then tracer=$current; elif [[ "$tracer" != "$current" ]]; then complete=no; break; fi
        raw=$(cat "/proc/$pid/task/$tid/stat"); fields=${raw##*) }; read -r -a parts <<< "$fields"
        [[ ${parts[19]} == "$tick" && $(readlink -f "/proc/$pid/task/$tid/exe") == "$executable" ]] || { complete=no; break; }
      done < "$trace/tids.tsv"
      if [[ "$complete" == yes && -n "$tracer" && $(readlink -f "/proc/$tracer/exe") == "$strace_exe" ]]; then
        bash "$0" "$evidence" register tracer "$tracer" "$strace_exe"
        capture "$trace/attached-tracer.cmdline" cat "/proc/$tracer/cmdline"
        capture "$trace/attached.utc" date -u --iso-8601=ns
        capture "$trace/attached.uptime" cat /proc/uptime
        bash "$0" "$evidence" trace-state attached
        printf 'attached\ttracer=%s\toriginal_tids=%s\n' "$tracer" "$count" > "$trace/attached.tsv"
        attached=yes; break
      fi
      [[ ! -s "$trace/completed.tsv" ]] || break
      sleep 0.05
    done
    if [[ "$attached" != yes ]]; then
      capture "$trace/attachment-failed.utc" date -u --iso-8601=ns
      bash "$0" "$evidence" trace-state attachment-failed || true
      printf 'attachment-failed; no rebind, retry, or preparation normal return\n' > "$trace/attachment-failed.txt"
      exit 1
    fi
    ;;
  trace-supervise)
    [[ $(id -u) == 0 ]]
    trace="$base/trace"; read -r strace_exe < "$trace/executable.txt"
    bash "$0" "$evidence" register trace_observer "$$"
    bash "$0" "$evidence" register trace_timeout "$PPID"
    args=(-I 2 -ttt -r -e trace=none -e signal=all -o "$trace/events.txt")
    while IFS=$'\t' read -r name pid tid tick executable; do
      [[ "$name" != role ]] || continue
      args+=(-p "$tid")
    done < "$trace/tids.tsv"
    printf '%q ' "$strace_exe" "${args[@]}" > "$trace/command.txt"; printf '\n' >> "$trace/command.txt"
    capture "$trace/start.utc" date -u --iso-8601=ns
    capture "$trace/start.uptime" cat /proc/uptime
    # timeout owns this shell AND strace. INT requests strace detach; the
    # shell's trap attempts an interrupt marker (inherited async dispositions
    # can prevent it); absent marker does not exclude deadline/signal delivery.
    # KILL after1s can preclude a
    # completion receipt, which remains an explicit infrastructure outcome.
    interrupted=no
    trap 'interrupted=yes; printf "observer-deadline-INT\\n" > "$trace/deadline.txt"' INT
    "$strace_exe" "${args[@]}" > "$trace/strace.stdout" 2> "$trace/strace.stderr" &
    tracer_child=$!
    result=0; wait "$tracer_child" || result=$?
    if [[ "$interrupted" == yes ]]; then result=0; wait "$tracer_child" || result=$?; fi
    printf '%s\n' "$result" > "$trace/strace.exit"
    capture "$trace/observer-return.utc" date -u --iso-8601=ns
    capture "$trace/observer-return.uptime" cat /proc/uptime
    printf 'completed\tobserved_shell_interrupt=%s\tstrace_exit=%s\n' "$interrupted" "$result" > "$trace/completed.tsv"
    ;;
  trace-state)
    export LC_ALL=C
    trace="$base/trace"; out="$trace/$label"; mkdir "$out"
    capture "$out/observed.utc" date -u --iso-8601=ns
    capture "$out/uptime.txt" cat /proc/uptime
    for name in app wm xvfb; do
      read -r pid tick executable < "$base/$name.ref"
      capture "$out/$name.task-inventory.txt" find "/proc/$pid/task" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
    done
    while IFS=$'\t' read -r name pid tid tick executable; do
      [[ "$name" != role ]] || continue
      capture "$out/$name-$tid.stat" cat "/proc/$pid/task/$tid/stat"
      capture "$out/$name-$tid.status" cat "/proc/$pid/task/$tid/status"
      capture "$out/$name-$tid.exe" readlink -f "/proc/$pid/task/$tid/exe"
      capture "$out/$name-$tid.after.stat" cat "/proc/$pid/task/$tid/stat"
    done < "$trace/tids.tsv"
    ;;
  register)
    pid=${4:?original pid}; [[ "$pid" =~ ^[1-9][0-9]*$ ]]
    ref="$base/$label.ref"
    [[ ! -e "$ref" ]]
    raw=$(cat "/proc/$pid/stat"); fields=${raw##*) }; read -r -a parts <<< "$fields"
    observed_executable=$(readlink -f "/proc/$pid/exe")
    # App/Xvfb callers supply their existing validated canonical executable.
    # Other selected references are forensic observations, not liveness gates.
    executable=${5:-$observed_executable}
    printf '%s\n' "$observed_executable" > "$base/$label.registration-exe.txt"
    printf '%s\n' "$raw" > "$base/$label.registration.stat"
    reference_tick=${6:-${parts[19]}}
    [[ ${parts[19]} == "$reference_tick" && "$observed_executable" == "$executable" ]] || {
      echo "Original $label identity changed before reference binding" >&2; exit 1;
    }
    printf '%s\t%s\t%s\n' "$pid" "$reference_tick" "$executable" > "$ref"
    ;;
  snapshot)
    out="$base/$label"; mkdir "$out"
    capture "$out/observed.utc" date -u --iso-8601=ns
    capture "$out/uptime.txt" cat /proc/uptime
    capture "$out/boot-id.txt" cat /proc/sys/kernel/random/boot_id
    capture "$out/pid1.stat" cat /proc/1/stat
    # Capture required display/socket evidence before the longer passive
    # process inventory, including when app/WM are already absent.
    if [[ -r "$evidence/receiver/session.env" ]]; then
      source "$evidence/receiver/session.env"
      capture "$out/listeners.txt" ss -ltnp
      capture "$out/unix-sockets.txt" ss -lxnp
      capture "$out/x11-directory.txt" stat -c '%n %F uid=%u gid=%g mode=%a device=%d inode=%i' /tmp/.X11-unix "/tmp/.X11-unix/X$DISPLAY_NUMBER"
      if [[ -n ${WINDOW:-} ]]; then
        capture "$out/window-pid.txt" timeout --kill-after=1s 1s env DISPLAY="$DISPLAY" xdotool getwindowpid "$WINDOW"
        capture "$out/visible-windows.txt" timeout --kill-after=1s 1s env DISPLAY="$DISPLAY" xdotool search --onlyvisible --pid "$APP_PID"
      fi
    fi
    for name in prepare supervisor receiver app xvfb wm dbus trace_observer trace_timeout tracer; do
      ref="$base/$name.ref"
      if [[ ! -r "$ref" ]]; then printf 'original reference unavailable\n' > "$out/$name.unavailable"; continue; fi
      read -r pid tick executable < "$ref"
      cp "$ref" "$out/$name.ref" || true
      capture "$out/$name.before.stat" cat "/proc/$pid/stat"
      capture "$out/$name.status" cat "/proc/$pid/status"
      capture "$out/$name.cmdline" cat "/proc/$pid/cmdline"
      capture "$out/$name.exe" readlink -f "/proc/$pid/exe"
      capture "$out/$name.after.stat" cat "/proc/$pid/stat"
      # Raw stat/status are retained even if identity changed during the read.
      state=unavailable; match=no
      if [[ -s "$out/$name.before.stat" && -s "$out/$name.after.stat" ]]; then
        raw=$(cat "$out/$name.before.stat"); fields=${raw##*) }; read -r -a before <<< "$fields"
        raw=$(cat "$out/$name.after.stat"); fields=${raw##*) }; read -r -a after <<< "$fields"
        state=${after[0]}
        if [[ ${before[19]} == "$tick" && ${after[19]} == "$tick" && $(cat "$out/$name.exe") == "$executable" ]]; then match=yes; fi
        printf 'pid\tstart_tick\tstate\tppid\tpgid\tsid\tidentity_matches\n%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$pid" "${after[19]}" "$state" "${after[1]}" "${after[2]}" "${after[3]}" "$match" > "$out/$name.identity.tsv"
      fi
    done
    ;;
  *) echo 'Unknown passive receipt action' >&2; exit 2 ;;
esac
