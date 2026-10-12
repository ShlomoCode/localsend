#!/usr/bin/env python3
"""Bounded real GNOME Shell DBus call; run with guest /usr/bin/python3."""
import argparse
import json
import sys
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser()
parser.add_argument("--pid", type=int, help="Require exactly one window with this Mutter host PID")
parser.add_argument("--backend", choices=["wayland", "x11"])
parser.add_argument("--require-focused", action="store_true", help="Require compositor focus on the PID-verified window")
args = parser.parse_args()
try:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    reply = bus.call_sync("org.gnome.Shell", "/org/localsend/Diagnostics/Geometry",
                          "org.localsend.Diagnostics.Geometry", "Snapshot", None,
                          GLib.VariantType.new("(s)"), Gio.DBusCallFlags.NONE, 5000, None)
    snapshot = json.loads(reply.unpack()[0])
    print(json.dumps(snapshot), flush=True)
    if snapshot.get("schema") != 1 or not snapshot.get("shellVersion", "").startswith("48."):
        raise ValueError("Unexpected oracle schema or GNOME Shell version")
    compositor = snapshot["compositorWayland"]
    if compositor["error"] is not None or compositor["value"] is not True:
        raise ValueError("GNOME compositor is not verified Wayland")
    scale = snapshot["shellThemeScaleFactor"]
    if scale["error"] is not None or not isinstance(scale["value"], (int, float)) or scale["value"] <= 0:
        raise ValueError("Shell theme scale is unavailable or invalid")
    if args.require_focused and args.pid is None:
        raise ValueError("--require-focused needs --pid to establish window identity")
    if args.pid is not None:
        windows = [w for w in snapshot["windows"] if w["pid"]["value"] == args.pid]
        if len(windows) != 1:
            raise ValueError("Expected exactly one target-PID window, found " + str(len(windows)))
        window = windows[0]
        for field in ("pid", "backend", "stableSequence", "frameStage", "bufferStage",
                      "atspiWindowOriginStage", "frameProtocol", "bufferProtocol",
                      "atspiWindowOriginProtocol"):
            if window[field]["error"] is not None or window[field]["value"] is None:
                raise ValueError("Required observation failed: " + field)
        if args.backend and window["backend"]["value"]["name"] != args.backend:
            raise ValueError("Target window has unexpected backend")
        if args.require_focused and (window["compositorFocused"]["error"] is not None
                                     or window["compositorFocused"]["value"] is not True):
            raise ValueError("Target window is not verified compositor focus")
except Exception as error:
    print(json.dumps({"oracleError": str(error)}), file=sys.stderr, flush=True)
    sys.exit(1)
