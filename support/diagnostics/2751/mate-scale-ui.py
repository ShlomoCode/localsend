"""Activate the real MATE Display Preferences radio button through AT-SPI."""
import sys
import time

import pyatspi

target = sys.argv[1] + "%"
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    pending = [pyatspi.Registry.getDesktop(0)]
    seen = []
    while pending:
        node = pending.pop()
        try:
            name = node.name
            role = node.getRoleName()
            if name:
                seen.append((name, role))
            if name == target and role == "radio button":
                action = node.queryAction()
                assert action.nActions > 0, (name, role)
                print("Activating UI control", name, role, action.getName(0), flush=True)
                assert action.doAction(0), "AT-SPI activation failed"
                sys.exit(0)
            pending.extend(node)
        except (RuntimeError, AttributeError):
            continue
    time.sleep(1)
print("Accessible controls:", seen, flush=True)
raise RuntimeError("MATE Display Preferences radio button not found: " + target)
