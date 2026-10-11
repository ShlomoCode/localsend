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
docker run --rm -v "$client_dir:/work" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" ubuntu:22.04 bash /diagnostic/build-client-jammy.sh > evidence/cloud/client-build.log 2>&1
cp "$client_dir"/*.txt "$client_dir"/*.sha256 evidence/cloud/
task_dir="$PWD/evidence/cloud/package-new-client"
mkdir -p "$task_dir"
cp -a evidence/cloud/package-candidate/AppDir "$task_dir/AppDir"
cp evidence/cloud/package-candidate/AppImageBuilder.yml "$task_dir/AppImageBuilder.yml"
# A causal diagnostic: retain filename, symlinks and existing AppRun/runtime bytes.
# --skip-build repackages this AppDir without redeploying the old apt client.
cp "$client_dir/client-jammy.so" "$task_dir/AppDir/usr/lib/x86_64-linux-gnu/libwayland-client.so.0.20.0"
docker run --rm --privileged -v "$task_dir:/work" -w /work appimagecrafters/appimage-builder:1.1.0 appimage-builder --recipe AppImageBuilder.yml --skip-build --skip-test > evidence/cloud/package-new-client.log 2>&1
cp "$task_dir"/*.AppImage evidence/cloud/repacked-new-client.AppImage
sha256sum evidence/cloud/repacked-new-client.AppImage > evidence/cloud/repacked-new-client.sha256
(cd "$task_dir/AppDir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > evidence/cloud/inventory-new-client.txt
diff -u evidence/cloud/inventory-candidate.txt evidence/cloud/inventory-new-client.txt > evidence/cloud/inventory-client-change.txt || test "$?" = 1
diff -u evidence/cloud/recipe-baseline.txt evidence/cloud/recipe-candidate.txt > evidence/cloud/recipe-diff.txt || test "$?" = 1
diff -u evidence/cloud/inventory-baseline.txt evidence/cloud/inventory-candidate.txt > evidence/cloud/inventory-diff.txt || test "$?" = 1
