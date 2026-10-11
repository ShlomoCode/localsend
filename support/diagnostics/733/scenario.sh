#!/usr/bin/env bash
# Real unmodified apps, X11 input and ordinary Flatpak deployment.
set -Eeuxo pipefail
cd /home/mint
mkdir -p evidence
desktop_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
tr '\0' '\n' < "/proc/$desktop_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE)=' > evidence/session-environment.txt
while IFS= read -r assignment; do export "$assignment"; done < evidence/session-environment.txt
{ uname -a; cat /etc/os-release; cinnamon --version; flatpak --version; } > evidence/desktop-identity.txt
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive -y flathub org.freedesktop.Platform/x86_64/22.08
flatpak install --user --noninteractive -y ./historical.flatpak
flatpak info --user org.localsend.localsend_app > evidence/app-identity.txt
flatpak info --user --show-metadata org.localsend.localsend_app > evidence/app-metadata.txt
flatpak override --user --show org.localsend.localsend_app > evidence/initial-overrides.txt
flatpak remote-info --user --log flathub org.localsend.localsend_app > evidence/official-deployment-history.txt
mkdir -p "$HOME/Downloads"
flatpak run --user org.localsend.localsend_app > evidence/receiver.log 2>&1 &
sleep 10
receiver_wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1)
xdotool windowmove "$receiver_wid" 0 0
xdotool windowsize "$receiver_wid" 1000 700
sleep 2
import -window "$receiver_wid" evidence/receiver-initial.png
# Independent OS profile, real Ethernet interface and actual second app.
sudo useradd -m -s /bin/bash sender
sudo mkdir -p /home/sender/Downloads /home/sender/.config /run/user/$(id -u sender)
sudo chown -R sender:sender /home/sender /run/user/$(id -u sender)
sudo chmod 700 /run/user/$(id -u sender)
sudo ip netns add issue733sender
sudo ip link add receiver0 type veth peer name sender0
sudo ip link set sender0 netns issue733sender
sudo ip address add 192.168.73.1/24 dev receiver0
sudo ip link set receiver0 up
sudo ip netns exec issue733sender ip link set lo up
sudo ip netns exec issue733sender ip address add 192.168.73.2/24 dev sender0
sudo ip netns exec issue733sender ip link set sender0 up
sudo ip netns exec issue733sender ip route add 224.0.0.0/4 dev sender0
# Shared display authorization; independent app profile and DBus stay separate.
xhost +SI:localuser:sender
sudo curl -fL --max-time 120 https://github.com/localsend/localsend/releases/download/v1.11.1/LocalSend-1.11.1-linux-x86-64.tar.gz -o /tmp/733-sender.tar.gz
printf '92f45a8e321a6f06c4bbdcb7b9f247aa486a081b8247e9d0499b4e53e9f1a1bd  /tmp/733-sender.tar.gz\n' | sha256sum -c - > evidence/sender-artifact.txt
sudo mkdir -p /home/sender/app
sudo tar -xzf /tmp/733-sender.tar.gz -C /home/sender/app
sudo chown -R sender:sender /home/sender/app
sudo apt-get install -y libayatana-appindicator3-1
printf 'LocalSend issue733 ordinary Downloads control\n' | sudo tee /home/sender/Downloads/733-control.txt >/dev/null
sudo chown sender:sender /home/sender/Downloads/733-control.txt
sudo sha256sum /home/sender/Downloads/733-control.txt > evidence/source-sha256.txt
# Start the receiver again with the real peer interface already present.
flatpak kill org.localsend.localsend_app
sleep 2
flatpak run --user org.localsend.localsend_app >> evidence/receiver.log 2>&1 &
sleep 8
receiver_wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1)
xdotool windowmove "$receiver_wid" 0 0
xdotool windowsize "$receiver_wid" 1000 700
nohup sudo ip netns exec issue733sender runuser -l sender -c "env DISPLAY=$DISPLAY XDG_RUNTIME_DIR=/run/user/$(id -u sender) dbus-run-session -- /home/sender/app/localsend_app" > evidence/sender.log 2>&1 < /dev/null &
sleep 10
xdotool search --onlyvisible --name '^LocalSend$' > evidence/windows.txt
import -window root evidence/two-apps-prepared.png
for wid in $(cat evidence/windows.txt); do
  xdotool getwindowpid "$wid" >> evidence/windows-pid.txt
  import -window "$wid" "evidence/window-$wid.png"
done
# Preserve destination namespace before any experiment. Private contents alone
# do not constitute the bug; control and actual UI outcomes must be observed.
receiver_pid=$(pgrep -u mint -n -x localsend_app || pgrep -u mint -n -x localsend)
printf '%s\n' "$receiver_pid" > evidence/receiver-pid.txt
sudo cat "/proc/$receiver_pid/root/.flatpak-info" > evidence/receiver-flatpak-info.txt
sudo ls -ld "/proc/$receiver_pid/root/home/mint/Downloads" /home/mint/Downloads > evidence/initial-destination.txt
sudo stat -Lc '%d:%i %n' "/proc/$receiver_pid/root/home/mint/Downloads" /home/mint/Downloads >> evidence/initial-destination.txt
echo 'PREPARATION_ONLY_NO_TRANSFER_VERDICT' > evidence/result.txt
sender_wid=''
for wid in $(cat evidence/windows.txt); do
  [[ "$wid" == "$receiver_wid" ]] || sender_wid=$wid
done
test -n "$sender_wid"
xdotool windowmove "$sender_wid" 0 0
xdotool windowsize "$sender_wid" 1000 700
sudo apt-get install -y jq
prefs=$(find "$HOME/.var/app/org.localsend.localsend_app" -name shared_preferences.json -print -quit)
test -n "$prefs"
# Retain settings/history only; do not emit the generated TLS private context.
jq 'with_entries(select(.key|test("alias|destination|receive_history|quick_save")))' "$prefs" > evidence/receiver-settings-before.json
receiver_alias=$(jq -r 'to_entries[]|select(.key|endswith("ls_alias"))|.value' "$prefs")
test -n "$receiver_alias"
receiver_alias_word=${receiver_alias%% *}
source /home/mint/transfer.sh
select_fixture 733-control.txt normal
send_and_approve 733-control.txt normal "$receiver_alias_word"
sudo cmp /home/sender/Downloads/733-control.txt /home/mint/Downloads/733-control.txt
sudo sha256sum /home/mint/Downloads/733-control.txt > evidence/normal-host-sha256.txt
echo ACTUAL_TWO_APP_NORMAL_DOWNLOADS_HASH_PASS > evidence/result.txt
