#!/usr/bin/env bash
# Host controller. Sourcing this file only exposes paths and bounded SSH helpers.
export DISPLAY=:99
VM_ROOT=/tmp/localsend-vm
EVIDENCE=${GITHUB_WORKSPACE:-$PWD}/evidence/vm
export EVIDENCE_DIR="$EVIDENCE"
if [[ -f /tmp/3478-job-start ]]; then export JOB_STARTED_UPTIME="$(cat /tmp/3478-job-start)"; fi
SOURCE_COMMIT=af0416be50770a97760f7070684bc667b759a15c
BUILD_ROOT=/tmp/localsend-build
SSH_OPTS=(-i "$VM_ROOT/id_ed25519" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$VM_ROOT/known_hosts" -o ConnectTimeout=5)
ssh_guest() {
  local SSH_OPTS=(-i "$VM_ROOT/id_ed25519" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$VM_ROOT/known_hosts" -o ConnectTimeout=5)
  timeout --kill-after=2s 30s ssh "${SSH_OPTS[@]}" probe@127.0.0.1 "$@"
}
scp_guest() {
  local args=("$@") last
  last=$(("${#args[@]}" - 1))
  # A plain final path names a guest destination; explicit remote endpoints also work.
  if [[ "${args[$last]}" != *:* ]]; then args[$last]="probe@127.0.0.1:${args[$last]}"; fi
  timeout --kill-after=2s 60s scp -i "$VM_ROOT/id_ed25519" -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$VM_ROOT/known_hosts" "${args[@]}"
}
work_remaining() {
  # Leave 20 seconds for termination and step transitions before the ten-minute reserve.
  awk -v started="$(cat /tmp/3478-job-start)" '{ print int(started + 4780 - $1) }' /proc/uptime
}
classification() { printf 'CLASSIFICATION=environment\nDETAIL=%s\n' "$*" > "$EVIDENCE/environment-result.txt"; }
export VM_ROOT EVIDENCE
export -f ssh_guest scp_guest work_remaining
setup() {
  mkdir -p "$EVIDENCE" "$VM_ROOT" /home/runner/localsend-vm
  cp /tmp/3478-job-start* "$EVIDENCE/"
  find support/diagnostics/3478 -type f -print0 | sort -z | xargs -0 sha256sum > "$EVIDENCE/harness-SHA256SUMS"
  # Source validation runs only on the authorized Actions host.
  bash -n support/diagnostics/3478/environment.sh support/diagnostics/3478/scenario.sh
  sudo apt-get update
  sudo apt-get install -y clang cmake libgtk-3-dev ninja-build libayatana-appindicator3-dev \
    qemu-system-x86 qemu-system-gui qemu-utils cloud-image-utils socat imagemagick openssh-client \
    xvfb mesa-utils xdotool x11-apps ffmpeg jq pkg-config libssl-dev
  test -c /dev/kvm
  sudo test -r /dev/kvm
  df -Th /home/runner /tmp > "$EVIDENCE/host-filesystems.txt"
  test "$(findmnt -no FSTYPE -T /home/runner)" != tmpfs
  test "$(df -Pk /home/runner | awk 'NR == 2 {print $4}')" -ge 10485760
  image_url=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
  curl --fail --location --retry 3 --output /home/runner/localsend-vm/debian.img "$image_url"
  printf '%s\n' "$image_url" > "$EVIDENCE/debian-image-url.txt"
  sha256sum /home/runner/localsend-vm/debian.img > "$EVIDENCE/debian-image-SHA256SUMS"
  qemu-img resize /home/runner/localsend-vm/debian.img 36G
  ssh-keygen -q -t ed25519 -N '' -f "$VM_ROOT/id_ed25519"
  probe_key=$(cat "$VM_ROOT/id_ed25519.pub")
  cat > "$VM_ROOT/user-data" <<CLOUD
#cloud-config
users:
  - default
  - name: probe
    groups: [adm, sudo, audio, video, render]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $probe_key
package_update: true
packages:
  - task-gnome-desktop
  - nautilus
  - gnome-text-editor
  - wl-clipboard
  - openssh-server
  - libayatana-appindicator3-1
  - python3-pyatspi
  - python3-gi
  - libgtk-3-dev
  - gcc
  - pkg-config
  - jq
  - binutils
  - dbus-x11
  - gnome-shell-extensions
runcmd:
  - [sh, -c, "mkdir -p /etc/gdm3 && printf '[daemon]\\nAutomaticLoginEnable=True\\nAutomaticLogin=probe\\n' > /etc/gdm3/daemon.conf"]
  - [systemctl, set-default, graphical.target]
  - [systemctl, enable, gdm3]
power_state:
  mode: reboot
  timeout: 30
  condition: true
CLOUD
  printf 'instance-id: localsend-3478\nlocal-hostname: localsend-3478\n' > "$VM_ROOT/meta-data"
  cp "$VM_ROOT/user-data" "$EVIDENCE/cloud-init-user-data.txt"
  cloud-localds /home/runner/localsend-vm/seed.iso "$VM_ROOT/user-data" "$VM_ROOT/meta-data"
  Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX > "$EVIDENCE/host-xvfb.log" 2>&1 &
  echo $! > "$VM_ROOT/xvfb.pid"
  export LIBGL_ALWAYS_SOFTWARE=1 SDL_VIDEODRIVER=x11
  for attempt in $(seq 1 20); do xdpyinfo >/dev/null 2>&1 && break; sleep 1; done
  glxinfo -B > "$EVIDENCE/host-glx.txt"
  cat > "$VM_ROOT/capture" <<'CAPTURE'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY=:99 xwd -root -silent | convert xwd:- "$1"
CAPTURE
  chmod +x "$VM_ROOT/capture"
  sudo --preserve-env=DISPLAY,LIBGL_ALWAYS_SOFTWARE,SDL_VIDEODRIVER qemu-system-x86_64 \
    -machine accel=kvm -cpu host -smp 2 -m 6144 \
    -drive file=/home/runner/localsend-vm/debian.img,if=virtio,format=qcow2 \
    -drive file=/home/runner/localsend-vm/seed.iso,media=cdrom,readonly=on \
    -device virtio-vga-gl -display sdl,gl=on -full-screen -usb -device usb-tablet \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
    -monitor unix:"$VM_ROOT/monitor",server,nowait -pidfile "$VM_ROOT/qemu.pid" \
    -serial file:"$EVIDENCE/serial.log" -daemonize 2> "$EVIDENCE/qemu-start.log"
  printf 'info kvm\n' | timeout 8 sudo socat - UNIX-CONNECT:"$VM_ROOT/monitor" > "$EVIDENCE/kvm-monitor.txt"
  grep -q 'kvm support: enabled' "$EVIDENCE/kvm-monitor.txt"
  uname -a > "$EVIDENCE/host-uname.txt"
  lscpu > "$EVIDENCE/host-cpu.txt"
}
build() {
  git clone --no-hardlinks "$GITHUB_WORKSPACE" "$BUILD_ROOT"
  git -C "$BUILD_ROOT" checkout --detach "$SOURCE_COMMIT"
  test "$(git -C "$BUILD_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT"
  git -C "$BUILD_ROOT" show --no-patch --format=fuller HEAD > "$EVIDENCE/source-identity.txt"
  git -C "$BUILD_ROOT" archive HEAD | gzip > "$EVIDENCE/unchanged-source.tar.gz"
  cp "$BUILD_ROOT/.fvmrc" "$BUILD_ROOT/rust-toolchain.toml" "$BUILD_ROOT/pubspec.lock" "$BUILD_ROOT/Cargo.lock" "$EVIDENCE/"
  cp "$BUILD_ROOT/packages/localsend_isolates/rust-toolchain.toml" "$EVIDENCE/plugin-rust-toolchain.toml"
  flutter --version --machine > "$EVIDENCE/bootstrap-flutter.json"
  dart pub global activate fvm 3.2.1
  export PATH="$PATH:$HOME/.pub-cache/bin"
  cd "$BUILD_ROOT"
  fvm install 3.41.9
  fvm flutter --version --machine > "$EVIDENCE/flutter-identity.json"
  test "$(jq -r .frameworkVersion "$EVIDENCE/flutter-identity.json")" = 3.41.9
  cd packages/localsend_isolates
  rustup show > "$EVIDENCE/rust-toolchain.txt"
  cargo --version >> "$EVIDENCE/rust-toolchain.txt"
  rustc --version >> "$EVIDENCE/rust-toolchain.txt"
  cd ../..
  cd app
  fvm flutter pub get --enforce-lockfile
  fvm flutter build linux
  cd "$BUILD_ROOT"
  git diff --exit-code > "$EVIDENCE/source-after-build.diff"
  cp .dart_tool/package_config.json "$EVIDENCE/resolved-package-config.json"
  pasteboard_path=$(jq -r '.packages[] | select(.name == "pasteboard") | .rootUri' .dart_tool/package_config.json)
  pasteboard_path=${pasteboard_path#file://}
  test "$(git -C "$pasteboard_path" rev-parse HEAD)" = 58748dae405df5e68a131e4905d48e75d0624be2
  git -C "$pasteboard_path" rev-parse HEAD > "$EVIDENCE/pasteboard-source.txt"
  git -C "$pasteboard_path" diff --exit-code >> "$EVIDENCE/pasteboard-source.txt"
  cd app/build/linux/x64/release/bundle
  find . -type f -print0 | sort -z | xargs -0 sha256sum > "$EVIDENCE/bundle-SHA256SUMS"
  tar -czf "$EVIDENCE/normal-release-bundle.tar.gz" .
  sha256sum "$EVIDENCE/normal-release-bundle.tar.gz" > "$EVIDENCE/bundle-archive-SHA256SUMS"
}
ready() {
  ready=0
  for attempt in $(seq 1 45); do
    if ssh_guest 'cloud-init status --wait >/dev/null 2>&1 && systemctl is-active --quiet gdm3 && test -S /run/user/$(id -u)/bus && find /run/user/$(id -u) -maxdepth 1 -type s -name "wayland-*" | grep -q .' > "$EVIDENCE/readiness-last.txt" 2>&1; then ready=1; break; fi
    sleep 5
  done
  test "$ready" = 1
  ssh_guest 'cat /etc/os-release; dpkg-query -W gnome-shell libmutter-16-0 nautilus libgtk-4-1 gnome-text-editor wl-clipboard libgtk-3-0t64; loginctl list-sessions; cloud-init status' > "$EVIDENCE/guest-packages.txt"
  if ! ssh_guest 'bash -s' <<'VERSION_CHECK'
set -euo pipefail
for p in gnome-shell libmutter-16-0; do
  v=$(dpkg-query -W -f='${Version}' "$p")
  v=${v#*:}
  test "${v%%-*}" = 48.7
done
test "$(. /etc/os-release; echo "$VERSION_ID")" = 13
VERSION_CHECK
  then classification 'Debian 13 GNOME/Mutter 48.7 identity mismatch'; return 1; fi
  scp_guest -r support/diagnostics/3478 probe@127.0.0.1:/home/probe/diagnostics
  scp_guest "$EVIDENCE/normal-release-bundle.tar.gz" "$EVIDENCE/bundle-SHA256SUMS" probe@127.0.0.1:/home/probe/
  ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
mkdir -p /home/probe/bundle /home/probe/evidence
cat > /home/probe/session-env <<'ENV'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
export WAYLAND_DISPLAY=$(basename "$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' | head -1)")
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME GDK_BACKEND=wayland
ENV
source /home/probe/session-env
tar -xzf /home/probe/normal-release-bundle.tar.gz -C /home/probe/bundle
(cd /home/probe/bundle && sha256sum -c /home/probe/bundle-SHA256SUMS) > /home/probe/evidence/bundle-verification.txt
ldd /home/probe/bundle/localsend_app > /home/probe/evidence/runtime-ldd.txt
! grep -q 'not found' /home/probe/evidence/runtime-ldd.txt
find /home/probe/diagnostics/geometry-oracle -type f -print0 | sort -z | xargs -0 sha256sum > /home/probe/evidence/oracle-source-SHA256SUMS
test -f /home/probe/diagnostics/gtk-clipboard-probe.c
sha256sum /home/probe/diagnostics/gtk-clipboard-probe.c > /home/probe/evidence/native-probe-source-SHA256SUMS
gcc -std=c11 -Wall -Wextra -O2 /home/probe/diagnostics/gtk-clipboard-probe.c -o /home/probe/diagnostics/gtk-clipboard-probe $(pkg-config --cflags --libs gtk+-3.0) > /home/probe/evidence/native-probe-build.log 2>&1
sha256sum /home/probe/diagnostics/gtk-clipboard-probe > /home/probe/evidence/native-probe-binary-SHA256SUMS
sh /home/probe/diagnostics/geometry-oracle/install-guest.sh > /home/probe/evidence/oracle-install.txt
sudo systemctl restart gdm3
GUEST
  ready=0
  for attempt in $(seq 1 30); do
    if ssh_guest 'source /home/probe/session-env; /usr/bin/python3 /home/probe/diagnostics/geometry-oracle/snapshot-guest.py' > "$EVIDENCE/oracle-ready.json" 2> "$EVIDENCE/oracle-ready-error.txt"; then ready=1; break; fi
    sleep 5
  done
  test "$ready" = 1
  xwininfo -root -tree > "$EVIDENCE/host-sdl-window-tree.txt"
  xdotool search --class qemu > "$VM_ROOT/sdl-window-id"
  test "$(wc -l < "$VM_ROOT/sdl-window-id")" = 1
  xdotool getwindowgeometry --shell "$(cat "$VM_ROOT/sdl-window-id")" > "$EVIDENCE/host-sdl-geometry.txt"
  jq -e '.shellVersion == "48.7" and .compositorWayland.value == true' "$EVIDENCE/oracle-ready.json"
  ffmpeg -y -f x11grab -video_size 1280x800 -framerate 15 -i :99 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$EVIDENCE/live-ui-original.mp4" > "$EVIDENCE/video.log" 2>&1 &
  echo $! > "$VM_ROOT/video.pid"
  "$VM_ROOT/capture" "$EVIDENCE/environment-ready.png"
  printf 'ENVIRONMENT_READY=1\n' > "$EVIDENCE/environment-result.txt"
}
collect() {
  mkdir -p "$EVIDENCE"
  collection_failed=0
  printf 'COLLECTION=started\n' > "$EVIDENCE/collection-status.txt"
  date -u +%FT%T.%N > "$EVIDENCE/collection-start.txt"
  if [[ -f "$EVIDENCE/scenario/input.log" ]]; then
    if ! ssh_guest 'test -f /home/probe/evidence/scenario-cleanup-complete' > "$EVIDENCE/scenario-cleanup-verification.txt" 2>&1; then
      printf 'GUEST_OWNED_PROCESSES_NOT_JOINED=1\n' >> "$EVIDENCE/collection-status.txt"
      collection_failed=1
    fi
  fi
  if ! timeout --kill-after=1s 15s ssh "${SSH_OPTS[@]}" probe@127.0.0.1 'sudo journalctl -b --no-pager -n 20000; journalctl --user -b --no-pager -n 20000' > "$EVIDENCE/session-journal.txt" 2>&1; then
    printf 'JOURNAL_COLLECTION=failed\n' >> "$EVIDENCE/collection-status.txt"; collection_failed=1
  fi
  if timeout --kill-after=2s 60s ssh "${SSH_OPTS[@]}" probe@127.0.0.1 'tar -C /home/probe -czf - evidence' > "$EVIDENCE/guest-evidence.tar.gz" 2> "$EVIDENCE/guest-collection.txt" &&
      timeout 10 tar -tzf "$EVIDENCE/guest-evidence.tar.gz" > "$EVIDENCE/guest-archive-members.txt" 2>&1; then
    printf 'GUEST_ARCHIVE=complete\n' >> "$EVIDENCE/collection-status.txt"
  else
    printf 'GUEST_ARCHIVE=failed\n' >> "$EVIDENCE/collection-status.txt"; collection_failed=1
  fi
  if [[ -x "$VM_ROOT/capture" ]] && timeout 5 "$VM_ROOT/capture" "$EVIDENCE/final.png"; then
    printf 'FINAL_CAPTURE=complete\n' >> "$EVIDENCE/collection-status.txt"
  else
    printf 'FINAL_CAPTURE=failed\n' >> "$EVIDENCE/collection-status.txt"; collection_failed=1
  fi
  if [[ -f "$VM_ROOT/video.pid" ]]; then
    video_pid=$(cat "$VM_ROOT/video.pid")
    kill -INT "$video_pid" || true
    for attempt in $(seq 1 10); do kill -0 "$video_pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$video_pid" 2>/dev/null; then kill -KILL "$video_pid" || true; printf 'VIDEO_FINALIZATION_INCOMPLETE=1\n' >> "$EVIDENCE/video.log"; collection_failed=1; fi
    timeout 5 ffprobe -v error -show_format -show_streams "$EVIDENCE/live-ui-original.mp4" > "$EVIDENCE/video-metadata.txt" 2>&1 || collection_failed=1
    timeout 5 ffprobe -v error -select_streams v:0 -show_entries frame=best_effort_timestamp_time,pkt_duration_time -of csv "$EVIDENCE/live-ui-original.mp4" > "$EVIDENCE/video-original-PTS.csv" 2>&1 || collection_failed=1
    if timeout 20 ffmpeg -v error -i "$EVIDENCE/live-ui-original.mp4" -f null - > "$EVIDENCE/video-decode.txt" 2>&1; then
      printf 'VIDEO_DECODE=complete\n' >> "$EVIDENCE/video-decode.txt"
    else
      printf 'VIDEO_DECODE=failed EXIT=%s\n' "$?" >> "$EVIDENCE/video-decode.txt"
      collection_failed=1
    fi
  elif [[ -f "$EVIDENCE/scenario/input.log" ]]; then
    printf 'VIDEO_PROCESS_MISSING=1\n' >> "$EVIDENCE/collection-status.txt"; collection_failed=1
  fi
  # QEMU removes its pidfile on normal exit; retain the owned PID before quit.
  qemu_owned_pid=
  if [[ -f "$VM_ROOT/qemu.pid" ]]; then qemu_owned_pid=$(cat "$VM_ROOT/qemu.pid"); fi
  if printf 'quit\n' | timeout 8 sudo socat - UNIX-CONNECT:"$VM_ROOT/monitor" > "$EVIDENCE/vm-quit.txt" 2>&1; then
    printf 'VM_MONITOR_QUIT=sent\n' >> "$EVIDENCE/collection-status.txt"
  else
    printf 'VM_MONITOR_QUIT=failed\n' >> "$EVIDENCE/collection-status.txt"; collection_failed=1
  fi
  for owned in qemu xvfb; do
    owned_pid=
    if [[ "$owned" == qemu ]]; then owned_pid=$qemu_owned_pid;
    elif [[ -f "$VM_ROOT/$owned.pid" ]]; then owned_pid=$(cat "$VM_ROOT/$owned.pid"); fi
    if [[ "$owned_pid" =~ ^[0-9]+$ ]]; then
      if [[ "$owned" == xvfb ]]; then kill -TERM "$owned_pid" 2>/dev/null || true; fi
      for attempt in $(seq 1 5); do sudo kill -0 "$owned_pid" 2>/dev/null || break; sleep 1; done
      if sudo kill -0 "$owned_pid" 2>/dev/null; then sudo kill -TERM "$owned_pid" 2>/dev/null || true; sleep 1; fi
      if sudo kill -0 "$owned_pid" 2>/dev/null; then sudo kill -KILL "$owned_pid" 2>/dev/null || true; sleep 1; fi
      if sudo kill -0 "$owned_pid" 2>/dev/null; then
        printf '%s_JOINED=failed PID=%s\n' "$owned" "$owned_pid" >> "$EVIDENCE/collection-status.txt"; collection_failed=1
      else
        printf '%s_JOINED=complete PID=%s\n' "$owned" "$owned_pid" >> "$EVIDENCE/collection-status.txt"
      fi
    else
      printf '%s_PID=missing\n' "$owned" >> "$EVIDENCE/collection-status.txt"; collection_failed=1
    fi
  done
  sudo chown -R "$(id -u):$(id -g)" "$EVIDENCE" || collection_failed=1
  if [[ "$collection_failed" == 0 ]]; then
    printf 'COLLECTION=complete\n' >> "$EVIDENCE/collection-status.txt"
  else
    date -u +%FT%T.%N > "$EVIDENCE/collection-incomplete.txt"
    printf 'COLLECTION=incomplete\n' >> "$EVIDENCE/collection-status.txt"
  fi
  if timeout 30 bash -c 'set -euo pipefail; find "$EVIDENCE" -type f ! -name originals-SHA256SUMS -print0 | sort -z | xargs -0 sha256sum' > "$EVIDENCE/originals-SHA256SUMS"; then
    if [[ "$collection_failed" == 0 ]]; then date -u +%FT%T.%N > "$EVIDENCE/collection-complete.txt"; fi
  else
    printf 'COLLECTION=incomplete HASH_MANIFEST=failed\n' >> "$EVIDENCE/collection-status.txt"
    date -u +%FT%T.%N > "$EVIDENCE/collection-incomplete.txt"
    return 1
  fi
  return "$collection_failed"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  phase=${1:?Expected setup, build, ready, collect, or internal phase}
  if [[ "$phase" == collect ]]; then collect; exit; fi
  if [[ "$phase" == _* ]]; then "${phase#_}"; exit; fi
  seconds=$(work_remaining)
  case "$phase" in
    setup) limit=$(awk -v s="$(cat /tmp/3478-job-start)" '{print int(s + 1200 - $1)}' /proc/uptime);;
    build) limit=$(awk -v s="$(cat /tmp/3478-build-start)" '{print int(s + 1800 - $1)}' /proc/uptime);;
    ready) limit=900;;
    *) exit 2;;
  esac
  if (( seconds < limit )); then limit=$seconds; fi
  test "$limit" -gt 0
  mkdir -p "$EVIDENCE"
  if timeout --signal=TERM --kill-after=5s "${limit}s" bash "$0" "_$phase" > "$EVIDENCE/$phase.log" 2>&1; then
    printf 'PHASE=%s STATUS=complete\n' "$phase" >> "$EVIDENCE/phases.txt"
  else
    result=$?
    printf 'PHASE=%s STATUS=failed EXIT=%s\n' "$phase" "$result" >> "$EVIDENCE/phases.txt"
    classification "$phase failed with exit $result; product episode is not evidence"
    exit "$result"
  fi
fi
