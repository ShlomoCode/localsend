#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
E=/work/evidence/cloud/cases/$PROBE_CASE
mkdir -p "$E"
exec > >(tee "$E/transcript.log") 2>&1
trap 'cp -a /var/log/apt "$E/apt-logs"; dpkg-query -W > "$E/final-inventory.tsv"; cp -a /tmp/issue2898-case "$E/ui" 2>/dev/null || true' EXIT
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$E/pre-inventory.tsv"
[ "$(dpkg-query -W -f='${Version}' libappindicator3-1)" = 0.4.92-7 ]
apt-get install -y "/work/evidence/cloud/packages/$PROBE_CASE.deb" 2>&1 | tee "$E/install.log"
apt-get check 2>&1 | tee "$E/apt-check.log"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$E/post-inventory.tsv"
exe=$(readlink -f "$(command -v localsend_app)")
echo "$exe" > "$E/installed-executable.txt"
ldd "$exe" > "$E/ldd.txt" || true
find "$(dirname "$exe")/lib" -name "*.so" -exec sh -c 'echo "$1"; readelf -d "$1" | grep NEEDED' _ {} \; > "$E/plugin-needed.txt"
useradd -m -s /bin/bash probe
mkdir -p /tmp/issue2898-case
chmod 777 /tmp/issue2898-case
cat > /tmp/issue2898-case/launch.sh <<'DESKTOP'
#!/usr/bin/env bash
set -Eeuo pipefail
export LIBGL_ALWAYS_SOFTWARE=1
trap 'import -window root /tmp/issue2898-case/failure-desktop.png || true; xwininfo -root -tree > /tmp/issue2898-case/failure-window-tree.txt; ps aux > /tmp/issue2898-case/failure-processes.txt' ERR
openbox > /tmp/issue2898-case/openbox.log 2>&1 &
zenity --info --text="GTK launch control" --title="GTK control" > /tmp/issue2898-case/gtk.log 2>&1 &
control=$!
for attempt in $(seq 1 75); do
  if xdotool search --onlyvisible --name "GTK control" > /tmp/issue2898-case/gtk-window.txt; then break; fi
  sleep 0.2
done
if ! xdotool search --onlyvisible --name "GTK control" > /tmp/issue2898-case/gtk-window.txt; then
  import -window root /tmp/issue2898-case/gtk-control-unlocated.png
  xwininfo -root -tree > /tmp/issue2898-case/gtk-control-window-tree.txt
  ps aux > /tmp/issue2898-case/gtk-control-processes.txt
  echo GTK_control_unlocated > /tmp/issue2898-case/gtk-control-status.txt
fi
import -window root /tmp/issue2898-case/gtk-control.png
kill "$control" || true
if [[ "$PROBE_CASE" == *baseline ]]; then
  for n in 1 2 3; do
    set +e
    localsend_app > /tmp/issue2898-case/launch-$n.log 2>&1
    result=$?
    set -e
    echo "$result" > /tmp/issue2898-case/launch-$n.exit
    test "$result" = 127
    grep -F "libayatana-appindicator3.so.1: cannot open shared object file" /tmp/issue2898-case/launch-$n.log
  done
else
  localsend_app > /tmp/issue2898-case/launch.log 2>&1 &
  app=$!
  sleep 12
  kill -0 "$app"
  readlink /proc/"$app"/exe > /tmp/issue2898-case/executable.txt
  xdotool search --onlyvisible --pid "$app" > /tmp/issue2898-case/window.txt
  import -window root /tmp/issue2898-case/app.png
  kill "$app"
fi
DESKTOP
runuser -u probe -- env PROBE_CASE="$PROBE_CASE" dbus-run-session -- xvfb-run -a -s "-screen 0 1600x1000x24" bash -x /tmp/issue2898-case/launch.sh 2>&1 | tee "$E/desktop-driver.log"
echo pass > "$E/result.txt"
