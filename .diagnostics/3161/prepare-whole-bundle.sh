#!/usr/bin/env bash
# Cloud host only. Transport complete approved source bundles, never engine overlays.
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 ACCEPTED_DESCRIPTOR control|B OUTPUT_DIR" >&2; exit 2; }
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]]
descriptor=$(realpath "$1")
variant=$2
[[ $variant == control || $variant == B ]]
[[ ! -e $3 ]]
mkdir -p "$3"
output=$(realpath "$3")
jq -e --arg v "$variant" '
  .schema == 1 and .root_accepted == true and .repository == "ShlomoCode/localsend" and
  (.app_build_run_id | test("^[1-9][0-9]*$")) and
  ([.source_sha,.framework_sha,.engine_sha] | all(test("^[a-f0-9]{40}$"))) and
  (.variants[$v].artifact_id | type == "number") and
  (.variants[$v].artifact_name | type == "string" and length > 0) and
  ([.variants[$v] | .bundle_sha256,.engine_so_sha256,.libapp_sha256,.manifest_sha256] |
    all(type == "string" and test("^[a-f0-9]{64}$")))' "$descriptor"
cp "$descriptor" "$output/accepted-descriptor.json"
artifact_id=$(jq -r --arg v "$variant" '.variants[$v].artifact_id' "$descriptor")
artifact_name=$(jq -r --arg v "$variant" '.variants[$v].artifact_name' "$descriptor")
run=$(jq -r .app_build_run_id "$descriptor")
gh api "repos/ShlomoCode/localsend/actions/artifacts/$artifact_id" > "$output/artifact-metadata.json"
jq -e --arg name "$artifact_name" --arg run "$run" --argjson id "$artifact_id" '
  .id == $id and .name == $name and .expired == false and
  (.workflow_run.id | tostring) == $run' "$output/artifact-metadata.json"
gh run download "$run" --repo ShlomoCode/localsend --name "$artifact_name" --dir "$output/artifact"
artifact="$output/artifact"
manifest="$artifact/provenance/manifest.json"
[[ $(sha256sum "$manifest" | awk '{print $1}') == $(jq -r --arg v "$variant" '.variants[$v].manifest_sha256' "$descriptor") ]]
jq -e --arg v "$variant" --slurpfile d "$descriptor" '
  .variant == $v and .runtime_mode == "release" and .build_validation_status == "pass" and
  .app_build_run_id == $d[0].app_build_run_id and
  .localsend_sha == $d[0].source_sha and .framework_sha == $d[0].framework_sha and
  .engine_sha == $d[0].engine_sha and
  .bundle_sha256 == $d[0].variants[$v].bundle_sha256 and
  .engine_so_sha256 == $d[0].variants[$v].engine_so_sha256 and
  .libapp_sha256 == $d[0].variants[$v].libapp_sha256' "$manifest"
archive="$artifact/source-bundle.tar.gz"
[[ $(sha256sum "$archive" | awk '{print $1}') == $(jq -r .bundle_sha256 "$manifest") ]]
(cd "$artifact" && sha256sum -c source-bundle.tar.gz.sha256)
tar -tzf "$archive" > "$output/archive-members.txt"
# Fail visibly on unexpected archive structure instead of normalizing it.
awk '/^\// || /(^|\/)\.\.(\/|$)/ {exit 1}' "$output/archive-members.txt"
tar -tvzf "$archive" > "$output/archive-details.txt"
awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {exit 1}' "$output/archive-details.txt"
mkdir "$output/bundle"
tar --no-same-owner -xzf "$archive" -C "$output/bundle"
(cd "$output/bundle" && sha256sum -c "$artifact/provenance/bundle-files-SHA256SUMS")
(cd "$output/bundle" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$output/extracted-files-SHA256SUMS"
cmp "$output/extracted-files-SHA256SUMS" "$artifact/provenance/bundle-files-SHA256SUMS"
[[ -x "$output/bundle/localsend_app" && -f "$output/bundle/lib/librust_lib_localsend_app.so" ]]
sha256sum "$output/bundle/localsend_app" "$output/bundle/lib/libapp.so" \
  "$output/bundle/lib/libflutter_linux_gtk.so" > "$output/core-files-SHA256SUMS"
readelf -h -d -n "$output/bundle/localsend_app" > "$output/app-elf.txt"
readelf -h -d -n "$output/bundle/lib/libflutter_linux_gtk.so" > "$output/engine-elf.txt"
date -u +%FT%T.%N > "$output/prepared-at.txt"
printf 'Complete approved %s source bundle verified. Guest loading and UI are still pending.\n' "$variant" > "$output/result.txt"
