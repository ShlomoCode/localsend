#!/bin/bash
set -euo pipefail
# Two distinct peers share the real X11 desktop but have separate network stacks.
sudo ip netns add issue2414-sender
sudo ip link add peer2414-host type veth peer name peer2414-send
sudo ip link set peer2414-send netns issue2414-sender
sudo ip addr add 10.84.24.1/24 dev peer2414-host
sudo ip link set peer2414-host up
sudo ip netns exec issue2414-sender ip addr add 10.84.24.2/24 dev peer2414-send
sudo ip netns exec issue2414-sender ip link set peer2414-send up
sudo ip netns exec issue2414-sender ip link set lo up
ip addr show peer2414-host > evidence/network.txt
sudo ip netns exec issue2414-sender ip addr >> evidence/network.txt
