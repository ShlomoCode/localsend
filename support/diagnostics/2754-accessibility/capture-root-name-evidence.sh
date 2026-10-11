#!/usr/bin/env bash
# Evidence observer only; does not alter the public geometry query or deadline.
set -euo pipefail
[[ ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 && $(id -un) == mint && -d /proc &&
   -f /home/mint/evidence/bootstrap-complete ]] || exit 8
source /etc/os-release
[[ ${ID:-} == linuxmint ]] || exit 8
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ $here == /home/mint/support/diagnostics/2754-accessibility ]] || exit 8
app=${1:?Usage: capture-root-name-evidence.sh APP_PID CLIENT_PID JSONL OUTPUT_DIR [EXPECTED_BUS]}
client=${2:?CLIENT_PID required}
jsonl=${3:?JSONL required}
out=${4:?OUTPUT_DIR required}
expected_bus=${5:-}
[[ $app =~ ^[1-9][0-9]*$ && $client =~ ^[1-9][0-9]*$ && $app != "$client" ]] || exit 2
[[ $out =~ ^/home/mint/[a-zA-Z0-9_./-]+$ ]] || exit 2
mkdir -p "$out"
out=$(realpath "$out")
[[ ! -e $out/result.json ]] || exit 2
observers=()
declare -A observer_start observer_exe observer_pgid observer_role observer_direct
status=incomplete
reason='Observer did not finish.'
collection_status=partial
collection_limited=false
collection_limit_reasons=()
now() { date --utc +%Y-%m-%dT%H:%M:%S.%NZ; }
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
    *launcher) [[ $(basename "$exe") == timeout && $pid == "$group" ]] || return 1 ;;
    strace) [[ $(basename "$exe") == strace ]] || return 1 ;;
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
     $(awk '{print $3}' <<< "$after") == "${observer_pgid[$pid]}" ]]
}
observer_terminated() {
  local pid=$1 current
  [[ -r /proc/$pid/stat ]] || return 0
  current=$(sed -E 's/^.*\) //' "/proc/$pid/stat") || return 1
  [[ $(awk '{print $20}' <<< "$current") != "${observer_start[$pid]}" || $(awk '{print $1}' <<< "$current") == Z ]]
}
signal_observer() {
  local pid=$1 signal=$2 target=$1 rc=0
  if ! observer_alive "$pid"; then
    event "cleanup_skip_identity_absent_changed_or_exited; pid=$pid signal=$signal"
    return 0
  fi
  # A live, verified session leader owns its observer group. If only the
  # retained tracer remains, signal that verified PID, never a stale PGID.
  [[ $pid != "${observer_pgid[$pid]}" ]] || target=-${observer_pgid[$pid]}
  sudo -n kill "-$signal" -- "$target" 2>> "$out/cleanup.stderr" || rc=$?
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$pid" "$target" "$signal" "$rc" >> "$out/cleanup-signals.tsv"
}
cleanup() {
  local code=$? pid attempt live rc
  trap - EXIT TERM INT
  for pid in "${observers[@]}"; do signal_observer "$pid" TERM; done
  # Stop our observer tools only. Never signal the observed app or client.
  sleep 0.2
  for pid in "${observers[@]}"; do signal_observer "$pid" KILL; done
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
  jq -n --arg status "$status" --arg reason "$reason" --arg at "$(now)" \
    --arg collection_status "$collection_status" --argjson observer_exit "$code" \
    --argjson collection_limited "$collection_limited" \
    --arg collection_limit_reasons "${collection_limit_reasons[*]}" \
    '{status:$status,collection_status:$collection_status,reason:$reason,at:$at,observer_exit:$observer_exit,
      collection_limited:$collection_limited,collection_limit_reasons:$collection_limit_reasons,
      pre_attach_traffic_observed:false,debugger_timing_is_latency_evidence:false,
      linkage:{status:"unknown",name_properties_request:"unknown",matched_reply_serial:"unknown",
        connection_and_fd:"unknown",causal_success:false,
        required_review:"Match root Properties.Get(Accessible,Name), request serial, reply_serial, and actual connection/fd; inspect truncation and unavailable locals."},
      transport:{post_attach_only:true,string_limit_bytes:65536,complete_stream:false,
        limitation:"Bounded tracing may omit prior traffic, split/coalesced messages, or bytes beyond the string limit; absence does not prove no reply."}}' > "$out/result.json"
}
trap cleanup EXIT
trap 'status=partial; reason="Observer interrupted; retained files may be partial."; exit 143' TERM
trap 'status=partial; reason="Observer interrupted; retained files may be partial."; exit 130' INT
app_start=$(starttime "$app")
app_exe=$(proc_exe "$app")
client_start=$(starttime "$client")
[[ -z ${PROBE_ROOT_NAME_CLIENT_STARTTIME:-} || $client_start == "$PROBE_ROOT_NAME_CLIENT_STARTTIME" ]] || {
  status=failed; reason='Client identity changed before observer launch.'; exit 3;
}
client_exe=$(readlink -f "/proc/$client/exe")
[[ $(basename "$client_exe") == geometry-client ]] || { status=failed; reason='Observed client is not geometry-client.'; exit 3; }
jq -n --argjson app "$app" --argjson client "$client" --arg app_start "$app_start" \
  --arg client_start "$client_start" --arg client_exe "$client_exe" --arg app_exe "$app_exe" \
  '{app_pid:$app,client_pid:$client,app_starttime:$app_start,client_starttime:$client_start,client_exe:$client_exe,app_exe:$app_exe}' \
  > "$out/process-identities.json"
same_processes() {
  [[ -r /proc/$app/stat && -r /proc/$client/stat && $(starttime "$app") == "$app_start" && $(proc_exe "$app") == "$app_exe" &&
     $(starttime "$client") == "$client_start" && $(readlink -f "/proc/$client/exe") == "$client_exe" ]]
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
event 'watch_started; no debugger or tracer attached'
call=''
for ((iteration=0; iteration<700; iteration++)); do
  if ! same_processes; then status=partial; reason='Target exited or changed before root Name entry.'; exit 0; fi
  call=$(root_call) || call=''
  [[ -n $call ]] && break
  sleep 0.2
done
[[ -n $call ]] || { status=partial; reason='No APP_PID-owned root Name entry within 140 seconds.'; exit 0; }
printf '%s\n' "$call" > "$out/root-query-enter.json"
call_id=$(jq -r .call_id <<< "$call")
event "root_name_entry_detected; call_id=$call_id; initial_wait_seconds=3"
sleep 3
if ! same_processes || call_completed; then
  status=completed-before-observer; reason='Name returned or client ended during the unmodified initial wait.'; exit 0
fi
event 'initial_unmodified_wait_complete; observer capture begins'
cp "$jsonl" "$out/query-at-attach.jsonl"
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
snapshot_proc app "$app"
snapshot_proc client "$client"
cat /proc/net/unix > "$out/unix-sockets.txt"
ss -xap > "$out/unix-connections.txt" 2> "$out/unix-connections.stderr" || true
bus_address=${AT_SPI_BUS_ADDRESS:-}
if [[ -z $bus_address ]]; then
  session_address=$(sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' "$out/app/bus-environment.txt" | head -1)
  if [[ -n $session_address ]]; then
    timeout --kill-after=1s 3s dbus-send --bus="$session_address" --print-reply \
      --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress \
      > "$out/a11y-address.stdout" 2> "$out/a11y-address.stderr" || true
    bus_address=$(awk -F '"' '/string "/ {print $2; exit}' "$out/a11y-address.stdout")
  fi
fi
if [[ -n $bus_address ]]; then
  printf '%s\n' "$bus_address" > "$out/global-a11y-address.txt"
  setsid timeout --kill-after=1s 30s dbus-monitor --address "$bus_address" \
    > "$out/global-bus-monitor.txt" 2> "$out/global-bus-monitor.stderr" &
  monitor_group=$!
  if ! record_launcher "$monitor_group" global-monitor; then
    collection_limited=true
    collection_limit_reasons+=('global-monitor launcher identity unavailable;')
  fi
else
  collection_limited=true
  collection_limit_reasons+=('accessibility-bus address unavailable;')
  printf 'partial: accessibility-bus address unavailable; private peer traffic is never covered by global monitor\n' > "$out/global-bus-monitor.stderr"
fi
event 'transport_attach_begin; prior traffic is unavailable'
same_processes || { status=partial; reason='App/client identity changed before transport attach.'; exit 0; }
setsid timeout --kill-after=2s 8s sudo -n strace -f -ttt -T -xx -yy -s 65536 \
  -e trace=connect,getsockname,getpeername,sendmsg,recvmsg,sendto,recvfrom,read,readv,write,writev,poll,ppoll \
  -p "$app" -p "$client" -o "$out/transport.strace" \
  > "$out/transport.stdout" 2> "$out/transport.stderr" &
trace_group=$!
record_launcher "$trace_group" transport || { status=partial; reason='Transport launcher identity unavailable.'; exit 0; }
tracer=''
for ((attempt=0; attempt<80; attempt++)); do
  candidate_tracer=$(awk '/^TracerPid:/ {print $2}' "/proc/$client/status" 2>/dev/null) || candidate_tracer=''
  if [[ $candidate_tracer =~ ^[1-9][0-9]*$ ]] && record_observer "$candidate_tracer" strace "$trace_group" false; then
    tracer=$candidate_tracer
    break
  fi
  observer_terminated "$trace_group" && break
  sleep 0.05
done
printf '%s\n' "${tracer:-unknown}" > "$out/actual-tracer-pid.txt"
trace_rc=0; wait "$trace_group" || trace_rc=$?
printf '%s\n' "$trace_rc" > "$out/transport.exit-status"
event "transport_wrapper_finished; status=$trace_rc; actual detach not inferred from wrapper alone"
if ! same_processes; then status=partial; reason='A target exited or changed before stack capture.'; exit 0; fi
detached=true
for pid in "$app" "$client"; do
  for thread_status in /proc/"$pid"/task/*/status; do
    [[ -r $thread_status ]] || { detached=false; continue; }
    tracer_value=$(awk '/^TracerPid:/ {print $2}' "$thread_status") || tracer_value=unknown
    printf '%s\t%s\t%s\n' "$(now)" "$thread_status" "$tracer_value" >> "$out/tracer-detach-check.tsv"
    [[ $tracer_value == 0 ]] || detached=false
  done
done
if [[ -z $tracer ]] || ! observer_terminated "$tracer" || [[ $detached != true ]]; then
  status=partial; reason='Actual tracer exit and all-thread detach could not be verified; GDB skipped.'; exit 0
fi
event "actual_tracer_exit_and_all_thread_detach_verified; tracer=$tracer"
# An ellipsis can be formatting or syscall truncation; conservatively retain
# this as a possible truncation marker, never as a complete stream claim.
grep -nE '\.\.\.' "$out/transport.strace" > "$out/transport-possible-truncation.txt" || true
debug_dir=${PROBE_ROOT_NAME_DEBUG_DIR:-/home/mint/evidence/root-name-symbols}
[[ $debug_dir =~ ^/home/mint/[a-zA-Z0-9_./-]+$ ]] || { status=failed; reason='Invalid debug directory.'; exit 3; }
gdb_snapshot() {
  local role=$1 pid=$2
  same_processes || return 1
  setsid timeout --kill-after=2s 12s sudo -n gdb -q -nx -batch \
    -ex 'set pagination off' -ex 'set confirm off' -ex 'set print elements 128' \
    -ex 'set auto-load python-scripts off' \
    -ex 'set may-call-functions off' -ex 'set debuginfod enabled off' \
    -ex "set debug-file-directory $debug_dir:/usr/lib/debug" \
    -ex "attach $pid" -ex 'info sharedlibrary' -ex 'info proc mappings' \
    -ex 'thread apply all bt full 24' -ex "source $here/root-name-gdb.py" -ex 'detach' \
    > "$out/$role/gdb.txt" 2> "$out/$role/gdb.stderr" &
  snapshot_group=$!
  record_launcher "$snapshot_group" "gdb-$role" || return 1
}
event 'parallel_stack_snapshots_begin; inferior function calls and network symbol fetch disabled'
gdb_snapshot app "$app" || { status=partial; reason='App GDB launcher identity unavailable.'; exit 0; }; app_snapshot=$snapshot_group
gdb_snapshot client "$client" || { status=partial; reason='Client GDB launcher identity unavailable.'; exit 0; }; client_snapshot=$snapshot_group
for ((attempt=0; attempt<20; attempt++)); do
  for role in app client; do
    if [[ $role == app ]]; then target=$app; launcher=$app_snapshot; else target=$client; launcher=$client_snapshot; fi
    candidate_debugger=$(awk '/^TracerPid:/ {print $2}' "/proc/$target/status" 2>/dev/null) || candidate_debugger=''
    if [[ $candidate_debugger =~ ^[1-9][0-9]*$ ]]; then
      record_observer "$candidate_debugger" "gdb-$role" "$launcher" false || true
    fi
  done
  sleep 0.05
done
app_gdb_rc=0; wait "$app_snapshot" || app_gdb_rc=$?
client_gdb_rc=0; wait "$client_snapshot" || client_gdb_rc=$?
printf '%s\n' "$app_gdb_rc" > "$out/app/gdb.exit-status"
printf '%s\n' "$client_gdb_rc" > "$out/client/gdb.exit-status"
event 'parallel_stack_snapshots_finished'
status=collected-only
collection_status=finished
if [[ $collection_limited == true ]]; then collection_status=partial; fi
reason='Raw evidence collected; downstream review must establish Name request/reply/connection linkage. No causal or geometry success claimed.'
if [[ $(cat "$out/app/gdb.exit-status" 2>/dev/null) != 0 || $(cat "$out/client/gdb.exit-status" 2>/dev/null) != 0 ||
      $trace_rc != 124 || ! -s $out/transport.strace || -s $out/transport-possible-truncation.txt ]] ||
   ! grep -q '"kind": "held_message"' "$out/client/gdb.txt"; then
  collection_status=partial
  collection_limited=true
  collection_limit_reasons+=('transport, stack, held-message, or truncation limitation;')
  reason='Transport, stacks, or held client message headers incomplete; inspect raw statuses and symbol availability.'
fi
