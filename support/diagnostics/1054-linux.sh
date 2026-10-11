#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || { echo "Cloud-only harness" >&2; exit 2; }
mkdir -p evidence released/base
cp -a source-artifact/provenance evidence/source-provenance
if [[ -n ${ISSUE1054_CONTROLLED_VARIANT:-} ]]; then
  (cd source-artifact && sha256sum -c source-bundle.tar.gz.sha256)
  [[ $(jq -r .variant source-artifact/provenance/build-inputs.json) == "$ISSUE1054_CONTROLLED_VARIANT" ]]
  [[ $(jq -r .run_url source-artifact/provenance/build-inputs.json) == "https://github.com/ShlomoCode/localsend/actions/runs/${ISSUE1054_SOURCE_RUN:-$GITHUB_RUN_ID}" ]]
  cmp source-artifact/provenance/source-diff-before.patch source-artifact/provenance/source-diff-after.patch
  if [[ $ISSUE1054_CONTROLLED_VARIANT == baseline ]]; then
    [[ ! -s source-artifact/provenance/source-diff-after.patch ]]
  else
    cmp support/diagnostics/1054-source/refresh-size.patch source-artifact/provenance/source-diff-after.patch
  fi
else
  printf "%s  %s\n" 98f6e749c0eb470b7d2bb4a365f704328ae7dc4bbc6d78ddf2d574dfb63cc20b source-artifact/source-bundle.tar.gz | sha256sum -c -
  [[ $(jq -r .run_url source-artifact/provenance/build-inputs.json) == https://github.com/ShlomoCode/localsend/actions/runs/38132747719 ]]
  [[ ! -s source-artifact/provenance/source-diff-after.patch ]]
fi
[[ $(jq -r .source_sha source-artifact/provenance/build-inputs.json) == c1ce322fb3acf08e44f329b8b7208b8b0d91e244 ]]
[[ $(jq -r .flutter_version source-artifact/provenance/build-inputs.json) == 3.41.9 ]]
sha256sum source-artifact/source-bundle.tar.gz > evidence/source-bundle-sha256.txt
tar -xzf source-artifact/source-bundle.tar.gz -C released/base
ldd released/base/localsend_app > evidence/executable-ldd.txt
if grep -q "not found" evidence/executable-ldd.txt; then exit 1; fi
find released/base -type f -exec sha256sum {} + > evidence/bundle-files-sha256.txt
uname -a > evidence/environment.txt
printf "Source run38132747719 artifact11700370485; decimal 11MB=11000000bytes,14MB=14000000bytes. Report did not specify byte units. Two fixed repeats.\n" >> evidence/environment.txt
sudo ip netns add issue1054-receiver
cleanup() {
  sudo ip netns pids issue1054-receiver | xargs -r sudo kill || true
  sudo ip netns del issue1054-receiver || true
  sudo ip link del peer1054-host || true
}
trap cleanup EXIT
sudo ip link add peer1054-host type veth peer name peer1054-recv
sudo ip link set peer1054-recv netns issue1054-receiver
sudo ip addr add 10.84.54.1/24 dev peer1054-host
sudo ip link set peer1054-host up
sudo ip netns exec issue1054-receiver ip addr add 10.84.54.2/24 dev peer1054-recv
sudo ip netns exec issue1054-receiver ip link set peer1054-recv up
sudo ip netns exec issue1054-receiver ip link set lo up
ip addr show peer1054-host > evidence/network.txt
sudo ip netns exec issue1054-receiver ip addr >> evidence/network.txt
# The sender retains ordinary host D-Bus/native GTK file picker access. Real
# receiver has its own network stack and session, same default protocol port.
timeout 1200 dbus-run-session -- xvfb-run -a -s "-screen 0 1200x800x24" bash -c '
  export LIBGL_ALWAYS_SOFTWARE=1
  openbox > evidence/openbox.log 2>&1 &
  for n in $(seq 1 30); do
    if xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id"; then break; fi
    sleep 1
  done
  xprop -root _NET_SUPPORTING_WM_CHECK > evidence/window-manager.txt
  grep -q "window id" evidence/window-manager.txt || exit 1
  python3 support/diagnostics/1054-ui.py
' > evidence/scenario.log 2>&1
