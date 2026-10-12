#!/usr/bin/env bash
# Evidence observer only; does not alter the public geometry query or deadline.
set -euo pipefail
[[ ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 && $(id -un) == mint && -d /proc &&
   -f /home/mint/evidence/bootstrap-complete ]] || exit 8
source /etc/os-release
[[ ${ID:-} == linuxmint ]] || exit 8
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ $here == /home/mint/support/diagnostics/2754-accessibility ]] || exit 8
app=${1:?Usage: capture-root-name-evidence.sh APP_PID CLIENT_EXE JSONL OUTPUT_DIR [EXPECTED_BUS]}
client_exe=${2:?CLIENT_EXE required}
jsonl=${3:?JSONL required}
out=${4:?OUTPUT_DIR required}
expected_bus=${5:-}
[[ $app =~ ^[1-9][0-9]*$ && $client_exe =~ ^/home/mint/[a-zA-Z0-9_./-]+/geometry-client$ ]] || exit 2
[[ $out =~ ^/home/mint/[a-zA-Z0-9_./-]+$ ]] || exit 2
mkdir -p "$out"
out=$(realpath "$out")
[[ ! -e $out/result.json ]] || exit 2
observers=()
pending_launchers=()
declare -A observer_start observer_exe observer_pgid observer_role observer_direct
status=incomplete
reason='Observer did not finish.'
collection_status=partial
collection_limited=false
collection_limit_reasons=()
client= client_start= birth_pid= birth_start= intermediate= launcher= launcher_start= tracer= call_id=
birth_cleanup_attempted=false
client_exec_verified=false
intermediate_released_by_observer=false
strace_exe=$(readlink -f "$(command -v strace)")
mint_uid=$(id -u)
debug_dir=${PROBE_ROOT_NAME_DEBUG_DIR:-/home/mint/evidence/root-name-symbols}
[[ $debug_dir =~ ^/home/mint/[a-zA-Z0-9_./-]+$ && -r $debug_dir/strace-verified.txt ]] || exit 3
grep -qx 'strace_identity_verified=true' "$debug_dir/strace-verified.txt" || exit 3
now() { date --utc +%Y-%m-%dT%H:%M:%S.%NZ; }
monotonic_ms() { local seconds rest; read -r seconds rest < /proc/uptime; awk -v s="$seconds" 'BEGIN {printf "%.0f\n",s*1000}'; }
event() { printf '%s\t%s\n' "$(now)" "$*" >> "$out/timeline.tsv"; }
starttime() { sed -E 's/^.*\) //' "/proc/$1/stat" | awk '{print $20}'; }
proc_exe() { readlink -f "/proc/$1/exe" 2>/dev/null || sudo -n readlink -f "/proc/$1/exe" 2>/dev/null; }
pgid() { sed -E 's/^.*\) //' "/proc/$1/stat" | awk '{print $3}'; }
record_observer() {
  local pid=$1 role=$2 group=$3 direct=$4 exe before after
  [[ -z ${observer_start[$pid]:-} ]] || return 0
  [[ -r /proc/$pid/stat ]] || return 1
  before=$(starttime "$pid") || return 1
  exe=$(proc_exe "$pid") || return 1
  [[ $(pgid "$pid") == "$group" ]] || return 1
  after=$(starttime "$pid") || return 1
  [[ $before == "$after" && -n $before && -n $exe ]] || return 1
  case $role in
    *launcher) [[ $(basename "$exe") == timeout && $pid == "$group" &&
                   $(parent_pid "$pid") == "$$" && $(proc_uid "$pid") == "$mint_uid" ]] || return 1 ;;
    strace) [[ $exe == "$strace_exe" && $pid == "$group" ]] || return 1 ;;
    strace-intermediate) [[ $exe == "$strace_exe" && $group == "$client_group" &&
                            $(parent_pid "$pid") == "$birth_pid" && $(proc_uid "$pid") == "$mint_uid" ]] || return 1 ;;
    gdb-*) [[ $(basename "$exe") == gdb ]] || return 1 ;;
  esac
  observers+=("$pid")
  observer_start[$pid]=$before; observer_exe[$pid]=$exe; observer_pgid[$pid]=$group
  observer_role[$pid]=$role; observer_direct[$pid]=$direct
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$group" "$before" "$exe" "$role" "$direct" >> "$out/observer-identities.tsv"
}
record_launcher() {
  local pid=$1 role=$2 attempt
  for ((attempt=0; attempt<20; attempt++)); do
    record_observer "$pid" "$role-launcher" "$pid" true && return 0
    [[ -e /proc/$pid/stat ]] || break
    sleep 0.05
  done
  event "observer_launcher_identity_unavailable; pid=$pid role=$role"
  return 1
}
observer_alive() {
  local pid=$1 current exe after
  [[ -r /proc/$pid/stat && -n ${observer_start[$pid]:-} ]] || return 1
  current=$(sed -E 's/^.*\) //' "/proc/$pid/stat") || return 1
  [[ $(awk '{print $1}' <<< "$current") != Z && $(awk '{print $20}' <<< "$current") == "${observer_start[$pid]}" &&
     $(awk '{print $3}' <<< "$current") == "${observer_pgid[$pid]}" ]] || return 1
  exe=$(proc_exe "$pid") || return 1
  after=$(sed -E 's/^.*\) //' "/proc/$pid/stat") || return 1
  [[ $exe == "${observer_exe[$pid]}" && $(awk '{print $1}' <<< "$after") != Z &&
     $(awk '{print $20}' <<< "$after") == "${observer_start[$pid]}" &&
     $(awk '{print $3}' <<< "$after") == "${observer_pgid[$pid]}" &&
     ( ${observer_role[$pid]} != strace-intermediate || $(awk '{print $2}' <<< "$after") == "$birth_pid" ) ]]
}
observer_terminated() {
  local pid=$1 current
  [[ -r /proc/$pid/stat ]] || return 0
  current=$(sed -E 's/^.*\) //' "/proc/$pid/stat") || return 1
  [[ $(awk '{print $20}' <<< "$current") == "${observer_start[$pid]}" && $(awk '{print $1}' <<< "$current") == Z ]]
}
signal_observer() {
  local pid=$1 signal=$2 target=$1 rc=0
  if [[ ${observer_role[$pid]:-} == strace-intermediate ]]; then
    [[ $(proc_uid "$pid" 2>/dev/null) == "$mint_uid" && $(parent_pid "$pid" 2>/dev/null) == "$birth_pid" &&
       $(starttime "$birth_pid" 2>/dev/null) == "$birth_start" ]] || {
      event "cleanup_skip_intermediate_lineage_unverified; pid=$pid signal=$signal"; return 0;
    }
  fi
  if [[ ${observer_role[$pid]:-} == strace ]]; then
    if [[ $signal == TERM && ( $client_exec_verified != true || $intermediate_released_by_observer == true ) ]]; then
      event "cleanup_skip_pre_exec_tracer_TERM; pid=$pid"; return 0
    fi
    # Recheck the owned daemon's isolation immediately before each signal.
    [[ $(proc_uid "$pid" 2>/dev/null) == "$mint_uid" && $pid != "$app_group" && $pid != "$client_group" &&
       $pid != "$launcher" && $pid != "$(pgid "$$")" &&
       $pid != "$(pgid "$app" 2>/dev/null || true)" &&
       ( -z $client || $pid != "$(pgid "$client" 2>/dev/null || true)" ) ]] || {
      event "cleanup_skip_tracer_isolation_unverified; pid=$pid signal=$signal"; return 0;
    }
  fi
  if ! observer_alive "$pid"; then
    event "cleanup_skip_identity_absent_changed_or_exited; pid=$pid signal=$signal"
    return 0
  fi
  # A live, verified session leader owns its observer group. If only the
  # retained tracer remains, signal that verified PID, never a stale PGID.
  if [[ ${observer_role[$pid]} != strace && $pid == "${observer_pgid[$pid]}" ]]; then target=-${observer_pgid[$pid]}; fi
  sudo -n kill "-$signal" -- "$target" 2>> "$out/cleanup.stderr" || rc=$?
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$pid" "$target" "$signal" "$rc" >> "$out/cleanup-signals.tsv"
}
cleanup() {
  local code=$? latest_child=${!:-} pid attempt live rc
  trap - EXIT TERM INT
  # Birth tracer is a daemon, not a shell child. Its cleanup is mandatory on
  # cancellation and client exit as well as the normal capture cutoff.
  if [[ -z $tracer ]]; then
    discovery_deadline=$(( $(monotonic_ms) + 5000 ))
    while (( $(monotonic_ms) < discovery_deadline )); do
      discover_client || true
      discover_tracer && break
      sleep 0.05
    done
  fi
  stop_birth_tracer || { collection_status=partial; collection_limited=true; collection_limit_reasons+=('birth tracer exit unverified;'); }
  # Recover the last direct background child even if a trap interrupted the
  # assignment immediately following launch; validate PPID/exe/UID/PGID.
  [[ $latest_child =~ ^[1-9][0-9]*$ ]] && pending_launchers+=("$latest_child")
  for pid in "${pending_launchers[@]}"; do
    [[ -n ${observer_start[$pid]:-} ]] || record_launcher "$pid" pending-gdb || true
  done
  for pid in "${observers[@]}"; do
    [[ ${observer_role[$pid]} == strace* ]] || signal_observer "$pid" TERM
  done
  # Stop our observer tools only. Never signal the observed app or client.
  sleep 0.2
  for pid in "${observers[@]}"; do
    [[ ${observer_role[$pid]} == strace* ]] || signal_observer "$pid" KILL
  done
  # Bound exit verification before waiting. Reap only our direct children;
  # debugger/tracer grandchildren have exit verification retained separately.
  for ((attempt=0; attempt<10; attempt++)); do
    live=0
    for pid in "${observers[@]}"; do observer_alive "$pid" && live=1; done
    [[ $live == 1 ]] || break
    sleep 0.05
  done
  for pid in "${observers[@]}"; do
    if ! observer_terminated "$pid"; then
      event "cleanup_exit_unverified; pid=$pid"; collection_status=partial
      collection_limited=true
      collection_limit_reasons+=("observer $pid exit unverified;")
    elif [[ ${observer_direct[$pid]} == true ]]; then
      rc=0; wait "$pid" 2>> "$out/cleanup.stderr" || rc=$?
      printf '%s\t%s\t%s\n' "$(now)" "$pid" "$rc" >> "$out/cleanup-waits.tsv"
    else
      event "cleanup_grandchild_not_alive; pid=$pid; not_a_direct_child"
    fi
  done
  # Decode also when Name returned early or the cutoff skipped GDB. Only a
  # proven exited tracer permits reading its completed raw output here.
  if [[ $code != 130 && $code != 143 && -n $tracer && -s $out/transport.strace && ! -e $out/decoder.exit-status ]] && observer_terminated "$tracer"; then
    rc=0
    timeout --kill-after=2s 6s python3 "$here/decode-root-name-transport.py" "$out/transport.strace" --output "$out/transport-decoded.json" \
      > "$out/decoder.stdout" 2> "$out/decoder.stderr" || rc=$?
    printf '%s\n' "$rc" > "$out/decoder.exit-status"
    if [[ $rc != 0 ]]; then
      collection_status=partial; collection_limited=true; collection_limit_reasons+=('offline decoder incomplete;')
    fi
  fi
  jq -n --arg status "$status" --arg reason "$reason" --arg at "$(now)" \
    --arg collection_status "$collection_status" --argjson observer_exit "$code" \
    --argjson collection_limited "$collection_limited" \
    --arg collection_limit_reasons "${collection_limit_reasons[*]}" \
    '{status:$status,collection_status:$collection_status,reason:$reason,at:$at,observer_exit:$observer_exit,
      collection_limited:$collection_limited,collection_limit_reasons:$collection_limit_reasons,
      birth_trace_requested:true,pre_attach_traffic_observed:"unknown",tracing_perturbs_scheduling:true,debugger_timing_is_latency_evidence:false,
      linkage:{status:"unknown",name_properties_request:"unknown",matched_reply_serial:"unknown",
        connection_and_fd:"unknown",causal_success:false,
        required_review:"Match root Properties.Get(Accessible,Name), request serial, reply_serial, and actual connection/fd; inspect truncation and unavailable locals."},
      transport:{post_attach_only:false,string_limit_bytes:1048576,complete_stream:false,
        limitation:"Birth trace is bounded and perturbed; gaps, split/coalesced messages or truncation require offline review. Absence does not prove no reply."}}' > "$out/result.json"
}
app_start=$(starttime "$app")
app_exe=$(proc_exe "$app")
app_group=$(pgid "$app")
client_exe=$(realpath "$client_exe")
timeout_exe=$(readlink -f "$(command -v timeout)")
proc_uid() { awk '/^Uid:/ {print $2}' "/proc/$1/status"; }
parent_pid() { sed -E 's/^.*\) //' "/proc/$1/stat" | awk '{print $2}'; }
process_state() { sed -E 's/^.*\) //' "/proc/$1/stat" | awk '{print $1}'; }
discover_client() {
  local child before after exe matches=0 found= found_start= found_exe=
  local -a children
  if [[ -z $launcher ]]; then
    [[ -r $out/launcher.tsv ]] || return 1
    read -r launcher launcher_start < "$out/launcher.tsv"
    [[ $launcher =~ ^[1-9][0-9]*$ && $launcher_start =~ ^[0-9]+$ ]] || return 1
  fi
  [[ $(starttime "$launcher" 2>/dev/null) == "$launcher_start" && $(proc_exe "$launcher") == "$timeout_exe" &&
     $(pgid "$launcher") == "$launcher" && $(proc_uid "$launcher") == "$mint_uid" ]] || return 1
  [[ -z $client ]] || { same_processes; return; }
  read -r -a children < "/proc/$launcher/task/$launcher/children" || true
  for child in "${children[@]}"; do
    [[ $child =~ ^[1-9][0-9]*$ ]] || continue
    before=$(starttime "$child" 2>/dev/null) || continue
    exe=$(proc_exe "$child") || continue
    [[ ( $exe == "$client_exe" || $exe == "$strace_exe" ) && $(parent_pid "$child") == "$launcher" &&
       $(proc_uid "$child") == "$mint_uid" ]] || continue
    after=$(starttime "$child" 2>/dev/null) || continue
    [[ $before == "$after" && -n $before ]] || continue
    matches=$((matches+1)); found=$child; found_start=$before; found_exe=$exe
  done
  [[ $matches == 1 && $found != "$app" ]] || return 1
  [[ -z $birth_pid || ( $found == "$birth_pid" && $found_start == "$birth_start" ) ]] || return 1
  birth_pid=$found; birth_start=$found_start; client_group=$(pgid "$found")
  [[ $found_exe != "$strace_exe" ]] || discover_intermediate || true
  # During -DD's pre-exec handshake the direct child still runs strace.
  # Retain its actual TracerPid owner before a short-lived client can exit.
  [[ -n $tracer ]] || discover_tracer || true
  [[ $found_exe == "$client_exe" ]] || return 1
  client=$found; client_start=$found_start; client_group=$(pgid "$client")
  client_exec_verified=true
  jq -n --argjson app "$app" --argjson client "$client" --argjson launcher "$launcher" --arg app_start "$app_start" \
    --arg client_start "$client_start" --arg client_exe "$client_exe" --arg app_exe "$app_exe" --arg launcher_start "$launcher_start" \
    '{app_pid:$app,client_pid:$client,launcher_pid:$launcher,launcher_starttime:$launcher_start,
      app_starttime:$app_start,client_starttime:$client_start,client_exe:$client_exe,app_exe:$app_exe}' > "$out/process-identities.json"
  event "exact_timeout_child_exec_verified; client=$client starttime=$client_start"
}
discover_intermediate() {
  local child matches=0 candidate= before after
  local -a children
  [[ -z $intermediate ]] || return 0
  [[ $(starttime "$birth_pid" 2>/dev/null) == "$birth_start" && $(proc_exe "$birth_pid") == "$strace_exe" ]] || return 1
  read -r -a children < "/proc/$birth_pid/task/$birth_pid/children" || true
  for child in "${children[@]}"; do
    [[ $child =~ ^[1-9][0-9]*$ ]] || continue
    before=$(starttime "$child" 2>/dev/null) || continue
    [[ $(proc_exe "$child") == "$strace_exe" && $(proc_uid "$child") == "$mint_uid" &&
       $(parent_pid "$child") == "$birth_pid" && $(pgid "$child") == "$client_group" ]] || continue
    after=$(starttime "$child" 2>/dev/null) || continue
    [[ $before == "$after" ]] || continue
    matches=$((matches+1)); candidate=$child
  done
  [[ $matches == 1 && $candidate != "$app" && $candidate != "$birth_pid" && $candidate != "$launcher" ]] || return 1
  record_observer "$candidate" strace-intermediate "$client_group" false || return 1
  intermediate=$candidate
  printf '%s\t%s\t%s\t%s\n' "$intermediate" "${observer_start[$intermediate]}" "$birth_pid" "$client_group" > "$out/intermediate-identity.tsv"
  cat "/proc/$intermediate/stat" > "$out/intermediate-stat.txt" || true
  event "birth_intermediate_lineage_retained; pid=$intermediate parent=$birth_pid"
}
discover_tracer() {
  local task value candidate= found=0 tracee=${client:-$birth_pid} tracee_start=${client_start:-$birth_start} tracee_exe
  [[ -n $tracee && $(starttime "$tracee" 2>/dev/null) == "$tracee_start" &&
     $(parent_pid "$tracee") == "$launcher" && $(proc_uid "$tracee") == "$mint_uid" ]] || return 1
  tracee_exe=$(proc_exe "$tracee") || return 1
  [[ $tracee_exe == "$client_exe" || $tracee_exe == "$strace_exe" ]] || return 1
  for task in /proc/"$tracee"/task/*/status; do
    [[ -r $task ]] || return 1
    value=$(awk '/^TracerPid:/ {print $2}' "$task") || return 1
    [[ $value =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\t%s\n' "$(now)" "$task" "$value" >> "$out/tracer-owner-discovery.tsv"
    [[ $value != 0 ]] || continue
    [[ -z $candidate || $candidate == "$value" ]] || return 1
    candidate=$value; found=1
  done
  [[ $(starttime "$tracee" 2>/dev/null) == "$tracee_start" && $found == 1 && $candidate != "$tracee" && $candidate != "$app" && $candidate != "$launcher" &&
     $(proc_uid "$candidate") == "$mint_uid" && $(pgid "$candidate") == "$candidate" &&
     $candidate != "$app_group" && $candidate != "$client_group" && $candidate != "$launcher" &&
     $candidate != "$(pgid "$$")" ]] || return 1
  record_observer "$candidate" strace "$candidate" false || return 1
  tracer=$candidate
  printf '%s\n' "$tracer" > "$out/actual-tracer-pid.txt"
  cat "/proc/$tracer/status" > "$out/tracer-status.txt"
  cat "/proc/$tracer/stat" > "$out/tracer-stat.txt"
  event "actual_birth_tracer_owned; tracer=$tracer"
}
stop_birth_tracer() {
  local deadline
  [[ -n $tracer ]] || return 1
  observer_terminated "$tracer" && return 0
  [[ $birth_cleanup_attempted == false ]] || return 1
  birth_cleanup_attempted=true
  if [[ $client_exec_verified == false && -n $birth_pid &&
        $(starttime "$birth_pid" 2>/dev/null) == "$birth_start" && $(proc_exe "$birth_pid") == "$client_exe" ]]; then
    client_exec_verified=true
  fi
  if [[ $client_exec_verified == true && $intermediate_released_by_observer == false ]]; then
    signal_observer "$tracer" TERM
    deadline=$(( $(monotonic_ms) + 4000 ))
    while (( $(monotonic_ms) < deadline )); do
      observer_terminated "$tracer" && return 0
      sleep 0.1
    done
  else
    # Before exact client exec strace_child may still equal the tracee PID;
    # strace's TERM cleanup can forward TERM to it. Verified KILL avoids that
    # user-space forwarding path (EXITKILL is deliberately not enabled).
    collection_status=partial; collection_limited=true
    collection_limit_reasons+=('pre-exec tracer cleanup used verified KILL only; client exec/reset unproven;')
    event 'pre_exec_cleanup; TERM forbidden because strace_child reset unproven'
    # The daemon normally releases the original child's exec wait by killing
    # its intermediate child. Killing only the daemon can strand that child
    # in pause(). Retain and stop this exact owned intermediate first.
    [[ -n $intermediate ]] || discover_intermediate || true
    if [[ -z $intermediate ]]; then
      event 'pre_exec_daemon_KILL_skipped; intermediate ownership unknown'
      return 1
    fi
    if ! observer_terminated "$intermediate"; then
      intermediate_released_by_observer=true
      signal_observer "$intermediate" KILL
      deadline=$(( $(monotonic_ms) + 1000 ))
      while (( $(monotonic_ms) < deadline )); do
        observer_terminated "$intermediate" && break
        sleep 0.05
      done
    fi
    observer_terminated "$intermediate" || { event 'intermediate_exit_unverified; daemon KILL skipped'; return 1; }
    event "intermediate_exit_verified_before_daemon_KILL; pid=$intermediate"
  fi
  signal_observer "$tracer" KILL
  deadline=$(( $(monotonic_ms) + 1000 ))
  while (( $(monotonic_ms) < deadline )); do
    observer_terminated "$tracer" && return 0
    sleep 0.05
  done
  return 1
}
same_processes() {
  [[ -n $client && -r /proc/$app/stat && -r /proc/$client/stat && $(starttime "$app") == "$app_start" && $(proc_exe "$app") == "$app_exe" &&
     $(starttime "$client") == "$client_start" && $(proc_exe "$client") == "$client_exe" &&
     $(proc_uid "$client") == "$mint_uid" && $(parent_pid "$client") == "$launcher" ]]
}
# Reads complete JSONL records; a writer's partial line is retried on the next
# iteration. Root identity comes from broker PID ownership, not a stable bus ID.
root_call() {
  [[ -r $jsonl ]] || return 1
  jq -sc --argjson pid "$app" --arg expected "$expected_bus" '
    . as $rows | [$rows[] | select(.kind=="query" and .op=="GetProcessId" and .result==$pid) | .identity] as $roots |
    [$rows[] | select(.kind=="query_enter" and .op=="GetName" and .identity.path=="/org/a11y/atspi/accessible/root") |
     select(.identity as $id | any($roots[]; .bus==$id.bus and .path==$id.path)) |
     select($expected=="" or .identity.bus==$expected)] | first // empty' "$jsonl" 2>/dev/null
}
call_completed() {
  jq -se --argjson call "$call_id" 'any(.[]; (.kind=="query" and .call_id==$call) or .kind=="process_exit")' "$jsonl" >/dev/null 2>&1
}
event 'watch_started_before_launch; no debugger attached'
trap cleanup EXIT
trap 'status=partial; reason="Observer interrupted; retained files may be partial."; exit 143' TERM
trap 'status=partial; reason="Observer interrupted; retained files may be partial."; exit 130' INT
touch "$out/watcher-ready"
for ((iteration=0; iteration<100; iteration++)); do
  [[ -r $out/launch-monotonic ]] && break
  sleep 0.05
done
[[ -r $out/launch-monotonic ]] || { reason='No launch event within five seconds.'; exit 0; }
read -r launch_seconds < "$out/launch-monotonic"
[[ $launch_seconds =~ ^[0-9]+[.][0-9]+$ ]] || { reason='Invalid monotonic launch event.'; exit 3; }
cutoff_ms=$(awk -v s="$launch_seconds" 'BEGIN {printf "%.0f\n",s*1000+30000}')
call=''
while (( $(monotonic_ms) < cutoff_ms )); do
  if [[ -z $client ]]; then discover_client || { sleep 0.05; continue; }; fi
  [[ -n $tracer ]] || { discover_tracer || { sleep 0.05; continue; }; }
  if ! same_processes; then status=partial; reason='Target exited or changed before root Name entry.'; exit 0; fi
  call=$(root_call) || call=''
  [[ -n $call ]] && break
  sleep 0.05
done
[[ -n $call ]] || { status=partial; reason='No owned pending root Name entry before 30s birth capture cutoff.'; exit 0; }
printf '%s\n' "$call" > "$out/root-query-enter.json"
call_id=$(jq -r .call_id <<< "$call")
[[ $call_id =~ ^[0-9]+$ ]] || { reason='Root Name call_id unavailable.'; exit 0; }
event "root_name_entry_detected; call_id=$call_id; unresolved_wait_seconds=3"
pending_until=$(( $(monotonic_ms) + 3000 ))
while (( $(monotonic_ms) < pending_until && $(monotonic_ms) < cutoff_ms )); do
  if ! same_processes || call_completed; then
    status=completed-during-birth-trace; reason='Name returned or client ended during the traced wait.'; exit 0
  fi
  sleep 0.05
done
(( $(monotonic_ms) >= pending_until )) || { reason='30s capture cutoff preceded the three-second unresolved gate.'; exit 0; }
same_processes && ! call_completed || { reason='Name completed or target changed at detach gate.'; exit 0; }
event 'three_second_unresolved_birth_trace_complete; detach begins'
cp "$jsonl" "$out/query-at-detach.jsonl"
snapshot_proc() {
  local role=$1 pid=$2 file library build_id
  mkdir -p "$out/$role"
  for file in stat status maps wchan syscall; do
    cat "/proc/$pid/$file" > "$out/$role/$file" 2> "$out/$role/$file.stderr" || true
  done
  ls -l "/proc/$pid/fd" > "$out/$role/fd-links.txt" 2> "$out/$role/fd-links.stderr" || true
  readlink -f "/proc/$pid/exe" > "$out/$role/exe.txt"
  # Keep only bus-related environment identifiers, never the whole environment.
  tr '\0' '\n' < "/proc/$pid/environ" | awk '/^(DBUS_SESSION_BUS_ADDRESS|AT_SPI_BUS_ADDRESS)=/' > "$out/$role/bus-environment.txt"
  awk '$6 ~ /^\// {print $6}' "$out/$role/maps" | sort -u > "$out/$role/mapped-files.txt"
  while IFS= read -r library; do
    [[ -f $library ]] || continue
    case $library in *libatspi*|*libdbus*|*libatk*|*libgtk*|*libflutter*|*localsend*|*geometry-client*) ;;
      *) continue ;; esac
    sha256sum "$library" >> "$out/$role/mapped-library.sha256"
    build_id=$(readelf -n "$library" 2>/dev/null | awk '/Build ID:/ {print $3; exit}') || build_id=''
    printf '%s\t%s\n' "$library" "$build_id" >> "$out/$role/mapped-build-ids.tsv"
  done < "$out/$role/mapped-files.txt"
}
all_thread_detached() {
  local pass=$1 pid task tid before after value state count
  same_processes || return 1
  for pid in "$client" "$app"; do
    count=0
    [[ $(process_state "$pid") != [TtZ] ]] || return 1
    for task in /proc/"$pid"/task/*/status; do
      [[ -r $task ]] || return 1
      tid=${task%/status}; tid=${tid##*/}
      before=$(starttime "$tid") || return 1
      value=$(awk '/^TracerPid:/ {print $2}' "$task") || return 1
      state=$(awk '/^State:/ {print $2}' "$task") || return 1
      after=$(starttime "$tid") || return 1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$pass" "$tid" "$before" "$value" "$state" >> "$out/tracer-detach-check.tsv"
      [[ $value == 0 && $state != [TtZ] && $before == "$after" ]] || return 1
      count=$((count+1))
    done
    (( count > 0 )) || return 1
  done
  same_processes
}
if ! stop_birth_tracer || ! all_thread_detached before-gdb-1 || ! all_thread_detached before-gdb-2; then
  status=partial; reason='Actual tracer exit and all-thread detach could not be verified; GDB skipped.'; exit 0
fi
event "actual_tracer_exit_and_all_thread_detach_verified; tracer=$tracer"
snapshot_proc app "$app"
snapshot_proc client "$client"
cat /proc/net/unix > "$out/unix-sockets.txt"
ss -xap > "$out/unix-connections.txt" 2> "$out/unix-connections.stderr" || true
# An ellipsis can be formatting or syscall truncation; conservatively retain
# this as a possible truncation marker, never as a complete stream claim.
grep -nE '\.\.\.' "$out/transport.strace" > "$out/transport-possible-truncation.txt" || true
gdb_snapshot() {
  local role=$1 pid=$2
  same_processes || return 1
  setsid timeout --kill-after=2s 12s sudo -n env ROOT_NAME_SYMBOL_MANIFEST="$debug_dir/manifest.tsv" gdb -q -nx -batch \
    -iex 'set auto-load off' -iex 'set debuginfod enabled off' \
    -ex 'set pagination off' -ex 'set confirm off' -ex 'set print elements 128' \
    -ex 'set auto-load python-scripts off' \
    -ex 'set may-call-functions off' -ex 'set debuginfod enabled off' \
    -ex "set debug-file-directory $debug_dir:/usr/lib/debug" \
    -ex "attach $pid" -ex 'info sharedlibrary' -ex 'info proc mappings' \
    -ex 'thread apply all bt full 24' -ex "source $here/root-name-gdb.py" -ex 'detach' \
    > "$out/$role/gdb.txt" 2> "$out/$role/gdb.stderr" &
  snapshot_group=$!
  pending_launchers+=("$snapshot_group")
  record_launcher "$snapshot_group" "gdb-$role" || return 1
}
event 'parallel_stack_snapshots_begin; inferior function calls and network symbol fetch disabled'
gdb_snapshot app "$app" || { status=partial; reason='App GDB launcher identity unavailable.'; exit 0; }; app_snapshot=$snapshot_group
gdb_snapshot client "$client" || { status=partial; reason='Client GDB launcher identity unavailable.'; exit 0; }; client_snapshot=$snapshot_group
for ((attempt=0; attempt<20; attempt++)); do
  for role in app client; do
    if [[ $role == app ]]; then target=$app; debugger_group=$app_snapshot; else target=$client; debugger_group=$client_snapshot; fi
    candidate_debugger=$(awk '/^TracerPid:/ {print $2}' "/proc/$target/status" 2>/dev/null) || candidate_debugger=''
    if [[ $candidate_debugger =~ ^[1-9][0-9]*$ ]]; then
      record_observer "$candidate_debugger" "gdb-$role" "$debugger_group" false || true
    fi
  done
  sleep 0.05
done
app_gdb_rc=0; wait "$app_snapshot" || app_gdb_rc=$?
client_gdb_rc=0; wait "$client_snapshot" || client_gdb_rc=$?
printf '%s\n' "$app_gdb_rc" > "$out/app/gdb.exit-status"
printf '%s\n' "$client_gdb_rc" > "$out/client/gdb.exit-status"
event 'parallel_stack_snapshots_finished'
for observer_pid in "${observers[@]}"; do
  if [[ ${observer_role[$observer_pid]} == gdb-* ]] && ! observer_terminated "$observer_pid"; then
    status=partial; reason='Actual GDB exit unverified after wrapper completion.'; exit 0
  fi
done
if ! all_thread_detached after-gdb-1 || ! all_thread_detached after-gdb-2; then
  status=partial; reason='Final all-thread GDB detach or non-stopped target state unverified.'; exit 0
fi
decode_rc=0
timeout --kill-after=2s 6s python3 "$here/decode-root-name-transport.py" "$out/transport.strace" --output "$out/transport-decoded.json" \
  > "$out/decoder.stdout" 2> "$out/decoder.stderr" || decode_rc=$?
printf '%s\n' "$decode_rc" > "$out/decoder.exit-status"
status=collected-only
collection_status=finished
if [[ $collection_limited == true ]]; then collection_status=partial; fi
reason='Raw evidence collected; downstream review must establish Name request/reply/connection linkage. No causal or geometry success claimed.'
if [[ $(cat "$out/app/gdb.exit-status" 2>/dev/null) != 0 || $(cat "$out/client/gdb.exit-status" 2>/dev/null) != 0 ||
      $decode_rc != 0 || ! -s $out/transport.strace || -s $out/transport-possible-truncation.txt ]] ||
   ! grep -q '"kind": "held_message"' "$out/client/gdb.txt"; then
  collection_status=partial
  collection_limited=true
  collection_limit_reasons+=('transport, stack, held-message, or truncation limitation;')
  reason='Transport, stacks, or held client message headers incomplete; inspect raw statuses and symbol availability.'
fi
