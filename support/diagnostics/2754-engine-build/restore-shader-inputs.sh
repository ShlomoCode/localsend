#!/usr/bin/env bash
# Restore omitted, verbatim source-copy inputs from the exact engine revision.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cloud_only
[[ $# == 3 ]] || { echo "Usage: $0 PINNED_FLUTTER_CHECKOUT ENGINE_OUTPUT PROVENANCE" >&2; exit 2; }
checkout=$(temporary_path "$1")
release=$(temporary_path "$2")
records=$(realpath "$3")
[[ $(git -C "$checkout" rev-parse HEAD) == "$FRAMEWORK_SHA" ]]
[[ -d "$release" && ! -e "$release/shader_lib" ]]
mkdir -p "$records"
git -C "$checkout" fetch --depth=1 origin "$ENGINE_SHA"
[[ $(git -C "$checkout" rev-parse 'FETCH_HEAD^{commit}') == "$ENGINE_SHA" ]]
shader_source=engine/src/flutter/impeller/compiler/shader_lib
for target in group flutter impeller; do
  source_path="$shader_source/BUILD.gn"
  [[ $target == group ]] || source_path="$shader_source/$target/BUILD.gn"
  git -C "$checkout" show "$ENGINE_SHA:$source_path" > "$records/$target-BUILD.gn"
done
(
  cd "$records"
  printf '%s\n' \
    'dc85806b31527a04ad79922833397d8a024fc53f2f1e9dfc981fc00726b2ff2d  group-BUILD.gn' \
    '7ff58501ef0d85325fb8a3741b1576a0d4daa47f11cb6b78d2194a3cd953f5bd  flutter-BUILD.gn' \
    '66277f7b9a2485554c41b6648bf4185b9acdc1ffd002e3c922cb01a6954ffd35  impeller-BUILD.gn' \
    | tee target-definitions-SHA256SUMS | sha256sum -c -
)
# These exact targets declare COPY operations with source_file_part destinations.
# The pinned definitions above are the authority for this closed input list.
shader_files=(flutter/runtime_effect.glsl
  impeller/blending.glsl impeller/branching.glsl impeller/color.glsl
  impeller/conical_gradient_uniform_fill.glsl impeller/constants.glsl
  impeller/conversions.glsl impeller/dithering.glsl impeller/external_texture_oes.glsl
  impeller/gaussian.glsl impeller/gradient.glsl impeller/math.glsl impeller/path.glsl
  impeller/texture.glsl impeller/tile_mode.glsl impeller/transform.glsl impeller/types.glsl)
mkdir -p "$release/shader_lib/flutter" "$release/shader_lib/impeller"
: > "$records/source-blobs.tsv"
for file in "${shader_files[@]}"; do
  git -C "$checkout" show "$ENGINE_SHA:$shader_source/$file" > "$release/shader_lib/$file"
  blob=$(git -C "$checkout" rev-parse "$ENGINE_SHA:$shader_source/$file")
  [[ $(git -C "$checkout" hash-object "$release/shader_lib/$file") == "$blob" ]]
  printf '%s\t%s\t%s\n' "$blob" "$shader_source/$file" "shader_lib/$file" >> "$records/source-blobs.tsv"
done
(cd "$release" && find shader_lib -type f -print0 | sort -z | xargs -0 sha256sum) > "$records/staged-files-SHA256SUMS"
[[ $(wc -l < "$records/staged-files-SHA256SUMS") == 17 ]]
(cd "$release" && sha256sum -c "$records/staged-files-SHA256SUMS")
jq -n --arg engine "$ENGINE_SHA" --arg framework "$FRAMEWORK_SHA" \
  --arg files_hash "$(sha256sum "$records/staged-files-SHA256SUMS" | awk '{print $1}')" \
  --arg blobs_hash "$(sha256sum "$records/source-blobs.tsv" | awk '{print $1}')" \
  --arg targets_hash "$(sha256sum "$records/target-definitions-SHA256SUMS" | awk '{print $1}')" \
  '{engine_sha:$engine,framework_sha:$framework,operation:"restore omitted official verbatim COPY inputs",
    official_targets:["flutter/impeller/compiler/shader_lib/flutter","flutter/impeller/compiler/shader_lib/impeller"],
    file_count:17,staged_files_sha256:$files_hash,source_blobs_sha256:$blobs_hash,target_definitions_sha256:$targets_hash,
    original_engine_archive_modified:false,engine_binary_modified:false}' > "$records/manifest.json"
