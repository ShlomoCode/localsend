#!/usr/bin/env python3
"""Record rendered Qt tray controls and their accessible screen bounds."""
import json
import subprocess
import time
import os
import shlex
from pathlib import Path
import pyatspi
import dbus


def describe(node, depth=0):
    if depth > 20:
        return None
    try:
        record = {"name": node.name, "role": node.getRoleName()}
        try:
            bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
            record["bounds"] = [bounds.x, bounds.y, bounds.width, bounds.height]
        except Exception:
            pass
        record["children"] = [value for child in node if (value := describe(child, depth + 1))]
        return record
    except Exception:
        return None


def walk(node):
    yield node
    try:
        for child in node:
            yield from walk(child)
    except Exception:
        pass


def find(name, role=None):
    for _ in range(20):
        for node in walk(pyatspi.Registry.getDesktop(0)):
            try:
                if node.name == name and (role is None or node.getRoleName() == role):
                    bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                    if bounds.width > 0 and bounds.height > 0 and node.getState().contains(pyatspi.STATE_SHOWING):
                        return node
            except Exception:
                continue
        time.sleep(.25)
    raise RuntimeError(f"Accessible UI control missing: {name} ({role})")


def click(node):
    bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
    subprocess.run(["xdotool", "mousemove", str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2), "click", "1"], check=True)
    time.sleep(1)


def snapshot(name):
    Path(f"evidence/{name}.json").write_text(json.dumps(describe(pyatspi.Registry.getDesktop(0)), indent=2))
    subprocess.run(["import", "-window", "root", f"evidence/{name}.png"], check=True)
    stacking = subprocess.run(["xprop", "-root", "_NET_ACTIVE_WINDOW", "_NET_CLIENT_LIST_STACKING"], capture_output=True, text=True)
    Path(f"evidence/{name}-stacking.txt").write_text(stacking.stdout + stacking.stderr)
    config = Path.home() / ".config/plasma-org.kde.plasma.desktop-appletsrc"
    Path(f"evidence/{name}-plasma-config.txt").write_text(config.read_text())


def registered_item(pid):
    for _ in range(80):
        response = subprocess.check_output(["busctl", "--user", "get-property", "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"], text=True)
        for item in shlex.split(response)[2:]:
            service, path = item.split("/", 1)
            try:
                owner = subprocess.check_output(["busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", service], text=True)
            except subprocess.CalledProcessError:
                continue
            if int(owner.split()[1]) == pid:
                value = subprocess.check_output(["busctl", "--user", "get-property", service, "/" + path, "org.kde.StatusNotifierItem", "Id"], text=True)
                return {"pid": pid, "address": item, "id": shlex.split(value)[1]}
        time.sleep(.25)
    raise RuntimeError(f"No tray registration for application PID {pid}")


def panel_item():
    for node in walk(pyatspi.Registry.getDesktop(0)):
        try:
            bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
            if node.name == "org.localsend.localsend_app" and node.getRoleName() == "button" and bounds.y >= 756 and node.getState().contains(pyatspi.STATE_SHOWING):
                return node
        except Exception:
            pass
    return None


def prepare_hide(stage):
    subprocess.run(["xdotool", "search", "--name", "^LocalSend$", "windowminimize"], check=True)
    click(find("Show hidden icons", "button"))
    click(find("Configure System Tray...", "button"))
    click(find("Entries"))
    label = find("org.localsend.localsend_app", "label")
    row = label.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
    candidates = []
    for node in walk(pyatspi.Registry.getDesktop(0)):
        try:
            if node.getRoleName() == "combo box" and node.getState().contains(pyatspi.STATE_SHOWING):
                bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                if abs(bounds.y - row.y) < 20:
                    candidates.append(node)
        except Exception:
            continue
    assert len(candidates) == 1, f"Expected one LocalSend visibility selector, got {len(candidates)}"
    click(candidates[0])
    subprocess.run(["xdotool", "key", "End", "Return"], check=True)
    time.sleep(.5)
    snapshot(stage + "-selected-hidden")
    click(find("Apply", "button"))
    click(find("OK", "button"))
    subprocess.run(["xdotool", "key", "Escape"], check=True)
    time.sleep(2)
    snapshot(stage + "-hidden-panel")
    assert panel_item() is None, "Hide did not remove LocalSend from rendered panel"


def quit_via_menu(pid, stage):
    item = registered_item(pid)
    service, path = item["address"].split("/", 1)
    detail = subprocess.run(["busctl", "--user", "introspect", service, "/" + path, "org.kde.StatusNotifierItem"], capture_output=True, text=True)
    Path(f"evidence/{stage}-sni.txt").write_text(detail.stdout + detail.stderr)
    # Invoke the application-owned menu leaf through the standard desktop API.
    # This dispatches the original Quit callback, with no process signal/config edits.
    bus = dbus.SessionBus()
    properties = dbus.Interface(bus.get_object(service, "/" + path), "org.freedesktop.DBus.Properties")
    menu_path = str(properties.Get("org.kde.StatusNotifierItem", "Menu"))
    menu = dbus.Interface(bus.get_object(service, menu_path), "com.canonical.dbusmenu")
    revision, layout = menu.GetLayout(0, -1, dbus.Array([], signature="s"))
    leaves = []
    def collect(entry):
        entry_id, props, children = entry
        record = {"id": int(entry_id), "properties": {str(k): str(v) for k, v in props.items()}, "children": []}
        for child in children:
            record["children"].append(collect(child))
        if str(props.get("label", "")) == "Quit LocalSend" and not children:
            leaves.append(int(entry_id))
        return record
    trace = {"pid": pid, "bus": service, "sni_path": "/" + path, "menu_path": menu_path, "revision": int(revision), "layout": collect(layout)}
    Path(f"evidence/{stage}-menu-api.json").write_text(json.dumps(trace, indent=2))
    assert len(leaves) == 1, f"Expected one original Quit LocalSend leaf, got {leaves}"
    trace["invocation"] = {"method": "com.canonical.dbusmenu.Event", "id": leaves[0], "event": "clicked", "timestamp": 0}
    Path(f"evidence/{stage}-menu-api.json").write_text(json.dumps(trace, indent=2))
    try:
        menu.Event(dbus.Int32(leaves[0]), "clicked", dbus.Int32(0, variant_level=1), dbus.UInt32(0))
    except dbus.DBusException as error:
        trace["event_error"] = str(error)
        Path(f"evidence/{stage}-menu-api.json").write_text(json.dumps(trace, indent=2))
        if error.get_dbus_name() not in ("org.freedesktop.DBus.Error.NoReply", "org.freedesktop.DBus.Error.Disconnected"):
            raise
    def record_exit():
        trace["process_exit"] = True
        for _ in range(20):
            response = subprocess.check_output(["busctl", "--user", "get-property", "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"], text=True)
            trace["watcher_after_quit"] = response.strip()
            trace["sni_unregistered"] = item["address"] not in shlex.split(response)[2:]
            if trace["sni_unregistered"]:
                break
            time.sleep(.25)
        Path(f"evidence/{stage}-menu-api.json").write_text(json.dumps(trace, indent=2))
        assert trace["sni_unregistered"], "Quit exited without unregistering original SNI"
    for _ in range(40):
        try:
            exited, _ = os.waitpid(pid, os.WNOHANG)
            if exited == pid:
                record_exit()
                return
        except ChildProcessError:
            pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            record_exit()
            return
        time.sleep(.25)
    raise RuntimeError("LocalSend's tray Quit action did not stop the application")


snapshot("accessibility")
try:
    try:
        click(find("Skip", "button"))
    except RuntimeError:
        pass
    click(find("Show hidden icons", "button"))
    snapshot("opened-tray-popup")
    click(find("Configure System Tray...", "button"))
    snapshot("configuration-general")
    click(find("Entries"))
    snapshot("configuration-entries")
    if os.environ.get("FULL_SCENARIO") == "1":
        click(find("Cancel", "button"))
        subprocess.run(["xdotool", "key", "Escape"], check=True)
        pid = int(os.environ["APP_PID"])
        expected_lost = os.environ.get("EXPECT_RETAINED") != "1"
        outcomes = []
        for cycle in range(1, 3):
            stage = f"{'baseline' if expected_lost else 'stable-id'}-cycle{cycle}"
            print(f"[3546] {stage} begin", flush=True)
            before = registered_item(pid)
            if cycle == 1 or expected_lost:
                assert panel_item() is not None, "Original tray item is not rendered in panel"
            else:
                assert panel_item() is None, "Intervention lost Hide before second cycle"
            prepare_hide(stage)
            quit_via_menu(pid, stage)
            app = Path(os.environ["APP_EXE"])
            with Path(f"evidence/{stage}-restart.log").open("w") as logfile:
                process = subprocess.Popen([str(app)], cwd=app.parent, stdout=logfile, stderr=subprocess.STDOUT)
            pid = process.pid
            after = registered_item(pid)
            time.sleep(3)
            subprocess.run(["xdotool", "search", "--name", "^LocalSend$", "windowminimize"], check=True)
            snapshot(stage + "-restarted-panel")
            outcomes.append({"before": before, "after": after, "preference_lost": panel_item() is not None})
            Path("evidence/outcomes.json").write_text(json.dumps(outcomes, indent=2))
            if panel_item() is not None:
                bounds = panel_item().queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                subprocess.run(["xdotool", "mousemove", str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2)], check=True)
                time.sleep(2)
                snapshot(stage + "-restarted-tooltip")
            click(find("Show hidden icons", "button"))
            click(find("Configure System Tray...", "button"))
            click(find("Entries"))
            snapshot(stage + "-restarted-entries")
            click(find("Cancel", "button"))
            subprocess.run(["xdotool", "key", "Escape"], check=True)
        Path("evidence/outcomes.json").write_text(json.dumps(outcomes, indent=2))
        assert all(case["preference_lost"] == expected_lost for case in outcomes), "Unexpected preference outcome"
        assert all((case["before"]["id"] != case["after"]["id"]) == expected_lost for case in outcomes), "Unexpected identity outcome"
except Exception:
    snapshot("ui-error")
    raise
