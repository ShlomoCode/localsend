set -eu
root=/home/probe/evidence/snap32-install
mkdir -p "$root"
for attempt in $(seq 1 90); do
  if grep -q SNAP_INSTALL_COMPLETE /home/probe/evidence/snap-install.log; then break; fi
  sleep 2
done
grep -q SNAP_INSTALL_COMPLETE /home/probe/evidence/snap-install.log
sudo snap refresh localsend --revision=32
snap list localsend | tee "$root/list.txt"
snap info localsend | tee "$root/info.txt"
snap connections localsend | tee "$root/connections.txt"
rev=$(snap list localsend | awk "NR==2 {print \$3}")
sudo sha256sum "/var/lib/snapd/snaps/localsend_${rev}.snap"
sudo cat /snap/localsend/current/meta/snap.yaml
find /snap/localsend/current -name localsend_app -o -name libflutter_linux_gtk.so
printf "SNAP32_INSTALL_COMPLETE\n"
