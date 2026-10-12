#!/bin/sh
# Run as the GNOME session user. The caller owns the display-manager restart.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
uuid=localsend-geometry-oracle@diagnostics.invalid
target_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$uuid"
mkdir -p "$target_dir"
cp "$source_dir/extension.js" "$source_dir/metadata.json" "$target_dir/"
gjs -c '
const Gio = imports.gi.Gio;
const settings = new Gio.Settings({schema_id: "org.gnome.shell"});
const uuid = "localsend-geometry-oracle@diagnostics.invalid";
const enabled = settings.get_strv("enabled-extensions");
print(JSON.stringify({beforeEnabled: enabled,
    beforeDisabled: settings.get_boolean("disable-user-extensions")}));
if (!enabled.includes(uuid)) {
    if (!settings.set_strv("enabled-extensions", [...enabled, uuid]))
        throw new Error("Could not enable diagnostic extension");
}
if (!settings.set_boolean("disable-user-extensions", false))
    throw new Error("Could not enable user extensions");
Gio.Settings.sync();
print(JSON.stringify({afterEnabled: settings.get_strv("enabled-extensions")}));
'
printf '%s\n' "Installed $target_dir. Start a new GNOME session before readiness."
