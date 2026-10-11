import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Config from 'resource:///org/gnome/shell/misc/config.js';

const XML = `<node><interface name="org.localsend.Diagnostics.Geometry">
<method name="Snapshot"><arg type="s" direction="out" name="json"/></method>
</interface></node>`;

function rect(r) {
    return {x: r.x, y: r.y, width: r.width, height: r.height};
}

function observe(call) {
    try {
        return {value: call(), error: null};
    } catch (e) {
        return {value: null, error: String(e)};
    }
}

export default class GeometryOracle extends Extension {
    enable() {
        this._exported = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this._exported.export(Gio.DBus.session, '/org/localsend/Diagnostics/Geometry');
    }

    disable() {
        this._exported?.unexport();
        this._exported = null;
    }

    Snapshot() {
        const start = GLib.get_monotonic_time();
        const windows = global.get_window_actors().map(actor => {
            const w = actor.meta_window;
            const frame = observe(() => rect(w.get_frame_rect()));
            const buffer = observe(() => rect(w.get_buffer_rect()));
            const content = observe(() => rect(w.get_client_content_rect()));
            const backend = observe(() => {
                const t = w.get_client_type();
                return {enum: t, name: t === Meta.WindowClientType.WAYLAND
                    ? 'wayland' : t === Meta.WindowClientType.X11 ? 'x11' : 'unknown'};
            });
            return {
                stableSequence: observe(() => w.get_stable_sequence()),
                pid: observe(() => w.get_pid()),
                backend,
                title: observe(() => w.get_title()),
                wmClass: observe(() => w.get_wm_class()),
                gtkApplicationId: observe(() => w.get_gtk_application_id()),
                minimized: observe(() => w.minimized),
                actorVisible: observe(() => actor.visible),
                monitor: observe(() => w.get_monitor()),
                frameStage: frame,
                bufferStage: buffer,
                atspiWindowOriginStage: content,
                frameProtocol: observe(() => rect(w.stage_to_protocol_rect(w.get_frame_rect()))),
                bufferProtocol: observe(() => rect(w.stage_to_protocol_rect(w.get_buffer_rect()))),
                atspiWindowOriginProtocol: observe(() => rect(w.stage_to_protocol_rect(w.get_client_content_rect()))),
            };
        });
        return JSON.stringify({schema: 1, shellVersion: Config.PACKAGE_VERSION,
            compositorWayland: observe(() => Meta.is_wayland_compositor()),
            monotonicStartUs: start, monotonicEndUs: GLib.get_monotonic_time(),
            stageSize: {width: global.stage.width, height: global.stage.height},
            windows});
    }
}
