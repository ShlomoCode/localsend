#!/usr/bin/env bash
set -euxo pipefail
archive_date=${1:-latest}
printf '%s\n' "$archive_date" > /work/evidence/cloud/arch-snapshot.txt
if [ "$archive_date" != latest ]; then
  printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "${archive_date//-//}" > /etc/pacman.d/mirrorlist
  pacman -Syyuu --noconfirm
else
  pacman -Syu --noconfirm
fi
pacman -S --noconfirm base-devel git curl jq gtk3 libayatana-appindicator libayatana-indicator fuse2 xdg-user-dirs quickshell hyprland xorg-xwayland grim imagemagick tesseract tesseract-data-eng mesa ttf-dejavu flameshot inotify-tools power-profiles-daemon sudo
pacman -Q > /work/evidence/cloud/package-versions.txt
cat /etc/os-release > /work/evidence/cloud/os-release.txt
useradd -m -G wheel,video,render investigator
printf 'investigator ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/investigator
chmod 440 /etc/sudoers.d/investigator
chown -R investigator:investigator /work/evidence/cloud
mkdir -p /work/input
chgrp wheel /work/input
chmod 2775 /work/input
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
mkdir -p .config/omarchy .local/state/omarchy/current
cp -a omarchy/themes/tokyo-night .local/state/omarchy/current/next-theme
export OMARCHY_PATH=/home/investigator/omarchy
export PATH="$OMARCHY_PATH/bin:$PATH"
bash omarchy/bin/omarchy-theme-set-templates
mv .local/state/omarchy/current/next-theme .local/state/omarchy/current/theme
cat > .config/omarchy/shell.json <<'CONFIG'
{"version":1,"idle":{"screensaver":86400,"lock":86400},"bar":{"position":"top","transparent":false,"layout":{"left":[{"id":"omarchy.tray"}],"center":[],"right":[]}},"plugins":[]}
CONFIG
cp .config/omarchy/shell.json /work/evidence/cloud/shell.json
cat > .config/hypr3484.conf <<'HYPR'
monitor=,1280x800@60,auto,1
misc {
  disable_hyprland_logo=true
  disable_splash_rendering=true
}
exec-once = bash /work/support/diagnostics/3484/wayland-session.sh
HYPR
cat > .bash_profile <<'PROFILE'
if [ "$(tty)" = /dev/tty1 ]; then
  export OMARCHY_PATH=/home/investigator/omarchy
  export PATH="$OMARCHY_PATH/bin:$PATH"
  export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe QT_QPA_PLATFORM=wayland
  exec dbus-run-session Hyprland --config "$HOME/.config/hypr3484.conf" > /work/evidence/cloud/hyprland.log 2>&1
fi
PROFILE
USER
printf '98f6e749c0eb470b7d2bb4a365f704328ae7dc4bbc6d78ddf2d574dfb63cc20b  /work/source-bundle.tar.gz\n' | sha256sum -c -
mkdir /opt/current-base
tar -xf /work/source-bundle.tar.gz -C /opt/current-base
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin investigator --noclear %I $TERM
GETTY
systemctl daemon-reload
systemctl enable getty@tty1
