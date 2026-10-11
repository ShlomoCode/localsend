#!/usr/bin/env bash
set -euxo pipefail
pacman -Syu --noconfirm
pacman -S --noconfirm base-devel git curl jq gtk3 libayatana-appindicator libayatana-indicator fuse2 xdg-user-dirs quickshell hyprland xorg-server-xvfb xdotool imagemagick tesseract tesseract-data-eng dbus openbox mesa ttf-dejavu sudo flameshot
pacman -Q > /work/evidence/cloud/package-versions.txt
cat /etc/os-release > /work/evidence/cloud/os-release.txt
useradd -m -G wheel investigator
printf 'investigator ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/investigator
chmod 440 /etc/sudoers.d/investigator
chown -R investigator:investigator /work/evidence/cloud
sudo -u investigator bash <<'USER'
set -euxo pipefail
cd /home/investigator
mkdir pkg
curl -fLsS 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=localsend-bin' -o pkg/PKGBUILD
cp pkg/PKGBUILD /work/evidence/cloud/PKGBUILD
cd pkg
makepkg --noconfirm --syncdeps --install
sha256sum LocalSend-*.deb *.pkg.tar.zst > /work/evidence/cloud/artifact-sha256.txt
cd /home/investigator
curl -fLsS https://api.github.com/repos/brenoperucchi/omarchy/tarball/31bd80daa4613ffdee995ac27467fce5a2990806 -o omarchy.tar.gz
sha256sum omarchy.tar.gz > /work/evidence/cloud/host-source-sha256.txt
mkdir omarchy
tar -xf omarchy.tar.gz -C omarchy --strip-components=1
mkdir -p .config/omarchy
cat > .config/omarchy/shell.json <<'CONFIG'
{"version":1,"idle":{"screensaver":0,"lock":0},"bar":{"position":"top","transparent":false,"layout":{"left":[{"id":"omarchy.tray"}],"center":[],"right":[]}},"plugins":[]}
CONFIG
cp .config/omarchy/shell.json /work/evidence/cloud/shell.json
export OMARCHY_PATH=/home/investigator/omarchy
export XDG_RUNTIME_DIR=/tmp/runtime-investigator
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY=:99 QT_QPA_PLATFORM=xcb LIBGL_ALWAYS_SOFTWARE=1
Xvfb :99 -screen 0 1280x800x24 > /work/evidence/cloud/xvfb.log 2>&1 &
sleep 2
dbus-run-session bash /work/support/diagnostics/3484/session.sh
USER
