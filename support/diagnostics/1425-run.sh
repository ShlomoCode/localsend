#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
evidence=$(realpath evidence)
rootdir=/tmp/issue1425
mkdir -p "$rootdir"
x_pids=()
cleanup() {
  pkill -u sender1425 || true
  pkill -u receiver1425 || true
  ip netns delete sender1425 || true
  ip netns delete receiver1425 || true
  for pid in "${x_pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  for role in sender1425 receiver1425; do cp "/tmp/$role-openbox.log" "$evidence/" 2>/dev/null || true; done
  chown -R "${SUDO_USER:-runner}" "$evidence"
}
trap cleanup EXIT
apt-get update
apt-get install -y xvfb openbox xdotool scrot tesseract-ocr imagemagick ffmpeg libfuse2 fuse libayatana-appindicator3-1 libsecret-1-0 libgtk-3-0 libegl1 libgles2 libgl1-mesa-dri libopengl0 at-spi2-core xdg-user-dirs network-manager tcpdump
systemctl start NetworkManager
for role in sender1425 receiver1425; do
  useradd --create-home --shell /bin/bash "$role"
  runtime="/run/user/$(id -u "$role")"
  install -d -m 700 -o "$role" -g "$role" "$runtime"
  mkdir -p "/home/$role/Downloads"
  chown "$role:$role" "/home/$role/Downloads"
  ip netns add "$role"
  ip netns exec "$role" ip link set lo up
done
ip link add send1425 type veth peer name recv1425
ip link set send1425 netns sender1425
ip link set recv1425 netns receiver1425
ip netns exec sender1425 ip addr add 192.168.142.1/24 dev send1425
ip netns exec receiver1425 ip addr add 192.168.142.2/24 dev recv1425
ip netns exec sender1425 ip link set send1425 up
ip netns exec receiver1425 ip link set recv1425 up
ip netns exec sender1425 ip route add default dev send1425
ip netns exec receiver1425 ip route add default dev recv1425
curl -fL --retry 2 -o "$rootdir/LocalSend-1.14.0-linux-x86-64.AppImage" https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0-linux-x86-64.AppImage
chmod 755 "$rootdir/LocalSend-1.14.0-linux-x86-64.AppImage"
sha256sum "$rootdir/LocalSend-1.14.0-linux-x86-64.AppImage" > "$evidence/artifact-sha256.txt"
available=$(df --output=avail -B1 "$rootdir" | tail -1)
printf 'Available bytes after dependencies and artifact: %s; minimum 15 GiB for up to 12 GiB retained transfer data plus evidence\n' "$available" > "$evidence/disk-budget.txt"
test "$available" -ge 16106127360
{
  uname -a
  cat /etc/os-release
  ls -l /dev/fuse
  df -h
  ip netns exec sender1425 ip -details addr
  ip netns exec receiver1425 ip -details addr
  dpkg-query -W xvfb openbox libfuse2 network-manager
  sysctl net.ipv4.tcp_wmem net.ipv4.tcp_rmem net.core.wmem_max net.core.rmem_max
  printf 'Reported kernel: 5.15.0-107-generic. The hosted runner kernel is an explicit environment delta.\n'
} > "$evidence/environment.txt"
for display in 81 82; do
  Xvfb ":$display" -screen 0 1100x800x24 -ac > "$evidence/xvfb-$display.log" 2>&1 &
  x_pids+=("$!")
done
for display in 81 82; do
  ready=0
  for attempt in $(seq 1 30); do
    if DISPLAY=":$display" xdotool getdisplaygeometry > "$evidence/display-$display.txt" 2>&1; then ready=1; break; fi
    sleep 1
  done
  test "$ready" = 1
done
for role in sender1425 receiver1425; do
  if [ "$role" = sender1425 ]; then display=:81; else display=:82; fi
  runtime="/run/user/$(id -u "$role")"
  ip netns exec "$role" runuser -u "$role" -- env DISPLAY="$display" XDG_RUNTIME_DIR="$runtime" LANG=C.UTF-8 LIBGL_ALWAYS_SOFTWARE=1 dbus-run-session -- bash -c 'openbox > /tmp/'"$role"'-openbox.log 2>&1 & exec /tmp/issue1425/LocalSend-1.14.0-linux-x86-64.AppImage' > "$evidence/$role-app.log" 2>&1 &
done
python3 support/diagnostics/1425-ui.py "$evidence"
ip netns exec sender1425 ss -tinp > "$evidence/sender-final-sockets.txt"
ip netns exec receiver1425 ss -tinp > "$evidence/receiver-final-sockets.txt"
