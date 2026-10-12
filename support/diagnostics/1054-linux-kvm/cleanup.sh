#!/usr/bin/env bash
# Called after both successful and interrupted steps. Never signal by name.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]] || exit 2
PRIVATE="${PRIVATE_DIR:?}"
OUT="${GITHUB_WORKSPACE:?}/evidence/1054-linux-kvm"
[[ "$PRIVATE" == "${RUNNER_TEMP:?}/issue1054-linux-private" && ! -L "$PRIVATE" ]] || exit 2
mkdir -p "$OUT"
exec > >(tee -a "$OUT/cleanup.txt") 2>&1
printf 'cleanup_start=%s\n' "$(date -u --iso-8601=seconds)"
result=0
STAGES=(firmware install)
KEEP_PRIVATE=false
if [[ "${1:-}" == --firmware-only ]]; then STAGES=(firmware); KEEP_PRIVATE=true; fi
if [[ "${1:-}" == --install-only ]]; then STAGES=(install); KEEP_PRIVATE=true; fi
if [[ "$KEEP_PRIVATE" == false && -f "$GITHUB_WORKSPACE/support/diagnostics/1054-linux-kvm/gui.sh" ]]; then
  gui_rc=0
  /usr/bin/timeout --signal=TERM --kill-after=5s 30s /bin/bash "$GITHUB_WORKSPACE/support/diagnostics/1054-linux-kvm/gui.sh" cleanup "$OUT/install" 30 || gui_rc=$?
  printf 'gui_cleanup_exit=%s\n' "$gui_rc"
  [[ "$gui_rc" == 0 ]] || result=2
fi
for stage in "${STAGES[@]}"; do
  manifest="$OUT/$stage"
  [[ ! -f "$manifest/qemu-cleanup-confirmed.txt" ]] || continue
  [[ -f "$manifest/qemu-pgid.txt" ]] || continue
  if [[ ! -f "$manifest/qemu-root-pid.txt" ]]; then
    group="$(cat "$manifest/qemu-pgid.txt")"
    [[ "$group" =~ ^[1-9][0-9]+$ ]] || { result=2; continue; }
    if ps -eo pgid= | tr -d ' ' | grep -Fxq "$group"; then
      printf 'cleanup_refused_pending_root_manifest stage=%s group=%s\n' "$stage" "$group"
      result=2
    else
      printf 'launcher_already_gone_no_root_manifest stage=%s group=%s\n' "$stage" "$group"
    fi
    continue
  fi
  group="$(cat "$manifest/qemu-pgid.txt")"; pid="$(cat "$manifest/qemu-root-pid.txt")"
  [[ "$group" =~ ^[1-9][0-9]+$ && "$pid" =~ ^[1-9][0-9]+$ && "$group" -gt 1 && "$pid" -gt 1 ]] || { result=2; continue; }
  # Root rechecks /proc immediately before both signals, requiring this exact
  # VM's executable, group and private media/serial boundary. Missing PID is
  # already stopped; a reused/mismatched PID is a refused cleanup, never killed.
  rc=0
  sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 25s /bin/bash -c '
    set -euo pipefail
    pid=$1; group=$2; private=$3; stage=$4
    owned() {
      [[ -e /proc/$pid/exe ]] || return 3
      [[ "$(readlink /proc/$pid/exe)" == /usr/bin/qemu-system-x86_64 ]] || return 2
      [[ "$(ps -o pgid= -p "$pid" | tr -d " ")" == "$group" ]] || return 2
      boundary="file=$private/windows.qcow2,format=qcow2,if=ide,index=0"
      [[ "$stage" != firmware ]] || boundary="file:$private/firmware-serial.txt"
      tr "\0" "\n" < "/proc/$pid/cmdline" | grep -Fxq -- "$boundary" || return 2
    }
    rc=0; owned || rc=$?
    if [[ "$rc" == 3 ]]; then echo "owned_qemu_already_gone pid=$pid group=$group"; exit 0; fi
    [[ "$rc" == 0 ]] || { echo "refused_unowned_qemu pid=$pid group=$group"; exit 2; }
    kill -TERM -- "-$group"
    for attempt in {1..50}; do [[ -e /proc/$pid ]] || { echo "owned_qemu_TERM_stopped pid=$pid group=$group"; exit 0; }; sleep 0.1; done
    rc=0; owned || rc=$?
    [[ "$rc" != 3 ]] || exit 0
    [[ "$rc" == 0 ]] || exit 2
    kill -KILL -- "-$group"
    for attempt in {1..50}; do [[ -e /proc/$pid ]] || { echo "owned_qemu_KILL_stopped pid=$pid group=$group"; exit 0; }; sleep 0.1; done
    echo "owned_qemu_stop_unconfirmed pid=$pid group=$group"; exit 2
  ' issue1054-cleanup "$pid" "$group" "$PRIVATE" "$stage" || rc=$?
  printf 'cleanup_stage=%s pid=%s group=%s exit=%s\n' "$stage" "$pid" "$group" "$rc"
  [[ "$rc" != 0 ]] || printf 'confirmed_stopped pid=%s group=%s\n' "$pid" "$group" > "$manifest/qemu-cleanup-confirmed.txt"
  [[ "$rc" == 0 ]] || result=2
done
# Do not unlink mounted VM media while ownership/stopping is unconfirmed.
if [[ "$result" == 0 && "$KEEP_PRIVATE" == false && -d "$PRIVATE" ]]; then
  sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=5s 60s /bin/rm -rf -- "$PRIVATE" || result=2
fi
printf 'private_removed=%s cleanup_end=%s exit=%s\n' "$([[ ! -e "$PRIVATE" ]] && echo true || echo false)" "$(date -u --iso-8601=seconds)" "$result"
exit "$result"
