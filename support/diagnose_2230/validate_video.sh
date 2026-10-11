#!/usr/bin/env bash
# Execute in the cloud after the recorder exits. Preserve the untouched MP4.
set -uo pipefail
out=${1:?Usage: validate_video.sh caseReceiverEvidenceDir}
video="$out/continuous.mp4"
started=$(date -u --iso-8601=ns)
status=failed
reason=missing_video
finish() {
  printf 'utc_started\tutc_finished\tstatus\treason\n%s\t%s\t%s\t%s\n' \
    "$started" "$(date -u --iso-8601=ns)" "$status" "$reason" > "$out/video-validation.tsv"
}
trap finish EXIT
[[ -s "$video" ]] || exit 1
# Each stage has its own retained command exit status, including timeout=124.
timeout 10 sha256sum "$video" > "$out/continuous.mp4.sha256" 2> "$out/video-hash.log"
rc=$?; printf '%s\n' "$rc" > "$out/video-hash.exit"
[[ "$rc" == 0 ]] || { reason=hash_failed; exit 1; }
timeout 15 ffprobe -v error -show_format -show_streams -of json "$video" \
  > "$out/video-metadata.json" 2> "$out/video-metadata.log"
rc=$?; printf '%s\n' "$rc" > "$out/video-metadata.exit"
[[ "$rc" == 0 && ! -s "$out/video-metadata.log" ]] || { reason=metadata_failed; exit 1; }
timeout 15 ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video" \
  > "$out/video-duration.txt" 2> "$out/video-duration.log"
rc=$?; printf '%s\n' "$rc" > "$out/video-duration.exit"
[[ "$rc" == 0 && ! -s "$out/video-duration.log" ]] || { reason=duration_probe_failed; exit 1; }
awk 'NR==1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ && $1>0 {valid=1} END{exit !valid}' "$out/video-duration.txt" || {
  reason=nonpositive_duration; exit 1;
}
# Retain every decoded frame's original timestamp; do not change timing.
timeout 45 ffprobe -v error -select_streams v:0 -show_frames \
  -show_entries frame=best_effort_timestamp_time -of csv=p=0 "$video" \
  > "$out/video-frame-pts.csv" 2> "$out/video-frame-pts.log"
rc=$?; printf '%s\n' "$rc" > "$out/video-frame-pts.exit"
[[ "$rc" == 0 && ! -s "$out/video-frame-pts.log" ]] || { reason=frame_probe_failed; exit 1; }
awk -F ',' '
  $1 ~ /^-?[0-9]+([.][0-9]+)?$/ {
    t=$1+0; if(n==0) first=t; else if(t<=last) bad=1; last=t; n++;
  }
  END {
    print "frame_count\tfirst_pts_seconds\tlast_pts_seconds\tpts_span_seconds\tstrictly_increasing";
    printf "%d\t%.6f\t%.6f\t%.6f\t%s\n",n,first,last,last-first,bad?"false":"true";
    exit(n<2 || last<=first || bad);
  }' "$out/video-frame-pts.csv" > "$out/video-frame-summary.tsv" || {
  reason=invalid_frame_timestamps; exit 1;
}
timeout 60 ffmpeg -nostdin -v error -xerror -i "$video" -map 0:v:0 -f null - \
  > "$out/video-decode.stdout" 2> "$out/video-decode.log"
rc=$?; printf '%s\n' "$rc" > "$out/video-decode.exit"
[[ "$rc" == 0 && ! -s "$out/video-decode.log" ]] || { reason=full_decode_failed; exit 1; }
status=passed
reason=metadata_timestamps_and_full_decode_verified
