"""Cloud-only observation and qualified Nautilus accessibility actions."""
import json
import sys
import pyatspi

# Read installed application metadata, without launching an application.
if len(sys.argv) > 1 and sys.argv[1] == "appnames":
    from gi.repository import Gio
    print(json.dumps(sorted({app.get_name() for app in Gio.AppInfo.get_all()
                             if app.should_show()})))
    sys.exit(0)

visited = []
ready_states = (pyatspi.STATE_SHOWING, pyatspi.STATE_VISIBLE,
                pyatspi.STATE_ENABLED, pyatspi.STATE_SENSITIVE)

def walk(node, ancestors=()):
    if len(ancestors) > 16 or len(visited) >= 12000:
        return
    try:
        role = node.getRoleName()
        path = ancestors + ((node.name, role),)
        state = node.getState()
        item = {"name": node.name, "role": role, "path": path,
                "ready": all(state.contains(value) for value in ready_states),
                "selected": state.contains(pyatspi.STATE_SELECTED),
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
            walk(child, path)
    except Exception:
        pass

walk(pyatspi.Registry.getDesktop(0))
mode = sys.argv[1] if len(sys.argv) > 1 else "dump"
if mode == "dump":
    print(json.dumps([item for _, item in visited], indent=2))
    sys.exit(0)

if mode == "desktop":
    # Ordinary first-login prompts observed in the original V7 evidence.
    # Defer updates using their own controls; never activate an upgrade/reboot.
    prompts = (("update-manager", "Software Updater", "Restart Later"),
               ("check-new-release-gtk", "Ubuntu 26.04.1 LTS Upgrade Available", "Ask Me Later"))
    for app, frame, button in prompts:
        def in_prompt(item):
            return ((app, "application") in item["path"] and
                    (frame, "frame") in item["path"])
        frames = [item for _, item in visited if in_prompt(item) and item["role"] == "frame"]
        windows = [item for item in frames if item["ready"]]
        print(json.dumps({"prompt": frame, "matching_frames": len(frames),
                          "ready_frames": len(windows)}), flush=True)
        if not windows:
            continue
        targets = [(node, item) for node, item in visited if in_prompt(item)
                   and item["name"] == button and item["role"] == "push button"
                   and item["ready"] and "click" in item["actions"]]
        if len(windows) != 1 or len(targets) != 1:
            print("DESKTOP_PROMPT_TARGET_NOT_UNIQUE_OR_READY", flush=True)
            sys.exit(2)
        node, item = targets[0]
        print(json.dumps({"target": item, "action": "click"}), flush=True)
        if not node.queryAction().doAction(item["actions"].index("click")):
            print("DESKTOP_PROMPT_DISMISS_FAILED", flush=True)
            sys.exit(2)
    sys.exit(0)

def qualified(item):
    applications = [name.lower() for name, role in item["path"] if role == "application"]
    native = any(name in ("nautilus", "org.gnome.nautilus", "files") for name in applications)
    dialogs = [name for name, role in item["path"] if role == "dialog"]
    chooser = "Open File" in dialogs
    if not native or not item["ready"]:
        return False
    if mode == "menu":
        return item["role"] in ("menu item", "push button") and any(
            role in ("menu", "popup menu", "popover") for _, role in item["path"])
    return chooser

names = sys.argv[2:]
matches = [(node, item) for node, item in visited if item["name"] in names and qualified(item)]
if mode == "bounds":
    dialogs = [item for _, item in visited if item["role"] == "dialog"
               and item["name"] == "Open File" and qualified(item)]
    if len(dialogs) == 1 and dialogs[0]["bounds"] is not None:
        print(json.dumps(dialogs[0]["bounds"]))
        sys.exit(0)
elif mode == "button":
    buttons = [item for _, item in matches if item["role"] == "push button"]
    if len(buttons) == 1:
        print(json.dumps(buttons[0]))
        print("QUALIFIED_NAUTILUS_OPEN_BUTTON_READY")
        sys.exit(0)
elif mode == "dialog":
    if any(qualified(item) for _, item in visited):
        print("QUALIFIED_NAUTILUS_CHOOSER_PRESENT")
        sys.exit(0)
else:
    # Focus alone never counts as activation. Record the named toolkit action
    # and native ancestry before invoking the application's actual control.
    for node, item in matches:
        for index, name in enumerate(item["actions"]):
            if name.lower() not in ("click", "activate", "select", "press"):
                continue
            print(json.dumps({"target": item, "action": name}), flush=True)
            if node.queryAction().doAction(index):
                print("QUALIFIED_ACCESSIBILITY_ACTION_PASS", flush=True)
                sys.exit(0)
print(json.dumps([item for _, item in visited], indent=2))
print("QUALIFIED_NATIVE_ACTION_OR_STATE_NOT_FOUND")
sys.exit(2)
