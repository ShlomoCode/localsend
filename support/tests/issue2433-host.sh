#!/bin/bash
set -euo pipefail
mkdir -p evidence/cloud /tmp/issue2433 /home/runner/issue2433
ssh_opts=(-i /tmp/issue2433/key -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue2433/known_hosts -o ConnectTimeout=10)
guest() { ssh "${ssh_opts[@]}" probe@127.0.0.1 "$@"; }
capture() {
  local name=$1
  printf 'screendump %s\n' "$GITHUB_WORKSPACE/evidence/cloud/$name.ppm" | timeout 10 sudo socat - UNIX-CONNECT:/tmp/issue2433/monitor
  sudo chown "$(id -u):$(id -g)" "evidence/cloud/$name.ppm"
  convert "evidence/cloud/$name.ppm" "evidence/cloud/$name.png"
}
case "$1" in
boot)
  sudo apt-get update
  sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils socat imagemagick openssh-client
  df -Th /home/runner /tmp > evidence/cloud/host-disk.txt
  test "$(findmnt -no FSTYPE -T /home/runner)" != tmpfs
  curl -fL --retry 3 -o /home/runner/issue2433/fedora.qcow2 https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2
  sha256sum /home/runner/issue2433/fedora.qcow2 > evidence/cloud/fedora-image.sha256
  qemu-img resize /home/runner/issue2433/fedora.qcow2 30G
  ssh-keygen -q -t ed25519 -N '' -f /tmp/issue2433/key
  probe_key=$(cat /tmp/issue2433/key.pub)
  cat > /tmp/issue2433/user-data <<EOF
#cloud-config
users:
  - default
  - name: probe
    groups: [wheel, video]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $probe_key
EOF
  printf 'instance-id: issue2433\nlocal-hostname: issue2433\n' > /tmp/issue2433/meta-data
  cloud-localds /home/runner/issue2433/seed.iso /tmp/issue2433/user-data /tmp/issue2433/meta-data
  sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 6144 \
    -drive file=/home/runner/issue2433/fedora.qcow2,if=virtio,format=qcow2 \
    -drive file=/home/runner/issue2433/seed.iso,media=cdrom,readonly=on \
    -device virtio-vga -display none -vnc 127.0.0.1:1 -usb -device usb-tablet \
    -netdev user,id=n,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n \
    -monitor unix:/tmp/issue2433/monitor,server,nowait -serial file:evidence/cloud/serial.log -daemonize
  for i in $(seq 1 60); do if guest 'cloud-init status --wait' > evidence/cloud/cloud-init.txt 2>&1; then break; fi; sleep 10; done
  guest 'uname -a; cat /etc/os-release; lscpu' > evidence/cloud/guest-initial.txt
  ;;
provision)
  guest 'mkdir -p /home/probe/evidence /home/probe/.local/share/gnome-shell/extensions/issue2433-probe@localsend.test'
  scp "${ssh_opts[@]/-p/-P}" support/tests/issue2433-probe/* probe@127.0.0.1:/home/probe/.local/share/gnome-shell/extensions/issue2433-probe@localsend.test/
  scp "${ssh_opts[@]/-p/-P}" support/tests/issue2433-guest.sh probe@127.0.0.1:/home/probe/
  timeout 2400 ssh "${ssh_opts[@]}" probe@127.0.0.1 'bash issue2433-guest.sh provision' > evidence/cloud/provision.log 2>&1
  ready=0
  for i in $(seq 1 90); do
    if guest 'test -S /run/user/$(id -u)/wayland-0 && pgrep -u $(id -u) gnome-shell' >> evidence/cloud/ready.txt 2>&1; then ready=1; break; fi
    if [ $((i % 5)) = 0 ]; then capture "provision-$i" || true; fi
    sleep 10
  done
  test "$ready" = 1
  timeout 900 ssh "${ssh_opts[@]}" probe@127.0.0.1 'bash issue2433-guest.sh integrate' > evidence/cloud/integration.log 2>&1
  capture integrated
  ;;
observe)
  timeout 600 ssh "${ssh_opts[@]}" probe@127.0.0.1 'bash issue2433-guest.sh observe' > evidence/cloud/observe.log 2>&1
  capture observation-final
  ;;
collect)
  guest 'journalctl --user -b --no-pager; sudo journalctl -b -u gdm --no-pager' > evidence/cloud/journal.txt 2>&1 || true
  guest 'cat /etc/os-release; gnome-shell --version; loginctl list-sessions; loginctl show-session $(loginctl list-sessions --no-legend | awk '\''$3=="probe" {print $1;exit}'\''); ps -eo user,pid,args; sudo dnf list --installed' > evidence/cloud/environment.txt 2>&1 || true
  scp "${ssh_opts[@]/-p/-P}" -r probe@127.0.0.1:/home/probe/evidence evidence/cloud/guest || true
  capture final || true
  sudo chown -R "$(id -u):$(id -g)" evidence/cloud
  ;;
esac
