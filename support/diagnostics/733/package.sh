#!/usr/bin/env bash
# Normal historical Flathub recipe; cloud only, no binary substitution.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
mkdir -p evidence/package
sudo apt-get update
sudo apt-get install -y flatpak flatpak-builder git
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
git clone --recursive https://github.com/flathub/org.localsend.localsend_app.git /tmp/733-flathub
cd /tmp/733-flathub
git checkout 7465669c22a2a4fc35e707e1e4e7e882772adc0e
git submodule update --init --recursive
git rev-parse HEAD > "$GITHUB_WORKSPACE/evidence/package/manifest-commit.txt"
cp org.localsend.localsend_app.yml "$GITHUB_WORKSPACE/evidence/package/manifest.yml"
flatpak install --user --noninteractive -y flathub org.freedesktop.Sdk/x86_64/22.08 org.freedesktop.Platform/x86_64/22.08 org.freedesktop.Sdk.Extension.vala/x86_64/22.08
flatpak-builder --user --force-clean --repo=/tmp/733-repo /tmp/733-build org.localsend.localsend_app.yml 2>&1 | tee "$GITHUB_WORKSPACE/evidence/package/build.log"
flatpak build-bundle /tmp/733-repo "$GITHUB_WORKSPACE/evidence/package/historical.flatpak" org.localsend.localsend_app
sha256sum "$GITHUB_WORKSPACE/evidence/package/historical.flatpak" > "$GITHUB_WORKSPACE/evidence/package/bundle.sha256"
flatpak info --user org.freedesktop.Platform/x86_64/22.08 > "$GITHUB_WORKSPACE/evidence/package/runtime-identity.txt"
