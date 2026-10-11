#!/bin/bash
set -euo pipefail
session_env() {
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
  export WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME
  export DISPLAY=$(systemctl --user show-environment | sed -n 's/^DISPLAY=//p' | head -1)
  export XAUTHORITY=$(systemctl --user show-environment | sed -n 's/^XAUTHORITY=//p' | head -1)
}
probe() { gdbus call --session --dest org.localsend.DockProbe --object-path /org/localsend/DockProbe --method "org.localsend.DockProbe.$1" "${@:2}"; }
case "$1" in
provision)
  sudo dnf -y --disablerepo='*' \
    --repofrompath=archive-base,https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/42/Everything/x86_64/os/ \
    --repofrompath=archive-updates,https://archives.fedoraproject.org/pub/archive/fedora/linux/updates/42/Everything/x86_64/ \
    --setopt=archive-base.gpgcheck=0 --setopt=archive-updates.gpgcheck=0 \
    install gnome-shell gnome-session gnome-session-wayland-session gdm gnome-control-center gnome-calculator nautilus flatpak fuse fuse-libs mesa-dri-drivers xorg-x11-server-Xwayland python3-gobject desktop-file-utils jq
  sudo mkdir -p /etc/gdm
  printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=probe\n' | sudo tee /etc/gdm/custom.conf
  mkdir -p ~/.config
  touch ~/.config/gnome-initial-setup-done
  sudo systemctl set-default graphical.target
  sudo systemctl enable --now gdm
  ;;
integrate)
  session_env
  gsettings set org.gnome.shell disable-user-extensions false
  gsettings set org.gnome.shell enabled-extensions "['issue2433-probe@localsend.test']"
  gsettings set org.gnome.desktop.session idle-delay 0
  gsettings set org.gnome.desktop.screensaver lock-enabled false
  gsettings get org.gnome.desktop.interface scaling-factor > evidence/scale.txt
  gsettings get org.gnome.desktop.interface text-scaling-factor >> evidence/scale.txt
  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  sudo flatpak install -y flathub it.mijorus.gearlever
  flatpak info it.mijorus.gearlever > evidence/gearlever-package.txt
  curl -fL --retry 3 -o /home/probe/LocalSend-1.17.0-linux-x86-64.AppImage https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.AppImage
  sha256sum /home/probe/LocalSend-1.17.0-linux-x86-64.AppImage > evidence/release.sha256
  chmod +x /home/probe/LocalSend-1.17.0-linux-x86-64.AppImage
  flatpak run it.mijorus.gearlever --integrate /home/probe/LocalSend-1.17.0-linux-x86-64.AppImage --yes > evidence/gearlever-integration.txt 2>&1
  find ~/.local/share/applications -name '*.desktop' -print -exec cat {} \; > evidence/integrated-desktop.txt
  find ~/.local/share -type f \( -name '*.png' -o -name '*.svg' \) -exec sha256sum {} \; > evidence/integrated-icons.sha256
  cp -a ~/.local/share/applications evidence/desktop-files
  mkdir -p evidence/icons
  while IFS= read -r icon; do test -f "$icon"; sha256sum "$icon" >> evidence/integrated-icons.sha256; cp "$icon" evidence/icons/; done < <(sed -n 's/^Icon=//p' evidence/integrated-desktop.txt)
  for i in $(seq 1 30); do if probe Inspect > evidence/probe-ready.txt 2>&1; then break; fi; sleep 2; done
  probe Inspect >> evidence/probe-ready.txt
  ;;
observe)
  session_env
  desktop=$(find ~/.local/share/applications -name '*.desktop' -exec grep -l '^Name=LocalSend' {} \; | head -1)
  test -n "$desktop"
  desktop_id=$(basename "$desktop")
  printf '%s\n' "$desktop_id" > evidence/desktop-id.txt
  desktop-file-validate "$desktop" > evidence/desktop-validation.txt 2>&1 || true
  probe Launch org.gnome.Calculator.desktop
  sleep 6
  probe ShowOverview
  sleep 3
  probe Inspect > evidence/calculator-control.txt
  probe Dump /home/probe/evidence/calculator-control.json
  jq -e '.windows[] | select(.title=="Calculator") | .windowBacked==false and .renderedIcon=="org.gnome.Calculator"' evidence/calculator-control.json
  probe Capture /home/probe/evidence/calculator-control.png
  run_case() {
    local tag=$1 expected=$2 class=$3
    probe LeaveOverview
    probe Launch "$desktop_id"
    sleep 25
    probe ShowOverview
    sleep 3
    probe Dump "/home/probe/evidence/$tag.json"
    probe Capture "/home/probe/evidence/$tag.png"
    pgrep -af 'localsend|AppImage' > "evidence/$tag-processes.txt"
    jq -e --arg class "$class" '.windows[] | select(.title=="LocalSend") | .wmClass==$class' "evidence/$tag.json"
    if [ "$expected" = generic ]; then
      jq -e '.windows[] | select(.title=="LocalSend") | .windowBacked==true and .renderedIcon=="application-x-executable" and .desktopFile==""' "evidence/$tag.json"
    else
      jq -e --arg id "$desktop_id" '.windows[] | select(.title=="LocalSend") | .windowBacked==false and .appId==$id and .renderedIcon=="/home/probe/AppImages/.icons/localsend"' "evidence/$tag.json"
    fi
    printf '%s %s PASS\n' "$tag" "$expected" >> evidence/verdicts.txt
    pkill -x localsend_app || true
    sleep 6
  }
  cp "$desktop" evidence/1.17-original.desktop
  for repeat in 1 2 3; do run_case "1.17-baseline-$repeat" generic localsend_app; done
  printf '\nStartupWMClass=localsend_app\n' >> "$desktop"
  cp "$desktop" evidence/1.17-matching-class.desktop
  update-desktop-database ~/.local/share/applications
  sleep 6
  for repeat in 1 2 3; do run_case "1.17-matching-class-$repeat" matched localsend_app; done
  cp evidence/1.17-original.desktop "$desktop"
  update-desktop-database ~/.local/share/applications
  sleep 6
  run_case 1.17-reversal generic localsend_app
  flatpak run it.mijorus.gearlever --remove /home/probe/AppImages/localsend.appimage --delete --yes > evidence/remove-old-integration.txt 2>&1
  curl -fL --retry 3 -o /home/probe/LocalSend-1.18.2-linux-x86-64.AppImage https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-linux-x86-64.AppImage
  sha256sum /home/probe/LocalSend-1.18.2-linux-x86-64.AppImage > evidence/release-1.18.2.sha256
  chmod +x /home/probe/LocalSend-1.18.2-linux-x86-64.AppImage
  flatpak run it.mijorus.gearlever --integrate /home/probe/LocalSend-1.18.2-linux-x86-64.AppImage --yes > evidence/integrate-1.18.2.txt 2>&1
  test "$(basename "$desktop")" = localsend.desktop
  test -f "$desktop"
  cp "$desktop" evidence/1.18.2-original.desktop
  sleep 6
  for repeat in 1 2 3; do run_case "1.18.2-baseline-$repeat" generic org.localsend.localsend_app; done
  printf '\nStartupWMClass=localsend_app\n' >> "$desktop"
  update-desktop-database ~/.local/share/applications
  sleep 6
  run_case 1.18.2-wrong-old-class generic org.localsend.localsend_app
  sed -i 's/^StartupWMClass=.*/StartupWMClass=org.localsend.localsend_app/' "$desktop"
  cp "$desktop" evidence/1.18.2-matching-class.desktop
  update-desktop-database ~/.local/share/applications
  sleep 6
  for repeat in 1 2 3; do run_case "1.18.2-matching-class-$repeat" matched org.localsend.localsend_app; done
  ;;
esac
