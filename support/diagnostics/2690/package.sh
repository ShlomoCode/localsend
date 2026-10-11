#!/bin/bash
set -euxo pipefail
docker pull appimagecrafters/appimage-builder:1.1.0
docker image inspect appimagecrafters/appimage-builder:1.1.0 > evidence/cloud/builder-image.json
for variant in baseline candidate cursor-egl client-only cursor-only egl-only; do
  task_dir="$PWD/evidence/cloud/package-$variant"
  mkdir -p "$task_dir"
  cp -a evidence/cloud/CurrentDir "$task_dir/AppDir"
  cp support/build/appimage/AppImageBuilder_x86_64.yml "$task_dir/AppImageBuilder.yml"
  if [[ $variant == candidate ]]; then
    sed -i '/      - librsvg2-common:amd64/a\      - libwayland-client0:amd64\n      - libwayland-cursor0:amd64\n      - libwayland-egl1:amd64' "$task_dir/AppImageBuilder.yml"
  fi
  if [[ $variant == cursor-egl ]]; then
    sed -i '/      - librsvg2-common:amd64/a\      - libwayland-cursor0:amd64\n      - libwayland-egl1:amd64' "$task_dir/AppImageBuilder.yml"
  fi
  case "$variant" in
    client-only) sed -i '/      - librsvg2-common:amd64/a\      - libwayland-client0:amd64' "$task_dir/AppImageBuilder.yml" ;;
    cursor-only) sed -i '/      - librsvg2-common:amd64/a\      - libwayland-cursor0:amd64' "$task_dir/AppImageBuilder.yml" ;;
    egl-only) sed -i '/      - librsvg2-common:amd64/a\      - libwayland-egl1:amd64' "$task_dir/AppImageBuilder.yml" ;;
  esac
  cp "$task_dir/AppImageBuilder.yml" "evidence/cloud/recipe-$variant.txt"
  docker run --rm --privileged -v "$task_dir:/work" -w /work appimagecrafters/appimage-builder:1.1.0 appimage-builder --recipe AppImageBuilder.yml --skip-test > "evidence/cloud/package-$variant.log" 2>&1
  cp "$task_dir"/*.AppImage "evidence/cloud/repacked-$variant.AppImage"
  sha256sum "evidence/cloud/repacked-$variant.AppImage" > "evidence/cloud/repacked-$variant.sha256"
  (cd "$task_dir/AppDir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "evidence/cloud/inventory-$variant.txt"
done
docker pull ubuntu:22.04
docker image inspect ubuntu:22.04 > evidence/cloud/client-build-image.json
client_dir="$PWD/evidence/cloud/wayland-jammy"
mkdir -p "$client_dir"
docker run --rm -e SOURCE_FIRST="${SOURCE_FIRST:-false}" -v "$client_dir:/work" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" ubuntu:22.04 bash /diagnostic/build-client-jammy.sh > evidence/cloud/client-build.log 2>&1
cp "$client_dir"/*.txt "$client_dir"/*.sha256 evidence/cloud/
task_dir="$PWD/evidence/cloud/package-new-client"
mkdir -p "$task_dir"
if [[ ${SOURCE_FIRST:-false} == true ]]; then
  test "${USE_C1CE:-false}" = true
  # Initial assembly from verified current-source input, not from a completed AppDir.
  cp -a evidence/cloud/CurrentDir "$task_dir/AppDir"
  test -z "$(find "$task_dir/AppDir" -name 'libwayland*' -print)"
  cp evidence/cloud/package-cursor-egl/AppImageBuilder.yml "$task_dir/AppImageBuilder.yml"
  installed="$client_dir/upstream-install/usr/lib/x86_64-linux-gnu"
  test -L "$installed/libwayland-client.so.0"
  test "$(readlink "$installed/libwayland-client.so.0")" = libwayland-client.so.0.26.0
  target="$task_dir/AppDir/usr/lib/x86_64-linux-gnu"
  mkdir -p "$target"
  # Explicit installed-runtime allowlist; no server, cursor, EGL or development link.
  cp -p "$installed/libwayland-client.so.0.26.0" "$target/"
  cp -P "$installed/libwayland-client.so.0" "$target/"
  mkdir -p "$task_dir/AppDir/usr/share/licenses/wayland-client"
  cp "$client_dir/client-COPYING.txt" "$task_dir/AppDir/usr/share/licenses/wayland-client/COPYING"
  sha256sum "$installed/libwayland-client.so.0.26.0" > "$task_dir/installed-client.sha256"
  cp "$task_dir/installed-client.sha256" evidence/cloud/source-first-installed-client.sha256
  expected=$(cut -d' ' -f1 "$task_dir/installed-client.sha256")
  bash support/diagnostics/2690/inspect-client.sh "$task_dir/AppDir" "$expected" "$task_dir/phase-before-builder.txt"
  (cd "$task_dir/AppDir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > evidence/cloud/source-first-initial-inventory.txt
  docker run --rm --privileged -v "$task_dir:/work" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" -w /work appimagecrafters/appimage-builder:1.1.0 bash /diagnostic/source-first-builder.sh > evidence/cloud/package-new-client.log 2>&1
  cp "$task_dir"/phase-*.txt "$task_dir/apt-wayland-ownership.txt" "$task_dir/source-first-bundle-record.txt" evidence/cloud/
  grep '^INFO:AptPackageDeploy:Deploying ' evidence/cloud/package-new-client.log > evidence/cloud/source-first-apt-deploy.txt
  if grep -Fq 'Deploying libwayland-client' evidence/cloud/source-first-apt-deploy.txt; then
    echo 'REJECT: apt deployed a competing client'; exit 1
  fi
  grep -Fq 'Deploying libwayland-cursor0' evidence/cloud/source-first-apt-deploy.txt
  grep -Fq 'Deploying libwayland-egl1' evidence/cloud/source-first-apt-deploy.txt
  cp "$task_dir/AppImageBuilder.yml" evidence/cloud/source-first-recipe.txt
  printf '%s\n' 'Normal upstream install + initial runtime allowlist assembly + normal pinned builder; no skip-build or late replacement' > evidence/cloud/source-first-mode.txt
else
  cp -a evidence/cloud/package-candidate/AppDir "$task_dir/AppDir"
  cp evidence/cloud/package-candidate/AppImageBuilder.yml "$task_dir/AppImageBuilder.yml"
  # Historical causal diagnostic only: replace bytes in a completed AppDir.
  cp "$client_dir/client-jammy.so" "$task_dir/AppDir/usr/lib/x86_64-linux-gnu/libwayland-client.so.0.20.0"
  docker run --rm --privileged -v "$task_dir:/work" -w /work appimagecrafters/appimage-builder:1.1.0 appimage-builder --recipe AppImageBuilder.yml --skip-build --skip-test > evidence/cloud/package-new-client.log 2>&1
fi
cp "$task_dir"/*.AppImage evidence/cloud/repacked-new-client.AppImage
sha256sum evidence/cloud/repacked-new-client.AppImage > evidence/cloud/repacked-new-client.sha256
if [[ ${SOURCE_FIRST:-false} == true ]]; then
  offset=$(evidence/cloud/repacked-new-client.AppImage --appimage-offset)
  unsquashfs -o "$offset" -d evidence/cloud/source-first-packed evidence/cloud/repacked-new-client.AppImage > evidence/cloud/source-first-extract.log
  bash support/diagnostics/2690/inspect-client.sh evidence/cloud/source-first-packed "$expected" evidence/cloud/source-first-packed-client.txt
  (cd evidence/cloud/source-first-packed && find . -type f -print0 | sort -z | xargs -0 sha256sum) > evidence/cloud/source-first-packed-inventory.txt
  (cd evidence/cloud/source-first-packed && find . -type l -printf '%p -> %l\n' | sort) > evidence/cloud/source-first-packed-links.txt
fi
(cd "$task_dir/AppDir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > evidence/cloud/inventory-new-client.txt
diff -u evidence/cloud/inventory-candidate.txt evidence/cloud/inventory-new-client.txt > evidence/cloud/inventory-client-change.txt || test "$?" = 1
diff -u evidence/cloud/recipe-baseline.txt evidence/cloud/recipe-candidate.txt > evidence/cloud/recipe-diff.txt || test "$?" = 1
diff -u evidence/cloud/inventory-baseline.txt evidence/cloud/inventory-candidate.txt > evidence/cloud/inventory-diff.txt || test "$?" = 1
