#!/bin/bash
set -euxo pipefail
mkdir -p evidence/cloud
exec > >(tee evidence/cloud/job.log) 2>&1
curl -fL --retry 3 https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.AppImage -o evidence/cloud/original.AppImage
sha256sum evidence/cloud/original.AppImage > evidence/cloud/artifact.sha256
sudo apt-get update -qq
sudo apt-get install -y squashfs-tools binutils
# Extract without executing the application or changing its contents.
chmod u+x evidence/cloud/original.AppImage
offset=$(evidence/cloud/original.AppImage --appimage-offset)
unsquashfs -o "$offset" -d evidence/cloud/AppDir evidence/cloud/original.AppImage
find evidence/cloud/AppDir -iname "*wayland*" -o -iname "*gtk*" > evidence/cloud/bundled-display-libraries.txt
find evidence/cloud/AppDir -type f -print0 | while IFS= read -r -d "" f; do
  if readelf -h "$f" >/dev/null 2>&1; then
    printf "FILE %s\n" "$f"
    readelf -d "$f" | grep -E "NEEDED|RPATH|RUNPATH" || true
  fi
done > evidence/cloud/elf-closure.txt
cat evidence/cloud/bundled-display-libraries.txt
file evidence/cloud/AppDir/AppRun
find evidence/cloud/AppDir -maxdepth 2 -type f -name "*.env" -o -name "*.json"
curl -fL --retry 3 https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-linux-x86-64.AppImage -o evidence/cloud/current.AppImage
echo '19f21613d1834f6caa69517113670461a3f10b80a2a315f86548c0663d9c0aaf  evidence/cloud/current.AppImage' | sha256sum -c -
chmod a+x evidence/cloud/current.AppImage
current_offset=$(evidence/cloud/current.AppImage --appimage-offset)
unsquashfs -o "$current_offset" -d evidence/cloud/CurrentDir evidence/cloud/current.AppImage
find evidence/cloud/CurrentDir -iname '*wayland*' > evidence/cloud/current-wayland-files.txt
readelf -d evidence/cloud/CurrentDir/usr/lib/x86_64-linux-gnu/libgdk-3.so.0 > evidence/cloud/current-gdk-elf.txt
if [[ ${USE_C1CE:-false} == true ]]; then
  source_tar=evidence/main-source/source-bundle.tar.gz
  echo '98f6e749c0eb470b7d2bb4a365f704328ae7dc4bbc6d78ddf2d574dfb63cc20b  evidence/main-source/source-bundle.tar.gz' | sha256sum -c -
  test "$(cat evidence/main-source/provenance/source-sha.txt)" = c1ce322fb3acf08e44f329b8b7208b8b0d91e244
  test ! -s evidence/main-source/provenance/source-diff-after.patch
  grep -Fxq 'exit_status=0' evidence/main-source/provenance/build-result.txt
  cmp evidence/main-source/provenance/lock-hashes-before.txt evidence/main-source/provenance/lock-hashes-after.txt
  git fetch --depth=1 origin c1ce322fb3acf08e44f329b8b7208b8b0d91e244
  git show c1ce322fb3acf08e44f329b8b7208b8b0d91e244:support/build/appimage/AppImageBuilder_x86_64.yml > evidence/cloud/main-source-recipe.txt
  diff -u evidence/cloud/main-source-recipe.txt support/build/appimage/AppImageBuilder_x86_64.yml > evidence/cloud/production-recipe-diff.txt || test "$?" = 1
  sha256sum "$source_tar" > evidence/cloud/main-source-tar.sha256
  cp evidence/main-source/provenance/build-inputs.json evidence/cloud/main-source-build-inputs.json
  cp evidence/main-source/provenance/bundle-file-sha256.txt evidence/cloud/main-source-files.txt
  rm -rf evidence/cloud/CurrentDir
  mkdir evidence/cloud/CurrentDir
  tar -xf "$source_tar" -C evidence/cloud/CurrentDir
  test -x evidence/cloud/CurrentDir/localsend_app
  source_manifest=$(readlink -f evidence/cloud/main-source-files.txt)
  (cd evidence/cloud/CurrentDir && sha256sum -c "$source_manifest") > evidence/cloud/main-source-verified.txt
  for size in 32 128 256; do
    icon_dir="evidence/cloud/CurrentDir/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    cp "evidence/cloud/CurrentDir/data/flutter_assets/assets/img/logo-$size.png" "$icon_dir/localsend.png"
  done
  printf '%s\n' 'Source-built c1ce artifact, not official-release repack' > evidence/cloud/package-source.txt
else
  printf '%s\n' 'Official1.18.2 release binary repack, not source-built current main' > evidence/cloud/package-source.txt
fi
bash support/diagnostics/2690/package.sh
docker pull gentoo/stage3:latest
docker image inspect gentoo/stage3:latest > evidence/cloud/gentoo-image.json
docker run --privileged --name issue2690-gentoo -v "$PWD/evidence/cloud:/evidence" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" gentoo/stage3:latest bash /diagnostic/gentoo.sh
docker pull ubuntu:20.04
docker image inspect ubuntu:20.04 > evidence/cloud/old-libc-image.json
docker run --privileged --name issue2690-old-libc -v "$PWD/evidence/cloud:/evidence" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" ubuntu:20.04 bash /diagnostic/old-libc.sh > evidence/cloud/old-libc.log 2>&1
