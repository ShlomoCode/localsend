#!/usr/bin/env bash
# Source-only diagnostic preparation; execute only in the authorized Mint VM.
set -euo pipefail
[[ ${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0} == 1 && $(id -un) == mint && -d /proc &&
   -f /home/mint/evidence/bootstrap-complete ]] || exit 8
source /etc/os-release
[[ ${ID:-} == linuxmint ]] || exit 8
out=${1:?Usage: prepare-root-name-symbols.sh DEBUG_DIR}
mkdir -p "$out/.build-id"
out=$(realpath "$out")
printf '{"status":"incomplete","reason":"Symbol preparation did not finish."}\n' > "$out/result.json"
printf 'package\telf\tbuild_id\tstatus\tdebug_sha256\n' > "$out/symbols.tsv"
dpkg-query -W libatspi2.0-0t64 libdbus-1-3 libgtk-3-0t64 > "$out/runtime-packages.txt" 2>&1 || true
for package in libatspi2.0-0t64 libdbus-1-3 libgtk-3-0t64; do
  if ! dpkg-query -L "$package" > "$out/$package.files" 2> "$out/$package.files.stderr"; then
    printf '%s\t\t\tpackage-unavailable\t\n' "$package" >> "$out/symbols.tsv"
    continue
  fi
  case $package in
    libatspi*) pattern='libatspi\.so\.' ;;
    libdbus*) pattern='libdbus-1\.so\.' ;;
    libgtk*) pattern='libgtk-3\.so\.' ;;
  esac
  while IFS= read -r library; do
    [[ -f $library && ! -L $library ]] || continue
    build_id=$(readelf -n "$library" | awk '/Build ID:/ {print $3; exit}')
    [[ $build_id =~ ^[0-9a-f]{40,}$ ]] || { printf '%s\t%s\t\tmissing-build-id\t\n' "$package" "$library" >> "$out/symbols.tsv"; continue; }
    sha256sum "$library" >> "$out/runtime-elf.sha256"
    target=$out/.build-id/${build_id:0:2}/${build_id:2}.debug
    mkdir -p "$(dirname "$target")"
    status=0
    # Debug data only: no package install, runtime-library replacement, or
    # network fetch at debugger attach. A missing symbol file remains explicit.
    curl --fail --location --connect-timeout 10 --max-time 45 \
      "https://debuginfod.ubuntu.com/buildid/$build_id/debuginfo" -o "$target.partial" \
      > "$out/$package.download.stdout" 2> "$out/$package.download.stderr" || status=$?
    if [[ $status != 0 ]]; then
      printf '%s\t%s\t%s\tdownload-failed-%s\t\n' "$package" "$library" "$build_id" "$status" >> "$out/symbols.tsv"
      continue
    fi
    debug_id=$(readelf -n "$target.partial" 2> "$out/$package.debug-readelf.stderr" | awk '/Build ID:/ {print $3; exit}') || debug_id=''
    if [[ $debug_id != "$build_id" ]]; then
      printf '%s\t%s\t%s\tdebug-build-id-mismatch\t\n' "$package" "$library" "$build_id" >> "$out/symbols.tsv"
      continue
    fi
    mv "$target.partial" "$target"
    printf '%s\t%s\t%s\tverified\t%s\n' "$package" "$library" "$build_id" \
      "$(sha256sum "$target" | cut -d ' ' -f 1)" >> "$out/symbols.tsv"
  done < <(awk -v pattern="$pattern" '$0 ~ /\/(usr\/)?lib\// && $0 ~ pattern' "$out/$package.files")
done
jq -Rn '[inputs | split("\t") | select(.[0] != "package") |
  {package:.[0],elf:.[1],build_id:.[2],status:.[3],debug_sha256:.[4]}] |
  {status:(if ([.[] | select(.package=="libatspi2.0-0t64" or .package=="libdbus-1-3") | .status] | length)==2 and
              ([.[] | select(.package=="libatspi2.0-0t64" or .package=="libdbus-1-3") | .status] | all(.=="verified"))
           then "required-symbols-verified" else "partial" end), symbols:.}' \
  < "$out/symbols.tsv" > "$out/result.json"
# Missing debug information is a recorded limitation, not a runtime mutation.
