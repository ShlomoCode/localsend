#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 2
mkdir -p evidence/current evidence/release17 released/current released/release17
printf '%s  %s\n' 98f6e749c0eb470b7d2bb4a365f704328ae7dc4bbc6d78ddf2d574dfb63cc20b source-artifact/source-bundle.tar.gz | sha256sum -c -
test ! -s source-artifact/provenance/source-diff-after.patch
cp -a source-artifact/provenance evidence/current/provenance
tar -xzf source-artifact/source-bundle.tar.gz -C released/current
curl -Lf https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.tar.gz -o evidence/release17/original.tar.gz
sha256sum evidence/release17/original.tar.gz > evidence/release17/original.sha256
tar -xzf evidence/release17/original.tar.gz -C released/release17
uname -a > evidence/environment.txt
ip addr >> evidence/environment.txt
for variant in current release17; do
  find released/$variant -type f -exec sha256sum {} + > evidence/$variant/bundle.sha256
  ISSUE2374_VARIANT=$variant timeout 600 dbus-run-session -- xvfb-run -a -s '-screen 0 1200x800x24' bash -c '
    export LIBGL_ALWAYS_SOFTWARE=1
    openbox > evidence/$ISSUE2374_VARIANT/openbox.log 2>&1 &
    for n in $(seq 1 30); do
      if xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id"; then break; fi
      sleep 1
    done
    python3 support/diagnostics/2374/ui.py
  ' > evidence/$variant/scenario.log 2>&1
done
