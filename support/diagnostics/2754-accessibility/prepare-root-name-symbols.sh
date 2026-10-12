#!/usr/bin/env bash
# Read-only runtime/debug qualification, only in the authorized Mint VM.
set -euo pipefail
[[ ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 && $(id -un) == mint && -d /proc &&
   -f /home/mint/evidence/bootstrap-complete ]] || exit 8
source /etc/os-release
[[ ${ID:-} == linuxmint ]] || exit 8
out=${1:?Usage: prepare-root-name-symbols.sh TRANSFERRED_DEBUG_DIR}
out=$(realpath "$out")
[[ $out == /home/mint/evidence/root-name-symbols ]]
trap 'status=$?; printf "preparation_exit_status=%s\n" "$status" > "$out/exit-status.txt"' EXIT
printf '{"status":"incomplete","reason":"Required symbol/tool gate did not finish; UI must not start."}\n' > "$out/result.json"
rm -f "$out/strace-verified.txt"
[[ $(cat "$out/manifest.sha256") =~ ^[0-9a-f]{64}[[:space:]][[:space:]]manifest.tsv$ ]]
(cd "$out" && sha256sum -c manifest.sha256) > "$out/manifest-transport-check.txt"
[[ $(head -n 1 "$out/manifest.tsv") == $'package\tversion\truntime_path\truntime_sha256\tbuild_id\tdebug_sha256\tdebug_relative_path\trequired' ]]
[[ $(wc -l < "$out/manifest.tsv") -ge 3 && $(wc -l < "$out/manifest.tsv") -le 4 ]]
printf 'package\telf\tbuild_id\tstatus\tdebug_sha256\n' > "$out/symbols.tsv"
required_count=0
optional_count=0
seen_atspi=0
seen_dbus=0

qualify_debug() {
 local label=$1 debug=$2 inventory=$3
 local commands=$out/$label-types.gdb
 {
  printf 'set pagination off\nset confirm off\nset auto-load off\nset debuginfod enabled off\nset may-call-functions off\n'
  printf 'symbol-file %s\npython\nimport gdb\nrequired = %s\n' "$debug" "$inventory"
  cat <<'GDB'
for name, expected_size, members in required:
    typ = gdb.lookup_type(name).strip_typedefs()
    assert typ.code in (gdb.TYPE_CODE_STRUCT, gdb.TYPE_CODE_UNION), (name, 'not concrete aggregate')
    assert typ.sizeof == expected_size, (name, typ.sizeof, expected_size)
    fields = {field.name for field in typ.fields()}
    assert set(members).issubset(fields), (name, fields, members)
    print('CONCRETE_TYPE', name, 'size', typ.sizeof, 'fields', sorted(str(field) for field in fields))
print('TYPE_GATE_PASSED')
end
quit
GDB
 } > "$commands"
 timeout --kill-after=2s 20s env DEBUGINFOD_URLS= gdb -nx -nh -batch -x "$commands" \
  > "$out/$label-types.stdout" 2> "$out/$label-types.stderr"
 grep -qx TYPE_GATE_PASSED "$out/$label-types.stdout"
}

while IFS=$'\t' read -r package version runtime runtime_sha build_id debug_sha relative required extra; do
 [[ -z $extra && $runtime_sha =~ ^[0-9a-f]{64}$ && $debug_sha =~ ^[0-9a-f]{64}$ && $build_id =~ ^[0-9a-f]{40}$ ]]
 [[ $relative == .build-id/${build_id:0:2}/${build_id:2}.debug ]]
 case $package in
  libatspi2.0-0t64-dbgsym)
   [[ $seen_atspi == 0 && $required == 1 && $version == 2.52.0-1build1 &&
      $runtime == /usr/lib/x86_64-linux-gnu/libatspi.so.0.0.1 &&
      $runtime_sha == 4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141 &&
      $build_id == d53e3f4bf82655a42a0cb86c25416fd443ee76c6 &&
      $debug_sha == dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9 ]]
   seen_atspi=1 ;;
  libdbus-1-3-dbgsym)
   [[ $seen_dbus == 0 && $required == 1 && $version == 1.14.10-4ubuntu4.1 &&
      $runtime == /usr/lib/x86_64-linux-gnu/libdbus-1.so.3.32.4 &&
      $runtime_sha == a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413 &&
      $build_id == 47829078e4267099473c6cf5f5742f16ccb2644d &&
      $debug_sha == f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899 ]]
   seen_dbus=1 ;;
  libatk-bridge2.0-0t64-dbgsym)
   [[ $optional_count == 0 && $required == 0 && $version == 2.52.0-1build1+localsend2754.1 &&
      $runtime == /usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0.0.0 &&
      $build_id == c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2 &&
      $debug_sha == c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b &&
      $runtime_sha == "$(jq -er .bridge_sha256 /home/mint/bridge-package/manifest.json)" ]]
   optional_count=1 ;;
  *) exit 1 ;;
 esac
 debug=$out/$relative
 [[ -f $debug && ! -L $debug && $(realpath "$debug") == "$debug" ]]
 sha256sum "$debug" >> "$out/debug-elf.sha256"
 readelf -n "$debug" > "$out/$package.debug-notes.txt"
 [[ $(sha256sum "$debug" | awk '{print $1}') == "$debug_sha" &&
    $(awk '/Build ID:/ {print $3; exit}' "$out/$package.debug-notes.txt") == "$build_id" ]]
 canonical=$(realpath "$runtime")
 printf '%s\n' "$canonical" > "$out/$package.runtime-path.txt"
 [[ $canonical == "$runtime" && -f $runtime && ! -L $runtime ]]
 runtime_package=${package%-dbgsym}
 dpkg-query -W -f='${Package}\t${Version}\n' "$runtime_package" > "$out/$package.runtime-package.txt"
 dpkg-query -S "$runtime" > "$out/$package.runtime-ownership.txt"
 [[ $(dpkg-query -W -f='${Version}' "$runtime_package") == "$version" ]]
 sha256sum "$runtime" >> "$out/runtime-elf.sha256"
 readelf -n "$runtime" > "$out/$package.runtime-notes.txt"
 [[ $(sha256sum "$runtime" | awk '{print $1}') == "$runtime_sha" &&
    $(awk '/Build ID:/ {print $3; exit}' "$out/$package.runtime-notes.txt") == "$build_id" ]]
 printf '%s\t%s\t%s\tverified\t%s\n' "$runtime_package" "$runtime" "$build_id" "$debug_sha" >> "$out/symbols.tsv"
 if [[ $required == 1 ]]; then required_count=$((required_count + 1)); fi
done < <(tail -n +2 "$out/manifest.tsv")
[[ $required_count == 2 && $seen_atspi == 1 && $seen_dbus == 1 ]]
qualify_debug atspi "$out/.build-id/d5/3e3f4bf82655a42a0cb86c25416fd443ee76c6.debug" \
 "[('SpiReentrantCallClosure', 8, ['reply'])]"
qualify_debug dbus "$out/.build-id/47/829078e4267099473c6cf5f5742f16ccb2644d.debug" \
 "[('DBusConnection', 264, ['dispatch_cond', 'io_path_cond', 'transport']), ('DBusCondVar', 48, ['cond']), ('DBusTransport', 144, ['vtable']), ('DBusTransportSocket', 232, ['fd']), ('DBusTransportVTable', 56, ['get_socket_fd']), ('DBusMessage', 184, ['header', 'body']), ('DBusPendingCall', 72, ['reply', 'reply_serial', 'completed']), ('DBusRealString', 24, ['str', 'len'])]"

# Birth tracer must be the qualified official ELF, not merely a version string.
strace_path=$(realpath "$(command -v strace)")
printf '%s\n' "$strace_path" > "$out/strace-path.txt"
dpkg-query -W -f='${Package}\t${Version}\n' strace > "$out/strace-package.txt"
dpkg-query -S "$strace_path" > "$out/strace-ownership.txt"
sha256sum "$strace_path" > "$out/strace-sha256.txt"
readelf -n "$strace_path" > "$out/strace-notes.txt"
[[ $strace_path == /usr/bin/strace && $(dpkg-query -W -f='${Version}' strace) == 6.8-0ubuntu2 &&
   $(sha256sum "$strace_path" | awk '{print $1}') == 28f957c227012de0b18d1bd7fff2d396cb693ea60ed8013be68de071e84b5001 &&
   $(awk '/Build ID:/ {print $3; exit}' "$out/strace-notes.txt") == 997a6f079008c26efee890fe845f79aa76018ea4 ]]
printf 'strace_identity_verified=true\n' > "$out/strace-verified.txt"
printf '{"status":"required-symbols-verified","scope":"static-no-inferior","optional_bridge":"mapped identity must be requalified per snapshot"}\n' > "$out/result.json"
