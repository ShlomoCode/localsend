#!/bin/bash
set -euxo pipefail
exec > >(tee /evidence/wayland-prepare.log) 2>&1
emerge-webrsync
mkdir -p /etc/portage/package.use
printf '%s\n' 'x11-libs/gtk+ wayland X' 'x11-libs/libxkbcommon wayland X' 'media-libs/mesa wayland X' 'dev-libs/weston X desktop gles2 -drm -suid' 'x11-base/xorg-server xvfb' > /etc/portage/package.use/issue2690
printf '%s\n' 'MAKEOPTS="-j4"' >> /etc/portage/make.conf
packages=(x11-libs/gtk+ x11-libs/libxkbcommon media-libs/mesa dev-libs/weston x11-wm/dwm x11-base/xorg-server x11-apps/xwd media-fonts/dejavu sys-apps/dbus sys-fs/fuse:0)
emerge --pretend --verbose --getbinpkg "${packages[@]}" > /evidence/wayland-plan.txt
emerge --verbose --getbinpkg --jobs=2 "${packages[@]}"
emerge --info > /evidence/wayland-info.txt
gcc /diagnostic/gtk-control.c -o /tmp/gtk-control $(pkg-config --cflags --libs gtk+-3.0)
useradd -m -s /bin/bash tester
chmod -R a+rX /evidence
chmod 777 /evidence/launch
chown -R tester:tester /evidence/launch
readelf -Ws /usr/lib64/libEGL_mesa.so.0 > /evidence/mesa-egl-symbols.txt
readelf -Ws /usr/lib64/libwayland-client.so.0 > /evidence/host-client-symbols.txt
Xvfb :99 -screen 0 1920x1080x24 +extension GLX > /evidence/xvfb.log 2>&1 &
sleep 3
su tester -c 'DISPLAY=:99 WAYLAND_FRESH_HOME=1 WAYLAND_FOCUSED=1 dbus-run-session -- bash /diagnostic/wayland.sh'
