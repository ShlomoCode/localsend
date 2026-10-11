#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence/cloud /home/runner/issue2754-mint /tmp/issue2754-mint/seed
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
cat > /tmp/issue2754-mint/seed/bootstrap.sh <<"BOOT"
#!/bin/bash
set -euxo pipefail
exec > >(tee /tmp/issue2754-bootstrap.log /dev/ttyS0) 2>&1
mkdir -p /home/mint/.ssh /home/mint/evidence /home/mint/support/diagnostics
cp /mnt/id.pub /home/mint/.ssh/authorized_keys
cp /mnt/ui.py /home/mint/support/diagnostics/2754-ui.py
chown -R mint:mint /home/mint/.ssh /home/mint/evidence /home/mint/support
chmod 700 /home/mint/.ssh
chmod 600 /home/mint/.ssh/authorized_keys
apt-get update
apt-get install -y -o DPkg::Lock::Timeout=120 openssh-server
systemctl start ssh
touch /home/mint/evidence/bootstrap-complete
BOOT
genisoimage -quiet -o /home/runner/issue2754-mint/probe.iso -V PROBE -r /tmp/issue2754-mint/seed
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -boot d -drive file=/home/runner/issue2754-mint/mint.iso,media=cdrom,readonly=on -drive file=/home/runner/issue2754-mint/probe.iso,media=cdrom,readonly=on -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2275-:22 -device virtio-net-pci,netdev=net0 -display none -monitor unix:/tmp/issue2754-mint/monitor,server,nowait -serial file:evidence/cloud/serial.log -daemonize
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
for n in $(seq 1 12); do
 if timeout 10 ssh "${opts[@]}" mint@127.0.0.1 "test -f /home/mint/evidence/bootstrap-complete && pgrep -x cinnamon && command -v tesseract" > evidence/cloud/readiness.log 2>&1; then ready=1; break; fi
 sleep 15
done
printf "screendump %s/evidence/cloud/bootstrap.ppm\n" "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue2754-mint/monitor
sudo chown -R "$(id -u):$(id -g)" evidence/cloud
if [ "$ready" != 1 ]; then exit 1; fi
set +e
timeout 600 ssh "${opts[@]}" mint@127.0.0.1 "bash -s" > evidence/cloud/scenario.log 2>&1 <<"GUEST"
set -euo pipefail
cd /home/mint
cp /tmp/issue2754-bootstrap.log evidence/bootstrap.log
sudo apt-get install -y -o DPkg::Lock::Timeout=120 xdotool scrot tesseract-ocr xclip ffmpeg gdb strace
curl -fL https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.deb -o /tmp/localsend.deb
sha256sum /tmp/localsend.deb > evidence/release-sha256.txt
sudo apt-get install -y /tmp/localsend.deb
export DISPLAY=:0 XAUTHORITY=/home/mint/.Xauthority XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
uname -a > evidence/environment.txt
cat /etc/os-release >> evidence/environment.txt
cinnamon --version >> evidence/environment.txt
dpkg-query -W cinnamon cinnamon-settings-daemon caribou >> evidence/environment.txt || true
loginctl list-sessions >> evidence/environment.txt
xrandr >> evidence/environment.txt
screen_size=$(xrandr | sed -n "s/.*current \([0-9]*\) x \([0-9]*\),.*/\1x\2/p")
ffmpeg -y -f x11grab -framerate 10 -video_size "$screen_size" -i :0 -c:v libx264 -preset ultrafast evidence/scenario.mp4 > evidence/video.log 2>&1 &
video_pid=$!
set +e
python3 support/diagnostics/2754-ui.py
status=$?
kill -INT "$video_pid"
wait "$video_pid"
sudo journalctl -b --no-pager > evidence/journal.txt
exit "$status"
GUEST
status=$?
set -e
scp -r -i /tmp/issue2754-mint/id -P 2275 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2754-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest || true
exit "$status"
