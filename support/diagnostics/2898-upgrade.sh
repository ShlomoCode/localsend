#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
E=/work/evidence/cloud
exec > >(tee "$E/transcript.log") 2>&1
trap 'cp -a /var/log/apt "$E/apt-logs"; dpkg-query -W > "$E/inventory-final.tsv"' EXIT
inventory() {
  cat /etc/os-release > "$E/$1-os-release.txt"
  dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$E/$1-inventory.tsv"
  apt-cache policy libappindicator3-1 libayatana-appindicator3-1 gir1.2-appindicator3-0.1 gir1.2-ayatanaappindicator3-0.1 > "$E/$1-policy.txt"
  apt-get check 2>&1 | tee "$E/$1-apt-check.log"
}
printf 'deb [check-valid-until=no] http://archive.debian.org/debian buster main\n' > /etc/apt/sources.list.d/legacy.list
apt-get update 2>&1 | tee "$E/debian12-apt-update.log"
apt-get install -y --no-install-recommends libappindicator3-1=0.4.92-7 gir1.2-appindicator3-0.1=0.4.92-7 curl ca-certificates zenity xvfb dbus-x11 openbox xdotool imagemagick binutils libgl1-mesa-dri xdg-user-dirs 2>&1 | tee "$E/debian12-legacy-install.log"
cd "$E"
apt-get download libappindicator3-1=0.4.92-7 gir1.2-appindicator3-0.1=0.4.92-7 libindicator3-7
sha256sum ./*.deb > old-deb-sha256.txt
inventory debian12
rm /etc/apt/sources.list.d/legacy.list
sed -i s/bookworm/trixie/g /etc/apt/sources.list.d/debian.sources
apt-get update 2>&1 | tee "$E/debian13-apt-update.log"
apt-get upgrade -y --without-new-pkgs 2>&1 | tee "$E/debian13-upgrade.log"
apt-get full-upgrade -y 2>&1 | tee "$E/debian13-full-upgrade.log"
inventory debian13-before-localsend
[ "$(dpkg-query -W -f='${Version}' libappindicator3-1)" = 0.4.92-7 ]
! dpkg-query -W -f='${db:Status-Abbrev}' libayatana-appindicator3-1 2>/dev/null | grep -q ^ii
curl -L --fail --retry 3 https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.deb -o "$E/LocalSend-1.17.0-linux-x86-64.deb"
sha256sum "$E/LocalSend-1.17.0-linux-x86-64.deb" > "$E/release-sha256.txt"
dpkg-deb -I "$E/LocalSend-1.17.0-linux-x86-64.deb" > "$E/release-metadata.txt"
apt-get install -y "$E/LocalSend-1.17.0-linux-x86-64.deb" 2>&1 | tee "$E/release-install.log"
inventory release-installed
! dpkg-query -W -f='${db:Status-Abbrev}' libayatana-appindicator3-1 2>/dev/null | grep -q ^ii
useradd -m -s /bin/bash probe
chmod -R a+rX "$E"
mkdir -p /tmp/issue2898-ui
chmod 777 /tmp/issue2898-ui
cat > /tmp/issue2898-ui/desktop.sh <<'DESKTOP'
#!/usr/bin/env bash
set -Eeuo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
openbox > /tmp/issue2898-ui/openbox.log 2>&1 &
zenity --info --text="GTK desktop control for issue 2898" --title="GTK control" > /tmp/issue2898-ui/gtk-control.log 2>&1 &
control=$!
sleep 3
xdotool search --onlyvisible --name "GTK control" > /tmp/issue2898-ui/gtk-control-window.txt
import -window root /tmp/issue2898-ui/gtk-control.png
kill "$control"
for n in 1 2 3; do
  set +e
  localsend_app > "/tmp/issue2898-ui/baseline-$n.log" 2>&1
  result=$?
  set -e
  echo "$result" > "/tmp/issue2898-ui/baseline-$n.exit"
  test "$result" = 127
  grep -F "libayatana-appindicator3.so.1: cannot open shared object file" "/tmp/issue2898-ui/baseline-$n.log"
done
import -window root /tmp/issue2898-ui/baseline-desktop.png
DESKTOP
runuser -u probe -- dbus-run-session -- xvfb-run -a -s "-screen 0 1280x800x24" bash /tmp/issue2898-ui/desktop.sh
cp -a /tmp/issue2898-ui "$E/baseline-ui"
# Only intervene after the release failed three times on a valid apt installation.
apt-get install -y libayatana-appindicator3-1 2>&1 | tee "$E/causal-ayatana-install.log"
inventory ayatana-control
cat > /tmp/issue2898-ui/success.sh <<'DESKTOP'
#!/usr/bin/env bash
set -Eeuo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
openbox > /tmp/issue2898-ui/openbox-control.log 2>&1 &
localsend_app > /tmp/issue2898-ui/ayatana-control-app.log 2>&1 &
app=$!
sleep 12
kill -0 "$app"
readlink /proc/"$app"/exe > /tmp/issue2898-ui/ayatana-control-executable.txt
xdotool search --onlyvisible --pid "$app" > /tmp/issue2898-ui/ayatana-control-window.txt
import -window root /tmp/issue2898-ui/ayatana-control.png
kill "$app"
DESKTOP
runuser -u probe -- dbus-run-session -- xvfb-run -a -s "-screen 0 1280x800x24" bash /tmp/issue2898-ui/success.sh
cp -a /tmp/issue2898-ui "$E/control-ui"
printf 'baseline_three_failures=yes\nayatana_install_launch=yes\n' > "$E/result.txt"
