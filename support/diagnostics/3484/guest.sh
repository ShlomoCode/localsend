#!/usr/bin/env bash
set -euxo pipefail
pacman -Syu --noconfirm
pacman -S --noconfirm base-devel git curl jq gtk3 libayatana-appindicator libayatana-indicator fuse2 xdg-user-dirs quickshell hyprland xorg-xwayland grim tesseract tesseract-data-eng mesa ttf-dejavu flameshot inotify-tools power-profiles-daemon sudo
pacman -Q > /work/evidence/cloud/package-versions.txt
cat /etc/os-release > /work/evidence/cloud/os-release.txt
useradd -m -G wheel,video,render investigator
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
mkdir -p .config/omarchy .local/state/omarchy/current
cp -a omarchy/themes/tokyo-night .local/state/omarchy/current/next-theme
export OMARCHY_PATH=/home/investigator/omarchy
bash omarchy/bin/omarchy-theme-set-templates
mv .local/state/omarchy/current/next-theme .local/state/omarchy/current/theme
cat > .config/omarchy/shell.json <<'CONFIG'
{"version":1,"idle":{"screensaver":0,"lock":0},"bar":{"position":"top","transparent":false,"layout":{"left":[{"id":"omarchy.tray"}],"center":[],"right":[]}},"plugins":[]}
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
  export LIBGL_ALWAYS_SOFTWARE=1
  exec dbus-run-session Hyprland --config "$HOME/.config/hypr3484.conf" > /work/evidence/cloud/hyprland.log 2>&1
fi
PROFILE
USER
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin investigator --noclear %I $TERM
GETTY
systemctl daemon-reload
systemctl restart getty@tty1
