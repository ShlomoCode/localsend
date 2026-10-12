#!/usr/bin/env bash
# Diagnostic only: original MX23.2 XFCE image, no portal alteration.
set -euo pipefail
mkdir -p evidence/mx /home/runner/issue1310-mx
mxroot=/home/runner/issue1310-mx
guest_user=demo
case "${MX_SESSION:-live}" in live|installed) ;; *) exit 2;; esac
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
ufw status verbose
iptables -S
# Permit this isolated QEMU host to reach observation SSH using the distro's
# normal firewall configuration. Preserve all other firewall rules.
ufw allow from 10.0.2.2 to any port 22 proto tcp
ufw status verbose
date -u
BOOTSTRAP
genisoimage -quiet -r -o "$mxroot/bootstrap.iso" -V OBSERVATION "$mxroot/bootstrap"
opts=(-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" -o ConnectTimeout=5)
cleanup() {
  printf '%s\n' "$?" > evidence/mx/host-exit-code.txt
  if test -n "${peer_job:-}"; then kill "$peer_job" 2>/dev/null || true; fi
  timeout 120 sshpass -p demo scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" -r "$guest_user@127.0.0.1:/home/$guest_user/evidence" evidence/mx/guest || true
  vncdo -s localhost::5900 capture evidence/mx/final.png || true
  if test -f "$mxroot/qemu.pid"; then sudo kill "$(sudo cat "$mxroot/qemu.pid")" || true; fi
  sudo chown -R "$(id -u):$(id -g)" evidence
}
trap cleanup EXIT
trap 'exit 143' TERM
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
  vncdo -s localhost::5900 type 'sudo mount --mkdir=0700 /dev/sr1 /run/issue1310-bootstrap' key enter
  sleep 3
  vncdo -s localhost::5900 capture evidence/mx/bootstrap-mounted.png
  vncdo -s localhost::5900 type 'sudo bash /run/issue1310-bootstrap/bootstrap.sh' key enter
  sleep 3
  vncdo -s localhost::5900 capture evidence/mx/bootstrap-started.png
  ready=0
  for n in $(seq 1 60); do
    if timeout 10 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 true; then ready=1; break; fi
    if (( n % 6 == 0 )); then
      vncdo -s localhost::5900 key shift capture "evidence/mx/bootstrap-progress-$n.png"
      sudo tail -n 30 evidence/mx/serial.log
    fi
    sleep 5
  done
  vncdo -s localhost::5900 capture evidence/mx/ssh-installed.png
  test "$ready" = 1
fi
sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 'id; cat /etc/os-release; command -v xdotool || true; command -v scrot || true; command -v tesseract || true'
if test "${MX_SESSION:-live}" = installed; then
  sshpass -p demo scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" support/diagnostics/1310/mx-install.sh support/diagnostics/1310/mx-install-gui.py demo@127.0.0.1:/home/demo/
  timeout 1200 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 "INSTALLER_TRACE=${INSTALLER_TRACE:-0} bash /home/demo/mx-install.sh" > evidence/mx/install-ssh.log 2>&1 &
  install_job=$!
  install_done=0
  install_deadline=$((SECONDS + 1200))
  n=0
  while (( SECONDS < install_deadline )); do
    n=$((n + 1))
    if grep -q 'FAILED Phase\|MANUALLY ABORTED' evidence/mx/install-ssh.log; then
      # Give the guest only a short evidence/detach window, never an install retry.
      timeout 15 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 'for n in $(seq 1 20); do test -f /home/demo/evidence/install/observation-finished && exit 0; sleep 0.5; done; exit 1' || true
      exit 1
    fi
    if ! sudo kill -0 "$(sudo cat "$mxroot/qemu.pid")" 2>/dev/null; then install_done=1; break; fi
    if ! kill -0 "$install_job" 2>/dev/null; then
      if ! grep -Eq '^\+\+[[:space:]]+Finished[[:space:]]+\+\+[[:space:]]*$' evidence/mx/install-ssh.log; then
        wait "$install_job" || true
        exit 1
      fi
      # Completed installer may close SSH slightly before shutdown finishes.
      install_deadline=$((SECONDS + 60))
      break
    fi
    if (( n % 6 == 1 )); then
      vncdo -s localhost::5900 capture "evidence/mx/installer-$n.png"
      timeout 15 sshpass -p demo scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" -r demo@127.0.0.1:/home/demo/evidence/install evidence/mx/install-live || true
      timeout 15 sshpass -p demo ssh "${opts[@]}" demo@127.0.0.1 "printf 'demo\\n' | sudo -S cat /var/log/minstall.log" > evidence/mx/installer-current.log 2>&1 || true
    fi
    sleep 10
  done
  if test "$install_done" != 1 && grep -Eq '^\+\+[[:space:]]+Finished[[:space:]]+\+\+[[:space:]]*$' evidence/mx/install-ssh.log; then
    while (( SECONDS < install_deadline )); do
      if ! sudo kill -0 "$(sudo cat "$mxroot/qemu.pid")" 2>/dev/null; then install_done=1; break; fi
      sleep 2
    done
  fi
  wait "$install_job" || true # Successful installer poweroff closes observation SSH.
  test "$install_done" = 1
  grep -Eq '^\+\+[[:space:]]+Finished[[:space:]]+\+\+[[:space:]]*$' evidence/mx/install-ssh.log
  if grep -q 'FAILED Phase\|MANUALLY ABORTED' evidence/mx/install-ssh.log; then exit 1; fi
  sudo rm -f "$mxroot/qemu.pid"
  rm -f "$mxroot/known"
  # Boot only the installed disk. The original OS ISO is absent.
  sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -drive file="$mxroot/disk.qcow2",if=virtio,format=qcow2 -drive file="$mxroot/bootstrap.iso",media=cdrom,readonly=on -boot c -device virtio-vga -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 -vnc 127.0.0.1:0 -serial file:evidence/mx/installed-serial.log -pidfile "$mxroot/qemu.pid" -daemonize
  guest_user=issue1310
  sleep 20
  vncdo -s localhost::5900 capture evidence/mx/installed-boot.png key enter
  sleep 120
  vncdo -s localhost::5900 capture evidence/mx/installed-desktop.png
  if ! timeout 12 sshpass -p demo ssh "${opts[@]}" "$guest_user@127.0.0.1" true; then
    vncdo -s localhost::5900 key ctrl-alt-t
    sleep 3
    vncdo -s localhost::5900 type 'sudo mount --mkdir=0700 /dev/sr0 /run/issue1310-bootstrap' key enter
    sleep 3
    vncdo -s localhost::5900 type demo key enter
    sleep 3
    vncdo -s localhost::5900 type 'sudo bash /run/issue1310-bootstrap/bootstrap.sh' key enter
    ready=0
    ready_deadline=$((SECONDS + 240))
    while (( SECONDS < ready_deadline )); do
      if timeout 10 sshpass -p demo ssh "${opts[@]}" "$guest_user@127.0.0.1" true; then ready=1; break; fi
      sleep 5
    done
    test "$ready" = 1
  fi
  sshpass -p demo ssh "${opts[@]}" "$guest_user@127.0.0.1" 'set -eu; id; cat /etc/os-release; cat /proc/cmdline; findmnt -no SOURCE,FSTYPE /; lsblk -f; cat /etc/fstab; test "$(findmnt -no FSTYPE /)" = ext4; case "$(findmnt -no SOURCE /)" in /dev/vda*) ;; *) exit 1;; esac; ! grep -Eq "(^| )(boot=live|from=|sq=)" /proc/cmdline' > evidence/mx/installed-attestation.txt
  sshpass -p demo ssh "${opts[@]}" "$guest_user@127.0.0.1" "printf 'demo\\n' | sudo -S cat /var/log/minstall.log /etc/minstall.conf" > evidence/mx/installed-installer-record.txt
fi
sshpass -p demo scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile="$mxroot/known" support/diagnostics/1310/mx-guest.sh support/diagnostics/1310/actions.sh "$guest_user@127.0.0.1:/home/$guest_user/"
bash support/diagnostics/1310/host-peer.sh prepare > evidence/host-peer-preflight.log 2>&1
bash support/diagnostics/1310/host-peer.sh run > evidence/host-peer-workload.log 2>&1 &
peer_job=$!
timeout 1200 sshpass -p demo ssh "${opts[@]}" "$guest_user@127.0.0.1" "TRANSFER_CONTROL=1 PACKAGE_FORMAT=${PACKAGE_FORMAT:-tar} RELEASE_VERSIONS='${RELEASE_VERSIONS:-1.14.0 1.18.2}' bash /home/$guest_user/mx-guest.sh" | tee evidence/mx/scenario.log
wait "$peer_job"
printf 'Issue 1310 real file selection control\n' > evidence/expected-control.txt
cmp evidence/expected-control.txt evidence/host-peer/saved-control.txt
sha256sum evidence/expected-control.txt evidence/host-peer/saved-control.txt > evidence/real-transfer-hashes.txt
