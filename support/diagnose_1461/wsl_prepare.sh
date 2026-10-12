#!/usr/bin/env bash
# Cloud Ubuntu 24.04 WSL2 only. Installs an official, hash-pinned 1.14.0 DEB.
set -Eeuo pipefail
evidence=${1:?evidence directory}; expected_sha=${2:?independently pinned official DEB SHA256 required}
[[ $(id -u) == 0 && "$expected_sha" =~ ^[a-fA-F0-9]{64}$ ]]
mkdir -p "$evidence"; evidence=$(realpath "$evidence")
exec > >(tee "$evidence/wsl-prepare.log") 2>&1
grep -q 'VERSION_ID="24.04"' /etc/os-release
grep -qi 'WSL2' /proc/sys/kernel/osrelease
[[ $(uname -m) == x86_64 ]]
[[ ! -e "$evidence/receiver/ready.tsv" ]] || { echo 'Use a fresh evidence directory'; exit 1; }
# The isolated host configures guiApplications=false before its first WSL
# startup. Treat the actual socket directory as evidence, not an assumption.
# Never repair, replace, empty, or reuse existing display infrastructure.
socket_dir=/tmp/.X11-unix
socket_receipts="$evidence/x11-directory"
mkdir -p "$socket_receipts"
for tool in stat namei readlink findmnt mountpoint ss pgrep find mkdir; do command -v "$tool"; done
capture_socket_probe() {
  local label=$1; shift
  local result=0
  printf '%q ' "$@" > "$socket_receipts/$socket_stage-$label.command"
  printf '\n' >> "$socket_receipts/$socket_stage-$label.command"
  "$@" > "$socket_receipts/$socket_stage-$label.txt" 2>&1 || result=$?
  printf '%s\n' "$result" > "$socket_receipts/$socket_stage-$label.exit"
}
snapshot_socket_directory() {
  socket_stage=$1
  date -u --iso-8601=ns > "$socket_receipts/$socket_stage.utc"
  capture_socket_probe tmp-stat stat -c '%n\t%F\tuid=%u\tgid=%g\tmode=%a\tdevice=%d\tinode=%i' -- /tmp
  capture_socket_probe x11-stat stat -c '%n\t%F\tuid=%u\tgid=%g\tmode=%a\tdevice=%d\tinode=%i' -- "$socket_dir"
  capture_socket_probe x11-target-stat stat -L -c '%n\t%F\tuid=%u\tgid=%g\tmode=%a\tdevice=%d\tinode=%i' -- "$socket_dir"
  capture_socket_probe tmp-namei namei -l -- /tmp
  capture_socket_probe x11-namei namei -l -- "$socket_dir"
  capture_socket_probe tmp-readlink readlink -- /tmp
  capture_socket_probe x11-readlink readlink -- "$socket_dir"
  capture_socket_probe tmp-findmnt findmnt --json -T /tmp -o TARGET,SOURCE,FSTYPE,OPTIONS
  capture_socket_probe x11-findmnt findmnt --json -T "$socket_dir" -o TARGET,SOURCE,FSTYPE,OPTIONS
  capture_socket_probe x11-mountpoint mountpoint -q -- "$socket_dir"
  capture_socket_probe unix-sockets ss -lxnp
  capture_socket_probe xservers pgrep -a -x 'Xvfb|Xorg|Xorg.bin|Xwayland|X|Xephyr|Xnest|Xvnc|Xtigervnc|XWin'
  capture_socket_probe directory-entries find "$socket_dir" -mindepth 1 -maxdepth 1 -print
}
snapshot_socket_directory before
reject_socket_directory() { echo "X11 directory preflight rejected: $1; preserve $socket_receipts"; exit 1; }
[[ ! -L /tmp && -d /tmp && -w /tmp && $(stat -c %u /tmp) == 0 && $(stat -c %g /tmp) == 0 && $(stat -c %a /tmp) == 1777 ]] ||
  reject_socket_directory 'guest /tmp must be an ordinary writable root-owned mode-1777 directory'
tmp_filesystem=$(findmnt -n -T /tmp -o FSTYPE)
tmp_mount_options=$(findmnt -n -T /tmp -o OPTIONS)
[[ "$tmp_filesystem" == ext4 || "$tmp_filesystem" == tmpfs ]] || reject_socket_directory 'guest /tmp filesystem must be ext4 or tmpfs'
[[ ",$tmp_mount_options," != *,ro,* ]] || reject_socket_directory 'guest /tmp is on a read-only mount'
[[ $(cat "$socket_receipts/before-unix-sockets.exit") == 0 ]] || reject_socket_directory 'socket inventory unavailable'
[[ $(cat "$socket_receipts/before-xservers.exit") == 1 && ! -s "$socket_receipts/before-xservers.txt" ]] ||
  reject_socket_directory 'existing X server process or unavailable process inventory'
if grep -Fq '.X11-unix/' "$socket_receipts/before-unix-sockets.txt"; then reject_socket_directory 'existing X11 socket'; fi
[[ ! -L "$socket_dir" ]] || reject_socket_directory 'X11 path is a symlink (including a dangling symlink)'
if [[ -e "$socket_dir" ]]; then
  [[ -d "$socket_dir" ]] || reject_socket_directory 'existing X11 path is not a directory'
  # util-linux mountpoint exit 32 means the existing path is not a mountpoint.
  [[ $(cat "$socket_receipts/before-x11-mountpoint.exit") == 32 ]] || reject_socket_directory 'X11 path is a mountpoint or mountpoint check failed'
  [[ $(stat -c %u "$socket_dir") == 0 && $(stat -c %g "$socket_dir") == 0 && $(stat -c %a "$socket_dir") == 1777 ]] ||
    reject_socket_directory 'existing X11 directory ownership or mode differs'
  [[ $(stat -c %d "$socket_dir") == "$(stat -c %d /tmp)" ]] || reject_socket_directory 'X11 directory filesystem differs from guest /tmp'
  [[ $(cat "$socket_receipts/before-directory-entries.exit") == 0 && ! -s "$socket_receipts/before-directory-entries.txt" ]] ||
    reject_socket_directory 'existing X11 directory is not empty or cannot be inventoried'
  printf 'preserved-existing-empty-directory\n' > "$socket_receipts/action.txt"
else
  # No -p: an intervening creation is rejected rather than changed or reused.
  mkdir -m 1777 -- "$socket_dir"
  printf 'created-new-directory-mode-1777\n' > "$socket_receipts/action.txt"
fi
snapshot_socket_directory after
[[ ! -L "$socket_dir" && -d "$socket_dir" && -w "$socket_dir" && $(stat -c %u "$socket_dir") == 0 && $(stat -c %g "$socket_dir") == 0 && $(stat -c %a "$socket_dir") == 1777 && $(stat -c %d "$socket_dir") == "$(stat -c %d /tmp)" ]] ||
  reject_socket_directory 'post-creation directory metadata failed'
[[ $(cat "$socket_receipts/after-x11-mountpoint.exit") == 32 && $(cat "$socket_receipts/after-directory-entries.exit") == 0 && ! -s "$socket_receipts/after-directory-entries.txt" ]] ||
  reject_socket_directory 'post-creation mountpoint or empty-directory verification failed'
[[ $(cat "$socket_receipts/after-unix-sockets.exit") == 0 && $(cat "$socket_receipts/after-xservers.exit") == 1 && ! -s "$socket_receipts/after-xservers.txt" ]] ||
  reject_socket_directory 'post-creation socket or X server inventory failed'
if grep -Fq '.X11-unix/' "$socket_receipts/after-unix-sockets.txt"; then reject_socket_directory 'X11 socket appeared during preflight'; fi
printf 'verified\t%s\n' "$(date -u --iso-8601=ns)" > "$socket_receipts/verified.tsv"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl xvfb openbox xdotool tesseract-ocr ffmpeg dbus-x11 iproute2 util-linux libgtk-3-0 libayatana-appindicator3-1 libsecret-1-0 libnotify4
url=https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0-linux-x86-64.deb
deb="$evidence/LocalSend-1.14.0-linux-x86-64.deb"
printf '%s\n' "$url" > "$evidence/linux-artifact-url.txt"
curl --fail --location --max-time 180 "$url" -o "$deb"
printf '%s  %s\n' "$expected_sha" "$deb" | sha256sum --check
sha256sum "$deb" > "$evidence/linux-release.sha256"
[[ $(dpkg-deb -f "$deb" Package) == localsend && $(dpkg-deb -f "$deb" Architecture) == amd64 ]]
[[ $(dpkg-deb -f "$deb" Version) =~ ^1\.14\.0([+-].*)?$ ]]
apt-get install -y "$deb"
dpkg -V localsend > "$evidence/package-verification.txt"
[[ ! -s "$evidence/package-verification.txt" ]]
id tester >/dev/null 2>&1 || useradd --create-home --shell /bin/bash tester
[[ $(id -u tester) != 0 && $(getent passwd tester | cut -d: -f6) == /home/tester ]]
exe=''
while IFS= read -r path; do
  if [[ -f "$path" && -x "$path" ]]; then [[ -z "$exe" ]] || exit 1; exe=$path; fi
done < <(dpkg -L localsend | grep '/localsend_app$')
[[ -n "$exe" ]]
printf '%s\n' "$exe" > "$evidence/linux-executable.txt"
chown -R tester:tester "$evidence"
scripts=$(cd "$(dirname "$0")" && pwd)
lifetime="$scripts/wsl_lifetime_snapshot.sh"
mkdir -p "$evidence/receiver/lifetime"; chown tester:tester "$evidence/receiver" "$evidence/receiver/lifetime"
bash "$lifetime" "$evidence" register prepare "$$"
printf -v launch 'bash %q %q %q' "$scripts/wsl_receiver.sh" "$evidence" "$exe"
nohup runuser -u tester -- bash -c "$launch" > "$evidence/receiver-supervisor.log" 2>&1 < /dev/null &
supervisor=$!
bash "$lifetime" "$evidence" register supervisor "$supervisor"
for ((attempt=0; attempt<120; attempt++)); do
  if [[ -s "$evidence/receiver/ready.tsv" ]]; then
    snapshot_status=0
    timeout --kill-after=1s 2s bash "$lifetime" "$evidence" snapshot prepare-before-normal-return || snapshot_status=$?
    printf '%s\n' "$snapshot_status" > "$evidence/receiver/lifetime/prepare-before-normal-return.exit"
    date -u --iso-8601=ns > "$evidence/receiver/lifetime/prepare-normal-return-observed.utc"
    exit 0
  fi
  kill -0 "$supervisor" || { cat "$evidence/receiver-supervisor.log"; exit 1; }
  sleep 1
done
echo 'Readiness failed; preserve receiver and logs for inspection.'; exit 1
