"""Cloud-only observation and actual GNOME accessibility actions."""
import json
import sys
import pyatspi

visited = []

def walk(node, depth=0):
    if depth > 16 or len(visited) > 12000:
        return
    try:
        item = {"name": node.name, "role": node.getRoleName(), "depth": depth,
                "actions": [], "bounds": None}
        try:
            action = node.queryAction()
            item["actions"] = [action.getName(i) for i in range(action.nActions)]
        except Exception:
            pass
        try:
            item["bounds"] = list(node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS))
        except Exception:
            pass
        visited.append((node, item))
        for child in node:
            walk(child, depth + 1)
    except Exception:
        pass

walk(pyatspi.Registry.getDesktop(0))
if len(sys.argv) == 1:
    print(json.dumps([item for _, item in visited], indent=2))
    sys.exit(0)

names = sys.argv[1:]
for name in names:
    matches = [(node, item) for node, item in visited if item["name"] == name]
    for node, item in matches:
        print(json.dumps(item), flush=True)
        try:
            action = node.queryAction()
            if action.nActions and action.doAction(0):
                print("ACCESSIBILITY_ACTION_PASS", flush=True)
                sys.exit(0)
        except Exception:
            pass
        try:
            if node.queryComponent().grabFocus():
                print("ACCESSIBILITY_FOCUS_PASS", flush=True)
                sys.exit(0)
        except Exception:
            pass
print(json.dumps([item for _, item in visited], indent=2))
sys.exit(2)
