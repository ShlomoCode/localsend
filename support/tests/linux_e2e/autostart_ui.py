# Operate LocalSend's real Flutter settings through Linux accessibility actions.

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
        candidates = [app for app in desktop if "localsend" in (app.name or "").lower()]
        owned = [app for app in candidates if process_id(app) == pid]
        if owned:
            candidates = owned
        elif any(process_id(app) is not None for app in candidates):
            return []
        assert len(candidates) <= 1, (
            "Multiple LocalSend accessibility applications and no usable PID: "
            f"{candidates}"
        )
        return list(nodes(candidates[0])) if candidates else []
    except (IndexError, RuntimeError):
        # Flutter can replace semantics children while a settings update is rendered.
        return []


def process_id(app):
    for method in ("get_process_id", "getProcessId"):
        getter = getattr(app, method, None)
        if callable(getter):
            try:
                return int(getter())
            except (NotImplementedError, TypeError, ValueError):
                pass
    return None


def actionable(node):
    try:
        return node.queryAction().nActions > 0
    except NotImplementedError:
        return False


def tap(node):
    action = node.queryAction()
    for index in range(action.nActions):
        if action.getName(index).lower() in ("tap", "click", "activate", "press"):
            assert action.doAction(index), f"Cannot activate {node.name!r}"
            return
    raise AssertionError(f"No activation action for {node.name!r}")


def wait_for(pid, predicate, description, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        items = app_nodes(pid)
        found = predicate(items)
        if found is not None:
            return found
        time.sleep(0.2)
    raise AssertionError(
        f"Cannot find {description} in LocalSend PID {pid} accessibility tree: "
        + json.dumps(
            [
                {"name": node.name, "role": node.getRoleName()}
                for node in app_nodes(pid)
            ],
            ensure_ascii=False,
        )
    )


def _rect(node):
    try:
        bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
    except NotImplementedError:
        return None
    if bounds.width <= 0 or bounds.height <= 0:
        return None
    return bounds


def switch_for(items, label):
    named = [
        node
        for node in items
        if node.name == label and node.getState().contains(pyatspi.STATE_CHECKABLE)
    ]
    assert len(named) <= 1, f"Multiple accessible switches named {label!r}"
    if named:
        return named[0]

    labels = [node for node in items if node.name == label and _rect(node) is not None]
    switches = [
        node
        for node in items
        if node.getState().contains(pyatspi.STATE_CHECKABLE) and _rect(node) is not None
    ]
    candidates = []
    for text in labels:
        text_bounds = _rect(text)
        for control in switches:
            control_bounds = _rect(control)
            vertical_overlap = min(
                text_bounds.y + text_bounds.height,
                control_bounds.y + control_bounds.height,
            ) - max(text_bounds.y, control_bounds.y)
            if (
                vertical_overlap <= 0
                or control_bounds.x < text_bounds.x + text_bounds.width
            ):
                continue
            candidates.append(
                (
                    control_bounds.x - text_bounds.x,
                    abs(control_bounds.y - text_bounds.y),
                    control,
                )
            )
    candidates.sort(key=lambda item: item[:2])
    return candidates[0][2] if candidates else None


def open_settings(pid):
    settings = wait_for(
        pid,
        lambda items: next(
            (
                node
                for node in items
                if (node.name or "").startswith("Settings") and actionable(node)
            ),
            None,
        ),
        "Settings navigation",
    )
    tap(settings)


def set_switch(pid, label, enabled):
    control = wait_for(pid, lambda items: switch_for(items, label), label)
    if control.getState().contains(pyatspi.STATE_CHECKED) != enabled:
        tap(control)
    wait_for(
        pid,
        lambda items: (
            True
            if (
                switch_for(items, label) is not None
                and switch_for(items, label).getState().contains(pyatspi.STATE_CHECKED)
                == enabled
            )
            else None
        ),
        f"{label} = {enabled}",
    )
