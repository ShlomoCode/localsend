#!/bin/bash
set -euxo pipefail
docker pull appimagecrafters/appimage-builder:1.1.0
docker image inspect appimagecrafters/appimage-builder:1.1.0 > evidence/cloud/builder-image.json
for variant in baseline candidate; do
  task_dir="$PWD/evidence/cloud/package-$variant"
  mkdir -p "$task_dir"
  cp -a evidence/cloud/CurrentDir "$task_dir/AppDir"
  cp support/build/appimage/AppImageBuilder_x86_64.yml "$task_dir/AppImageBuilder.yml"
  if [[ $variant == candidate ]]; then
    sed -i '/      - librsvg2-common:amd64/a\      - libwayland-client0:amd64\n      - libwayland-cursor0:amd64\n      - libwayland-egl1:amd64' "$task_dir/AppImageBuilder.yml"
  fi
  cp "$task_dir/AppImageBuilder.yml" "evidence/cloud/recipe-$variant.txt"
  docker run --rm --privileged -v "$task_dir:/work" -w /work appimagecrafters/appimage-builder:1.1.0 appimage-builder --recipe AppImageBuilder.yml --skip-test > "evidence/cloud/package-$variant.log" 2>&1
  cp "$task_dir"/*.AppImage "evidence/cloud/repacked-$variant.AppImage"
  sha256sum "evidence/cloud/repacked-$variant.AppImage" > "evidence/cloud/repacked-$variant.sha256"
  (cd "$task_dir/AppDir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "evidence/cloud/inventory-$variant.txt"
done
diff -u evidence/cloud/recipe-baseline.txt evidence/cloud/recipe-candidate.txt > evidence/cloud/recipe-diff.txt || test "$?" = 1
diff -u evidence/cloud/inventory-baseline.txt evidence/cloud/inventory-candidate.txt > evidence/cloud/inventory-diff.txt || test "$?" = 1
