#!/usr/bin/env bash
# Real unmodified apps, X11 input and ordinary Flatpak deployment.
set -Eeuxo pipefail
cd /home/mint
mkdir -p evidence
desktop_pid=$(pgrep -u "$(id -u)" -x cinnamon | head -n 1)
tr '\0' '\n' < "/proc/$desktop_pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE)=' > evidence/session-environment.txt
while IFS= read -r assignment; do export "$assignment"; done < evidence/session-environment.txt
{ uname -a; cat /etc/os-release; cinnamon --version; flatpak --version; } > evidence/desktop-identity.txt
sudo flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak install --system --noninteractive -y flathub org.freedesktop.Platform/x86_64/22.08
sudo flatpak install --system --noninteractive -y ./historical.flatpak
flatpak info --system org.localsend.localsend_app > evidence/app-identity.txt
flatpak info --system --show-metadata org.localsend.localsend_app > evidence/app-metadata.txt
flatpak override --user --show org.localsend.localsend_app > evidence/initial-overrides.txt
flatpak remote-info --system --log flathub org.localsend.localsend_app > evidence/official-deployment-history.txt
mkdir -p "$HOME/Downloads"
flatpak run --system org.localsend.localsend_app > evidence/receiver.log 2>&1 &
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
flatpak run --system org.localsend.localsend_app >> evidence/receiver.log 2>&1 &
sleep 8
receiver_wid=$(xdotool search --onlyvisible --name '^LocalSend$' | head -n 1)
xdotool windowmove "$receiver_wid" 0 0
xdotool windowsize "$receiver_wid" 1000 700
nohup sudo ip netns exec issue733sender runuser -l sender -c "env DISPLAY=$DISPLAY XDG_RUNTIME_DIR=/run/user/$(id -u sender) dbus-run-session -- /home/sender/app/localsend_app" > evidence/sender.log 2>&1 < /dev/null &
sleep 10
xdotool search --onlyvisible --name '^LocalSend$' > evidence/windows.txt
import -window root evidence/two-apps-prepared.png
for wid in $(cat evidence/windows.txt); do
  # Historical Flatpak11.1 lacks _NET_WM_PID; retain this observation and use
  # independent OS user/process identities below instead of inventing a PID.
  xdotool getwindowpid "$wid" >> evidence/windows-pid.txt 2>&1 || printf 'WINDOW_PID_UNAVAILABLE wid=%s\n' "$wid" >> evidence/windows-pid.txt
  import -window "$wid" "evidence/window-$wid.png"
done
ps -eo pid,uid,comm,args | grep -E '[l]ocalsend|[i]ssue733sender' > evidence/app-process-identities.txt
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
test ! -e /home/mint/Downloads/733-control.txt
select_fixture 733-control.txt normal
send_and_approve 733-control.txt normal "$receiver_alias_word"
sudo cmp /home/sender/Downloads/733-control.txt /home/mint/Downloads/733-control.txt
sudo sha256sum /home/mint/Downloads/733-control.txt > evidence/normal-host-sha256.txt
echo ACTUAL_TWO_APP_NORMAL_DOWNLOADS_HASH_PASS > evidence/result.txt
click_word "$receiver_wid" Done normal-receiver-done
observe_history normal 733-control.txt
# Same live receiver first: a supported override changes future launches;
# observe its actual currently mounted destination without assuming effect.
sudo flatpak override --nofilesystem=xdg-download org.localsend.localsend_app
sudo flatpak override --show org.localsend.localsend_app > evidence/system-revocation.txt
flatpak override --user --show org.localsend.localsend_app > evidence/user-revocation.txt
sudo cp /home/sender/Downloads/733-control.txt /home/sender/Downloads/733-live-denial.txt
sudo chown sender:sender /home/sender/Downloads/733-live-denial.txt
test ! -e /home/mint/Downloads/733-live-denial.txt
restart_sender
select_fixture 733-live-denial.txt live-revocation
send_and_approve 733-live-denial.txt live-revocation "$receiver_alias_word"
sudo cmp /home/sender/Downloads/733-live-denial.txt /home/mint/Downloads/733-live-denial.txt
echo LIVE_RECEIVER_EXISTING_MOUNT_CONTROL_PASS >> evidence/result.txt
click_word "$receiver_wid" Done live-revocation-receiver-done
observe_history live-revocation 733-live-denial.txt
for repetition in 1 2 3; do
  label="revoked-$repetition"
  filename="733-revoked-$repetition.txt"
  sudo cp /home/sender/Downloads/733-control.txt "/home/sender/Downloads/$filename"
  sudo chown sender:sender "/home/sender/Downloads/$filename"
  test ! -e "/home/mint/Downloads/$filename"
  restart_receiver "$label"
  # The exact reported system override must remove the effective grant in
  # this fresh ordinary system installation before calling it a denied trial.
  effective_filesystems=$(sed -n 's/^filesystems=//p' "evidence/$label-process-flatpak-info.txt")
  if printf '%s\n' "$effective_filesystems" | grep -Eq '(^|;)xdg-download(:[^;]*)?(;|$)'; then
    printf '%s HARNESS_PERMISSION_STILL_GRANTED\n' "$label" >> evidence/result.txt
    exit 1
  fi
  restart_sender
  select_fixture "$filename" "$label"
  send_and_approve "$filename" "$label" "$receiver_alias_word"
  click_word "$receiver_wid" Done "$label-receiver-done"
  observe_history "$label" "$filename"
  sudo find /home/mint /run/user -name "$filename" -exec sha256sum {} \; > "evidence/$label-host-search-while-alive.txt" 2>&1 || printf '%s HOST_SEARCH_INCOMPLETE_SEE_RETAINED_ERRORS\n' "$label" >> evidence/result.txt
  flatpak kill org.localsend.localsend_app
  sleep 2
  sudo find /home/mint /run/user -name "$filename" -exec sha256sum {} \; > "evidence/$label-host-search-after-exit.txt" 2>&1 || printf '%s HOST_SEARCH_INCOMPLETE_SEE_RETAINED_ERRORS\n' "$label" >> evidence/result.txt
  if [[ -e "/home/mint/Downloads/$filename" ]]; then
    echo "$label HOST_FILE_PRESENT_REVIEW_UI_AND_HASH" >> evidence/result.txt
  else
    echo "$label HOST_FILE_ABSENT_REVIEW_ACTUAL_UI_PRIVATE_FILE_AND_HISTORY" >> evidence/result.txt
  fi
  # The next receiver restart helper handles an already stopped instance.
  flatpak run --system org.localsend.localsend_app >> evidence/receiver.log 2>&1 &
  sleep 8
  receiver_wid=$(xdotool search --onlyvisible --name '^LocalSend$' | grep -v "^$sender_wid$" | head -n 1)
done
