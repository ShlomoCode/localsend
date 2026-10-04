#!/usr/bin/env bash
# Repack the signed store Snap with a controlled Flutter bundle. The caller
# installs the result with --dangerous, which leaves strict confinement on.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 original.snap flutter-bundle output.snap" >&2
  exit 2
fi

original=$(realpath "$1")
bundle=$(realpath "$2")
output=$(realpath -m "$3")

if [ ! -f "$original" ] || [ ! -x "$bundle/localsend_app" ]; then
  echo "Expected a store Snap and an executable Flutter bundle" >&2
  exit 1
fi
if [ "$original" = "$output" ]; then
  echo "Output must differ from the original store Snap" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/snap"
unsquashfs -no-progress -d "$stage" "$original"

metadata="$stage/meta/snap.yaml"
if ! grep -Eq '^name: localsend$' "$metadata" ||
   ! grep -Eq '^confinement: strict$' "$metadata" ||
   ! grep -Eq 'command: opt/localsend_app/localsend_app$' "$metadata" ||
   [ ! -d "$stage/opt/localsend_app" ]; then
  echo "Store Snap layout or strict metadata differs from the expected LocalSend package" >&2
  exit 1
fi

# Preserve meta/, command chains, staged libraries, desktop files and every
# other path from the store package. Only the application bundle is replaced.
rm -rf "$stage/opt/localsend_app"
cp -a "$bundle" "$stage/opt/localsend_app"
chmod +x "$stage/opt/localsend_app/localsend_app"

# The official LocalSend recipe uses lzo. Keep the store archive's algorithm
# if that changes in a later revision.
compression=$(unsquashfs -s "$original" | awk '/^Compression / { print $2; exit }')
case "$compression" in
  xz|lzo|gzip|zstd) ;;
  *) echo "Unsupported store Snap compression: $compression" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$output")"
snap pack --compression "$compression" --filename "$output" "$stage"

# Check both the unchanged Snap contract and the executable actually packed.
unsquashfs -cat "$output" meta/snap.yaml | cmp -s "$metadata" -
unsquashfs -cat "$output" opt/localsend_app/localsend_app | cmp -s "$bundle/localsend_app" -
sha256sum "$original" "$bundle/localsend_app" "$output"
