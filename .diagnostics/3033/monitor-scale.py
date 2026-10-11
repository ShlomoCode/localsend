import sys, json
from gi.repository import Gio, GLib
p = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", None)
s = p.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None).unpack()
if len(sys.argv) > 1:
    scale = float(sys.argv[1])
    monitor = s[1][0]
    mode = next(m for m in monitor[1] if m[6].get("is-current"))
    assert scale in mode[5], (scale, mode[5])
    props = {"layout-mode": GLib.Variant("u", 1)} if s[3].get("supports-changing-layout-mode") else {}
    v = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (s[0], 1, [(0, 0, scale, 0, True, [(monitor[0][0], mode[0], {})])], props))
    p.call_sync("ApplyMonitorsConfig", v, Gio.DBusCallFlags.NONE, -1, None)
    s = p.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None).unpack()
print(json.dumps(s))
