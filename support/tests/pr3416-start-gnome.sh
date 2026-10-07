#!/usr/bin/env bash
# Run as the dedicated desktop user from a PAM-backed systemd service.
set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export DESKTOP_SESSION=ubuntu
export GNOME_SHELL_SESSION_MODE=ubuntu
export LIBGL_ALWAYS_SOFTWARE=1
unset DISPLAY WAYLAND_DISPLAY

mkdir -p "$XDG_CONFIG_HOME/autostart" "$XDG_DATA_HOME/gnome-shell/extensions/pr3416-probe@localsend.test"
printf 'yes\n' > "$XDG_CONFIG_HOME/gnome-initial-setup-done"
cat > "$XDG_CONFIG_HOME/autostart/update-notifier.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Update notifier
Hidden=true
EOF
cp /opt/pr3416/support/tests/pr3416-gnome-probe/* \
  "$XDG_DATA_HOME/gnome-shell/extensions/pr3416-probe@localsend.test/"

# Ubuntu's GNOME session starts Shell through this user service. Override only
# that service so its compositor has a real virtual Wayland monitor in CI.
unit_dir="$XDG_CONFIG_HOME/systemd/user/org.gnome.Shell@wayland.service.d"
mkdir -p "$unit_dir"
cat > "$unit_dir/pr3416-headless.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --wayland --headless --virtual-monitor 1280x800
EOF
systemctl --user daemon-reload
systemctl --user import-environment HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP DESKTOP_SESSION GNOME_SHELL_SESSION_MODE LIBGL_ALWAYS_SOFTWARE
dbus-update-activation-environment --systemd XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP DESKTOP_SESSION GNOME_SHELL_SESSION_MODE
systemctl --user reset-failed

gsettings set org.gnome.shell enabled-extensions "['ubuntu-dock@ubuntu.com', 'pr3416-probe@localsend.test']"
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.shell welcome-dialog-last-shown-version '46'
gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true
gsettings set org.gnome.shell.extensions.dash-to-dock show-running true

exec gnome-session --session=ubuntu
