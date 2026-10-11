#!/bin/bash
set -euxo pipefail
production=3613f65
cp evidence/history/candidate-client-symbols.txt evidence/cloud/candidate-client-symbols.txt
git fetch --depth=1 origin codex/bug-2690-packaging-proposal
test "$(git rev-parse FETCH_HEAD)" = "$(git rev-parse "$production")"
git diff --exit-code "$production" -- support/build/appimage/build_wayland_client.sh support/build/appimage/AppImageBuilder_x86_64.yml .github/workflows/build_linux_appimage_x64.yml support/scripts/compile_linux_appimage.sh
git rev-parse "$production" > evidence/cloud/production-head.txt
git diff c1ce322 "$production" > evidence/cloud/production.patch
sha256sum support/build/appimage/build_wayland_client.sh support/build/appimage/AppImageBuilder_x86_64.yml > evidence/cloud/production-inputs.sha256
for variant in baseline candidate cursor-egl client-only cursor-only egl-only; do
  cp "evidence/history/repacked-$variant.AppImage" "evidence/cloud/repacked-$variant.AppImage"
  cp "evidence/history/repacked-$variant.sha256" "evidence/cloud/repacked-$variant.sha256"
  sha256sum -c "evidence/cloud/repacked-$variant.sha256"
  chmod a+x "evidence/cloud/repacked-$variant.AppImage"
done
task_dir="$PWD/evidence/cloud/package-new-client"
mkdir -p "$task_dir"
cp -a evidence/cloud/CurrentDir "$task_dir/AppDir"
test -z "$(find "$task_dir/AppDir" -name 'libwayland*' -print)"
cp support/build/appimage/AppImageBuilder_x86_64.yml "$task_dir/AppImageBuilder.yml"
docker pull ubuntu:22.04
docker image inspect ubuntu:22.04 > evidence/cloud/client-build-image.json
docker run --rm -v "$task_dir:/work" -v "$PWD/support/build/appimage:/production:ro" ubuntu:22.04 bash -euxc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential pkg-config libffi-dev libexpat1-dev libxml2-dev python3-venv ninja-build curl ca-certificates && bash /production/build_wayland_client.sh /work/AppDir' > evidence/cloud/client-build.log 2>&1
sha256sum "$task_dir/AppDir/usr/lib/x86_64-linux-gnu/libwayland-client.so.0.26.0" > "$task_dir/installed-client.sha256"
cp "$task_dir/installed-client.sha256" evidence/cloud/source-first-installed-client.sha256
expected=$(cut -d' ' -f1 "$task_dir/installed-client.sha256")
bash support/diagnostics/2690/inspect-client.sh "$task_dir/AppDir" "$expected" "$task_dir/phase-before-builder.txt"
docker pull appimagecrafters/appimage-builder:1.1.0
docker image inspect appimagecrafters/appimage-builder:1.1.0 > evidence/cloud/builder-image.json
docker run --rm --privileged -v "$task_dir:/work" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" -w /work appimagecrafters/appimage-builder:1.1.0 bash /diagnostic/source-first-builder.sh > evidence/cloud/package-new-client.log 2>&1
cp "$task_dir"/phase-*.txt "$task_dir/apt-wayland-ownership.txt" "$task_dir/source-first-bundle-record.txt" evidence/cloud/
grep '^INFO:AptPackageDeploy:Deploying ' evidence/cloud/package-new-client.log > evidence/cloud/source-first-apt-deploy.txt
! grep -Fq 'Deploying libwayland-client' evidence/cloud/source-first-apt-deploy.txt
grep -Fq 'Deploying libwayland-cursor0' evidence/cloud/source-first-apt-deploy.txt
grep -Fq 'Deploying libwayland-egl1' evidence/cloud/source-first-apt-deploy.txt
cp "$task_dir/AppImageBuilder.yml" evidence/cloud/source-first-recipe.txt
cp "$task_dir"/*.AppImage evidence/cloud/repacked-new-client.AppImage
sha256sum evidence/cloud/repacked-new-client.AppImage > evidence/cloud/repacked-new-client.sha256
offset=$(evidence/cloud/repacked-new-client.AppImage --appimage-offset)
unsquashfs -o "$offset" -d evidence/cloud/source-first-packed evidence/cloud/repacked-new-client.AppImage > evidence/cloud/source-first-extract.log
bash support/diagnostics/2690/inspect-client.sh evidence/cloud/source-first-packed "$expected" evidence/cloud/source-first-packed-client.txt
(cd evidence/cloud/source-first-packed && find . -type f -print0 | sort -z | xargs -0 sha256sum) > evidence/cloud/source-first-packed-inventory.txt
(cd evidence/cloud/source-first-packed && find . -type l -printf '%p -> %l\n' | sort) > evidence/cloud/source-first-packed-links.txt
