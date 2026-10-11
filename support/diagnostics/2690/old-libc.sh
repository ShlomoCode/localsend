#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y libgtk-3-dev libgl1-mesa-dri libegl1-mesa libgl1 xvfb xterm xdotool dwm x11-apps gcc pkg-config fonts-dejavu-core dbus-x11 libfuse2
cat /etc/os-release > /evidence/old-libc-os.txt
ldd --version > /evidence/old-libc-version.txt
dpkg-query -W > /evidence/old-libc-packages.txt
gcc /diagnostic/gtk-control.c -o /tmp/gtk-control $(pkg-config --cflags --libs gtk+-3.0)
useradd -m -s /bin/bash tester
chmod -R a+rX /evidence
chmod 777 /evidence/launch
Xvfb :99 -screen 0 1920x1080x24 +extension GLX > /evidence/old-libc-xvfb.log 2>&1 &
sleep 3
su tester -c 'DISPLAY=:99 GDK_BACKEND=x11 TRACE_LOADER=1 dbus-run-session -- bash /diagnostic/launch.sh observe-old-libc-current /evidence/current.AppImage'
su tester -c 'DISPLAY=:99 GDK_BACKEND=x11 TRACE_LOADER=1 dbus-run-session -- bash /diagnostic/launch.sh observe-old-libc-candidate /evidence/repacked-candidate.AppImage'
su tester -c 'DISPLAY=:99 GDK_BACKEND=x11 TRACE_LOADER=1 dbus-run-session -- bash /diagnostic/launch.sh old-libc-new-client /evidence/repacked-new-client.AppImage'
su tester -c 'DISPLAY=:99 GDK_BACKEND=x11 TRACE_LOADER=1 dbus-run-session -- bash /diagnostic/launch.sh observe-old-libc-current-after /evidence/current.AppImage'
