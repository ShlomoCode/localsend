#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
(cd evidence/packages && sha256sum -c SHA256SUMS)
mkdir -p evidence/cloud /home/runner/issue1927-mint /tmp/issue1927-mint/seed
collect() {
  result=$?
  set +e
  if [ -f /tmp/issue1927-mint/id ]; then
    timeout 60 scp -r -i /tmp/issue1927-mint/id -P 2277 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest
  fi
  sudo chown -R "$(id -u):$(id -g)" evidence
  printf 'harness_exit=%s\n' "$result" > evidence/cloud/result.txt
}
trap collect EXIT
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage socat imagemagick openssh-client tesseract-ocr
for mirror in https://mirror.csclub.uwaterloo.ca/linuxmint https://mirrors.edge.kernel.org/linuxmint; do
  if curl -fL --connect-timeout 20 --max-time 600 "$mirror/stable/22.2/linuxmint-22.2-cinnamon-64bit.iso" -o /home/runner/issue1927-mint/mint.iso; then break; fi
done
printf '759c9b5a2ad26eb9844b24f7da1696c705ff5fe07924a749f385f435176c2306  /home/runner/issue1927-mint/mint.iso\n' | sha256sum -c - | tee evidence/cloud/iso-hash.txt
ssh-keygen -q -t ed25519 -N '' -f /tmp/issue1927-mint/id
cp /tmp/issue1927-mint/id.pub /tmp/issue1927-mint/seed/id.pub
cp support/diagnostics/issue1927.sh /tmp/issue1927-mint/seed/scenario.sh
cp support/diagnostics/issue1927-portal-gui.sh /tmp/issue1927-mint/seed/portal-gui.sh
cp support/diagnostics/issue1927-ui.sh /tmp/issue1927-mint/seed/ui.sh
cp support/diagnostics/issue1927-xres-owner.c /tmp/issue1927-mint/seed/xres-owner.c
cp evidence/packages/{baseline,candidate}.flatpak /tmp/issue1927-mint/seed/
cat > /tmp/issue1927-mint/seed/bootstrap.sh <<'BOOT'
#!/bin/bash
set -euxo pipefail
exec > >(tee /tmp/issue1927-bootstrap.log /dev/ttyS0) 2>&1
mkdir -p /home/mint/.ssh /home/mint/evidence
cp /mnt/id.pub /home/mint/.ssh/authorized_keys
cp /mnt/scenario.sh /home/mint/scenario.sh
cp /mnt/portal-gui.sh /home/mint/portal-gui.sh
cp /mnt/ui.sh /home/mint/ui.sh
cp /mnt/xres-owner.c /home/mint/xres-owner.c
cp /mnt/{baseline,candidate}.flatpak /home/mint/
chown -R mint:mint /home/mint/.ssh /home/mint/evidence /home/mint/scenario.sh
chmod 700 /home/mint/.ssh
chmod 600 /home/mint/.ssh/authorized_keys
# Give the normal user Flatpak installation real ext4 storage instead of the
# live ISO's small RAM overlay. App code, permissions, HOME and session stay stock.
mkfs.ext4 -F -L FLATPAK /dev/vda
mkdir -p /home/mint/.local/share/flatpak
mount /dev/vda /home/mint/.local/share/flatpak
chown mint:mint /home/mint/.local/share/flatpak
df -Th / /home/mint/.local/share/flatpak > /home/mint/evidence/installation-storage.txt
cp -a /etc/apt /home/mint/evidence/apt-before
for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  test -f "$source" || continue
  sed -i '/^[[:space:]]*deb.*cdrom:/s/^/# Live-media cdrom source disabled: /' "$source"
done
timeout --foreground 240 apt-get update
timeout --foreground 600 apt-get install -y openssh-server xdotool imagemagick tesseract-ocr ffmpeg gcc pkg-config libx11-dev libxres-dev
gcc -std=c11 -Wall -Wextra -Werror /home/mint/xres-owner.c -o /home/mint/xres-owner $(pkg-config --cflags --libs x11 xres)
{ pkg-config --modversion x11 xres; dpkg-query -W libxres1 libxres-dev libx11-6; sha256sum /home/mint/xres-owner.c /home/mint/xres-owner; } > /home/mint/evidence/xres-build-provenance.txt
systemctl start ssh
touch /home/mint/evidence/bootstrap-complete
BOOT
genisoimage -quiet -o /home/runner/issue1927-mint/probe.iso -V PROBE -r /tmp/issue1927-mint/seed
qemu-img create -f qcow2 /home/runner/issue1927-mint/flatpak.qcow2 12G
sudo qemu-system-x86_64 -machine accel=kvm:tcg -cpu host -smp 2 -m 4096 -boot d -drive file=/home/runner/issue1927-mint/mint.iso,media=cdrom,readonly=on -drive file=/home/runner/issue1927-mint/probe.iso,media=cdrom,readonly=on -drive file=/home/runner/issue1927-mint/flatpak.qcow2,if=virtio,format=qcow2 -device virtio-vga -usb -device usb-tablet -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2277-:22 -device virtio-net-pci,netdev=net0 -display none -monitor unix:/tmp/issue1927-mint/monitor,server,nowait -serial file:evidence/cloud/serial.log -daemonize
ready=0
for n in $(seq 1 18); do
  sleep 15
  printf 'screendump %s/evidence/cloud/desktop.ppm\n' "$GITHUB_WORKSPACE" | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
  sudo chmod a+r evidence/cloud/desktop.ppm
  convert evidence/cloud/desktop.ppm evidence/cloud/desktop.png
  tesseract evidence/cloud/desktop.png stdout > evidence/cloud/desktop.txt 2>/dev/null
  if grep -Eq 'Computer|Home|Install.*Mint' evidence/cloud/desktop.txt; then ready=1; break; fi
done
test "$ready" = 1
printf 'sendkey ctrl-alt-t\n' | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
sleep 5
command='sudo mount /dev/sr1 /mnt; sudo bash /mnt/bootstrap.sh'
for ((index=0; index<${#command}; index++)); do
  key=${command:index:1}
  case "$key" in ' ') key=spc;; '/') key=slash;; ';') key=semicolon;; '.') key=dot;; '-') key=minus;; esac
  printf 'sendkey %s 40\n' "$key" | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor >/dev/null
  sleep .08
done
printf 'sendkey ret 80\n' | sudo socat - UNIX-CONNECT:/tmp/issue1927-mint/monitor
opts=(-i /tmp/issue1927-mint/id -p 2277 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known -o ConnectTimeout=5)
ready=0
for n in $(seq 1 60); do
  if timeout 10 ssh "${opts[@]}" mint@127.0.0.1 'test -f /home/mint/evidence/bootstrap-complete && pgrep -x cinnamon'; then ready=1; break; fi
  sleep 15
done
test "$ready" = 1
timeout 1200 ssh "${opts[@]}" mint@127.0.0.1 'bash -s' > evidence/cloud/scenario.log 2>&1 <<'GUEST'
set -Eeuxo pipefail
cd /home/mint
OUT=$(realpath evidence)
source /home/mint/ui.sh
desktop_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
tr '\0' '\n' < "/proc/$desktop_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE)=' > evidence/session-environment.txt
while IFS= read -r assignment; do export "$assignment"; done < evidence/session-environment.txt
start_xres_control initial
{ cinnamon --version; flatpak --version; loginctl list-sessions; } > evidence/desktop-identity.txt
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive -y flathub org.freedesktop.Platform/x86_64/26.08
flatpak install --user --noninteractive -y ./baseline.flatpak
{ dpkg-query -W '*xdg-desktop-portal*'; flatpak remote-info --user --log flathub org.localsend.localsend_app; } > evidence/portal-and-package-history.txt 2>&1
gdbus introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop > evidence/portal-host-introspection.txt 2>&1 || true
flatpak run --user --command=sh org.localsend.localsend_app -c 'command -v gdbus; gdbus introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop' > evidence/portal-sandbox-introspection.txt 2>&1 || true
cp -a /usr/share/xdg-desktop-portal evidence/portal-backend-config
session_environment() {
  local desktop_pid
  desktop_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
  test -n "$desktop_pid"
  while IFS= read -r assignment; do export "$assignment"; done < <(tr '\0' '\n' < "/proc/$desktop_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE)=')
}
relogin() {
  local before_pid
  before_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
  sudo systemctl restart lightdm
  for attempt in $(seq 1 60); do
    new_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1 || true)
    if [ -n "$new_pid" ] && [ "$new_pid" != "$before_pid" ]; then sleep 15; session_environment; start_xres_control "$new_pid"; return; fi
    sleep 2
  done
  return 1
}
# Use the unmodified exported launcher as a supported manual startup control.
mkdir -p "$HOME/.config/autostart"
cp "$HOME/.local/share/flatpak/exports/share/applications/org.localsend.localsend_app.desktop" "$HOME/.config/autostart/issue1927-manual-control.desktop"
cp "$HOME/.config/autostart/issue1927-manual-control.desktop" evidence/manual-control.desktop
relogin
pgrep -x localsend > evidence/manual-login-app-pid.txt
xdotool search --onlyvisible --name '^LocalSend$' > evidence/manual-login-window.txt
import -window root evidence/manual-login.png
flatpak kill org.localsend.localsend_app
rm "$HOME/.config/autostart/issue1927-manual-control.desktop"
EXISTING_DESKTOP=1 bash scenario.sh
relogin
{ loginctl list-sessions; flatpak ps --columns=instance,application,pid; pgrep -x localsend || true; } > evidence/app-generated-login-state.txt
import -window root evidence/app-generated-login.png
session_environment
flatpak run --user org.localsend.localsend_app > evidence/post-login-app.log 2>&1 &
sleep 8
wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1)
stabilize_window
xdotool mousemove --window "$wid" 105 211 click 1
sleep 2
import -window "$wid" evidence/post-login-settings.png
flatpak kill org.localsend.localsend_app
flatpak override --user --reset org.localsend.localsend_app
flatpak uninstall --user --delete-data --noninteractive -y org.localsend.localsend_app
rm -f "$HOME/.config/autostart/localsend_app.desktop" "$HOME/.config/autostart/org.localsend.localsend_app.desktop"
flatpak install --user --noninteractive -y ./candidate.flatpak
flatpak override --user --show org.localsend.localsend_app > evidence/candidate-overrides.txt
source /home/mint/portal-gui.sh
GUEST
scp -r -i /tmp/issue1927-mint/id -P 2277 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/issue1927-mint/known mint@127.0.0.1:/home/mint/evidence evidence/cloud/guest
sudo chown -R "$(id -u):$(id -g)" evidence
