#!/usr/bin/env bash
# Host controller. All UI input passes physically through the QEMU SDL client.
set -Eeuo pipefail
scenario_dir=$(cd "$(dirname "$0")" && pwd)
source "$scenario_dir/environment.sh"
export DISPLAY=:99
out=${EVIDENCE_DIR:-$GITHUB_WORKSPACE/evidence/vm}/scenario
mkdir -p "$out"
started=$(cut -d' ' -f1 /proc/uptime)
job_started=${JOB_STARTED_UPTIME:-$(cat /tmp/3478-job-start)}
stop=$(awk -v s="$started" -v j="$job_started" 'BEGIN {print (s+840<j+4740?s+840:j+4740)}')
qemu_window=$(cat /tmp/localsend-vm/sdl-window-id)
[[ "$qemu_window" =~ ^[0-9]+$ ]]
index=0
app_pid=
now() { cut -d' ' -f1 /proc/uptime; }
step() {
  local seconds=$1 label=$2 status=0
  shift 2
  awk -v n="$(now)" -v s="$stop" -v b="$seconds" 'BEGIN {exit !(n+b+2<s)}' || return 124
  printf 'START %s %s uptime=%s UTC=%s\n' "$index" "$label" "$(now)" "$(date -u +%FT%T.%N)" >> "$out/input.log"
  timeout --kill-after=1s "${seconds}s" bash -c 'source "$1"; shift; "$@"' _ "$scenario_dir/environment.sh" "$@" || status=$?
  printf 'JOIN %s %s status=%s uptime=%s UTC=%s\n' "$index" "$label" "$status" "$(now)" "$(date -u +%FT%T.%N)" >> "$out/input.log"
  index=$((index+1))
  return "$status"
}
guest() { local label=$1; shift; step 30 "$label" ssh_guest "$@"; }
# Every remote command has a second bounded guest-side timeout where it can block.
remote() { local label=$1 command=$2; guest "$label" ". /home/probe/session-env; timeout --kill-after=1s 25s bash -c $(printf '%q' "$command")"; }
capture() { step 5 "$1-pixels" /tmp/localsend-vm/capture "$out/$1.png"; }
snapshot() {
  remote "$1-oracle" 'python3 /home/probe/diagnostics/geometry-oracle/snapshot-guest.py' > "$out/$1-snapshot.json"
}
focus_check() {
  remote "$1-focus" "python3 /home/probe/diagnostics/geometry-oracle/snapshot-guest.py --pid $2 --backend wayland --require-focused" > "$out/$1-focused.json"
}
geometry() {
  step 3 "$1-host-client" xdotool getwindowgeometry --shell "$qemu_window" > "$out/$1-host-client.txt"
  # X/Y are the observed client origin, WIDTH/HEIGHT exclude WM decoration.
  local hx hy hw hh
  hx=$(sed -n 's/^X=//p' "$out/$1-host-client.txt")
  hy=$(sed -n 's/^Y=//p' "$out/$1-host-client.txt")
  hw=$(sed -n 's/^WIDTH=//p' "$out/$1-host-client.txt")
  hh=$(sed -n 's/^HEIGHT=//p' "$out/$1-host-client.txt")
  [[ "$hx $hy $hw $hh" =~ ^-?[0-9]+\ -?[0-9]+\ [0-9]+\ [0-9]+$ ]]
  snapshot "$1"
  step 8 "$1-stage-observation" scp_guest "$out/$1-snapshot.json" probe@127.0.0.1:/home/probe/evidence/input-snapshot.json
  remote "$1-point" "python3 /home/probe/diagnostics/accessible-dump.py point --pid $2 --snapshot /home/probe/evidence/input-snapshot.json --host $hx $hy $hw $hh ${3:+--label $(printf '%q' "$3")}" > "$out/$1-point.json"
}
click() {
  local label=$1 pid=$2 name=${3:-} x y
  if [[ -z "$name" ]]; then
    # Native physical window cycling brings a covered header into view. Observe
    # each resulting compositor foreground; never call a focus-changing oracle.
    local attempt found=0
    for attempt in 1 2 3 4 5 6 7 8; do
      snapshot "$label-cycle-$attempt"
      if jq -e --argjson pid "$pid" 'any(.windows[]; .pid.value==$pid and .compositorFocused.value==true)' "$out/$label-cycle-$attempt-snapshot.json" >/dev/null; then found=1; break; fi
      step 3 "$label-cycle-$attempt-host-focus" xdotool windowfocus "$qemu_window"
      snapshot "$label-cycle-$attempt-host-focused"
      step 3 "$label-cycle-$attempt-physical-alt-escape" xdotool key --clearmodifiers alt+Escape
      step 2 "$label-cycle-$attempt-settle" sleep 0.5
      snapshot "$label-cycle-$attempt-after-key"
      capture "$label-cycle-$attempt"
    done
    [[ "$found" == 1 ]]
  fi
  geometry "$label" "$pid" "$name"
  read -r x y < <(jq -r '.hostPoint | @tsv' "$out/$label-point.json")
  step 3 "$label-host-focus" xdotool windowfocus "$qemu_window"
  focus_check "$label-host-focused" "$pid"
  step 3 "$label-mouse" xdotool mousemove --sync "$x" "$y"
  focus_check "$label-after-mouse" "$pid"
  step 3 "$label-click" xdotool click 1
  step 2 "$label-settle" sleep 0.6
  focus_check "$label" "$pid"
  capture "$label"
}
key() {
  local label=$1 pid=$2 chord=$3
  focus_check "$label-before" "$pid"
  step 3 "$label-key-$chord" xdotool key --clearmodifiers "$chord"
  step 2 "$label-settle" sleep 0.6
  focus_check "$label-after" "$pid"
  capture "$label"
}
tree() { remote "$1-atspi" "python3 /home/probe/diagnostics/accessible-dump.py tree --pid $2" > "$out/$1-tree.json"; }
identity() {
  remote "$1-process" "python3 /home/probe/diagnostics/accessible-dump.py identity --pid $2" > "$out/$1-process.json"
  local ticks
  ticks=$(jq -r '.startTicks' "$out/$1-process.json")
  [[ "$ticks" =~ ^[0-9]+$ ]]
  remote "$1-owner-receipt" "printf '%s\\n' '$ticks' > /home/probe/evidence/owned-$2.start"
}
wait_window() {
  local label=$1 pid=$2 attempt
  for attempt in 1 2 3 4 5; do
    snapshot "$label-$attempt"
    if jq -e --argjson pid "$pid" '[.windows[] | select(.pid.value==$pid and .backend.value.name=="wayland" and .actorVisible.value==true)] | length==1' "$out/$label-$attempt-snapshot.json" >/dev/null; then return 0; fi
    step 2 "$label-wait" sleep 1
  done
  return 2
}
numlock_off() {
  snapshot "$1-numlock"
  jq -e '.keyboardNumLock.error==null and (.keyboardNumLock.value | type)=="boolean"' "$out/$1-numlock-snapshot.json" >/dev/null
  if jq -e '.keyboardNumLock.value == true' "$out/$1-numlock-snapshot.json" >/dev/null; then
    key "$1-numlock-disable" "$2" Num_Lock
  fi
  snapshot "$1-numlock-off"
  jq -e '.keyboardNumLock=={"value":false,"error":null}' "$out/$1-numlock-off-snapshot.json" >/dev/null
  focus_check "$1-after-keymap-observation" "$2"
}
launch_app() {
  local label=$1
  if [[ -n "$app_pid" ]]; then
    remote "$label-close" "kill -TERM $app_pid; for i in 1 2 3 4 5; do kill -0 $app_pid 2>/dev/null || exit 0; sleep 1; done; exit 2" > "$out/$label-close.txt"
  fi
  # No saved settings or selection is written by this controller. Keep one fresh
  # external XDG profile and restart normally to clear only transient selection.
  remote "$label-launch" "mkdir -p /home/probe/evidence/profile/config /home/probe/evidence/profile/cache; cd /home/probe/bundle; nohup env XDG_CONFIG_HOME=/home/probe/evidence/profile/config XDG_CACHE_HOME=/home/probe/evidence/profile/cache WAYLAND_DEBUG=1 ./localsend_app > /home/probe/evidence/$label-wayland.log 2>&1 < /dev/null & echo \$!" > "$out/$label-launch-pid.txt"
  app_pid=$(cat "$out/$label-launch-pid.txt")
  [[ "$app_pid" =~ ^[0-9]+$ ]]
  wait_window "$label" "$app_pid"
  identity "$label" "$app_pid"
  click "$label-header" "$app_pid"
  tree "$label-initial" "$app_pid"
  click "$label-send-tab" "$app_pid" Send
  tree "$label-empty" "$app_pid"
  # Verified real empty Send tab, rather than assuming persisted selection clears.
  jq -e '[.nodes[].name] | (index("Selection")!=null and index("File")!=null and index("Text")!=null and all(.[]; startswith("Files: ")|not))' "$out/$label-empty-tree.json" >/dev/null
  remote "$label-persisted-profile" 'find /home/probe/evidence/profile -type f -maxdepth 6 -print -exec sha256sum {} \;' > "$out/$label-profile.txt"
}
copy_file() {
  local label=$1
  click "$label-nautilus-header" "$nautilus_pid"
  key "$label-select-all" "$nautilus_pid" ctrl+a
  tree "$label-selected" "$nautilus_pid"
  jq -e '[.nodes[] | select(.name=="probe3478.txt") | .states[]] | any(.[]; contains("SELECTED"))' "$out/$label-selected-tree.json" >/dev/null
  key "$label-copy" "$nautilus_pid" ctrl+c
}
inspect_selection() {
  local label=$1
  tree "$label-after-paste" "$app_pid"
  capture "$label-after-paste"
  if jq -e '[.nodes[].name] | index("Files: 1")!=null' "$out/$label-after-paste-tree.json" >/dev/null; then
    click "$label-edit" "$app_pid" Edit
    tree "$label-selection-detail" "$app_pid"
    capture "$label-selection-detail"
    # Retain semantic details and pixels for the owner to decide file vs message.
    # Do not equate a .txt name or nonempty selection with successful file read.
    printf '%s\tselection-present-review-originals\n' "$label" >> "$out/outcomes.tsv"
  elif jq -e '[.nodes[].name] | index("File")!=null and index("Text")!=null' "$out/$label-after-paste-tree.json" >/dev/null; then
    printf '%s\tno-selection-needs-shortcut-protocol-review\n' "$label" >> "$out/outcomes.tsv"
  else
    printf '%s\tinconclusive-unrecognized-real-ui\n' "$label" >> "$out/outcomes.tsv"
  fi
}
finish() {
  local status=$?
  trap - EXIT INT TERM
  local pid cleanup_command cleanup_failed=0
  # Verify the process start tick before stopping an owned PID.
  for pid in "${app_pid:-}" "${editor_pid:-}" "${nautilus_pid:-}" "${probe_pid:-}" "${probe_timeout_pid:-}" "${probe_supervisor_pid:-}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    cleanup_command="if kill -0 $pid 2>/dev/null; then actual=\$(sed -E 's/^.*\\) //' /proc/$pid/stat | cut -d' ' -f20); test \"\$actual\" = \"\$(cat /home/probe/evidence/owned-$pid.start)\" || exit 2; kill -TERM $pid; for i in 1 2 3 4; do kill -0 $pid 2>/dev/null || exit 0; sleep 1; done; exit 2; fi"
    timeout --kill-after=1s 8s bash -c 'source "$1"; ssh_guest "$2"' _ "$scenario_dir/environment.sh" "timeout --kill-after=1s 6s bash -c $(printf '%q' "$cleanup_command")" >> "$out/cleanup.txt" 2>&1 || cleanup_failed=1
  done
  if [[ "$cleanup_failed" == 0 ]]; then
    timeout --kill-after=1s 5s bash -c 'source "$1"; ssh_guest "$2"' _ "$scenario_dir/environment.sh" 'touch /home/probe/evidence/scenario-cleanup-complete' >> "$out/cleanup.txt" 2>&1 || cleanup_failed=1
  fi
  [[ "$cleanup_failed" == 0 ]] || status=2
  printf 'SCENARIO_JOINED status=%s uptime=%s UTC=%s\n' "$status" "$(now)" "$(date -u +%FT%T.%N)" >> "$out/input.log" || true
  printf '%s\n' "$status" > "$out/scenario-exit-status"
  # Environment collector owns video/process cleanup and retains guest logs.
  if [[ "$status" != 0 ]]; then printf 'harness-or-control-inconclusive\n' >> "$out/outcomes.tsv"; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'started=%s stop=%s jobStarted=%s\n' "$started" "$stop" "$job_started" > "$out/deadlines.txt"
remote prepare-real-file 'mkdir -p /home/probe/evidence/one-file; test -z "$(ls -A /home/probe/evidence/one-file)"; printf "LocalSend real Nautilus file copy 3478\n" > /home/probe/evidence/one-file/probe3478.txt; sha256sum /home/probe/evidence/one-file/probe3478.txt; cat /home/probe/evidence/one-file/probe3478.txt; gsettings get org.gnome.desktop.peripherals.keyboard numlock-state; gsettings get org.gnome.desktop.peripherals.keyboard remember-numlock-state' > "$out/file-and-keyboard-settings.txt"
# Genuine ordinary GTK editor copy control comes before the file trials.
token="clipboard-3478-control-$(date -u +%Y%m%dT%H%M%S)"
printf '%s\n' "$token" > "$out/control-token.txt"
remote editor-launch 'nohup gnome-text-editor --new-window > /home/probe/evidence/editor.log 2>&1 < /dev/null & echo $!' > "$out/editor-pid.txt"
editor_pid=$(cat "$out/editor-pid.txt")
[[ "$editor_pid" =~ ^[0-9]+$ ]]
wait_window editor "$editor_pid"
identity editor "$editor_pid"
click editor-header "$editor_pid"
tree editor-initial "$editor_pid"
# --new-window creates a normal draft. A missing editable text view is a
# first-login/provider blocker; do not type into an assumed content region.
jq -e '[.nodes[] | select(.role=="text" and any(.states[]; contains("EDITABLE")))] | length==1' "$out/editor-initial-tree.json" >/dev/null
focus_check editor-type-before "$editor_pid"
step 5 editor-real-typing xdotool type --clearmodifiers --delay 25 "$token"
focus_check editor-type-after "$editor_pid"
key editor-select-all "$editor_pid" ctrl+a
key editor-copy "$editor_pid" ctrl+c
tree editor-control "$editor_pid"
jq -e --arg token "$token" '[.nodes[] | (.text // "")] | any(.[]; contains($token))' "$out/editor-control-tree.json" >/dev/null
launch_app control
numlock_off control "$app_pid"
key control-paste "$app_pid" ctrl+v
inspect_selection control
# SelectedFilesPage exposes quoted message bytes in its actual visible label.
jq -e --arg token "$token" '[.nodes[] | (.name // ""), (.text // "")] | any(.[]; contains($token))' "$out/control-selection-detail-tree.json" >/dev/null
printf 'control\tvisible-real-text-token-confirmed\n' >> "$out/outcomes.tsv"
remote nautilus-launch 'nohup env WAYLAND_DEBUG=1 nautilus --new-window /home/probe/evidence/one-file > /home/probe/evidence/nautilus-wayland.log 2>&1 < /dev/null & echo $!' > "$out/nautilus-pid.txt"
nautilus_pid=$(cat "$out/nautilus-pid.txt")
[[ "$nautilus_pid" =~ ^[0-9]+$ ]]
wait_window nautilus "$nautilus_pid"
identity nautilus "$nautilus_pid"
for trial in 1 2 3; do
  label="file-$trial"
  launch_app "$label"
  copy_file "$label"
  click "$label-app-header" "$app_pid"
  numlock_off "$label-before-paste" "$app_pid"
  key "$label-paste" "$app_pid" ctrl+v
  numlock_off "$label-after-paste" "$app_pid"
  inspect_selection "$label"
done
# Only after all real app assertions: unsupported data-control is a separate result.
for mime in list text/uri-list x-special/gnome-copied-files; do
  safe=${mime//\//-}
  remote "wl-paste-$safe" "set +e; if test '$mime' = list; then timeout --kill-after=1s 5s env WAYLAND_DEBUG=1 wl-paste --list-types > /home/probe/evidence/wl-paste-$safe.stdout 2> /home/probe/evidence/wl-paste-$safe.stderr; else timeout --kill-after=1s 5s env WAYLAND_DEBUG=1 wl-paste --type '$mime' > /home/probe/evidence/wl-paste-$safe.stdout 2> /home/probe/evidence/wl-paste-$safe.stderr; fi; printf '%s\\n' \$? > /home/probe/evidence/wl-paste-$safe.status" > "$out/wl-paste-$safe-controller.txt"
done
remote gtk-probe-launch 'nohup bash -c '\''timeout --kill-after=1s 119s /home/probe/diagnostics/gtk-clipboard-probe > /home/probe/evidence/gtk-probe.jsonl 2> /home/probe/evidence/gtk-probe.stderr & timer=$!; echo "$timer" > /home/probe/evidence/gtk-probe-timeout.pid; wait "$timer"; status=$?; printf "%s\n" "$status" > /home/probe/evidence/gtk-probe.exit; touch /home/probe/evidence/gtk-probe-supervisor-joined'\'' > /home/probe/evidence/gtk-probe-supervisor.log 2>&1 < /dev/null & echo $! > /home/probe/evidence/gtk-probe-supervisor.pid; for i in 1 2 3 4 5; do if test -s /home/probe/evidence/gtk-probe.jsonl; then jq -sr '\''[.[] | select(.event=="ready") | .pid] | if length==1 then .[0] else error("no unique ready observer") end'\'' /home/probe/evidence/gtk-probe.jsonl && exit 0; fi; sleep 1; done; exit 2' > "$out/gtk-probe-pid.txt"
probe_pid=$(cat "$out/gtk-probe-pid.txt")
[[ "$probe_pid" =~ ^[0-9]+$ ]]
remote gtk-probe-supervisor-identities 'cat /home/probe/evidence/gtk-probe-timeout.pid /home/probe/evidence/gtk-probe-supervisor.pid' > "$out/gtk-probe-supervisor-pids.txt"
probe_timeout_pid=$(sed -n '1p' "$out/gtk-probe-supervisor-pids.txt")
probe_supervisor_pid=$(sed -n '2p' "$out/gtk-probe-supervisor-pids.txt")
[[ "$probe_timeout_pid $probe_supervisor_pid" =~ ^[0-9]+\ [0-9]+$ ]]
identity gtk-probe-timeout "$probe_timeout_pid"
identity gtk-probe-supervisor "$probe_supervisor_pid"
wait_window gtk-probe "$probe_pid"
identity gtk-probe "$probe_pid"
copy_file gtk-probe
click gtk-probe-header "$probe_pid"
numlock_off gtk-probe "$probe_pid"
focus_check gtk-probe-before-paste "$probe_pid"
step 3 gtk-probe-key-ctrl-v xdotool key --clearmodifiers ctrl+v
remote gtk-probe-await 'for i in $(seq 1 20); do if test -f /home/probe/evidence/gtk-probe-supervisor-joined; then cat /home/probe/evidence/gtk-probe.exit; exit 0; fi; sleep 1; done; exit 124' > "$out/gtk-probe-exit.txt"
capture gtk-probe-result
remote gtk-probe-result 'cat /home/probe/evidence/gtk-probe.jsonl /home/probe/evidence/gtk-probe.stderr' > "$out/gtk-probe-result.txt"
printf 'episode\tcompleted-observations-parent-must-review-originals\n' >> "$out/outcomes.tsv"
