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
    for name in prepare supervisor receiver app xvfb wm dbus; do
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
