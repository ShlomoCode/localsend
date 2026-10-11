set -eu
mkdir -p /home/probe/evidence/snap-install
sudo apt-get install -y snapd squashfs-tools
sudo systemctl enable --now snapd.socket
sudo snap info localsend | tee /home/probe/evidence/snap-install/store-info.txt
sudo snap install localsend
snap list --all | tee /home/probe/evidence/snap-install/list.txt
snap info localsend | tee /home/probe/evidence/snap-install/installed-info.txt
snap connections localsend | tee /home/probe/evidence/snap-install/connections.txt
snap debug sandbox-features | tee /home/probe/evidence/snap-install/sandbox-features.txt
rev=$(snap list localsend | awk "NR==2 {print \$3}")
sudo sha256sum "/var/lib/snapd/snaps/localsend_${rev}.snap"
sudo cat /snap/localsend/current/meta/snap.yaml
printf "SNAP_INSTALL_COMPLETE\n"
