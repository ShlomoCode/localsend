# Operate the real Flutter settings through Linux accessibility actions, without screen coordinates.

import argparse
import json
import time

import pyatspi


def nodes(root):
    yield root
    for index in range(root.childCount):
        yield from nodes(root[index])


def app_nodes():
    desktop = pyatspi.Registry.getDesktop(0)
    for app in desktop:
        if "localsend" in app.name.lower():
            return list(nodes(app))
    return []


def tap(node):
    action = node.queryAction()
    for index in range(action.nActions):
        if action.getName(index).lower() in ("tap", "click", "activate", "press"):
            assert action.doAction(index), f"Cannot activate {node.name!r}"
            return
    raise AssertionError(f"No activation action for {node.name!r}")


def wait_for(predicate, description):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        found = predicate(app_nodes())
        if found is not None:
            return found
        time.sleep(0.2)
    raise AssertionError(f"Cannot find {description} in accessibility tree: " + json.dumps(
        [{"name": node.name, "role": node.getRoleName()} for node in app_nodes()], ensure_ascii=False))


def switch_for(items, label):
    matches = [node for node in items if node.name == label
               and node.getState().contains(pyatspi.STATE_CHECKABLE)]
    assert len(matches) <= 1, f"Multiple accessible switches named {label!r}"
    return matches[0] if matches else None


def set_switch(label, enabled):
    control = wait_for(lambda items: switch_for(items, label), label)
    if control.getState().contains(pyatspi.STATE_CHECKED) != enabled:
        tap(control)
    wait_for(lambda items: True if (switch_for(items, label) is not None and
             switch_for(items, label).getState().contains(pyatspi.STATE_CHECKED) == enabled) else None,
             f"{label} = {enabled}")


def actionable(node):
    try:
        return node.queryAction().nActions > 0
    except NotImplementedError:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["enable", "enable-hidden", "disable", "dump"])
    args = parser.parse_args()
    if args.action == "dump":
        print(json.dumps([{"name": node.name, "role": node.getRoleName()} for node in app_nodes()], indent=2))
        return
    settings = wait_for(lambda items: next((node for node in items if node.name.startswith("Settings")
                        and actionable(node)), None), "Settings navigation")
    tap(settings)
    set_switch("Autostart after login", args.action != "disable")
    if args.action != "disable":
        set_switch("Autostart: Start hidden", args.action == "enable-hidden")


if __name__ == "__main__":
    main()
