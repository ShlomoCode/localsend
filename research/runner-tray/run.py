#!/usr/bin/env python3
"""Run on Linux inside dbus-run-session and Xvfb; never modifies LocalSend."""
import argparse
import json
import subprocess
import time
from pathlib import Path

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

WATCHER = "org.kde.StatusNotifierWatcher"
ITEM = "org.kde.StatusNotifierItem"
PROPS = "org.freedesktop.DBus.Properties"
MENU = "com.canonical.dbusmenu"
STABLE_ID = "org.localsend.localsend_app"


def plain(value):
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, (dbus.String, dbus.ObjectPath, dbus.Signature)):
        return str(value)
    if isinstance(value, dbus.Boolean):
        return bool(value)
    if isinstance(value, (dbus.Byte, dbus.Int16, dbus.Int32, dbus.Int64,
                          dbus.UInt16, dbus.UInt32, dbus.UInt64)):
        return int(value)
    return value


class Watcher(dbus.service.Object):
    def __init__(self, bus):
        self.items = []
        self.name = dbus.service.BusName(WATCHER, bus=bus, do_not_queue=True)
        super().__init__(bus, "/StatusNotifierWatcher")

    @dbus.service.method(WATCHER, in_signature="s", out_signature="", sender_keyword="sender")
    def RegisterStatusNotifierItem(self, service, sender=None):
        service = str(service)
        # AppIndicator may register an object path, in which case its unique
        # sender identifies the service; otherwise the default path applies.
        address = {"service": str(sender) if service.startswith("/") else service,
                   "path": service if service.startswith("/") else "/StatusNotifierItem"}
        self.items.append(address)
        self.StatusNotifierItemRegistered(address["service"] + address["path"])

    @dbus.service.method(WATCHER, in_signature="s", out_signature="")
    def RegisterStatusNotifierHost(self, service):
        self.StatusNotifierHostRegistered()

    @dbus.service.signal(WATCHER, signature="s")
    def StatusNotifierItemRegistered(self, service):
        pass

    @dbus.service.signal(WATCHER, signature="")
    def StatusNotifierHostRegistered(self):
        pass

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != WATCHER:
            return {}
        return {
            "RegisteredStatusNotifierItems": dbus.Array(
                [x["service"] + x["path"] for x in self.items], signature="s"),
            "IsStatusNotifierHostRegistered": dbus.Boolean(True),
            "ProtocolVersion": dbus.Int32(0),
        }

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface)[name]


def pump():
    context = GLib.MainContext.default()
    while context.pending():
        context.iteration(False)


def records(log):
    if not log.exists():
        return []
    result = []
    for line in log.read_text(errors="replace").splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                result.append(value)
        except json.JSONDecodeError:
            pass
    return result


def wait_for(predicate, process, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        pump()
        value = predicate()
        if value:
            return value
        if process.poll() is not None:
            raise RuntimeError("App exited before the expected observation")
        time.sleep(0.02)
    raise TimeoutError("Timed out waiting for the tray observation")


def find_menu(layout):
    found = {}
    def visit(node):
        node_id, properties, children = node
        if str(properties.get("label", "")) in ("Open", "Quit"):
            found[str(properties["label"])] = int(node_id)
        for child in children:
            visit(child)
    visit(layout)
    return found


def launch(bus, watcher, binary, directory, mode, number):
    logfile = directory / f"{mode}-{number}.log"
    registration_count = len(watcher.items)
    with logfile.open("w") as output:
        process = subprocess.Popen([str(binary), mode], stdout=output, stderr=subprocess.STDOUT)
        try:
            ready = wait_for(
                lambda: next((r for r in records(logfile) if r.get("event") == "ready"), None),
                process)
            address = wait_for(
                lambda: watcher.items[registration_count]
                if len(watcher.items) > registration_count else None, process)
            item = bus.get_object(address["service"], address["path"])
            properties = dbus.Interface(item, PROPS).GetAll(ITEM)
            actual_id = str(properties["Id"])
            menu_path = str(properties["Menu"])
            menu = dbus.Interface(bus.get_object(address["service"], menu_path), MENU)
            revision, layout = menu.GetLayout(
                dbus.Int32(0), dbus.Int32(-1), dbus.Array(["label"], signature="s"))
            labels = find_menu(layout)
            if set(labels) != {"Open", "Quit"}:
                raise AssertionError(f"Unexpected actual DBus menu labels: {labels}")
            timestamp = dbus.UInt32(int(time.time() * 1000) % (2 ** 32))
            menu.Event(dbus.Int32(labels["Open"]), "clicked",
                       dbus.Int32(0, variant_level=1), timestamp)
            wait_for(lambda: any(r.get("event") == "menu_callback" and r.get("key") == "open"
                                 for r in records(logfile)), process)
            menu.Event(dbus.Int32(labels["Quit"]), "clicked",
                       dbus.Int32(0, variant_level=1), timestamp)
            deadline = time.monotonic() + 10
            while process.poll() is None and time.monotonic() < deadline:
                pump()
                time.sleep(0.02)
            if process.poll() is None:
                raise TimeoutError("Quit DBus event did not terminate the app")
            log_records = records(logfile)
            if not any(r.get("event") == "menu_callback" and r.get("key") == "quit"
                       for r in log_records):
                raise AssertionError("Quit callback was not recorded")
            if process.returncode != 0:
                raise AssertionError(f"Quit exit code was {process.returncode}")
            return {"mode": mode, "launch": number, "id": actual_id,
                    "address": address, "menuPath": menu_path,
                    "dbusMenuIds": labels, "ready": ready,
                    "openCallback": True, "quitCallback": True,
                    "exitCode": process.returncode, "log": str(logfile)}
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("observations"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    watcher = Watcher(bus)
    result = {"scope": "native DBus identity and actual menu callbacks; no KDE settings persistence claim",
              "observations": []}
    try:
        for mode in ("before", "after"):
            for number in (1, 2):
                observation = launch(bus, watcher, args.binary.resolve(),
                                     args.output.resolve(), mode, number)
                result["observations"].append(observation)
                print(json.dumps(observation), flush=True)
        before = [x["id"] for x in result["observations"] if x["mode"] == "before"]
        after = [x["id"] for x in result["observations"] if x["mode"] == "after"]
        assert before[0] != before[1], "Random-ID baseline unexpectedly reused an ID"
        assert after == [STABLE_ID, STABLE_ID], "Patched native ID was not stable"
        result["pass"] = True
    except Exception as error:
        result["pass"] = False
        result["error"] = repr(error)
        raise
    finally:
        (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
