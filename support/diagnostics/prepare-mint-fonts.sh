#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare a reproducible Linux Mint 22.3 font corpus on an ephemeral Actions runner.
# This script never installs or copies fonts into the runner's live font directories.

PRIMARY_URL='https://pub.linuxmint.io/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso'
MIRROR_URL='https://mirror.ibcp.fr/pub/linuxmint/iso/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso'
EXPECTED_SHA256='a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4'
OUT="${OUT:-${GITHUB_WORKSPACE:-$PWD}/evidence-mint-fonts}"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK=""

mkdir -p "$OUT" "$TEMP_ROOT"
OUT="$(realpath "$OUT")"
WORK="$(mktemp -d "$TEMP_ROOT/mint-fonts.XXXXXX")"

cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for tool in curl sha256sum 7z unsquashfs tar find sort awk timeout; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not installed: $tool"
done

ISO="$WORK/linuxmint-22.3-cinnamon-64bit.iso"
ISO_DIR="$WORK/iso"
ROOT="$WORK/mint-root"
mkdir -p "$ISO_DIR" "$ROOT"

SOURCE_URL="$PRIMARY_URL"
echo "Downloading the official Linux Mint 22.3 ISO."
if ! timeout 15m curl --fail --location --retry 2 --retry-delay 2 "$PRIMARY_URL" -o "$ISO"; then
  echo "Primary ISO download failed; trying the official mirror."
  SOURCE_URL="$MIRROR_URL"
  rm -f "$ISO"
  timeout 15m curl --fail --location --retry 2 --retry-delay 2 "$MIRROR_URL" -o "$ISO" || fail "Both official ISO URLs failed."
fi

actual_sha=$(sha256sum "$ISO" | awk '{print $1}')
[[ "$actual_sha" == "$EXPECTED_SHA256" ]] || fail "ISO SHA256 mismatch: expected $EXPECTED_SHA256, got $actual_sha"

echo "Extracting casper manifest and filesystem image from the ISO."
timeout 5m 7z x -y "$ISO" 'casper/filesystem.manifest' 'casper/filesystem.squashfs' "-o$ISO_DIR" > "$OUT/7z-extraction.log" 2>&1 || fail "Could not extract required casper files from ISO."
MANIFEST="$ISO_DIR/casper/filesystem.manifest"
SQUASHFS="$ISO_DIR/casper/filesystem.squashfs"
[[ -s "$MANIFEST" ]] || fail "ISO is missing casper/filesystem.manifest"
[[ -s "$SQUASHFS" ]] || fail "ISO is missing casper/filesystem.squashfs"

cp "$MANIFEST" "$OUT/filesystem.manifest"
printf '%s\n' "$MANIFEST" > "$OUT/manifest-source.txt"

echo "Extracting font files and fontconfig metadata from the squashfs."
unsquashfs -s "$SQUASHFS" > "$OUT/squashfs-info.txt" 2>&1 || fail "Could not read squashfs metadata."
timeout 12m unsquashfs -no-progress -d "$ROOT" "$SQUASHFS" \
  usr/share/fonts etc/fonts > "$OUT/unsquashfs-extraction.log" 2>&1 || fail "Could not extract required font and fontconfig paths."

if timeout 3m unsquashfs -no-progress -d "$ROOT" "$SQUASHFS" usr/local/share/fonts >> "$OUT/unsquashfs-extraction.log" 2>&1 && [[ -d "$ROOT/usr/local/share/fonts" ]]; then
  HAS_LOCAL_FONTS=true
else
  # This path is optional in the Mint image. Keep the first extraction log as evidence.
  HAS_LOCAL_FONTS=false
fi

[[ -d "$ROOT/usr/share/fonts" ]] || fail "The Mint image contains no usr/share/fonts directory."
[[ -d "$ROOT/etc/fonts" ]] || fail "The Mint image contains no etc/fonts metadata directory."

awk '
  {
    package=$1
    sub(/:.*/, "", package)
    if (package ~ /^fonts-/ || package ~ /^fontconfig($|-)/) print $0
  }
' "$MANIFEST" | LC_ALL=C sort -u > "$OUT/font-packages.txt"
[[ -s "$OUT/font-packages.txt" ]] || fail "No font/fontconfig packages were found in the Mint manifest."

{
  find "$ROOT/usr/share/fonts" -type f -print0
  if [[ "$HAS_LOCAL_FONTS" == true && -d "$ROOT/usr/local/share/fonts" ]]; then
    find "$ROOT/usr/local/share/fonts" -type f -print0
  fi
} | while IFS= read -r -d '' file; do
  relative=${file#"$ROOT/"}
  printf '%s\0%s\n' "$file" "$relative"
done | while IFS= read -r -d '' file && IFS= read -r relative; do
  sha256sum "$file" | awk -v path="$relative" '{print $1 "  " path}'
done | LC_ALL=C sort -k2,2 > "$OUT/fontfile-sha256.txt"
[[ -s "$OUT/fontfile-sha256.txt" ]] || fail "No font files were extracted."

cat > "$OUT/source-provenance.txt" <<EOF
distribution=Linux Mint
release=22.3
edition=Cinnamon 64-bit
source_url=$SOURCE_URL
iso_sha256=$actual_sha
expected_iso_sha256=$EXPECTED_SHA256
manifest_sha256=$(sha256sum "$MANIFEST" | awk '{print $1}')
font_files=$(wc -l < "$OUT/fontfile-sha256.txt" | tr -d ' ')
local_font_directory_present=$HAS_LOCAL_FONTS
EOF

echo "Creating the font corpus archive."
archive_root="$WORK/archive"
mkdir -p "$archive_root"
cp -a "$ROOT/usr/share/fonts" "$archive_root/usr-share-fonts"
if [[ "$HAS_LOCAL_FONTS" == true && -d "$ROOT/usr/local/share/fonts" ]]; then
  cp -a "$ROOT/usr/local/share/fonts" "$archive_root/usr-local-share-fonts"
fi
cp -a "$ROOT/etc/fonts" "$archive_root/etc-fonts-metadata"
cp "$MANIFEST" "$archive_root/filesystem.manifest"
cp "$OUT/font-packages.txt" "$archive_root/font-packages.txt"
cp "$OUT/fontfile-sha256.txt" "$archive_root/fontfile-sha256.txt"
cp "$OUT/source-provenance.txt" "$archive_root/source-provenance.txt"
cp "$OUT/7z-extraction.log" "$archive_root/7z-extraction.log"
cp "$OUT/unsquashfs-extraction.log" "$archive_root/unsquashfs-extraction.log"
cp "$OUT/squashfs-info.txt" "$archive_root/squashfs-info.txt"
tar -czf "$OUT/mint-fonts.tar.gz" -C "$archive_root" .

echo "Mint font corpus ready: $OUT/mint-fonts.tar.gz"
echo "Extracted $(wc -l < "$OUT/fontfile-sha256.txt" | tr -d ' ') font files; ISO SHA256 verified."
