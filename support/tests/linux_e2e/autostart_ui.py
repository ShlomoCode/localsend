# Operate LocalSend's real Settings controls through AT-SPI, without screen coordinates.

import argparse
import json
import time

import pyatspi


def nodes(root):
    yield root
    for index in range(root.childCount):
        yield from nodes(root[index])


def app_nodes(pid):
    desktop = pyatspi.Registry.getDesktop(0)
    try:
        owned = [app for app in desktop if "localsend" in app.name.lower() and app.get_process_id() == pid]
        assert len(owned) <= 1, f"Multiple LocalSend accessibility applications belong to PID {pid}: {owned}"
        return list(nodes(owned[0])) if owned else []
    except (IndexError, RuntimeError):
        # Flutter can replace children while a snapshot is being read.
        return []


def tree(items):
    return [{"name": node.name, "role": node.getRoleName()} for node in items]


def tap(node):
    action = node.queryAction()
    for index in range(action.nActions):
        if action.getName(index).lower() in ("tap", "click", "activate", "press"):
            assert action.doAction(index), f"Cannot activate {node.name!r}"
            return
    raise AssertionError(f"No activation action for {node.name!r}")


def wait_for(pid, predicate, description):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        found = predicate(app_nodes(pid))
        if found is not None:
            return found
        time.sleep(0.2)
    raise AssertionError(f"Cannot find {description} in LocalSend PID {pid} accessibility tree: " +
                         json.dumps(tree(app_nodes(pid)), ensure_ascii=False))


def switch_for(items, label):
    matches = [node for node in items if node.name == label and node.getState().contains(pyatspi.STATE_CHECKABLE)]
    assert len(matches) <= 1, f"Multiple accessible switches named {label!r}"
    return matches[0] if matches else None


def switch_checked(pid, label):
    control = wait_for(pid, lambda items: switch_for(items, label), label)
    return control.getState().contains(pyatspi.STATE_CHECKED)


def set_switch(pid, label, enabled):
    control = wait_for(pid, lambda items: switch_for(items, label), label)
    if control.getState().contains(pyatspi.STATE_CHECKED) != enabled:
        tap(control)
    wait_for(pid, lambda items: True if (switch_for(items, label) is not None and
             switch_for(items, label).getState().contains(pyatspi.STATE_CHECKED) == enabled) else None,
             f"{label} = {enabled}")


def actionable(node):
    try:
        return node.queryAction().nActions > 0
    except NotImplementedError:
        return False


def settings(pid):
    navigation = wait_for(pid, lambda items: next((node for node in items if node.name.startswith("Settings")
                          and actionable(node)), None), "Settings navigation")
    tap(navigation)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["enable", "enable-hidden", "disable", "state", "dump"])
    parser.add_argument("--pid", required=True, type=int)
    args = parser.parse_args()
    if args.action == "dump":
        print(json.dumps(tree(app_nodes(args.pid)), indent=2))
        return
    settings(args.pid)
    if args.action == "state":
        print(json.dumps({"autostart": switch_checked(args.pid, "Autostart after login")}))
        return
    set_switch(args.pid, "Autostart after login", args.action != "disable")
    if args.action != "disable":
        set_switch(args.pid, "Autostart: Start hidden", args.action == "enable-hidden")
    print(json.dumps({"autostart": switch_checked(args.pid, "Autostart after login")}))


if __name__ == "__main__":
    main()
