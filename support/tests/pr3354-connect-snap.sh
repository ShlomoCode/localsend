#!/usr/bin/env bash
set -euo pipefail
# Content providers are auto-installed by snapd. Exercise the declared desktop
# interfaces without disabling AppArmor or installing in devmode.
for plug in desktop desktop-legacy wayland x11 opengl network network-bind home gsettings unity7 network-manager removable-media; do
  if snap connections localsend | awk -v endpoint="localsend:$plug" '$2 == endpoint { found=1 } END { exit !found }'; then
    sudo snap connect "localsend:$plug"
  fi
done
test "$(snap debug confinement)" = strict
