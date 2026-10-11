#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == ShlomoCode/localsend ]]
gal_repository="$(realpath "${1:?Gal repository required}")"
gal_commit="${2:?Full immutable Gal commit required}"
plugin_hash="${3:?Expected GalPlugin.java SHA-256 required}"
gradle_wrapper="$(realpath "${4:?Provisioned Gradle wrapper required}")"
evidence="$(realpath -m "${5:?Evidence directory required}")"
module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$gal_commit" =~ ^[0-9a-f]{40}$ && "$plugin_hash" =~ ^[0-9a-f]{64}$ ]]
mkdir -p "$evidence" "$module/src/main/java/studio/midoridesign/gal"
exec > >(tee "$evidence/component-run.log") 2>&1
git -C "$gal_repository" cat-file -e "$gal_commit^{commit}"
source_path=android/src/main/java/studio/midoridesign/gal/GalPlugin.java
plugin_source="$module/src/main/java/studio/midoridesign/gal/GalPlugin.java"
# Copy the immutable blob verbatim into the disposable diagnostic module.
# Production sources and the original checkout are never modified.
git -C "$gal_repository" show "$gal_commit:$source_path" > "$plugin_source"
printf '%s  %s\n' "$plugin_hash" "$plugin_source" | sha256sum --check --strict
cp "$plugin_source" "$evidence/GalPlugin.java"
git -C "$gal_repository" show "$gal_commit:LICENSE" > "$evidence/GAL-LICENSE"
printf 'gal_commit=%s\ngal_plugin_sha256=%s\nevidence_level=controlled-provider Robolectric component checks\nruntime=SDK29 shadow API with real host file timestamps and bytes\nlimitations=no real Android MediaProvider/scanner/Flutter engine or Android device race coverage\n' "$gal_commit" "$plugin_hash" > "$evidence/component-identity.txt"
java -version > "$evidence/java-version.txt" 2>&1
"$gradle_wrapper" --version > "$evidence/gradle-version.txt"
finish(){
  local status=$?
  printf '%s  %s\n' "$plugin_hash" "$plugin_source" | sha256sum --check --strict || status=1
  for directory in test-results reports; do
    if [[ -d "$module/build/$directory" ]]; then cp -R "$module/build/$directory" "$evidence/$directory"; fi
  done
  printf 'component_command_exit=%s\n' "$status" >> "$evidence/component-identity.txt"
  exit "$status"
}
trap finish EXIT
"$gradle_wrapper" -p "$module" --no-daemon --console=plain testDebugUnitTest
