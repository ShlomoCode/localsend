#!/usr/bin/env bash
# Read only the two SDK cache roots and exact NDK properties; never unpack bytes.
set -euo pipefail
export LC_ALL=C
sdk_root=${1:?SDK root required}
destination=${2:?Evidence destination required}
budget=${3:?Shared byte/file reservation required}
inventory="$destination/inventory.txt"
limit=1048576
metadata_bytes=0
metadata_truncated=0
emit() {
  local line=$1 bytes
  bytes=$((${#line} + 1))
  if [ "$((metadata_bytes + bytes))" -gt "$limit" ]; then
    metadata_truncated=1
    return 0
  fi
  printf '%s\n' "$line" >> "$inventory"
  metadata_bytes=$((metadata_bytes + bytes))
}
mkdir -p "$destination/candidates"
: > "$inventory"
list=$(mktemp "$RUNNER_TEMP/issue1864-ndk-files.XXXXXXXX")
trap 'rm -f "$list"' EXIT
emit 'Scope: SDK .temp, HOME/.android/cache, exact NDK source.properties only. No symlinks followed.'
emit 'Caps: 500 inventory files and 1 MiB inventory text per phase; 1 GiB/file, 2 GiB and 20 candidate reservations across both phases.'
emit 'Every regular cache file is a download candidate, including opaque/non-ZIP bytes. Package attribution is unverified.'
roots=()
for cache_root in "$sdk_root/.temp" "$HOME/.android/cache"; do
  printf -v quoted '%q' "$cache_root"
  if [ "$cache_root" = "$HOME/.android/cache" ] && [ -L "$HOME/.android" ]; then
    emit "root=$quoted status=excluded-symlink-parent"
  elif [ -L "$cache_root" ]; then
    emit "root=$quoted status=excluded-symlink"
  elif [ ! -e "$cache_root" ]; then
    emit "root=$quoted status=missing"
  elif [ ! -d "$cache_root" ]; then
    emit "root=$quoted status=excluded-nondirectory"
  else
    emit "root=$quoted status=present"
    roots+=("$cache_root")
  fi
done
find_status=0
head_status=0
if [ "${#roots[@]}" -gt 0 ]; then
  set +e
  find -P "${roots[@]}" -type f -print0 2> "$destination/find-stderr.txt" | head -z -n 501 > "$list"
  listing_status=("${PIPESTATUS[@]}")
  set -e
  find_status=${listing_status[0]}
  head_status=${listing_status[1]}
fi
emit "find_exit=$find_status head_exit=$head_status (find SIGPIPE can result from the entry cap)"
read -r reserved_bytes reserved_files < "$budget"
[[ "$reserved_bytes" =~ ^[0-9]+$ && "$reserved_files" =~ ^[0-9]+$ ]]
entries=0
copied=0
inventory_truncated=0
while IFS= read -r -d '' path; do
  entries=$((entries + 1))
  if [ "$entries" -gt 500 ]; then
    inventory_truncated=1
    emit 'inventory=truncated-at-500-files; remaining files excluded from this phase'
    break
  fi
  printf -v quoted '%q' "$path"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    emit "path=$quoted status=disappeared-or-nonregular-or-symlink"
    continue
  fi
  if ! details=$(stat --printf='%s %Y' -- "$path"); then
    emit "path=$quoted status=stat-failed"
    continue
  fi
  read -r size mtime <<< "$details"
  emit "path=$quoted bytes=$size mtime_epoch=$mtime"
  if [ "$size" -gt 1073741824 ]; then
    emit "path=$quoted status=excluded-per-file-cap"
    continue
  fi
  if [ "$reserved_files" -ge 20 ]; then
    emit "path=$quoted status=excluded-shared-file-cap"
    continue
  fi
  if [ "$((reserved_bytes + size))" -gt 2147483648 ]; then
    emit "path=$quoted status=excluded-shared-byte-cap"
    continue
  fi
  # Reserve before copying. A timeout may waste a reservation, never exceed it.
  reserved_bytes=$((reserved_bytes + size))
  reserved_files=$((reserved_files + 1))
  printf '%s %s\n' "$reserved_bytes" "$reserved_files" > "$budget.next"
  mv -f -- "$budget.next" "$budget"
  copy="$destination/candidates/candidate-$reserved_files.bin"
  printf -v copy_quoted '%q' "$copy"
  # GNU dd refuses a symlink at open and cannot copy beyond the observed size.
  if dd if="$path" of="$copy" iflag=nofollow,count_bytes count="$size" status=none; then
    copy_status=0
  else
    copy_status=$?
  fi
  copied=$((copied + 1))
  actual_size=$(stat --printf='%s' -- "$copy")
  after_details=$(stat --printf='%s %Y' -- "$path") || after_details=unavailable
  emit "path=$quoted copy=$copy_quoted copy_exit=$copy_status copied_bytes=$actual_size source_after=$after_details"
  if [ "$copy_status" -ne 0 ] || [ "$actual_size" -ne "$size" ] || [ "$after_details" != "$details" ]; then
    emit "copy=$copy_quoted status=partial-or-source-changed; bytes retained without claiming a stable original"
  else
    emit "copy=$copy_quoted status=copied attribution=unverified"
  fi
  if digest=$(sha256sum -- "$copy"); then emit "copy=$copy_quoted sha256=${digest%% *}"; else emit "copy=$copy_quoted sha256=failed"; fi
  if kind=$(file --brief -- "$copy"); then
    printf -v kind_quoted '%q' "$kind"
    emit "copy=$copy_quoted file=$kind_quoted"
  else
    emit "copy=$copy_quoted file=failed"
  fi
  if header=$(od -An -tx1 -N64 -- "$copy"); then
    printf -v header_quoted '%q' "$header"
    emit "copy=$copy_quoted first64bytes_hex=$header_quoted"
  else
    emit "copy=$copy_quoted first64bytes_hex=failed"
  fi
done < "$list"
if [ "$entries" -eq 0 ]; then emit 'inventory=empty; no regular download candidate bytes available in eligible roots'; fi
properties="$sdk_root/ndk/28.2.13676358/source.properties"
printf -v quoted '%q' "$properties"
if [ -L "$sdk_root/ndk" ] || [ -L "$sdk_root/ndk/28.2.13676358" ] || [ -L "$properties" ]; then
  emit "properties=$quoted status=excluded-symlink"
elif [ ! -f "$properties" ]; then
  emit "properties=$quoted status=missing-or-nonregular"
elif details=$(stat --printf='%s %Y' -- "$properties"); then
  emit "properties=$quoted bytes_and_mtime=$details"
  read -r size mtime <<< "$details"
  if [ "$size" -le 1048576 ]; then
    if dd if="$properties" of="$destination/source.properties" iflag=nofollow,count_bytes count="$size" status=none; then
      emit "properties=$quoted status=copied"
      if digest=$(sha256sum -- "$destination/source.properties"); then emit "properties_sha256=${digest%% *}"; fi
    else
      emit "properties=$quoted status=copy-failed-or-partial"
    fi
  else
    emit "properties=$quoted status=excluded-properties-1MiB-cap"
  fi
else
  emit "properties=$quoted status=stat-failed"
fi
printf 'inventory_entries_observed=%s\ninventory_entry_cap_truncated=%s\ninventory_text_bytes=%s\ninventory_text_cap_truncated=%s\ncandidate_copies_attempted=%s\nshared_reserved_bytes=%s\nshared_reserved_files=%s\nfind_exit=%s\nhead_exit=%s\n' \
  "$entries" "$inventory_truncated" "$metadata_bytes" "$metadata_truncated" "$copied" "$reserved_bytes" "$reserved_files" \
  "$find_status" "$head_status" > "$destination/summary.txt"
if [ "$head_status" -ne 0 ]; then exit "$head_status"; fi
if [ "$find_status" -ne 0 ]; then
  # A capped NUL listing can terminate find with SIGPIPE; other failures are partial.
  if [ "$find_status" -ne 141 ] || [ "$inventory_truncated" -ne 1 ]; then exit "$find_status"; fi
fi
