#!/usr/bin/env bash
# Diagnostic only: original MX23.2 live XFCE image, no portal alteration.
set -euo pipefail
mkdir -p evidence/mx /home/runner/issue1310-mx
mxroot=/home/runner/issue1310-mx
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils sshpass python3-pip imagemagick genisoimage
pip install vncdotool
if ! test -f "$mxroot/mx.iso"; then
  downloaded=0
  for attempt in 1 2 3; do
    if curl -fL --continue-at - --connect-timeout 30 --max-time 900 -o "$mxroot/mx.iso" https://downloads.sourceforge.net/project/mx-linux/Old/MX-23.2/Xfce/MX-23.2_x64.iso; then downloaded=1; break; fi
  done
  test "$downloaded" = 1
fi
curl -fL --retry 3 -o "$mxroot/MX-23.2_x64.iso.sha256" https://downloads.sourceforge.net/project/mx-linux/Old/MX-23.2/Xfce/MX-23.2_x64.iso.sha256
sha256sum "$mxroot/mx.iso" > evidence/mx/iso-sha256.txt
cat "$mxroot/MX-23.2_x64.iso.sha256" > evidence/mx/published-sha256.txt
expected=$(awk '{print $1;exit}' "$mxroot/MX-23.2_x64.iso.sha256")
actual=$(sha256sum "$mxroot/mx.iso" | awk '{print $1}')
test "$expected" = "$actual"
printf 'media_verified=true\n' >> "$GITHUB_OUTPUT"
qemu-img create -f qcow2 "$mxroot/disk.qcow2" 24G
mkdir -p "$mxroot/bootstrap"
cat > "$mxroot/bootstrap/bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
exec > /dev/ttyS0 2>&1
set -euxo pipefail
date -u
ip address
ip route
cat /etc/resolv.conf
df -h
free -m
dpkg-query -W openssh-server || true
apt-get update
apt-get install -y openssh-server
service ssh start
ss -lntp
date -u
BOOTSTRAP
genisoimage -quiet -r -o "$mxroot/bootstrap.iso" -V OBSERVATION "$mxroot/bootstrap"
opts=(-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" -o ConnectTimeout=5)
cleanup() {
  printf '%s\n' "$?" > evidence/mx/host-exit-code.txt
  timeout 120 sshpass -p demo scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" -r demo@127.0.0.1:/home/demo/evidence evidence/mx/guest || true
  vncdo -s localhost::5900 capture evidence/mx/final.png || true
  if test -f "$mxroot/qemu.pid"; then sudo kill "$(sudo cat "$mxroot/qemu.pid")" || true; fi
  sudo chown -R "$(id -u):$(id -g)" evidence
}
trap cleanup EXIT
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -drive file="$mxroot/disk.qcow2",if=virtio,format=qcow2 -cdrom "$mxroot/mx.iso" -drive file="$mxroot/bootstrap.iso",media=cdrom,index=3,readonly=on -boot d -device virtio-vga -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 -vnc 127.0.0.1:0 -serial file:evidence/mx/serial.log -pidfile "$mxroot/qemu.pid" -daemonize
sleep 20
vncdo -s localhost::5900 capture evidence/mx/boot-menu.png key enter
sleep 120
vncdo -s localhost::5900 capture evidence/mx/desktop-before.png key ctrl-alt-t
sleep 3
# MX live session public default account. Enable its normal SSH server solely
# for remote UI tooling; do not change desktop package/configuration behavior.
vncdo -s localhost::5900 type 'sudo service ssh start' key enter
sleep 3
vncdo -s localhost::5900 type demo key enter
sleep 3
vncdo -s localhost::5900 capture evidence/mx/ssh-start.png
if ! timeout 12 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 true; then
  vncdo -s localhost::5900 type 'sudo mount /dev/sr1 /mnt' key enter
  sleep 3
  vncdo -s localhost::5900 capture evidence/mx/bootstrap-mounted.png
  vncdo -s localhost::5900 type 'sudo bash /mnt/bootstrap.sh' key enter
  sleep 3
  vncdo -s localhost::5900 capture evidence/mx/bootstrap-started.png
  ready=0
  for n in $(seq 1 60); do
    if timeout 10 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 true; then ready=1; break; fi
    if (( n % 6 == 0 )); then
      vncdo -s localhost::5900 key shift capture "evidence/mx/bootstrap-progress-$n.png"
      tail -n 30 evidence/mx/serial.log
    fi
    sleep 5
  done
  vncdo -s localhost::5900 capture evidence/mx/ssh-installed.png
  test "$ready" = 1
fi
sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 'id; cat /etc/os-release; command -v xdotool || true; command -v scrot || true; command -v tesseract || true'
sshpass -p demo scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" support/diagnostics/1310/mx-guest.sh support/diagnostics/1310/actions.sh demo@127.0.0.1:/home/demo/
bash support/diagnostics/1310/host-peer.sh > evidence/host-peer-workload.log 2>&1 &
peer_job=$!
timeout 1200 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 "TRANSFER_CONTROL=1 PACKAGE_FORMAT=${PACKAGE_FORMAT:-tar} bash /home/demo/mx-guest.sh" | tee evidence/mx/scenario.log
wait "$peer_job"
printf 'Issue 1310 real file selection control\n' > evidence/expected-control.txt
cmp evidence/expected-control.txt evidence/host-peer/saved-control.txt
sha256sum evidence/expected-control.txt evidence/host-peer/saved-control.txt > evidence/real-transfer-hashes.txt
