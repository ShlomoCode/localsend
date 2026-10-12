#!/usr/bin/env bash
# Cloud-only, debug data extraction; never installs or runs a fetched binary.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux && ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 ]] || exit 8
out=${1:?Usage: prepare-root-name-symbols-host.sh OUTPUT_DIR [SELECTED_A_PACKAGE_DIR]}
bridge_package=${2:-}
mkdir -p "$out/records" "$out/transfer/.build-id"
out=$(realpath "$out")
trap 'status=$?; printf "preparation_exit_status=%s\n" "$status" > "$out/records/exit-status.txt"' EXIT
printf '{"status":"incomplete","reason":"Host symbol preparation did not finish; no VM/UI may start."}\n' > "$out/result.json"
manifest=$out/transfer/manifest.tsv
printf 'package\tversion\truntime_path\truntime_sha256\tbuild_id\tdebug_sha256\tdebug_relative_path\trequired\n' > "$manifest"

qualify_debug() {
 local label=$1 debug=$2
 shift 2
 local commands=$out/records/$label-types.gdb
 {
  printf 'set pagination off\nset confirm off\nset auto-load off\nset debuginfod enabled off\nset may-call-functions off\n'
  printf 'symbol-file %s\npython\nimport gdb\n' "$debug"
  printf 'required = %s\n' "$1"
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
  > "$out/records/$label-types.stdout" 2> "$out/records/$label-types.stderr"
 grep -qx TYPE_GATE_PASSED "$out/records/$label-types.stdout"
}

stage_package() {
 local label=$1 package=$2 version=$3 url=$4 package_sha=$5 build_id=$6 debug_sha=$7 runtime=$8 runtime_sha=$9
 local archive=$out/records/$label.ddeb status=0
 printf '%s\n' "$url" > "$out/records/$label-url.txt"
 curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 90 \
  --max-filesize 33554432 --output "$archive.partial" --write-out 'http_code=%{http_code}\nsize_download=%{size_download}\nurl_effective=%{url_effective}\n' \
  "$url" > "$out/records/$label-download.txt" 2> "$out/records/$label-download.stderr" || status=$?
 printf 'curl_exit_status=%s\n' "$status" >> "$out/records/$label-download.txt"
 if [[ -f $archive.partial ]]; then
  wc -c < "$archive.partial" > "$out/records/$label-package-bytes.txt"
  sha256sum "$archive.partial" > "$out/records/$label-package.sha256"
 fi
 [[ $status == 0 ]]
 [[ $(sha256sum "$archive.partial" | awk '{print $1}') == "$package_sha" ]]
 mv "$archive.partial" "$archive"
 timeout --kill-after=2s 10s dpkg-deb --info "$archive" > "$out/records/$label-control.txt"
 [[ $(dpkg-deb -f "$archive" Package) == "$package" && $(dpkg-deb -f "$archive" Version) == "$version" &&
    $(dpkg-deb -f "$archive" Architecture) == amd64 ]]
 timeout --kill-after=2s 30s dpkg-deb -x "$archive" "$out/records/$label-extracted"
 local relative=.build-id/${build_id:0:2}/${build_id:2}.debug
 local debug=$out/records/$label-extracted/usr/lib/debug/$relative
 readelf -n "$debug" > "$out/records/$label-debug-notes.txt"
 sha256sum "$debug" > "$out/records/$label-debug.sha256"
 [[ $(awk '/Build ID:/ {print $3; exit}' "$out/records/$label-debug-notes.txt") == "$build_id" &&
    $(sha256sum "$debug" | awk '{print $1}') == "$debug_sha" ]]
 mkdir -p "$out/transfer/.build-id/${build_id:0:2}"
 cp "$debug" "$out/transfer/$relative"
 printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t1\n' "$package" "$version" "$runtime" "$runtime_sha" "$build_id" "$debug_sha" "$relative" >> "$manifest"
}

stage_package atspi libatspi2.0-0t64-dbgsym 2.52.0-1build1 \
 https://launchpad.net/ubuntu/+source/at-spi2-core/2.52.0-1build1/+build/28034835/+files/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb \
 6be64cf137f649471785d44e373e4fba5f6e79598ebca9289f8c13f9e7d4c16b d53e3f4bf82655a42a0cb86c25416fd443ee76c6 \
 dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9 \
 /usr/lib/x86_64-linux-gnu/libatspi.so.0.0.1 4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141
stage_package dbus libdbus-1-3-dbgsym 1.14.10-4ubuntu4.1 \
 https://launchpad.net/ubuntu/+source/dbus/1.14.10-4ubuntu4.1/+build/28726865/+files/libdbus-1-3-dbgsym_1.14.10-4ubuntu4.1_amd64.ddeb \
 3ba3c5094950d8913a56267f4f8ff13fd3d1000af44b2bdd8678119abc0928fe 47829078e4267099473c6cf5f5742f16ccb2644d \
 f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899 \
 /usr/lib/x86_64-linux-gnu/libdbus-1.so.3.32.4 a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413
qualify_debug atspi "$out/transfer/.build-id/d5/3e3f4bf82655a42a0cb86c25416fd443ee76c6.debug" \
 "[('SpiReentrantCallClosure', 8, ['reply'])]"
qualify_debug dbus "$out/transfer/.build-id/47/829078e4267099473c6cf5f5742f16ccb2644d.debug" \
 "[('DBusConnection', 264, ['dispatch_cond', 'io_path_cond', 'transport']), ('DBusCondVar', 48, ['cond']), ('DBusTransport', 144, ['vtable']), ('DBusTransportSocket', 232, ['fd']), ('DBusTransportVTable', 56, ['get_socket_fd']), ('DBusMessage', 184, ['header', 'body']), ('DBusPendingCall', 72, ['reply', 'reply_serial', 'completed']), ('DBusRealString', 24, ['str', 'len'])]"

# Optional retained A symbols: absence/mismatch is explicit and cannot weaken the required gate.
printf 'optional_bridge_status=absent\n' > "$out/records/bridge-status.txt"
if [[ -n $bridge_package ]]; then
 # The selected package directory is build/candidate; retained debug products
 # live in its sibling build/work, not in the installable candidate directory.
 bridge_archive=$bridge_package/../work/libatk-bridge2.0-0t64-dbgsym_2.52.0-1build1+localsend2754.1_amd64.ddeb
 printf 'optional_bridge_status=archive-absent-or-symlink\n' > "$out/records/bridge-status.txt"
 if [[ -f $bridge_archive && ! -L $bridge_archive ]]; then
  printf 'optional_bridge_status=archive-qualification-incomplete\n' > "$out/records/bridge-status.txt"
  bridge_bytes=$(stat -c %s "$bridge_archive")
  printf '%s\n' "$bridge_bytes" > "$out/records/bridge-package-bytes.txt"
  [[ $bridge_bytes =~ ^[0-9]+$ && $bridge_bytes -gt 0 && $bridge_bytes -le 33554432 ]]
  sha256sum "$bridge_archive" > "$out/records/bridge-package.sha256"
  dpkg-deb --info "$bridge_archive" > "$out/records/bridge-control.txt"
  # Rebuilt archive metadata varies; retain its hash as provenance. Exact
  # debug bytes/Build ID and the selected runtime bytes remain identity gates.
  printf 'optional_bridge_status=control-mismatch-or-extraction-failed\n' > "$out/records/bridge-status.txt"
  if [[ $(dpkg-deb -f "$bridge_archive" Package) == libatk-bridge2.0-0t64-dbgsym &&
        $(dpkg-deb -f "$bridge_archive" Version) == 2.52.0-1build1+localsend2754.1 &&
        $(dpkg-deb -f "$bridge_archive" Architecture) == amd64 ]] &&
     timeout --kill-after=2s 30s dpkg-deb -x "$bridge_archive" "$out/records/bridge-extracted"; then
   bridge_debug=$out/records/bridge-extracted/usr/lib/debug/.build-id/c8/8dc5ceb3f29cb6dfbeee30473e90e846e2e4d2.debug
   printf 'optional_bridge_status=debug-file-absent\n' > "$out/records/bridge-status.txt"
   if [[ -f $bridge_debug ]]; then
    printf 'optional_bridge_status=debug-identity-mismatch-or-inspection-failed\n' > "$out/records/bridge-status.txt"
    readelf -n "$bridge_debug" > "$out/records/bridge-debug-notes.txt"
    sha256sum "$bridge_debug" > "$out/records/bridge-debug.sha256"
    if [[ $(sha256sum "$bridge_debug" | awk '{print $1}') == c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b &&
          $(awk '/Build ID:/ {print $3; exit}' "$out/records/bridge-debug-notes.txt") == c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2 ]]; then
     bridge_path=$(jq -er .bridge_path "$bridge_package/manifest.json")
     bridge_sha=$(jq -er .bridge_sha256 "$bridge_package/manifest.json")
     printf 'optional_bridge_status=selected-runtime-identity-incomplete\n' > "$out/records/bridge-status.txt"
     [[ $bridge_path == /usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0.0.0 &&
        $bridge_sha == a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297 ]]
     mkdir -p "$out/transfer/.build-id/c8"
     cp "$bridge_debug" "$out/transfer/.build-id/c8/8dc5ceb3f29cb6dfbeee30473e90e846e2e4d2.debug"
     printf 'libatk-bridge2.0-0t64-dbgsym\t2.52.0-1build1+localsend2754.1\t%s\t%s\tc88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2\tc8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b\t.build-id/c8/8dc5ceb3f29cb6dfbeee30473e90e846e2e4d2.debug\t0\n' "$bridge_path" "$bridge_sha" >> "$manifest"
     printf 'optional_bridge_status=staged-pending-mapped-identity\n' > "$out/records/bridge-status.txt"
    fi
   fi
  fi
 fi
fi
(cd "$out/transfer" && sha256sum manifest.tsv > manifest.sha256)
printf '{"status":"required-symbols-verified","scope":"static-no-inferior","optional_bridge":"see records/bridge-status.txt"}\n' > "$out/result.json"
