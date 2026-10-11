#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux ]] || { echo "Requires the authorized Linux cloud Actions runner" >&2; exit 8; }
mkdir -p evidence/cloud /home/runner/issue2754-mint /tmp/issue2754-mint/seed
probe_bridge_variant=${PROBE_BRIDGE_VARIANT:-system}
probe_bridge_delivery=${PROBE_BRIDGE_DELIVERY:-diagnostic}
case "$probe_bridge_delivery" in diagnostic|package) ;; *) exit 2 ;; esac
if [[ $probe_bridge_delivery == package ]]; then
 [[ $probe_bridge_variant == A ]]
 bridge_package=${PROBE_BRIDGE_PACKAGE_DIR:?Missing source-built candidate package}
 (cd "$bridge_package" && sha256sum -c SHA256SUMS)
 jq -e '.variant == "A" and .source_version == "2.52.0-1build1" and
   .package_name == "libatk-bridge2.0-0t64" and .package_version == "2.52.0-1build1+localsend2754.1" and
   .patch_sha256 == "d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d"' "$bridge_package/manifest.json"
fi
probe_engine_variant=${PROBE_ENGINE_VARIANT:-official}
probe_bundle_run_id=${PROBE_BUNDLE_RUN_ID:-}
probe_engine_patch_hash=unused
case "$probe_engine_variant" in
 official) ;;
 control|B)
  test "${PROBE_APP_SOURCE:-official-deb}" = c1ce
  [[ "$probe_bundle_run_id" =~ ^[0-9]+$ ]]
  [[ "$probe_bridge_variant" = system || "$probe_bridge_variant" = A ]]
  probe_engine_patch_hash=$(sha256sum support/diagnostics/2754-engine-build/B-with-tests.patch | awk '{print $1}')
  ;;
 *) echo "Unsupported engine variant: $probe_engine_variant" >&2; exit 2 ;;
esac
probe_capture_geometry=${PROBE_CAPTURE_GEOMETRY:-0}
probe_capture_interactions=${PROBE_CAPTURE_INTERACTIONS:-0}
probe_capture_root_name_evidence=${PROBE_CAPTURE_ROOT_NAME_EVIDENCE:-0}
case "$probe_capture_root_name_evidence" in 0|1) ;; *) exit 2 ;; esac
if [[ $probe_capture_root_name_evidence == 1 ]]; then
 [[ $probe_capture_geometry == 1 && $probe_engine_variant == B && $probe_bridge_variant == A && $probe_bridge_delivery == package ]]
fi
case "$probe_capture_interactions" in 0|1) ;; *) exit 2 ;; esac
if [[ $probe_capture_interactions == 1 ]]; then
 [[ $probe_capture_geometry == 1 && $probe_engine_variant != official ]]
fi
case "$probe_capture_geometry" in
 0) ;;
 1) [[ "$probe_bridge_variant" == stock || "$probe_bridge_variant" == A || "$probe_engine_variant" != official ]] || { echo "Geometry capture requires a bridge or source-built engine run" >&2; exit 2; } ;;
 *) echo "Unsupported geometry capture flag: $probe_capture_geometry" >&2; exit 2 ;;
esac
case "$probe_bridge_variant" in
 system) ;;
 stock|A)
  test "${PROBE_APP_SOURCE:-official-deb}" = c1ce
  if [[ $probe_bridge_delivery == diagnostic ]]; then
  bridge_artifact=${PROBE_BRIDGE_ARTIFACT:?Missing accepted native bridge artifact}
  grep -qx 'exit_status=0' "$bridge_artifact/result.txt"
  grep -qx 'stock_self_wait_detected=true' "$bridge_artifact/gates.txt"
  grep -qx 'candidate_native_suite_passed=true' "$bridge_artifact/gates.txt"
  cmp support/diagnostics/2754-atspi-native/A-local-dispatch.patch "$bridge_artifact/A-local-dispatch.patch"
  bridge_expected=$(awk 'NR==1 {print $1}' "$bridge_artifact/bridge-$probe_bridge_variant.sha256")
  [[ "$bridge_expected" =~ ^[0-9a-f]{64}$ ]]
  printf '%s  %s\n' "$bridge_expected" "$bridge_artifact/libatk-bridge-$probe_bridge_variant.so.0" | sha256sum -c -
  mkdir -p /tmp/issue2754-mint/diagnostic-bridge
  cp "$bridge_artifact/libatk-bridge-$probe_bridge_variant.so.0" /tmp/issue2754-mint/diagnostic-bridge/libatk-bridge-2.0.so.0
  printf '%s  libatk-bridge-2.0.so.0\n' "$bridge_expected" > /tmp/issue2754-mint/diagnostic-bridge/library.sha256
  printf '%s\n' "$probe_bridge_variant" > /tmp/issue2754-mint/diagnostic-bridge/variant.txt
  cp "$bridge_artifact/source.sha256" "$bridge_artifact/tested-source.sha256" "$bridge_artifact/gates.txt" "$bridge_artifact/result.txt" "$bridge_artifact/A-local-dispatch.patch" /tmp/issue2754-mint/diagnostic-bridge/
  cp "$bridge_artifact/bridge-build-id-$probe_bridge_variant.txt" /tmp/issue2754-mint/diagnostic-bridge/native-build-id.txt
  cp evidence/cloud/bridge/selection.txt evidence/cloud/bridge/native-run.json /tmp/issue2754-mint/diagnostic-bridge/
  fi
  ;;
 *) echo "Unsupported bridge variant: $probe_bridge_variant" >&2; exit 1 ;;
esac
free -m > evidence/cloud/resources.txt
df -Th /home/runner /tmp >> evidence/cloud/resources.txt
test "$(df -Pk /home/runner | awk "NR==2 {print \$4}")" -ge 12582912
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage socat imagemagick openssh-client tesseract-ocr
for mirror in https://mirror.csclub.uwaterloo.ca/linuxmint https://mirrors.edge.kernel.org/linuxmint; do
  if curl -fL --connect-timeout 20 --max-time 600 --speed-time 90 --speed-limit 1048576 "$mirror/stable/22.2/linuxmint-22.2-cinnamon-64bit.iso" -o /home/runner/issue2754-mint/mint.iso; then break; fi
done
printf "759c9b5a2ad26eb9844b24f7da1696c705ff5fe07924a749f385f435176c2306  /home/runner/issue2754-mint/mint.iso\n" | sha256sum -c - | tee evidence/cloud/iso-hash.txt
ssh-keygen -q -t ed25519 -N "" -f /tmp/issue2754-mint/id
cp /tmp/issue2754-mint/id.pub /tmp/issue2754-mint/seed/id.pub
sed "s@/home/probe@/home/mint@g" support/diagnostics/2754-ui.py > /tmp/issue2754-mint/seed/ui.py
cp support/diagnostics/2754-recording-clips.py /tmp/issue2754-mint/seed/recording-clips.py
{
 printf 'diagnostic_commit=%s\n' "$(git rev-parse HEAD)"
 sha256sum support/diagnostics/2754-mint-vm.sh support/diagnostics/2754-ui.py support/diagnostics/2754-recording-clips.py
} > /tmp/issue2754-mint/seed/recording-source.txt
if [ "$probe_capture_geometry" = 1 ]; then
 cp -a support/diagnostics/2754-accessibility /tmp/issue2754-mint/seed/
fi
if [ "$probe_engine_variant" != official ]; then
 cp support/diagnostics/2754-engine-build/verify-loaded-engine.sh /tmp/issue2754-mint/seed/
fi
cat > /tmp/issue2754-mint/seed/bootstrap.sh <<"BOOT"
#!/bin/bash
set -euxo pipefail
exec > >(tee /tmp/issue2754-bootstrap.log /dev/ttyS0) 2>&1
phase=files
monitor_pid=
trap 'status=$?; echo "BOOTSTRAP_EXIT phase=$phase status=$status"; if [ -n "$monitor_pid" ]; then kill "$monitor_pid" || true; fi' EXIT
mkdir -p /home/mint/.ssh /home/mint/evidence /home/mint/support/diagnostics
cp /mnt/id.pub /home/mint/.ssh/authorized_keys
cp /mnt/ui.py /home/mint/support/diagnostics/2754-ui.py
cp /mnt/recording-clips.py /home/mint/support/diagnostics/2754-recording-clips.py
cp /mnt/recording-source.txt /home/mint/evidence/recording-source.txt
sha256sum /home/mint/support/diagnostics/2754-ui.py /home/mint/support/diagnostics/2754-recording-clips.py > /home/mint/evidence/recording-staged-source.sha256
if [ -d /mnt/2754-accessibility ]; then
 cp -a /mnt/2754-accessibility /home/mint/support/diagnostics/
fi
if [ -f /mnt/verify-loaded-engine.sh ]; then
 cp /mnt/verify-loaded-engine.sh /home/mint/support/diagnostics/
fi
chown -R mint:mint /home/mint/.ssh /home/mint/evidence /home/mint/support
chmod 700 /home/mint/.ssh
chmod 600 /home/mint/.ssh/authorized_keys
# Preserve evidence while package post-install scripts run, independently of SSH readiness.
(
  while true; do
    date -u '+%FT%TZ'
    ps --forest -eo pid,ppid,etimes,stat,pcpu,pmem,wchan:32,args
    for process in $(pgrep -x 'apt-get|dpkg|ldconfig.*|mandb' || true); do
      echo "PACKAGE_PROCESS $process"
      cat "/proc/$process/status" "/proc/$process/io" "/proc/$process/stack" || true
    done
    free -m
    df -h / /tmp
    vmstat 1 2
    sleep 10
  done
) > /home/mint/evidence/bootstrap-processes.txt 2>&1 &
monitor_pid=$!
phase=apt-sources
# The live ISO enables an unregistered cdrom source; retain it and disable only that source.
cp -a /etc/apt /home/mint/evidence/apt-before
for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  test -f "$source" || continue
  sed -i '/^[[:space:]]*deb.*cdrom:/s/^/# Diagnostic live-media source disabled: /' "$source"
done
phase=apt-update
timeout 240 apt-get update
phase=ssh-install
# APT uses the live terminal; a separate timeout process group stopped it during job control.
timeout --foreground 240 apt-get install -y -o DPkg::Lock::Timeout=120 openssh-server
phase=ssh-start
systemctl start ssh
systemctl show ssh -p ActiveState -p SubState
ss -ltnp 'sport = :22'
timeout 10 ssh-keyscan 127.0.0.1
touch /home/mint/evidence/bootstrap-complete
phase=complete
BOOT
genisoimage -quiet -o /home/runner/issue2754-mint/probe.iso -V PROBE -r /tmp/issue2754-mint/seed
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -boot d -drive file=/home/runner/issue2754-mint/mint.iso,media=cdrom,readonly=on -drive file=/home/runner/issue2754-mint/probe.iso,media=cdrom,readonly=on -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2275-:22 -device virtio-net-pci,netdev=net0 -display none -monitor unix:/tmp/issue2754-mint/monitor,server,nowait -serial file:evidence/cloud/serial.log -pidfile /tmp/issue2754-mint/qemu.pid -daemonize
qemu_pid=$(sudo cat /tmp/issue2754-mint/qemu.pid)
[[ $qemu_pid =~ ^[1-9][0-9]*$ ]]
qemu_start_time=$(sudo awk '{print $22}' "/proc/$qemu_pid/stat")
[[ $qemu_start_time =~ ^[0-9]+$ ]]
sudo cat "/proc/$qemu_pid/cmdline" > evidence/cloud/owned-qemu-cmdline.bin
owned_qemu_alive() {
 sudo kill -0 "$qemu_pid" 2>/dev/null || return 1
 [[ $(sudo awk '{print $22}' "/proc/$qemu_pid/stat" 2>/dev/null) == "$qemu_start_time" ]] || return 1
 sudo cmp -s "/proc/$qemu_pid/cmdline" evidence/cloud/owned-qemu-cmdline.bin
}
stop_owned_vm() {
 local status=$?
 trap - EXIT
 set +e
 printf 'quit\n' | timeout 5 sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor > evidence/cloud/vm-stop.log 2>&1
 for attempt in $(seq 1 50); do
  owned_qemu_alive || break
  sleep 0.1
 done
 if owned_qemu_alive; then
  sudo kill -TERM "$qemu_pid" >> evidence/cloud/vm-stop.log 2>&1
 fi
 for attempt in $(seq 1 50); do
  owned_qemu_alive || break
  sleep 0.1
 done
 if owned_qemu_alive; then
  printf 'owned_vm_still_alive=true\n' >> evidence/cloud/vm-stop.log
  status=1
 fi
 printf 'scenario_exit_status=%s\nowned_qemu_pid=%s\n' "$status" "$qemu_pid" > evidence/cloud/vm-stop-status.txt
 exit "$status"
}
trap stop_owned_vm EXIT
# Verify normal graphical live login from the rendered desktop before sending terminal input.
desktop_ready=0
for n in $(seq 1 18); do
  sleep 15
  printf "screendump %s/evidence/cloud/desktop-readiness.ppm\n" "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor
  sudo chmod a+r evidence/cloud/desktop-readiness.ppm
  convert evidence/cloud/desktop-readiness.ppm evidence/cloud/desktop-readiness.png
  tesseract evidence/cloud/desktop-readiness.png stdout > evidence/cloud/desktop-readiness.txt 2>/dev/null
  if grep -Eq "Computer|Home|Install.*Mint" evidence/cloud/desktop-readiness.txt; then desktop_ready=1; break; fi
done
echo "DESKTOP_READY=$desktop_ready"
test "$desktop_ready" = 1
printf "screendump %s/evidence/cloud/mint-start.ppm\n" "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor
printf "sendkey ctrl-alt-t\n" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor
sleep 5
# Only cloud execution: transmit terminal keystrokes through QEMU monitor.
sudo python3 - <<"KEYS"
import socket,time
command="sudo mount /dev/sr1 /mnt; sudo bash /mnt/bootstrap.sh"
keys={" ":"spc","/":"slash",";":"semicolon",".":"dot","-":"minus"}
s=socket.socket(socket.AF_UNIX);s.connect("/tmp/issue2754-mint/monitor");s.settimeout(.1)
for ch in command:
    s.sendall(("sendkey "+keys.get(ch,ch)+" 40\n").encode());time.sleep(.08)
time.sleep(.5);s.close()
KEYS
# A separate HMP invocation keeps Return from being lost when the typing socket closes.
printf "sendkey ret 80\n" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor > evidence/cloud/return-monitor.log
sleep 3
printf "screendump %s/evidence/cloud/terminal-checkpoint.ppm\n" "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor > evidence/cloud/checkpoint-monitor.log
opts=(-i /tmp/issue2754-mint/id -p 2275 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known -o ConnectTimeout=5)
ready=0
for n in $(seq 1 50); do
 date -u '+%FT%TZ' >> evidence/cloud/readiness.log
 if timeout 10 ssh "${opts[@]}" mint@127.0.0.1 "test -f /home/mint/evidence/bootstrap-complete && pgrep -x cinnamon" >> evidence/cloud/readiness.log 2>&1; then ready=1; break; fi
 if sudo grep -Eq 'BOOTSTRAP_EXIT.*status=[1-9]' evidence/cloud/serial.log; then break; fi
 sleep 15
done
printf "screendump %s/evidence/cloud/bootstrap.ppm\n" "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor
sudo chown -R "$(id -u):$(id -g)" evidence/cloud
if [ "$ready" != 1 ]; then
 timeout 30 scp -r -i /tmp/issue2754-mint/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest || true
 exit 1
fi
probe_app_source=${PROBE_APP_SOURCE:-official-deb}
case "$probe_app_source" in
 official-deb) ;;
 c1ce)
  test -f "${PROBE_BUNDLE_TAR:?Missing pinned source bundle}"
  bundle_directory=$(dirname "$PROBE_BUNDLE_TAR")
  (cd "$bundle_directory" && sha256sum -c source-bundle.tar.gz.sha256)
  test "$(cat "$bundle_directory/provenance/source-sha.txt")" = c1ce322fb3acf08e44f329b8b7208b8b0d91e244
  grep -q '"frameworkVersion": "3.41.9"' "$bundle_directory/provenance/flutter-version.json"
  grep -q '^exit_status=0$' "$bundle_directory/provenance/build-result.txt"
  scp -r -i /tmp/issue2754-mint/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known "$bundle_directory" mint@127.0.0.1:/home/mint/source-artifact
  ;;
 *) echo "Unsupported diagnostic source: $probe_app_source" >&2; exit 1 ;;
esac
if [[ $probe_bridge_delivery == package ]]; then
 scp -r -i /tmp/issue2754-mint/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known "$bridge_package" mint@127.0.0.1:/home/mint/bridge-package
elif [ "$probe_bridge_variant" != system ]; then
 scp -r -i /tmp/issue2754-mint/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known /tmp/issue2754-mint/diagnostic-bridge mint@127.0.0.1:/home/mint/diagnostic-bridge
fi
set +e
timeout 900 ssh "${opts[@]}" mint@127.0.0.1 "PROBE_APP_SOURCE=$probe_app_source PROBE_BRIDGE_VARIANT=$probe_bridge_variant PROBE_BRIDGE_DELIVERY=$probe_bridge_delivery PROBE_ENGINE_VARIANT=$probe_engine_variant PROBE_BUNDLE_RUN_ID=$probe_bundle_run_id PROBE_ENGINE_PATCH_HASH=$probe_engine_patch_hash PROBE_CAPTURE_GEOMETRY=$probe_capture_geometry PROBE_CAPTURE_INTERACTIONS=$probe_capture_interactions PROBE_CAPTURE_ROOT_NAME_EVIDENCE=$probe_capture_root_name_evidence bash -s" > evidence/cloud/provision.log 2>&1 <<"GUEST"
set -euo pipefail
cd /home/mint
cp /tmp/issue2754-bootstrap.log evidence/bootstrap.log
geometry_packages=()
if [ "$PROBE_CAPTURE_GEOMETRY" = 1 ]; then
 geometry_packages=(build-essential pkg-config libatspi2.0-dev libglib2.0-dev libx11-dev jq)
 test -f support/diagnostics/2754-accessibility/capture-geometry.sh
 test -f support/diagnostics/2754-accessibility/x11-window.c
fi
engine_packages=()
if [ "$PROBE_ENGINE_VARIANT" != official ]; then
 engine_packages=(jq)
 test -f support/diagnostics/verify-loaded-engine.sh
fi
interaction_packages=()
root_name_packages=()
if [[ $PROBE_CAPTURE_ROOT_NAME_EVIDENCE == 1 ]]; then
 root_name_packages=(curl ca-certificates)
 test -f support/diagnostics/2754-accessibility/capture-root-name-evidence.sh
 test -f support/diagnostics/2754-accessibility/prepare-root-name-symbols.sh
fi
if [[ $PROBE_CAPTURE_INTERACTIONS == 1 ]]; then
 interaction_packages=(orca python3-speechd speech-dispatcher speech-dispatcher-espeak-ng pulseaudio-utils)
 test -f support/diagnostics/2754-accessibility/capture-interactions.sh
 test -f support/diagnostics/2754-accessibility/interaction-client.c
fi
dpkg-query -W -f='${Package}\t${Version}\n' | sort > evidence/provision-packages-before.tsv
timeout 600 sudo apt-get install -y -o DPkg::Lock::Timeout=120 xdotool scrot tesseract-ocr xclip ffmpeg gdb strace binutils "${geometry_packages[@]}" "${engine_packages[@]}" "${interaction_packages[@]}" "${root_name_packages[@]}"
dpkg-query -W -f='${Package}\t${Version}\n' | sort > evidence/provision-packages-after.tsv
diff -u evidence/provision-packages-before.tsv evidence/provision-packages-after.tsv > evidence/provision-package-diff.txt || test "$?" = 1
printf 'capture_interactions=%s\n' "$PROBE_CAPTURE_INTERACTIONS" > evidence/interaction-capture-setting.txt
printf 'capture_geometry=%s\n' "$PROBE_CAPTURE_GEOMETRY" > evidence/geometry-capture-setting.txt
printf 'capture_root_name_evidence=%s\n' "$PROBE_CAPTURE_ROOT_NAME_EVIDENCE" > evidence/root-name-evidence-setting.txt
if [ "$PROBE_APP_SOURCE" = c1ce ]; then
 cd /home/mint/source-artifact
 sha256sum -c source-bundle.tar.gz.sha256 > /home/mint/evidence/source-bundle-verified.txt
 mkdir -p /home/mint/source-bundle
 tar -xzf source-bundle.tar.gz -C /home/mint/source-bundle
 if [ "$PROBE_ENGINE_VARIANT" != official ]; then
  provenance=/home/mint/source-artifact/provenance
  jq -e --arg variant "$PROBE_ENGINE_VARIANT" --arg run_id "$PROBE_BUNDLE_RUN_ID" --arg patch_hash "$PROBE_ENGINE_PATCH_HASH" \
   '.variant == $variant and .app_build_run_id == $run_id and
    (.run_id == $run_id or .run_id == "38153341418") and
    .engine_sha == "42d3d75a56efe1a2e9902f52dc8006099c45d937" and
    .framework_sha == "00b0c91f06209d9e4a41f71b7a512d6eb3b9c694" and
    .localsend_sha == "c1ce322fb3acf08e44f329b8b7208b8b0d91e244" and
    .depot_tools_sha == "a03dfbf7f2d1cefa2795d81d59ca4f16c8616a8f" and
    .deps_sha256 == "0d0b2b9c4b103613bb242635328497bc8a47d64f31309f2dfa93e66abb20d4f3" and
    .experiment_patch_sha256 == $patch_hash and .runtime_mode == "release"' "$provenance/manifest.json" \
   > /home/mint/evidence/engine-manifest-check.txt
  test "$(sha256sum source-bundle.tar.gz | awk '{print $1}')" = "$(jq -er .bundle_sha256 "$provenance/manifest.json")"
  test "$(sha256sum "$provenance/engine/bootstrap/records-SHA256SUMS" | awk '{print $1}')" = "$(jq -er .bootstrap_records_sha256 "$provenance/manifest.json")"
  (cd "$provenance/engine/bootstrap" && sha256sum -c records-SHA256SUMS) > /home/mint/evidence/engine-bootstrap-check.txt
  (cd /home/mint/source-bundle && sha256sum -c "$provenance/bundle-files-SHA256SUMS") > /home/mint/evidence/engine-bundle-files-check.txt
 fi
 cp -a /home/mint/source-artifact /home/mint/evidence/source-artifact
 ldd /home/mint/source-bundle/localsend_app > /home/mint/evidence/source-main-ldd.txt
 if grep -q 'not found' /home/mint/evidence/source-main-ldd.txt; then
  echo "Pinned executable runtime dependencies missing; no app scenario attempted" >&2
  exit 1
 fi
 # Standalone plugin ldd lacks the executable's RPATH. Preserve these reports separately;
 # unused JNI native assets can require libjvm without being dependencies of the Linux app.
 for library in /home/mint/source-bundle/lib/*.so; do
  printf '\nFILE %s\n' "$library" >> /home/mint/evidence/source-library-ldd.txt
  LD_LIBRARY_PATH=/home/mint/source-bundle/lib ldd "$library" >> /home/mint/evidence/source-library-ldd.txt || true
 done
 printf '/home/mint/source-bundle/localsend_app\n' > /home/mint/evidence/app-executable.txt
else
 curl -fL --connect-timeout 20 --max-time 180 https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.deb -o /tmp/localsend.deb
 sha256sum /tmp/localsend.deb > evidence/release-sha256.txt
 timeout 120 sudo apt-get install -y /tmp/localsend.deb
 printf 'localsend_app\n' > /home/mint/evidence/app-executable.txt
fi
printf 'bridge_variant=%s\n' "$PROBE_BRIDGE_VARIANT" > /home/mint/evidence/bridge-variant.txt
printf '%s\n' "$PROBE_BRIDGE_DELIVERY" > /home/mint/evidence/bridge-delivery.txt
printf 'engine_variant=%s\nbundle_run_id=%s\n' "$PROBE_ENGINE_VARIANT" "$PROBE_BUNDLE_RUN_ID" > /home/mint/evidence/engine-selection.txt
printf '%s\n' "$PROBE_ENGINE_VARIANT" > /home/mint/evidence/engine-variant.txt
system_bridge=$(readlink -f /usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0)
sha256sum "$system_bridge" > /home/mint/evidence/system-bridge-library.sha256
dpkg-query -S "$system_bridge" > /home/mint/evidence/system-bridge-library-ownership.txt
dpkg-query -W -f='${Package}\t${Version}\n' libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 > /home/mint/evidence/system-accessibility-packages.tsv
if [ "$PROBE_BRIDGE_VARIANT" != system ]; then
 for package in libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64; do
  test "$(dpkg-query -W -f='${Version}' "$package")" = 2.52.0-1build1
 done
 if [[ $PROBE_BRIDGE_DELIVERY == package ]]; then
  package_records=/home/mint/evidence/bridge-package
  mkdir -p "$package_records"
  cp -a /home/mint/bridge-package/. "$package_records/"
  (cd /home/mint/bridge-package && sha256sum -c SHA256SUMS) > "$package_records/transport-verified.txt"
  candidate=/home/mint/bridge-package/libatk-bridge2.0-0t64_2.52.0-1build1+localsend2754.1_amd64.deb
  test "$(dpkg-deb -f "$candidate" Package)" = libatk-bridge2.0-0t64
  test "$(dpkg-deb -f "$candidate" Version)" = 2.52.0-1build1+localsend2754.1
  test "$(dpkg-deb -f "$candidate" Architecture)" = amd64
  test "$(sha256sum "$candidate" | awk '{print $1}')" = "$(jq -er .deb_sha256 /home/mint/bridge-package/manifest.json)"
  dpkg-query -W -f='${Package}\t${Version}\n' | sort > "$package_records/packages-before.tsv"
  sudo apt-get --simulate --no-install-recommends install "$candidate" > "$package_records/apt-plan.txt"
  test "$(awk '/^Inst / {print $2}' "$package_records/apt-plan.txt")" = libatk-bridge2.0-0t64
  ! grep -q '^Remv ' "$package_records/apt-plan.txt"
  timeout --foreground 180 sudo apt-get install -y --no-install-recommends "$candidate" > "$package_records/apt-install.txt" 2>&1
  dpkg-query -W -f='${Package}\t${Version}\n' | sort > "$package_records/packages-after.tsv"
  diff -u "$package_records/packages-before.tsv" "$package_records/packages-after.tsv" > "$package_records/package-diff.txt" || test "$?" = 1
  awk -F '\t' '$1 != "libatk-bridge2.0-0t64"' "$package_records/packages-before.tsv" > "$package_records/other-packages-before.tsv"
  awk -F '\t' '$1 != "libatk-bridge2.0-0t64"' "$package_records/packages-after.tsv" > "$package_records/other-packages-after.tsv"
  cmp "$package_records/other-packages-before.tsv" "$package_records/other-packages-after.tsv"
  for package in libatk1.0-0t64 libatspi2.0-0t64; do
   test "$(dpkg-query -W -f='${Version}' "$package")" = 2.52.0-1build1
  done
  test "$(dpkg-query -W -f='${Version}' libatk-bridge2.0-0t64)" = 2.52.0-1build1+localsend2754.1
  dpkg-query -s libatk-bridge2.0-0t64 > "$package_records/installed-control.txt"
  dpkg -V libatk-bridge2.0-0t64 > "$package_records/dpkg-verification.txt"
  test ! -s "$package_records/dpkg-verification.txt"
  bridge_path=$(jq -er .bridge_path /home/mint/bridge-package/manifest.json)
  test "$(readlink -f /usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0)" = "$bridge_path"
  dpkg-query -S "$bridge_path" > "$package_records/library-ownership.txt"
  grep -q '^libatk-bridge2.0-0t64:amd64: ' "$package_records/library-ownership.txt"
  test "$(sha256sum "$bridge_path" | awk '{print $1}')" = "$(jq -er .bridge_sha256 /home/mint/bridge-package/manifest.json)"
 else
 (cd /home/mint/diagnostic-bridge && sha256sum -c library.sha256) > /home/mint/evidence/bridge-library-verified.txt
 cp -a /home/mint/diagnostic-bridge /home/mint/evidence/diagnostic-bridge
 ldd /home/mint/diagnostic-bridge/libatk-bridge-2.0.so.0 > /home/mint/evidence/bridge-library-ldd.txt
 ! grep -q 'not found' /home/mint/evidence/bridge-library-ldd.txt
 readelf -n /home/mint/diagnostic-bridge/libatk-bridge-2.0.so.0 > /home/mint/evidence/bridge-library-build-id.txt
 fi
fi
if [ "$PROBE_BRIDGE_VARIANT" != system ] || [ "$PROBE_ENGINE_VARIANT" != official ]; then
 cp /home/mint/evidence/app-executable.txt /home/mint/evidence/app-real-executable.txt
 cat > /home/mint/support/diagnostics/2754-bridge-app <<'LAUNCH'
#!/bin/bash
set -euo pipefail
real_executable=$(cat /home/mint/evidence/app-real-executable.txt)
variant=system
delivery=$(cat /home/mint/evidence/bridge-delivery.txt)
if [[ $delivery == package ]]; then variant=A; fi
if [ -f /home/mint/diagnostic-bridge/variant.txt ]; then variant=$(cat /home/mint/diagnostic-bridge/variant.txt); fi
engine_variant=$(cat /home/mint/evidence/engine-variant.txt)
case "$variant" in system|stock|A) ;; *) exit 2 ;; esac
case "$engine_variant" in official|control|B) ;; *) exit 2 ;; esac
app_pid=$$
printf '%s\n' "$app_pid" > /home/mint/evidence/bridge-app-pid.txt
printf 'launcher=%s\nreal_executable=%s\nbridge_variant=%s\n' "$0" "$real_executable" "$variant" > /home/mint/evidence/bridge-launch.txt
# Observe the same PID after exec; no library override leaks to the UI harness.
if [ "$variant" != system ] || [ "$engine_variant" != official ]; then
(
 set -euo pipefail
 trap 'observer_status=$?; if [ "$observer_status" != 0 ]; then printf "observer_exit_status=%s\n" "$observer_status" >> /home/mint/evidence/bridge-process-map-check.txt; kill "$app_pid" 2>/dev/null || true; fi' EXIT
 mapped_library=
 for attempt in $(seq 1 100); do
  if [ "$(readlink "/proc/$app_pid/exe" 2>/dev/null || true)" = "$real_executable" ]; then
   mapped_library=$(awk '$6 ~ /libatk-bridge-2[.]0/ { print $6; exit }' "/proc/$app_pid/maps" 2>/dev/null || true)
   [ -n "$mapped_library" ] && break
  fi
  sleep 0.1
 done
 expected_path=/home/mint/diagnostic-bridge/libatk-bridge-2.0.so.0
 if [[ $variant == system ]]; then expected_path=$(awk 'NR==1 {print $2}' /home/mint/evidence/system-bridge-library.sha256); fi
 if [[ $delivery == package ]]; then expected_path=$(jq -er .bridge_path /home/mint/bridge-package/manifest.json); fi
 if [ "$mapped_library" != "$expected_path" ]; then
  printf 'mapped_bridge_mismatch=%s\n' "$mapped_library" > /home/mint/evidence/bridge-process-map-check.txt
  cat "/proc/$app_pid/maps" > /home/mint/evidence/bridge-process-maps.txt 2>/dev/null || true
  kill "$app_pid" 2>/dev/null || true
  exit 1
 fi
 cat "/proc/$app_pid/maps" > /home/mint/evidence/bridge-process-maps.txt
 readlink "/proc/$app_pid/exe" > /home/mint/evidence/bridge-process-executable.txt
 tr '\0' '\n' < "/proc/$app_pid/environ" | grep -E '^(LD_LIBRARY_PATH|LD_PRELOAD|G_MESSAGES_DEBUG)=' > /home/mint/evidence/bridge-process-loader-env.txt || true
 if [[ $delivery == package || $variant == system ]]; then
  ! grep -Eq '^(LD_LIBRARY_PATH|LD_PRELOAD)=' /home/mint/evidence/bridge-process-loader-env.txt
  dpkg-query -S "$mapped_library" > /home/mint/evidence/bridge-process-library-ownership.txt
  if [[ $delivery == package ]]; then
   expected=$(jq -er .bridge_sha256 /home/mint/bridge-package/manifest.json)
  else
   expected=$(awk 'NR==1 {print $1}' /home/mint/evidence/system-bridge-library.sha256)
  fi
 else
  expected=$(awk 'NR==1 {print $1}' /home/mint/diagnostic-bridge/library.sha256)
 fi
 printf '%s  %s\n' "$expected" "$mapped_library" | sha256sum -c - > /home/mint/evidence/bridge-process-hash-check.txt
 sha256sum "$mapped_library" > /home/mint/evidence/bridge-process-library.sha256
 readelf -n "$mapped_library" > /home/mint/evidence/bridge-process-build-id.txt
 printf 'mapped_selected_bridge=true\nactual_app_pid=%s\n' "$app_pid" > /home/mint/evidence/bridge-process-map-check.txt
) > /home/mint/evidence/bridge-map-observer.log 2>&1 &
fi
if [ "$engine_variant" != official ]; then
 # Fail closed before the driver's first UI action even if hashing stalls.
 (
  sleep 13
  if ! grep -qx 'mapped_selected_engine=true' /home/mint/evidence/engine-process-map-check.txt 2>/dev/null ||
     ! grep -qx 'mapped_selected_aot=true' /home/mint/evidence/engine-process-map-check.txt 2>/dev/null ||
     ! grep -qx 'mapped_selected_bridge=true' /home/mint/evidence/bridge-process-map-check.txt 2>/dev/null; then
   printf 'loader_gate_deadline_failed=true\nactual_app_pid=%s\n' "$app_pid" > /home/mint/evidence/engine-loader-deadline.txt
   if [ "$(readlink "/proc/$app_pid/exe" 2>/dev/null || true)" = "$real_executable" ]; then kill "$app_pid" 2>/dev/null || true; fi
  else
   printf 'loader_gate_before_ui=true\nactual_app_pid=%s\n' "$app_pid" > /home/mint/evidence/engine-loader-deadline.txt
  fi
 ) > /home/mint/evidence/engine-loader-deadline.log 2>&1 &
 (
  set -euo pipefail
  trap 'observer_status=$?; if [ "$observer_status" != 0 ]; then printf "observer_exit_status=%s\n" "$observer_status" >> /home/mint/evidence/engine-process-map-check.txt; kill "$app_pid" 2>/dev/null || true; fi' EXIT
  loaded=0
  # The driver waits 15 seconds after launching. Bound loader observation to 10 seconds.
  for attempt in $(seq 1 100); do
   if [ "$(readlink "/proc/$app_pid/exe" 2>/dev/null || true)" = "$real_executable" ] &&
      awk '$6 == "/home/mint/source-bundle/lib/libflutter_linux_gtk.so" { found=1 } END { exit !found }' "/proc/$app_pid/maps" 2>/dev/null &&
      awk '$6 == "/home/mint/source-bundle/lib/libapp.so" { found=1 } END { exit !found }' "/proc/$app_pid/maps" 2>/dev/null; then
    loaded=1
    break
   fi
   sleep 0.1
  done
  test "$loaded" = 1
  timeout 3 bash /home/mint/support/diagnostics/verify-loaded-engine.sh "$app_pid" /home/mint/source-bundle /home/mint/source-artifact/provenance /home/mint/evidence/engine-loaded
  awk '/\/libapp[.]so/ { for (i=6; i<=NF; i++) printf "%s%s", $i, (i==NF ? "\n" : " ") }' /home/mint/evidence/engine-loaded/process-maps.txt | sort -u > /home/mint/evidence/engine-loaded/mapped-aot-paths.txt
  test "$(cat /home/mint/evidence/engine-loaded/mapped-aot-paths.txt)" = /home/mint/source-bundle/lib/libapp.so
  expected_executable=$(awk '$2 == "./localsend_app" { print $1 }' /home/mint/source-artifact/provenance/bundle-files-SHA256SUMS)
  [[ "$expected_executable" =~ ^[0-9a-f]{64}$ ]]
  test "$(sha256sum "/proc/$app_pid/exe" | awk '{print $1}')" = "$expected_executable"
  tr '\0' '\n' < "/proc/$app_pid/environ" | grep -E '^(LD_LIBRARY_PATH|G_MESSAGES_DEBUG)=' > /home/mint/evidence/engine-loaded/process-loader-env.txt || true
  printf 'mapped_selected_engine=true\nmapped_selected_aot=true\nactual_app_pid=%s\n' "$app_pid" > /home/mint/evidence/engine-process-map-check.txt
 ) > /home/mint/evidence/engine-map-observer.log 2>&1 &
fi
if [ "$variant" = system ] || [[ $delivery == package ]]; then
 [[ -z ${LD_LIBRARY_PATH:-} && -z ${LD_PRELOAD:-} ]]
 exec "$real_executable"
elif [ "$variant" = A ]; then
 exec env LD_LIBRARY_PATH=/home/mint/diagnostic-bridge:/home/mint/source-bundle/lib G_MESSAGES_DEBUG=all "$real_executable"
else
 exec env -u G_MESSAGES_DEBUG LD_LIBRARY_PATH=/home/mint/diagnostic-bridge:/home/mint/source-bundle/lib "$real_executable"
fi
LAUNCH
 chmod +x /home/mint/support/diagnostics/2754-bridge-app
 printf '/home/mint/support/diagnostics/2754-bridge-app\n' > /home/mint/evidence/app-executable.txt
fi
cd /home/mint
# Prepare exact debug files before any UI/public query. They are separate
# evidence files; runtime packages and mapped libraries are not substituted.
if [[ $PROBE_CAPTURE_ROOT_NAME_EVIDENCE == 1 ]]; then
 symbol_status=0
 bash support/diagnostics/2754-accessibility/prepare-root-name-symbols.sh /home/mint/evidence/root-name-symbols \
  > evidence/root-name-symbols-prepare.stdout 2> evidence/root-name-symbols-prepare.stderr || symbol_status=$?
 printf 'symbol_prepare_exit_status=%s\n' "$symbol_status" > evidence/root-name-symbols-prepare-status.txt
fi
# Use the actual Cinnamon login bus, which need not equal the systemd user bus.
desktop_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
tr '\0' '\n' < "/proc/$desktop_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE)=' > evidence/session-environment.txt
while IFS= read -r assignment; do export "$assignment"; done < evidence/session-environment.txt
uname -a > evidence/environment.txt
cat /etc/os-release >> evidence/environment.txt
cinnamon --version >> evidence/environment.txt
dpkg-query -W cinnamon cinnamon-settings-daemon caribou libgtk-3-0t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 dbus >> evidence/environment.txt || true
loginctl list-sessions >> evidence/environment.txt
xrandr >> evidence/environment.txt
echo UI_PROVISION_READY
GUEST
status=$?
if [ "$status" = 0 ]; then
scenario_deadline=1500
if [[ $probe_capture_interactions == 1 ]]; then scenario_deadline=3000; fi
timeout "$scenario_deadline" ssh "${opts[@]}" mint@127.0.0.1 "PROBE_BRIDGE_VARIANT=$probe_bridge_variant PROBE_ENGINE_VARIANT=$probe_engine_variant PROBE_BUNDLE_RUN_ID=$probe_bundle_run_id PROBE_ENGINE_PATCH_HASH=$probe_engine_patch_hash PROBE_CAPTURE_GEOMETRY=$probe_capture_geometry PROBE_CAPTURE_INTERACTIONS=$probe_capture_interactions PROBE_CAPTURE_ROOT_NAME_EVIDENCE=$probe_capture_root_name_evidence bash -s" > evidence/cloud/scenario.log 2>&1 <<"GUEST"
set -euo pipefail
cd /home/mint
while IFS= read -r assignment; do export "$assignment"; done < evidence/session-environment.txt
export APP_EXECUTABLE=$(cat evidence/app-executable.txt)
screen_size=$(xrandr | sed -n "s/.*current \([0-9]*\) x \([0-9]*\),.*/\1x\2/p")
set +e
date -u '+%FT%TZ' > evidence/recording-start-request.txt
ffmpeg -version > evidence/recording-ffmpeg-version.txt
# Preserve X11 wall-clock PTS for exact alignment to UI event wall timestamps.
# Draw the real pointer; no synthetic frames, cuts, or input overlay are inserted.
recording_args=(ffmpeg -nostdin -y -copyts -f x11grab -use_wallclock_as_timestamps 1 -draw_mouse 1 -framerate 10 -video_size "$screen_size" -i :0 -an -vsync 0 -c:v libx264 -preset ultrafast -crf 25 -avoid_negative_ts disabled evidence/scenario.mp4)
printf '%s\n' "${recording_args[@]}" > evidence/recording-command-args.txt
"${recording_args[@]}" > evidence/video.log 2>&1 &
video_pid=$!
set +e
# Optional geometry validity is retained by the UI driver separately from causal timing.
# A quick query or capture exit cannot establish valid geometry or correction success.
# This bash reads its commands from SSH stdin. UI subprocesses must not consume
# that command stream; in particular FFmpeg otherwise reads interactive keys.
PROBE_BRIDGE_VARIANT="$PROBE_BRIDGE_VARIANT" PROBE_CAPTURE_GEOMETRY="$PROBE_CAPTURE_GEOMETRY" PROBE_CAPTURE_INTERACTIONS="$PROBE_CAPTURE_INTERACTIONS" PROBE_CAPTURE_ROOT_NAME_EVIDENCE="$PROBE_CAPTURE_ROOT_NAME_EVIDENCE" python3 support/diagnostics/2754-ui.py < /dev/null
status=$?
if [ "$(cat evidence/bridge-variant.txt)" != bridge_variant=system ] || [ "$PROBE_ENGINE_VARIANT" != official ]; then
 grep -qx 'mapped_selected_bridge=true' evidence/bridge-process-map-check.txt || status=1
fi
if [ "$PROBE_ENGINE_VARIANT" != official ]; then
 grep -qx 'mapped_selected_engine=true' evidence/engine-process-map-check.txt || status=1
 grep -qx 'mapped_selected_aot=true' evidence/engine-process-map-check.txt || status=1
 grep -qx 'loader_gate_before_ui=true' evidence/engine-loader-deadline.txt || status=1
fi
printf 'ui_and_loader_exit_status=%s\n' "$status" > evidence/recording-ui-status.txt
kill -INT "$video_pid"
wait "$video_pid"
recording_status=$?
printf 'recorder_exit_status=%s\n' "$recording_status" > evidence/recording-exit-status.txt
case "$recording_status" in 0|255) ;; *) status=1 ;; esac
# Extract short continuous source intervals only after all timed UI work finishes.
# Failures retain source/status and cannot turn a causal or geometry result into a pass.
PROBE_CLOUD_RECORDING=1 PROBE_BRIDGE_VARIANT="$PROBE_BRIDGE_VARIANT" PROBE_ENGINE_VARIANT="$PROBE_ENGINE_VARIANT" python3 support/diagnostics/2754-recording-clips.py > evidence/recording-clips.log 2>&1
clip_status=$?
printf 'clip_exit_status=%s\n' "$clip_status" >> evidence/recording-exit-status.txt
[ "$clip_status" = 0 ] || status=1
sudo journalctl -b --no-pager > evidence/journal.txt
exit "$status"
GUEST
status=$?
fi
set -e
scp -r -i /tmp/issue2754-mint/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest || true
exit "$status"
