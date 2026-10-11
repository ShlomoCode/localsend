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
bash support/diagnostics/2690/package.sh
docker pull gentoo/stage3:latest
docker image inspect gentoo/stage3:latest > evidence/cloud/gentoo-image.json
docker run --privileged --name issue2690-gentoo -v "$PWD/evidence/cloud:/evidence" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" gentoo/stage3:latest bash /diagnostic/gentoo.sh
docker pull ubuntu:20.04
docker image inspect ubuntu:20.04 > evidence/cloud/old-libc-image.json
docker run --privileged --name issue2690-old-libc -v "$PWD/evidence/cloud:/evidence" -v "$PWD/support/diagnostics/2690:/diagnostic:ro" ubuntu:20.04 bash /diagnostic/old-libc.sh > evidence/cloud/old-libc.log 2>&1
