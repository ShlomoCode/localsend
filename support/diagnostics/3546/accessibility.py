#!/usr/bin/env python3
"""Record rendered Qt tray controls and their accessible screen bounds."""
import json
import subprocess
import time
import os
import shlex
import shutil
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


def prepare_visibility(stage, hidden=True):
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
    keys = ["End", "Return"] if hidden else ["Home", "Down", "Return"]
    subprocess.run(["xdotool", "key", *keys], check=True)
    time.sleep(.5)
    snapshot(stage + ("-selected-hidden" if hidden else "-selected-shown"))
    click(find("Apply", "button"))
    click(find("OK", "button"))
    subprocess.run(["xdotool", "key", "Escape"], check=True)
    time.sleep(2)
    snapshot(stage + ("-hidden-panel" if hidden else "-shown-panel"))
    assert (panel_item() is None) == hidden, "Visibility selection did not update the rendered panel"


def prepare_hide(stage):
    prepare_visibility(stage)


def visible_windows(pid):
    result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(pid), "--name", "^LocalSend$"], capture_output=True, text=True)
    return result.stdout.split()


def open_via_menu(pid, stage):
    item = registered_item(pid)
    service, path = item["address"].split("/", 1)
    bus = dbus.SessionBus()
    props = dbus.Interface(bus.get_object(service, "/" + path), "org.freedesktop.DBus.Properties")
    menu_path = str(props.Get("org.kde.StatusNotifierItem", "Menu"))
    menu = dbus.Interface(bus.get_object(service, menu_path), "com.canonical.dbusmenu")
    _, layout = menu.GetLayout(0, -1, dbus.Array([], signature="s"))
    leaves = []
    def collect(entry):
        entry_id, properties, children = entry
        if str(properties.get("label", "")) == "Open" and not children:
            leaves.append(int(entry_id))
        for child in children:
            collect(child)
    collect(layout)
    assert len(leaves) == 1, f"Expected one original Open leaf, got {leaves}"
    subprocess.run(["xdotool", "search", "--name", "^LocalSend$", "windowminimize"], check=True)
    time.sleep(1)
    assert not visible_windows(pid), "Target window remained visible before Open"
    menu.Event(dbus.Int32(leaves[0]), "clicked", dbus.Int32(0, variant_level=1), dbus.UInt32(0))
    time.sleep(2)
    windows = visible_windows(pid)
    Path(f"evidence/{stage}-open-api.json").write_text(json.dumps({"item": item, "menu_path": menu_path, "leaf": leaves[0], "visible_windows_after": windows}, indent=2))
    snapshot(stage + "-opened-window")
    assert windows, "Original Open callback did not reveal its application window"


def regression_controls(pid):
    app = Path(os.environ["APP_EXE"])
    before = registered_item(pid)
    prepare_visibility("control-always-shown", hidden=False)
    quit_via_menu(pid, "control-always-shown")
    with Path("evidence/control-always-shown-restart.log").open("w") as logfile:
        process = subprocess.Popen([str(app)], cwd=app.parent, stdout=logfile, stderr=subprocess.STDOUT)
    pid = process.pid
    after = registered_item(pid)
    time.sleep(3)
    snapshot("control-always-shown-restarted")
    assert panel_item() is not None, "Always shown was lost on restart"
    assert before["id"] == after["id"], "Always shown restart changed identity"
    click(find("Show hidden icons", "button"))
    click(find("Configure System Tray...", "button"))
    click(find("Entries"))
    snapshot("control-always-shown-restarted-entries")
    click(find("Cancel", "button"))
    subprocess.run(["xdotool", "key", "Escape"], check=True)
    open_via_menu(pid, "control-single")
    with Path("evidence/control-handoff.log").open("w") as logfile:
        second = subprocess.Popen([str(app)], cwd=app.parent, stdout=logfile, stderr=subprocess.STDOUT)
    exit_code = second.wait(timeout=20)
    assert exit_code == 0, f"Same-profile handoff exited {exit_code}"
    assert registered_item(pid)["address"] == after["address"], "Handoff replaced original tray"
    Path("evidence/control-handoff.json").write_text(json.dumps({"original": after, "second_pid": second.pid, "second_exit_code": exit_code}, indent=2))
    quit_via_menu(pid, "control-single")
    processes = []
    items = []
    for index in range(2):
        directory = Path(f"profile-{index + 1}")
        shutil.copytree(app.parent, directory)
        settings = {"flutter.ls_port": 53318 + index, "flutter.ls_alias": f"Tray control {index + 1}", "flutter.ls_locale": "en"}
        (directory / "settings.json").write_text(json.dumps(settings))
        executable = (directory / app.name).resolve()
        with Path(f"evidence/control-profile-{index + 1}.log").open("w") as logfile:
            process = subprocess.Popen([str(executable)], cwd=directory.resolve(), stdout=logfile, stderr=subprocess.STDOUT)
        processes.append(process)
        items.append(registered_item(process.pid))
        time.sleep(3)
        try:
            click(find("Skip", "button"))
        except RuntimeError:
            pass
    Path("evidence/control-two-profiles.json").write_text(json.dumps(items, indent=2))
    snapshot("control-two-profiles")
    assert items[0]["address"] != items[1]["address"], "Two processes shared a D-Bus tray registration"
    assert all(item["id"] == "org.localsend.localsend_app" for item in items), "Application identity changed across profiles"
    for index, process in enumerate(processes):
        open_via_menu(process.pid, f"control-profile-{index + 1}")
        other = processes[1 - index]
        assert not visible_windows(other.pid), "Open targeted the other profile's window"
    quit_via_menu(processes[0].pid, "control-profile-1")
    assert registered_item(processes[1].pid)["address"] == items[1]["address"], "Quitting first profile removed the second tray"
    open_via_menu(processes[1].pid, "control-surviving-profile")
    with Path("evidence/control-profile-1-restart.log").open("w") as logfile:
        directory = Path("profile-1").resolve()
        processes[0] = subprocess.Popen([str(directory / app.name)], cwd=directory, stdout=logfile, stderr=subprocess.STDOUT)
    restarted_first = registered_item(processes[0].pid)
    assert restarted_first["id"] == items[0]["id"], "First profile restart changed application identity"
    assert restarted_first["address"] != items[0]["address"], "First profile did not create a new live registration"
    open_via_menu(processes[0].pid, "control-profile-1-restarted")
    quit_via_menu(processes[1].pid, "control-profile-2")
    assert registered_item(processes[0].pid)["address"] == restarted_first["address"], "Quitting second profile removed restarted first tray"
    with Path("evidence/control-profile-2-restart.log").open("w") as logfile:
        directory = Path("profile-2").resolve()
        processes[1] = subprocess.Popen([str(directory / app.name)], cwd=directory, stdout=logfile, stderr=subprocess.STDOUT)
    restarted_second = registered_item(processes[1].pid)
    assert restarted_second["id"] == items[1]["id"], "Second profile restart changed application identity"
    assert restarted_second["address"] != items[1]["address"], "Second profile did not create a new live registration"
    open_via_menu(processes[1].pid, "control-profile-2-restarted")
    Path("evidence/control-two-profiles-restarted.json").write_text(json.dumps([restarted_first, restarted_second], indent=2))
    quit_via_menu(processes[0].pid, "control-profile-1-final")
    quit_via_menu(processes[1].pid, "control-profile-2-final")
    Path("evidence/control-result.json").write_text(json.dumps({"always_shown_retained": True, "same_profile_handoff": True, "two_independent_trays": True, "open_targets_owner": True, "quit_preserves_other": True}, indent=2))


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
        if os.environ.get("REGRESSION_CONTROLS") == "1":
            regression_controls(pid)
except Exception:
    snapshot("ui-error")
    raise
