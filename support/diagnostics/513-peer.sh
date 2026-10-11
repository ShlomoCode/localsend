#!/bin/bash
# Cloud-only real peer: independent profile and virtual Ethernet network.
set -euo pipefail
/home/runner/513-vm/ssh 'bash -s' > evidence/vm/peer-setup.txt 2>&1 <<'GUEST'
set -euo pipefail
sudo useradd -m -s /bin/bash receiver
peer_uid=$(id -u receiver)
sudo mkdir -p "/run/user/$peer_uid" /home/receiver/Downloads /home/receiver/.config
sudo chown -R receiver:receiver "/run/user/$peer_uid" /home/receiver/Downloads /home/receiver/.config
sudo chmod 700 "/run/user/$peer_uid"
printf 'XDG_DOWNLOAD_DIR="/home/receiver/Downloads"\n' | sudo tee /home/receiver/.config/user-dirs.dirs >/dev/null
sudo chown receiver:receiver /home/receiver/.config/user-dirs.dirs
# Grant the other VM user access only to the graphical session socket.
sudo setfacl -m u:receiver:x /run/user/$(id -u)
sudo setfacl -m u:receiver:rw /run/user/$(id -u)/wayland-0
printf 'RECEIVER_UID=%s\nRECEIVER_HOME=/home/receiver\n' "$peer_uid"
sudo ip netns add issue513peer
sudo ip link add peer0 type veth peer name peer1
sudo ip link set peer1 netns issue513peer
sudo ip address add 192.168.51.1/24 dev peer0
sudo ip link set peer0 up
sudo ip netns exec issue513peer ip link set lo up
sudo ip netns exec issue513peer ip address add 192.168.51.2/24 dev peer1
sudo ip netns exec issue513peer ip link set peer1 up
sudo ip netns exec issue513peer ip route add 224.0.0.0/4 dev peer1
ip -brief address
sudo ip netns exec issue513peer ip -brief address
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0
nohup sudo ip netns exec issue513peer runuser -l receiver -c "env XDG_RUNTIME_DIR=/run/user/$peer_uid WAYLAND_DISPLAY=/run/user/$(id -u)/wayland-0 XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland dbus-run-session -- flatpak run org.localsend.localsend_app" > /home/probe/513-peer.log 2>&1 < /dev/null &
GUEST
sleep 12
