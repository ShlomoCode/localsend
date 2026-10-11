#!/usr/bin/env bash
set -euo pipefail
evidence=$1
exec > >(tee "$evidence/ubuntu-prepare.log") 2>&1
cat /etc/os-release
uname -a
grep -q 'VERSION_ID="24.04"' /etc/os-release
uname -r | grep -qi 'WSL2'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl xvfb openbox xdotool tesseract-ocr ffmpeg dbus-x11 libgtk-3-0 libayatana-appindicator3-1 libsecret-1-0 libnotify4 fonts-noto-cjk
curl --fail --location --max-time 180 https://github.com/localsend/localsend/releases/download/v1.16.1/LocalSend-1.16.1-linux-x86-64.deb -o /tmp/localsend2230.deb
sha256sum /tmp/localsend2230.deb | tee "$evidence/linux-release-sha256.txt"
apt-get install -y /tmp/localsend2230.deb
dpkg-query -W localsend | tee "$evidence/linux-package.txt"
id tester >/dev/null 2>&1 || useradd --create-home --shell /bin/bash tester
executable=$(dpkg -L localsend | grep '/localsend_app$' | head -1)
test -x "$executable"
# A supported portable preferences file is the only writable file in the release directory.
touch "$(dirname "$executable")/settings.json"
chown tester:tester "$(dirname "$executable")/settings.json"
printf '%s\n' "$executable" > "$evidence/linux-executable.txt"
scriptRoot=$(cd "$(dirname "$0")" && pwd)
chmod a+rwX "$evidence"
nohup su tester -c "bash '$scriptRoot/receiver.sh' '$evidence' '$executable'" > "$evidence/receiver-supervisor.log" 2>&1 < /dev/null &
supervisor=$!
for attempt in $(seq 1 120); do
  if test -s "$evidence/receiver/ready.tsv"; then exit 0; fi
  kill -0 "$supervisor" || { cat "$evidence/receiver-supervisor.log"; exit 1; }
  sleep 1
done
echo 'Receiver readiness exceeded 120 seconds; inspect preserved guest logs.'
exit 1
