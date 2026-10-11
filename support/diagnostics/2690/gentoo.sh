#!/bin/bash
set -euxo pipefail
exec > >(tee /evidence/gentoo-prepare.log) 2>&1
cat /etc/gentoo-release
cat /etc/portage/make.conf
emerge-webrsync
readlink -f /etc/portage/make.profile
mkdir -p /etc/portage/package.use
printf '%s\n' 'x11-libs/gtk+ -wayland X' 'x11-libs/libxkbcommon -wayland X' 'media-libs/mesa -wayland X' > /etc/portage/package.use/issue2690
printf '%s\n' 'x11-base/xorg-server xvfb' >> /etc/portage/package.use/issue2690
printf '%s\n' 'MAKEOPTS="-j4"' >> /etc/portage/make.conf
emerge --info > /evidence/gentoo-info.txt
packages=(x11-libs/gtk+ x11-wm/dwm x11-base/xorg-server x11-misc/xdotool x11-terms/xterm x11-apps/xwd media-fonts/dejavu media-fonts/font-misc-misc sys-apps/dbus sys-fs/fuse:0)
emerge --pretend --verbose --getbinpkg "${packages[@]}" > /evidence/gentoo-plan.txt
cat /evidence/gentoo-plan.txt
emerge --verbose --getbinpkg --jobs=2 "${packages[@]}"
gcc /diagnostic/gtk-control.c -o /tmp/gtk-control $(pkg-config --cflags --libs gtk+-3.0)
find /var/db/pkg -maxdepth 2 -type d | sort > /evidence/installed-before.txt
if find /var/db/pkg/dev-libs -maxdepth 1 -name 'wayland-*' | grep .; then
  echo 'INVALID BASELINE: Wayland was unexpectedly installed'; exit 1
fi
find /usr/lib* /lib* -name 'libwayland*' > /evidence/wayland-before.txt
test ! -s /evidence/wayland-before.txt
useradd -m -s /bin/bash tester
chmod -R a+rX /evidence
mkdir -p /evidence/launch
chmod 777 /evidence/launch
Xvfb :99 -screen 0 1280x800x24 +extension GLX > /evidence/xvfb.log 2>&1 &
sleep 3
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh baseline'
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh baseline-current /evidence/current.AppImage'
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh baseline-repacked /evidence/repacked-baseline.AppImage'
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh candidate /evidence/repacked-candidate.AppImage'
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh baseline-client /evidence/repacked-cursor-egl.AppImage libwayland-client.so.0'
emerge --verbose --getbinpkg dev-libs/wayland
find /var/db/pkg -maxdepth 2 -type d | sort > /evidence/installed-after.txt
find /usr/lib* /lib* -name 'libwayland*' > /evidence/wayland-after.txt
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh control'
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh control-current /evidence/current.AppImage'
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/launch.sh control-candidate /evidence/repacked-candidate.AppImage'
printf '%s\n' 'x11-libs/gtk+ wayland X' 'x11-libs/libxkbcommon wayland X' 'media-libs/mesa wayland X' 'dev-libs/weston X desktop gles2 -drm -suid' > /etc/portage/package.use/issue2690
emerge --pretend --verbose --getbinpkg x11-libs/gtk+ x11-libs/libxkbcommon media-libs/mesa dev-libs/weston > /evidence/wayland-plan.txt
emerge --verbose --getbinpkg --jobs=2 x11-libs/gtk+ x11-libs/libxkbcommon media-libs/mesa dev-libs/weston
emerge --info > /evidence/wayland-info.txt
gcc /diagnostic/gtk-control.c -o /tmp/gtk-control $(pkg-config --cflags --libs gtk+-3.0)
readelf -Ws /usr/lib64/libEGL_mesa.so.0 > /evidence/mesa-egl-symbols.txt
readelf -Ws /usr/lib64/libwayland-client.so.0 > /evidence/host-client-symbols.txt
readelf -Ws /evidence/package-candidate/AppDir/usr/lib/x86_64-linux-gnu/libwayland-client.so.0 > /evidence/candidate-client-symbols.txt
su tester -c 'DISPLAY=:99 dbus-run-session -- bash /diagnostic/wayland.sh'
