#!/usr/bin/env python3
"""Record rendered Qt tray controls and their accessible screen bounds."""
import json
import subprocess
import time
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
    for child in node:
        yield from walk(child)


def find(name, role=None):
    for _ in range(20):
        for node in walk(pyatspi.Registry.getDesktop(0)):
            if node.name == name and (role is None or node.getRoleName() == role):
                try:
                    bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                    if bounds.width > 0 and bounds.height > 0:
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


snapshot("accessibility")
try:
    click(find("Configure System Tray...", "button"))
    snapshot("configuration-general")
    click(find("Entries"))
    snapshot("configuration-entries")
except Exception:
    snapshot("ui-error")
    raise
