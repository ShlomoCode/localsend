#!/usr/bin/env python3
"""Record rendered Qt tray controls and their accessible screen bounds."""
import json
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


Path("evidence/accessibility.json").write_text(json.dumps(describe(pyatspi.Registry.getDesktop(0)), indent=2))
