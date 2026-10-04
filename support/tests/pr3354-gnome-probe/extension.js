import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const xml = `<node><interface name="org.localsend.TrayProbe">
  <method name="Inspect"><arg type="s" direction="out"/></method>
  <method name="LeaveOverview"/>
</interface></node>`;

function describeIcon(icon) {
    if (!icon)
        return '';
    if (icon instanceof Gio.EmblemedIcon)
        return describeIcon(icon.gicon);
    if (icon instanceof Gio.FileIcon)
        return icon.get_file().get_path() ?? '';
    return icon.to_string() ?? '';
}

function inspectActor(actor, depth = 0) {
    if (depth > 20 || !actor)
        return [];
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    const result = [{
        type: actor.constructor.name, x, y, width, height,
        visible: actor.is_mapped(),
        text: typeof actor.get_text === 'function' ? actor.get_text() : '',
        icon: actor.icon_name ?? '',
        gicon: describeIcon(actor.gicon),
        fallback: typeof actor.get_fallback_icon_name === 'function' ? actor.get_fallback_icon_name() : '',
    }];
    for (const child of actor.get_children())
        result.push(...inspectActor(child, depth + 1));
    return result;
}

export default class TrayProbe {
    enable() {
        this._object = Gio.DBusExportedObject.wrapJSObject(xml, {
            Inspect() {
                return JSON.stringify({
                    panel: inspectActor(Main.panel),
                    actors: inspectActor(Main.uiGroup),
                    windows: global.get_window_actors().map(actor => ({
                        title: actor.meta_window.get_title(),
                        pid: actor.meta_window.get_pid(),
                        minimized: actor.meta_window.minimized,
                        frame: actor.meta_window.get_frame_rect(),
                    })),
                    overview: Main.overview.visible,
                });
            },
            LeaveOverview() {
                Main.overview.hide();
            },
        });
        this._object.export(Gio.DBus.session, '/org/localsend/TrayProbe');
        this._name = Gio.bus_own_name_on_connection(Gio.DBus.session, 'org.localsend.TrayProbe', Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        this._object?.unexport();
        if (this._name)
            Gio.bus_unown_name(this._name);
    }
}
