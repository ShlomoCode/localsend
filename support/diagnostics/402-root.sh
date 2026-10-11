#!/bin/bash
set -euo pipefail
mkdir -p /run/dbus
dbus-daemon --system --fork
NetworkManager --no-daemon > /tmp/network-manager.log 2>&1 &
sleep 3
exec runuser -u probe -- bash /home/probe/session.sh
