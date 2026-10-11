#!/bin/bash
# Cloud-only real peer: independent profile and virtual Ethernet network.
set -euo pipefail
/home/runner/513-vm/ssh 'bash -s' > evidence/vm/peer-setup.txt 2>&1 <<'GUEST'
set -euo pipefail
app_home=/home/probe/.var/app/org.localsend.localsend_app
profile=$(find "$app_home" -type f -name shared_preferences.json -print -quit)
test -n "$profile"
relative=${profile#"$app_home/"}
peer_profile="$app_home/peer/$relative"
mkdir -p "$(dirname "$peer_profile")" /home/probe/Downloads/513-received
printf '%s\n' '{"flutter.ls_alias":"Issue513Receiver","flutter.ls_destination":"/home/probe/Downloads/513-received"}' > "$peer_profile"
printf 'SOURCE_PROFILE_PATH=%s\nPEER_PROFILE_PATH=%s\n' "$profile" "$peer_profile"
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
nohup sudo ip netns exec issue513peer runuser -l probe -c "env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY=wayland-0 flatpak run --env=XDG_DATA_HOME=$app_home/peer/data --env=XDG_CONFIG_HOME=$app_home/peer/config --env=XDG_CACHE_HOME=$app_home/peer/cache org.localsend.localsend_app" > /home/probe/513-peer.log 2>&1 < /dev/null &
GUEST
sleep 12
