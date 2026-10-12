#!/bin/bash
# Transport-only helper. The host must wrap this entire script in timeout 600s.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  printf 'usage: %s ISO_URL OUTPUT_ISO EVIDENCE_DIR\n' "$0" >&2
  exit 2
fi
iso_url=$1
output_iso=$2
evidence_dir=$3
official_url=https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso
total=5387960320
part_length=1346990080
etag='"0xB860EC49C4DEA6FEE22EF0D213FA02C0E2900CBA3E1F73C5E5E64D60B958EED0"'
if [ "$iso_url" != "$official_url" ]; then
  printf 'unexpected_windows_iso_url\n' >&2
  exit 2
fi
# curl config values are quoted, with literal quotes and backslashes escaped.
# Reject control characters rather than allowing config-line injection.
for value in "$output_iso" "$evidence_dir"; do
  if [[ "$value" != /* || "$value" =~ [[:cntrl:]] ]]; then
    printf 'expected_absolute_path_without_control_characters\n' >&2
    exit 2
  fi
done
if [ -e "$output_iso" ] || [ -L "$output_iso" ]; then
  printf 'output_iso_already_exists\n' >&2
  exit 2
fi
test -d "$(dirname "$output_iso")"
mkdir -p "$evidence_dir"
work_dir=$(mktemp -d "$(dirname "$output_iso")/.2884-iso-ranges.XXXXXXXX")
stage=prepare_ranges
cleanup() {
  status=$?
  trap - EXIT
  printf 'stage=%s exit=%s\n' "$stage" "$status" > "$evidence_dir/windows-iso-range-result.txt"
  # Only files in this helper's freshly created directory are removed.
  timeout --signal=TERM --kill-after=1s 5s rm -rf -- "$work_dir" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
config_value() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}
config="$work_dir/ranges.curl"
printf 'part\tstart\tend\texpected_bytes\ttotal_bytes\tetag\n' > "$evidence_dir/windows-iso-range-manifest.tsv"
for part in 0 1 2 3; do
  start=$((part * part_length))
  end=$((start + part_length - 1))
  header="$evidence_dir/windows-iso-range-$part-headers.txt"
  body="$work_dir/part-$part"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$part" "$start" "$end" "$part_length" "$total" "$etag" >> "$evidence_dir/windows-iso-range-manifest.tsv"
  {
    if [ "$part" -ne 0 ]; then printf 'next\n'; fi
    printf 'fail\nlocation\nconnect-timeout = 15\nmax-time = 550\n'
    printf 'max-filesize = %s\n' "$part_length"
    printf 'proto = "=https"\nproto-redir = "=https"\n'
    printf 'url = '; config_value "$iso_url"; printf '\n'
    printf 'range = "%s-%s"\n' "$start" "$end"
    printf 'header = '; config_value "If-Range: $etag"; printf '\n'
    printf 'dump-header = '; config_value "$header"; printf '\n'
    printf 'output = '; config_value "$body"; printf '\n'
  } >> "$config"
done
stage=parallel_range_download
set +e
timeout --signal=TERM --kill-after=5s 550s \
  curl --disable --fail-early --parallel --parallel-immediate --parallel-max 4 --config "$config" \
  > "$evidence_dir/windows-iso-range-curl-stdout.txt" 2> "$evidence_dir/windows-iso-range-curl-stderr.txt"
curl_status=$?
set -e
printf '%s\n' "$curl_status" > "$evidence_dir/windows-iso-range-curl-exit.txt"
if [ "$curl_status" -ne 0 ]; then exit "$curl_status"; fi
stage=validate_final_range_responses
for part in 0 1 2 3; do
  start=$((part * part_length))
  end=$((start + part_length - 1))
  # Every HTTP status line starts a new response block, including redirects.
  # Only the final block can authorize use of a part body.
  if ! awk -v expected_range="bytes $start-$end/$total" -v expected_length="$part_length" -v expected_etag="$etag" '
    /^HTTP\/[0-9.]+[[:space:]]/ {
      status = $2; range = ""; content_length = ""; etag = "";
      range_count = 0; length_count = 0; etag_count = 0; next
    }
    {
      sub(/\r$/, ""); colon = index($0, ":");
      if (!colon) next;
      key = tolower(substr($0, 1, colon - 1)); value = substr($0, colon + 1);
      sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value);
      if (key == "content-range") { range = value; range_count++ }
      if (key == "content-length") { content_length = value; length_count++ }
      if (key == "etag") { etag = value; etag_count++ }
    }
    END {
      if (status != 206 || range_count != 1 || length_count != 1 || etag_count != 1 ||
          range != expected_range || ("x" content_length) != ("x" expected_length) || etag != expected_etag) exit 1;
    }
  ' "$evidence_dir/windows-iso-range-$part-headers.txt"; then
    printf 'final_range_response_validation_failed part=%s\n' "$part" >&2
    exit 2
  fi
  if [ "$(stat -c %s "$work_dir/part-$part")" -ne "$part_length" ]; then
    printf 'range_body_length_mismatch part=%s\n' "$part" >&2
    exit 2
  fi
done
stage=concatenate_validated_ranges
timeout --signal=TERM --kill-after=5s 30s \
  cat "$work_dir/part-0" "$work_dir/part-1" "$work_dir/part-2" "$work_dir/part-3" > "$work_dir/windows.iso"
if [ "$(stat -c %s "$work_dir/windows.iso")" -ne "$total" ]; then
  printf 'assembled_iso_length_mismatch\n' >&2
  exit 2
fi
mv -- "$work_dir/windows.iso" "$output_iso"
stage=validated_transport_complete
