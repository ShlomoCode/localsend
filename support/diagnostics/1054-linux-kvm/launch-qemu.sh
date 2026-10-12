#!/usr/bin/env bash
# The unprivileged Ruby supervisor starts this fixed launcher with pgroup:true.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend && ${ISSUE1054_HOST:-} == linux ]] || exit 2
PRIVATE="${PRIVATE_DIR:?}"
OUT="${EVIDENCE_DIR:?}"
MODE="${1:-windows}"
[[ "$MODE" == windows || "$MODE" == firmware ]] || exit 2
SUBDIR=install
[[ "$MODE" != firmware ]] || SUBDIR=firmware
[[ "$PRIVATE" == "${RUNNER_TEMP:?}/issue1054-linux-private" && "$OUT" == "${GITHUB_WORKSPACE:?}/evidence/1054-linux-kvm/$SUBDIR" ]] || exit 2
[[ -d "$PRIVATE" && "$(stat -c %a "$PRIVATE")" == 700 && -d "$OUT" ]] || exit 2
if [[ "$MODE" == windows ]]; then
  for media in windows.iso windows.qcow2 seed.iso; do [[ -f "$PRIVATE/$media" && ! -L "$PRIVATE/$media" ]] || exit 2; done
fi
GROUP="$(ps -o pgid= -p $$ | tr -d ' ')"
[[ "$GROUP" == "$$" ]] || { echo 'Launcher must own its process group'; exit 2; }
printf '%s\n' "$GROUP" > "$OUT/qemu-pgid.txt"
printf '%s\n' "$$" > "$OUT/qemu-launcher-pid.txt"
# timeout --foreground inherits Ruby's process group. Root shell records its PID
# then execs QEMU, preserving the exact PID used by guarded cleanup.
LIMIT=2400s
[[ "$MODE" != firmware ]] || LIMIT=25s
exec sudo -n -- /usr/bin/timeout --foreground --signal=TERM --kill-after=5s "$LIMIT" \
  /bin/bash -c '
    set -euo pipefail
    private=$1; out=$2; group=$3; mode=$4
    [[ "$(ps -o pgid= -p $$ | tr -d " ")" == "$group" ]] || exit 2
    printf "%s\n" "$$" > "$out/qemu-root-pid.txt"
    media=()
    serial="$private/firmware-serial.txt"
    if [[ "$mode" == windows ]]; then
      media=(-drive "file=$private/windows.qcow2,format=qcow2,if=ide,index=0"
        -drive "file=$private/windows.iso,media=cdrom,if=ide,index=2,readonly=on"
        -drive "file=$private/seed.iso,media=cdrom,if=ide,index=3,readonly=on" -boot order=c,once=d)
      serial="$out/guest-serial.txt"
    fi
    command=(/usr/bin/qemu-system-x86_64 -machine pc -accel kvm -cpu host -smp 2 -m 4096 "${media[@]}"
      -netdev user,id=net0 -device e1000,netdev=net0,id=nic0,mac=52:54:00:12:34:56
      -qmp tcp:127.0.0.1:4444,server=on,wait=off -S -vga std
      -usb -device usb-tablet -display none -vnc 127.0.0.1:1,share=force-shared -serial "file:$serial")
    printf "%q " "${command[@]}" > "$out/root-qemu-command.txt"
    printf "\n" >> "$out/root-qemu-command.txt"
    exec "${command[@]}"
  ' issue1054-qemu "$PRIVATE" "$OUT" "$GROUP" "$MODE"
