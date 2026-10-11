#!/usr/bin/env python3
"""Record rendered Qt tray controls and their accessible screen bounds."""
import json
import subprocess
import time
import os
import shlex
from pathlib import Path
import pyatspi


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
            if node.name == name and (role is None or node.getRoleName() == role):
                try:
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
        if node.getRoleName() == "combo box" and node.getState().contains(pyatspi.STATE_SHOWING):
            bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
            if abs(bounds.y - row.y) < 20:
                candidates.append(node)
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
    # Ctrl+Q is LocalSend's supported Linux Quit shortcut in the original release.
    subprocess.run(["xdotool", "search", "--name", "^LocalSend$", "windowactivate", "--sync"], check=True)
    time.sleep(.5)
    snapshot(stage + "-quit-shortcut-before")
    active = subprocess.check_output(["xdotool", "getwindowfocus", "getwindowname"], text=True).strip()
    assert active == "LocalSend", f"Quit shortcut focus is {active!r}"
    # Activate a Flutter control as well as its native top-level window.
    subprocess.run(["xdotool", "mousemove", "294", "229", "click", "1"], check=True)
    time.sleep(.5)
    subprocess.run(["xdotool", "key", "--clearmodifiers", "ctrl+q"], check=True)
    for _ in range(40):
        try:
            exited, _ = os.waitpid(pid, os.WNOHANG)
            if exited == pid:
                return
        except ChildProcessError:
            pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(.25)
    raise RuntimeError("LocalSend's Ctrl+Q Quit shortcut did not stop the application")


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
        outcomes = []
        for cycle in range(1, 3):
            stage = f"baseline-cycle{cycle}"
            before = registered_item(pid)
            assert panel_item() is not None, "Original tray item is not rendered in panel"
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
        Path("evidence/outcomes.json").write_text(json.dumps(outcomes, indent=2))
        assert all(case["preference_lost"] for case in outcomes), "Baseline did not reproduce in both restart cycles"
except Exception:
    snapshot("ui-error")
    raise
