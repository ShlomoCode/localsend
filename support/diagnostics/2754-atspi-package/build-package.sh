#!/usr/bin/env bash
# Build the diagnostic bridge through Ubuntu's unchanged Debian build rules.
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 2; }
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend &&
   ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || fail 'Use a GitHub-hosted Actions runner in ShlomoCode/localsend.'
[[ $(uname -m) == x86_64 ]] || fail 'The package gate requires x86_64.'
# shellcheck source=/dev/null
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || fail 'The package gate requires Ubuntu 24.04.'
[[ -z ${LD_PRELOAD:-} && -z ${LD_LIBRARY_PATH:-} && -z ${DEB_BUILD_OPTIONS:-} &&
   -z ${DEB_BUILD_PROFILES:-} ]] || fail 'Loader overrides and build-option/profile overrides are prohibited.'

PACKAGE_OUTPUT=${1:?Usage: build-package.sh OUTPUT_DIR}
mkdir -p "$PACKAGE_OUTPUT"
PACKAGE_OUTPUT=$(realpath "$PACKAGE_OUTPUT")
[[ ! -e $PACKAGE_OUTPUT/work ]] || fail 'Choose a fresh output directory.'
PACKAGE_ASSETS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../2754-atspi-native" && pwd)
PACKAGE_PATCH=$PACKAGE_ASSETS/A-local-dispatch.patch
PACKAGE_VERSION=2.52.0-1build1+localsend2754.1
PACKAGE_TARGET=libatk-bridge2.0-0t64
PACKAGE_BASE=https://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core
PACKAGE_WORK=$PACKAGE_OUTPUT/work
PACKAGE_SOURCE=$PACKAGE_WORK/at-spi2-core-2.52.0
mkdir -p "$PACKAGE_WORK" "$PACKAGE_OUTPUT/official-source" "$PACKAGE_OUTPUT/artifacts" "$PACKAGE_OUTPUT/metadata" "$PACKAGE_OUTPUT/candidate"
exec > >(tee "$PACKAGE_OUTPUT/package-build.log") 2>&1
retain_result() {
  PACKAGE_STATUS=$?
  printf 'exit_status=%s\n' "$PACKAGE_STATUS" > "$PACKAGE_OUTPUT/result.txt"
  if [[ -d $PACKAGE_SOURCE ]]; then
    cp -a "$PACKAGE_SOURCE/debian" "$PACKAGE_OUTPUT/debian-final"
    find "$PACKAGE_SOURCE" -path '*/meson-logs/*' -type f -exec cp --parents '{}' "$PACKAGE_OUTPUT/metadata" \;
  fi
}
trap retain_result EXIT

uname -a > "$PACKAGE_OUTPUT/uname.txt"
cp /etc/os-release "$PACKAGE_OUTPUT/os-release.txt"
dpkg-query -W > "$PACKAGE_OUTPUT/packages-before.tsv"
git rev-parse HEAD > "$PACKAGE_OUTPUT/diagnostic-head.txt"
for PACKAGE_NAME in libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64; do
  [[ $(dpkg-query -W -f='${Version}' "$PACKAGE_NAME") == 2.52.0-1build1 ]] || fail "Baseline version mismatch: $PACKAGE_NAME"
  dpkg-query -s "$PACKAGE_NAME" > "$PACKAGE_OUTPUT/metadata/baseline-$PACKAGE_NAME.control"
  dpkg-query -L "$PACKAGE_NAME" > "$PACKAGE_OUTPUT/metadata/baseline-$PACKAGE_NAME.files"
done
cp "$PACKAGE_PATCH" "$PACKAGE_OUTPUT/A-local-dispatch.patch"
printf '%s  %s\n' d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d "$PACKAGE_PATCH" | sha256sum -c -
sha256sum "$PACKAGE_PATCH" > "$PACKAGE_OUTPUT/patch.sha256"

for PACKAGE_ARCHIVE in at-spi2-core_2.52.0.orig.tar.xz at-spi2-core_2.52.0-1build1.debian.tar.xz at-spi2-core_2.52.0-1build1.dsc; do
  curl --fail --location --retry 3 "$PACKAGE_BASE/$PACKAGE_ARCHIVE" -o "$PACKAGE_OUTPUT/official-source/$PACKAGE_ARCHIVE"
done
(
  cd "$PACKAGE_OUTPUT/official-source"
  printf '%s\n' \
    '0ac3fc8320c8d01fa147c272ba7fa03806389c6b03d3c406d0823e30e35ff5ab  at-spi2-core_2.52.0.orig.tar.xz' \
    '20bda0a6815fb1e7c6ca286a02b4b70aaa706f304664aad30bd88a4ee163b91c  at-spi2-core_2.52.0-1build1.debian.tar.xz' \
    '16b82af63769eefb96343366f34545f2af2de5c3661c83293f50969de7fa450a  at-spi2-core_2.52.0-1build1.dsc' \
    | tee source.sha256 | sha256sum -c -
)
cp "$PACKAGE_OUTPUT/official-source/at-spi2-core_2.52.0.orig.tar.xz" "$PACKAGE_WORK/"
dpkg-source --no-check-signature -x "$PACKAGE_OUTPUT/official-source/at-spi2-core_2.52.0-1build1.dsc" "$PACKAGE_SOURCE"
cp -a "$PACKAGE_SOURCE/debian" "$PACKAGE_OUTPUT/debian-official"
cp "$PACKAGE_SOURCE/atk-adaptor/adaptors/socket-adaptor.c" "$PACKAGE_OUTPUT/socket-adaptor-stock.c"
(
  cd "$PACKAGE_SOURCE"
  # dpkg-source applied the distribution series. Register A with that same
  # quilt source mechanism; do not edit build outputs or Debian build rules.
  cp "$PACKAGE_PATCH" debian/patches/localsend-2754-local-dispatch.patch
  printf '%s\n' localsend-2754-local-dispatch.patch >> debian/patches/series
  QUILT_PATCHES=debian/patches quilt push -a
  DEBFULLNAME='LocalSend diagnostic build' DEBEMAIL='diagnostics@example.invalid' \
    dch --newversion "$PACKAGE_VERSION" --distribution noble --force-distribution \
    'Diagnostic source build for issue 2754: apply the local socket dispatch patch and its native regression fixtures.'
  dpkg-checkbuilddeps
  # Retain a reconstructable source package, then run the full binary build.
  dpkg-source -b .
  dpkg-buildpackage -us -uc -b
)
cmp "$PACKAGE_OUTPUT/debian-official/rules" "$PACKAGE_SOURCE/debian/rules"
cmp "$PACKAGE_OUTPUT/debian-official/control" "$PACKAGE_SOURCE/debian/control"
sha256sum "$PACKAGE_SOURCE/atk-adaptor/adaptors/socket-adaptor.c" \
  "$PACKAGE_SOURCE/tests/at-spi2-atk/socket-local-experiment.c" > "$PACKAGE_OUTPUT/patched-source.sha256"

shopt -s nullglob
PACKAGE_PRODUCTS=("$PACKAGE_WORK"/*.deb "$PACKAGE_WORK"/*.udeb "$PACKAGE_WORK"/*.dsc "$PACKAGE_WORK"/*.tar.* "$PACKAGE_WORK"/*.buildinfo "$PACKAGE_WORK"/*.changes)
[[ ${#PACKAGE_PRODUCTS[@]} -gt 0 ]] || fail 'The package build produced no artifacts.'
cp "${PACKAGE_PRODUCTS[@]}" "$PACKAGE_OUTPUT/artifacts/"
PACKAGE_DEBS=("$PACKAGE_OUTPUT/artifacts"/*.deb)
[[ ${#PACKAGE_DEBS[@]} -gt 0 ]] || fail 'The package build produced no .deb files.'
for PACKAGE_DEB in "${PACKAGE_DEBS[@]}"; do
  PACKAGE_FILE=$(basename "$PACKAGE_DEB")
  dpkg-deb --info "$PACKAGE_DEB" > "$PACKAGE_OUTPUT/metadata/$PACKAGE_FILE.info"
  dpkg-deb --field "$PACKAGE_DEB" > "$PACKAGE_OUTPUT/metadata/$PACKAGE_FILE.control"
  dpkg-deb --contents "$PACKAGE_DEB" > "$PACKAGE_OUTPUT/metadata/$PACKAGE_FILE.contents"
done
PACKAGE_TARGETS=("$PACKAGE_OUTPUT/artifacts/${PACKAGE_TARGET}_${PACKAGE_VERSION}_amd64.deb")
[[ -f ${PACKAGE_TARGETS[0]} ]] || fail 'Missing target bridge package.'
PACKAGE_DEB=${PACKAGE_TARGETS[0]}
[[ $(dpkg-deb -f "$PACKAGE_DEB" Package) == "$PACKAGE_TARGET" &&
   $(dpkg-deb -f "$PACKAGE_DEB" Version) == "$PACKAGE_VERSION" &&
   $(dpkg-deb -f "$PACKAGE_DEB" Architecture) == amd64 ]] || fail 'Target metadata mismatch.'
mkdir "$PACKAGE_OUTPUT/target-root"
dpkg-deb -x "$PACKAGE_DEB" "$PACKAGE_OUTPUT/target-root"
PACKAGE_LIBRARY=$PACKAGE_OUTPUT/target-root/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0
[[ -f $PACKAGE_LIBRARY ]] || fail 'Target package contains no bridge library.'
sha256sum "$(readlink -f "$PACKAGE_LIBRARY")" > "$PACKAGE_OUTPUT/target-library.sha256"
readelf -d "$PACKAGE_LIBRARY" > "$PACKAGE_OUTPUT/metadata/target-library.dynamic"
readelf -n "$PACKAGE_LIBRARY" > "$PACKAGE_OUTPUT/metadata/target-library.notes"
printf '%s\n' "artifacts/$(basename "$PACKAGE_DEB")" > "$PACKAGE_OUTPUT/target-deb.txt"
PACKAGE_CANONICAL_LIBRARY=$(readlink -f "$PACKAGE_LIBRARY")
PACKAGE_BRIDGE_PATH=${PACKAGE_CANONICAL_LIBRARY#"$PACKAGE_OUTPUT/target-root"}
cp "$PACKAGE_DEB" "$PACKAGE_OUTPUT/candidate/"
jq -n --arg package_name "$PACKAGE_TARGET" --arg package_version "$PACKAGE_VERSION" \
  --arg deb_sha256 "$(sha256sum "$PACKAGE_DEB" | cut -d ' ' -f 1)" \
  --arg bridge_path "$PACKAGE_BRIDGE_PATH" \
  --arg bridge_sha256 "$(sha256sum "$PACKAGE_CANONICAL_LIBRARY" | cut -d ' ' -f 1)" \
  --arg patch_sha256 "$(sha256sum "$PACKAGE_PATCH" | cut -d ' ' -f 1)" \
  '{package_name:$package_name, package_version:$package_version, deb_sha256:$deb_sha256,
    bridge_path:$bridge_path, bridge_sha256:$bridge_sha256, variant:"A",
    source_version:"2.52.0-1build1", patch_sha256:$patch_sha256}' > "$PACKAGE_OUTPUT/candidate/manifest.json"
(
  cd "$PACKAGE_OUTPUT/candidate"
  sha256sum ./*.deb manifest.json > SHA256SUMS
)
(
  cd "$PACKAGE_OUTPUT/artifacts"
  sha256sum ./*.deb > ../debs.sha256
  sha256sum ./* > ../artifacts.sha256
)
# This does not install anything. The later VM gate must verify its own apt
# plan and installed package/mapped-library identity against these artifacts.
apt-get --simulate --no-install-recommends install "$PACKAGE_DEB" > "$PACKAGE_OUTPUT/metadata/apt-plan-runner.txt"
printf 'official_source_checksums=true\nquilt_source_patch=true\nofficial_packaging_unchanged=true\nfull_binary_build_passed=true\ntarget_package=%s\ntarget_version=%s\n' \
  "$PACKAGE_TARGET" "$PACKAGE_VERSION" > "$PACKAGE_OUTPUT/gates.txt"
