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
printf -v launch 'bash %q %q %q' "$scripts/wsl_receiver.sh" "$evidence" "$exe"
nohup runuser -u tester -- bash -c "$launch" > "$evidence/receiver-supervisor.log" 2>&1 < /dev/null &
supervisor=$!
for ((attempt=0; attempt<120; attempt++)); do
  [[ ! -s "$evidence/receiver/ready.tsv" ]] || exit 0
  kill -0 "$supervisor" || { cat "$evidence/receiver-supervisor.log"; exit 1; }
  sleep 1
done
echo 'Readiness failed; preserve receiver and logs for inspection.'; exit 1
