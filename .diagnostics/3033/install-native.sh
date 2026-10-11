set -eu
root=/home/probe/evidence/native-deb
mkdir -p "$root"
curl --fail --location --retry 3 https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.deb -o "$root/localsend.deb"
sha256sum "$root/localsend.deb"
sudo apt-get install -y "$root/localsend.deb"
dpkg-query -W localsend
dpkg-query -L localsend
printf "INSTALL_COMPLETE\n"
