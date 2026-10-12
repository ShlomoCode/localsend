"""Cloud-only observation and qualified Nautilus accessibility actions."""
import json
import sys
import pyatspi

discovery_fields = ("XDG_DATA_DIRS", "XDG_DATA_HOME", "XDG_CURRENT_DESKTOP")

def manager_discovery_environment():
    import subprocess
    values = {}
    for line in subprocess.check_output(["systemctl", "--user", "show-environment"], timeout=5, text=True).splitlines():
        key, separator, value = line.partition("=")
        if separator and key in discovery_fields:
            values[key] = value
    return {key: values.get(key) for key in discovery_fields}

def discovery_environment():
    import os
    from gi.repository import Gio, GLib
    manager = manager_discovery_environment()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    def primary_pid(name="org.gnome.Nautilus"):
        return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                             "GetConnectionUnixProcessID", GLib.Variant("(s)", (name,)),
                             GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
    owner_pid = primary_pid()
    file_manager_pid = primary_pid("org.freedesktop.FileManager1")
    with open(f"/proc/{owner_pid}/environ", "rb") as source:
        values = dict(value.split(b"=", 1) for value in source.read().split(b"\0") if b"=" in value)
    with open(f"/proc/{owner_pid}/stat") as source:
        stat = source.read()
    actual = {key: values.get(key.encode(), b"").decode() or None for key in discovery_fields}
    start_time = stat.rsplit(")", 1)[1].split()[19]
    result = {"caller": {key: os.environ.get(key) for key in discovery_fields}, "manager": manager,
              "primary": {"pid": owner_pid, "file_manager_pid": file_manager_pid, "stat": stat,
                          "start_time": start_time, "uid": os.stat(f"/proc/{owner_pid}").st_uid,
                          "exe": os.readlink(f"/proc/{owner_pid}/exe"), "environment": actual}}
    print(json.dumps(result), flush=True)
    with open(f"/proc/{owner_pid}/stat") as source:
        current_start = source.read().rsplit(")", 1)[1].split()[19]
    if (actual != manager or result["primary"]["exe"] != "/usr/bin/nautilus"
            or result["primary"]["uid"] != os.getuid() or current_start != start_time
            or primary_pid() != owner_pid or file_manager_pid != owner_pid):
        raise RuntimeError("Actual Nautilus primary does not inherit the admitted discovery environment")
    return result

if len(sys.argv) > 1 and sys.argv[1] == "discovery":
    discovery_environment()
    sys.exit(0)

# Read installed application metadata, without launching an application.
if len(sys.argv) > 1 and sys.argv[1] == "appnames":
    import hashlib
    import os
    from gi.repository import Gio
    apps = Gio.AppInfo.get_all()
    targets = [app for app in apps if app.get_id() == "org.localsend.localsend_app.desktop"]
    if len(targets) != 1 or not targets[0].should_show() or targets[0].get_name() != "LocalSend":
        raise RuntimeError("Official LocalSend desktop ID is not uniquely visible in the session metadata")
    exported = "/var/lib/flatpak/exports/share/applications/org.localsend.localsend_app.desktop"
    if os.path.realpath(targets[0].get_filename()) != os.path.realpath(exported):
        raise RuntimeError("Discovered LocalSend metadata does not identify the installed system export")
    with open(exported, "rb") as source:
        payload = source.read()
    with open("/home/probe/3417-provenance/exported-desktop-entry.txt", "rb") as source:
        if source.read() != payload:
            raise RuntimeError("System-exported desktop entry differs from the qualified deployment export")
    environment = {key: os.environ.get(key) for key in discovery_fields}
    if environment != manager_discovery_environment():
        raise RuntimeError("Metadata service does not inherit admitted manager discovery fields")
    receipt = {"environment": environment,
               "desktop_id": targets[0].get_id(), "name": targets[0].get_name(),
               "filename": targets[0].get_filename(), "should_show": targets[0].should_show(),
               "exported_path": exported, "sha256": hashlib.sha256(payload).hexdigest(),
               "exported_desktop_entry": payload.decode()}
    with open("/home/probe/3417-metadata-discovery.json", "w") as target:
        json.dump(receipt, target)
    print(json.dumps(sorted({app.get_name() for app in apps if app.should_show()})))
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
                "states": {"showing": state.contains(pyatspi.STATE_SHOWING),
                           "visible": state.contains(pyatspi.STATE_VISIBLE),
                           "enabled": state.contains(pyatspi.STATE_ENABLED),
                           "sensitive": state.contains(pyatspi.STATE_SENSITIVE)},
                "selected": state.contains(pyatspi.STATE_SELECTED),
                "actions": [], "bounds": None, "window_bounds": None}
        try:
            action = node.queryAction()
            item["actions"] = [action.getName(i) for i in range(action.nActions)]
        except Exception:
            pass
        try:
            item["bounds"] = list(node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS))
            # Query extra local geometry only for the exact chooser anchors.
            if (("org.gnome.Nautilus", "application") in path
                    and ("Open File", "dialog") in path
                    and (role == "dialog" or role == "label" and node.name in
                         ("Open File", "Cancel", "Choose an app to open 3417-control.txt", "Always use for this file type"))):
                item["window_bounds"] = list(node.queryComponent().getExtents(pyatspi.WINDOW_COORDS))
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

if mode == "file-menu-command":
    # GTK4 omits the rendered context-menu items from this backend, but the
    # selected Files view exposes its own named Open With command as an action.
    command = "view.open-with-other-application"
    targets = [(node, item) for node, item in visited
               if ("org.gnome.Nautilus", "application") in item["path"]
               and item["role"] == "frame" and item["name"] == "Documents"
               and command in item["actions"]]
    if len(targets) == 1:
        node, item = targets[0]
        action = node.queryAction()
        # GTK rebuilds the enabled-action list on each request. Refresh names
        # on this exact node immediately before dispatching the selected index.
        names = [action.getName(i) for i in range(action.nActions)]
        print(json.dumps({"target": item, "fresh_actions": names, "action": command}), flush=True)
        if names.count(command) == 1:
            index = names.index(command)
            print(json.dumps({"action_index": index}), flush=True)
            if action.doAction(index):
                print("NATIVE_OPEN_WITH_COMMAND_ACCEPTED_REVIEW_CHOOSER", flush=True)
                sys.exit(0)
    print("NATIVE_OPEN_WITH_COMMAND_NOT_UNIQUE_OR_ACCEPTED", flush=True)
    sys.exit(2)

def qualified(item):
    applications = [name.lower() for name, role in item["path"] if role == "application"]
    native = any(name in ("nautilus", "org.gnome.nautilus", "files") for name in applications)
    dialogs = [name for name, role in item["path"] if role == "dialog"]
    chooser = "Open File" in dialogs
    # GTK4's supported AT-SPI state collection does not emit ENABLED.
    # Preserve the original aggregate while checking its actual native flags.
    required = ("showing", "visible") if mode in ("bounds", "dialog") else ("showing", "visible", "sensitive")
    gtk_ready = all(item["states"][key] for key in required)
    if not native or not (item["ready"] if mode == "menu" else gtk_ready):
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
        anchors = [item for _, item in visited if qualified(item)
                   and item["role"] == "label" and item["name"] in
                   ("Open File", "Cancel", "Choose an app to open 3417-control.txt")]
        footers = [item for _, item in visited if qualified(item)
                   and item["role"] == "label" and item["name"] == "Always use for this file type"]
        if len(anchors) == 3 and len({item["name"] for item in anchors}) == 3 and len(footers) == 1:
            print(json.dumps({"dialog": dialogs[0], "anchors": anchors, "footer": footers[0]}))
            sys.exit(0)
elif mode == "button":
    buttons = [item for _, item in matches if item["role"] == "push button"]
    if len(buttons) == 1:
        print(json.dumps(buttons[0]))
        print("QUALIFIED_NAUTILUS_OPEN_BUTTON_READY")
        sys.exit(0)
elif mode == "dialog":
    dialogs = [item for _, item in visited if item["role"] == "dialog"
               and item["name"] == "Open File" and qualified(item)]
    if len(dialogs) == 1:
        print(json.dumps(dialogs[0]))
        print("QUALIFIED_NAUTILUS_CHOOSER_PRESENT")
        sys.exit(0)
else:
    # Focus alone never counts as activation. Record the named toolkit action
    # and native ancestry before invoking the application's actual control.
    buttons = [(node, item) for node, item in matches if item["role"] == "push button"]
    if len(buttons) == 1:
        node, item = buttons[0]
        action = node.queryAction()
        fresh = [action.getName(i) for i in range(action.nActions)]
        if fresh.count("click") == 1:
            index = fresh.index("click")
            print(json.dumps({"target": item, "fresh_actions": fresh, "action_index": index}), flush=True)
            if action.doAction(index):
                print("QUALIFIED_ACCESSIBILITY_ACTION_PASS", flush=True)
                sys.exit(0)
print(json.dumps([item for _, item in visited], indent=2))
print("QUALIFIED_NATIVE_ACTION_OR_STATE_NOT_FOUND")
sys.exit(2)
