#!/usr/bin/env bash
set -Eeuo pipefail
INPUT="${1:-/mnt}"
EVIDENCE="${2:-/mnt/evidence}"
DATA="${3:-/mnt/flatpak-data}"
mkdir -p "$EVIDENCE" "$DATA"
mountpoint -q "$INPUT" || mount -t 9p -o trans=virtio,version=9p2000.L,ro localsend_input "$INPUT"
mountpoint -q "$EVIDENCE" || mount -t 9p -o trans=virtio,version=9p2000.L localsend_evidence "$EVIDENCE"
mountpoint -q "$DATA" || mount -t ext4 /dev/vda "$DATA"
exec > >(tee -a "$EVIDENCE/guest.log") 2>&1
fail() { echo "ERROR: $*" | tee -a "$EVIDENCE/infrastructure-failures.txt"; exit 1; }

[[ -r "$INPUT/reproduce.sh" && -r "$INPUT/mint-vm-guest.sh" ]] || fail 'Read-only harness share is incomplete.'
source /etc/os-release
printf 'PRETTY_NAME=%s\nVERSION_ID=%s\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-unknown}" > "$EVIDENCE/guest-os.txt"
[[ "${VERSION_ID:-}" == 22.3 ]] || fail "Expected Mint 22.3, got ${VERSION_ID:-unknown}."
id mint > "$EVIDENCE/mint-user.txt" 2>&1 || fail 'Mint live user is missing.'
HOME_MINT=$(getent passwd mint | cut -d: -f6)
[[ -d "$HOME_MINT" ]] || fail "Mint home directory is missing: $HOME_MINT"
SESSION_PID=""
for ((i=0; i<180; i++)); do
  SESSION_PID=$(pgrep -u mint -f 'cinnamon-session' | head -n1 || true)
  [[ -n "$SESSION_PID" ]] && break
  sleep 1
done
[[ -n "$SESSION_PID" ]] || fail 'Cinnamon session process did not start within 180 seconds.'
SESSION_ENV=$(tr '\0' '\n' < "/proc/$SESSION_PID/environ")
for key in DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XAUTHORITY; do
  value=$(printf '%s\n' "$SESSION_ENV" | sed -n "s/^$key=//p" | head -n1)
  [[ -z "$value" ]] || export "$key=$value"
done
[[ -n "${DISPLAY:-}" && "${XDG_CURRENT_DESKTOP:-}" == *Cinnamon* && "${XDG_SESSION_TYPE:-}" == x11 ]] || fail "Expected Cinnamon/X11 session; DISPLAY=${DISPLAY:-} desktop=${XDG_CURRENT_DESKTOP:-} session=${XDG_SESSION_TYPE:-}"
export DISPLAY XDG_RUNTIME_DIR="/run/user/$(id -u mint)"
BUS="$XDG_RUNTIME_DIR/bus"
for ((i=0; i<180; i++)); do [[ -S "$BUS" ]] && break; sleep 1; done
[[ -S "$BUS" ]] || fail 'Mint desktop D-Bus session socket did not appear within 180 seconds.'
export DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS"
export XAUTHORITY="${XAUTHORITY:-$HOME_MINT/.Xauthority}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y xvfb openbox dbus-x11 flatpak imagemagick xdotool x11-utils x11-xserver-utils iproute2 gdb strace fontconfig locales libgtk-3-0 libayatana-appindicator3-1 libgl1-mesa-dri libegl1 libgles2 curl procps
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-apt-keyring.gpg
curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
apt-get update
apt-get install -y brave-keyring

install -d -o mint -g mint "$DATA/flatpak-user-data" "$DATA/flatpak-app-data" "$HOME_MINT/.local/share" "$HOME_MINT/.var"
if [[ -d "$HOME_MINT/.local/share/flatpak" && ! -L "$HOME_MINT/.local/share/flatpak" ]]; then
  mv "$HOME_MINT/.local/share/flatpak" "$DATA/flatpak-user-data/flatpak"
fi
if [[ -d "$HOME_MINT/.var/app" && ! -L "$HOME_MINT/.var/app" ]]; then
  mv "$HOME_MINT/.var/app" "$DATA/flatpak-app-data/app"
fi
install -d -o mint -g mint "$DATA/flatpak-user-data/flatpak" "$DATA/flatpak-app-data/app"
ln -sfn "$DATA/flatpak-user-data/flatpak" "$HOME_MINT/.local/share/flatpak"
ln -sfn "$DATA/flatpak-app-data/app" "$HOME_MINT/.var/app"
runuser -u mint -- env DISPLAY="$DISPLAY" XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP="$XDG_CURRENT_DESKTOP" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XAUTHORITY="$XAUTHORITY" xrandr --current > "$EVIDENCE/display.txt" 2>&1 || fail 'Cannot access the Cinnamon X11 display.'
runuser -u mint -- env DISPLAY="$DISPLAY" XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP="$XDG_CURRENT_DESKTOP" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XAUTHORITY="$XAUTHORITY" import -window root "$EVIDENCE/cinnamon-desktop.png" || fail 'Could not capture initial Cinnamon desktop.'

export RUNNER_TEMP="$DATA/tmp" OUT="$EVIDENCE" GUI_MODE=native
export RUNTIME_BRANCH=26.08
export EXPECTED_APP_COMMIT=a7a6bc3f9debbbfd90c2e8874a83a5606db10b53dffc187449b0684991e7740c
export EXPECTED_RUNTIME_COMMIT=92659297ffdb4f9f14dd1562bd919b48160b0dc42c99653dcfc0688096af41df
install -d -o mint -g mint "$RUNNER_TEMP" "$EVIDENCE"
chown -R mint:mint "$DATA"
printf 'GUI_MODE=%s DISPLAY=%s XDG_CURRENT_DESKTOP=%s XDG_SESSION_TYPE=%s\n' "$GUI_MODE" "$DISPLAY" "$XDG_CURRENT_DESKTOP" "$XDG_SESSION_TYPE" > "$EVIDENCE/session.txt"
runuser -u mint -- env HOME="$HOME_MINT" USER=mint LOGNAME=mint PATH="$PATH" DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP="$XDG_CURRENT_DESKTOP" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" XAUTHORITY="$XAUTHORITY" GUI_MODE=native RUNNER_TEMP="$RUNNER_TEMP" OUT="$EVIDENCE" RUNTIME_BRANCH="$RUNTIME_BRANCH" EXPECTED_APP_COMMIT="$EXPECTED_APP_COMMIT" EXPECTED_RUNTIME_COMMIT="$EXPECTED_RUNTIME_COMMIT" bash "$INPUT/reproduce.sh"
echo 'result=completed' > "$EVIDENCE/guest-status.txt"
