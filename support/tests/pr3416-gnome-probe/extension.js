import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Config from 'resource:///org/gnome/shell/misc/config.js';

const BUS_NAME = 'org.localsend.DockProbe';
const OBJECT_PATH = '/org/localsend/DockProbe';
const EVIDENCE_DIR = '/opt/pr3416/evidence/';
const xml = `<node><interface name="org.localsend.DockProbe">
  <method name="Inspect"><arg type="s" direction="out"/></method>
  <method name="LeaveOverview"/>
  <method name="Capture"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
</interface></node>`;

// GNOME Shell itself uses the same async Screenshot method; the image is
// rendered by Mutter, so it includes native Wayland surfaces and the dock.
Gio._promisify(Shell.Screenshot.prototype, 'screenshot');

function iconDescription(icon) {
    if (!icon)
        return '';
    if (icon instanceof Gio.EmblemedIcon)
        return iconDescription(icon.gicon);
    if (icon instanceof Gio.FileIcon)
        return icon.get_file().get_path() ?? '';
    return icon.to_string() ?? '';
}

function actorInfo(actor) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    let appId = '';
    try {
        appId = actor.app?.get_id() ?? '';
    } catch (e) {
        // Most Clutter actors are not app icons.
    }
    return {
        type: actor.constructor.name,
        styleClass: actor.get_style_class_name?.() ?? '',
        name: actor.name ?? '',
        x, y, width, height,
        mapped: actor.is_mapped(),
        appId,
        iconName: actor.icon_name ?? '',
        gicon: iconDescription(actor.gicon),
    };
}

function inspectTree(actor, ancestry = [], depth = 0, path = '0') {
    if (!actor || depth > 25)
        return [];
    const info = actorInfo(actor);
    info.ancestry = ancestry;
    info.path = path;
    const result = [info];
    const ancestor = [info.type, info.styleClass, info.name].filter(Boolean).join(' ');
    actor.get_children().forEach((child, index) =>
        result.push(...inspectTree(child, [...ancestry, ancestor], depth + 1, `${path}.${index}`)));
    return result;
}

function inspectWindow(actor, tracker) {
    const window = actor.meta_window;
    const app = tracker.get_window_app(window);
    const appInfo = app?.get_app_info() ?? null;
    const frame = window.get_frame_rect();
    const texture = app?.create_icon_texture(64);
    const renderedIcon = iconDescription(texture?.gicon);
    const renderedIconName = texture?.icon_name ?? '';
    texture?.destroy();
    return {
        title: window.get_title(),
        pid: window.get_pid(),
        wmClass: window.get_wm_class(),
        wmClassInstance: window.get_wm_class_instance?.() ?? '',
        clientType: window.get_client_type() === Meta.WindowClientType.WAYLAND ? 'wayland' : 'x11',
        appId: app?.get_id() ?? '',
        appName: app?.get_name() ?? '',
        windowBacked: app?.is_window_backed?.() ?? false,
        desktopFile: appInfo?.get_filename() ?? '',
        appInfoIcon: iconDescription(appInfo?.get_icon()),
        appIcon: iconDescription(app?.get_icon?.()),
        renderedIcon,
        renderedIconName,
        frame: {x: frame.x, y: frame.y, width: frame.width, height: frame.height},
        windowType: window.get_window_type(),
    };
}

function inspect() {
    const tracker = Shell.WindowTracker.get_default();
    const installed = Shell.AppSystem.get_default().lookup_app('localsend_app.desktop');
    const installedInfo = installed?.get_app_info() ?? null;
    const actors = inspectTree(global.stage);
    return JSON.stringify({
        backend: Meta.is_wayland_compositor() ? 'wayland' : 'x11',
        shellVersion: Config.PACKAGE_VERSION,
        stage: {width: global.stage.width, height: global.stage.height},
        overview: Main.overview.visible,
        desktopEntry: {
            appId: installed?.get_id() ?? '',
            file: installedInfo?.get_filename() ?? '',
            startupWMClass: installedInfo?.get_startup_wm_class?.() ?? '',
            icon: iconDescription(installedInfo?.get_icon()),
        },
        windows: global.get_window_actors().map(actor => inspectWindow(actor, tracker)),
        actors,
    });
}

export default class DockProbe {
    enable() {
        this._object = Gio.DBusExportedObject.wrapJSObject(xml, {
            Inspect() {
                return inspect();
            },
            LeaveOverview() {
                Main.overview.hide();
            },
            async CaptureAsync([filename], invocation) {
                if (!filename.startsWith(EVIDENCE_DIR) || !filename.endsWith('.png')) {
                    invocation.return_dbus_error(`${BUS_NAME}.InvalidPath`, `Screenshot must be a PNG below ${EVIDENCE_DIR}`);
                    return;
                }
                let stream;
                try {
                    stream = Gio.File.new_for_path(filename).replace(null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
                    await new Shell.Screenshot().screenshot(false, stream);
                    stream.close(null);
                    invocation.return_value(new GLib.Variant('(s)', [filename]));
                } catch (error) {
                    try {
                        stream?.close(null);
                    } catch (e) {
                        // Preserve the screenshot failure.
                    }
                    invocation.return_dbus_error(`${BUS_NAME}.CaptureFailed`, String(error));
                }
            },
        });
        this._object.export(Gio.DBus.session, OBJECT_PATH);
        this._name = Gio.bus_own_name_on_connection(Gio.DBus.session, BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        this._object?.unexport();
        if (this._name)
            Gio.bus_unown_name(this._name);
    }
}
