#!/bin/bash
set -euxo pipefail
exec > >(tee /evidence/gentoo-prepare.log) 2>&1
cat /etc/gentoo-release
cat /etc/portage/make.conf
emerge-webrsync
readlink -f /etc/portage/make.profile
mkdir -p /etc/portage/package.use
printf '%s\n' 'x11-libs/gtk+ -wayland X' 'x11-libs/libxkbcommon -wayland X' 'media-libs/mesa -wayland X' > /etc/portage/package.use/issue2690
emerge --info > /evidence/gentoo-info.txt
emerge --pretend --verbose --getbinpkg x11-libs/gtk+ x11-wm/dwm x11-base/xorg-server x11-misc/xdotool > /evidence/gentoo-plan.txt
cat /evidence/gentoo-plan.txt
