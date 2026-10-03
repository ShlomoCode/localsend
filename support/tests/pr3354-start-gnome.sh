#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME/.local/share/gnome-shell/extensions/pr3354-probe@localsend.test"
cp /opt/pr3354/support/tests/pr3354-gnome-probe/* "$HOME/.local/share/gnome-shell/extensions/pr3354-probe@localsend.test/"
systemctl --user import-environment HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GNOME_SHELL_SESSION_MODE LIBGL_ALWAYS_SOFTWARE
dbus-update-activation-environment --systemd DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GNOME_SHELL_SESSION_MODE
systemctl --user reset-failed
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
gsettings set org.gnome.shell enabled-extensions "['ubuntu-appindicators@ubuntu.com', 'ubuntu-dock@ubuntu.com', 'pr3354-probe@localsend.test']"
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.shell welcome-dialog-last-shown-version '46'
exec gnome-session --session=ubuntu
