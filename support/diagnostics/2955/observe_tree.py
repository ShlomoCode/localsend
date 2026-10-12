"""Cloud-only independent native observation; parent enforces a 20s deadline."""
import json
from pathlib import Path
import sys

import pyatspi

output = Path(sys.argv[1])
rows = []


def persist():
    temporary = output.with_suffix('.partial')
    temporary.write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    temporary.replace(output)


def visit(node, path, depth=0):
    if depth > 30 or len(rows) >= 2000:
        return
    row = {'path': path}
    rows.append(row)
    # Record each operation independently; an unsupported parent component
    # must not hide its children. No SHOWING or ENABLED filter is applied.
    for key, fn in {
        'name': lambda: node.name,
        'role': node.getRoleName,
        'states': lambda: [int(value) for value in node.getState().getStates()],
        'bounds': lambda: list(node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)),
        'child_count': lambda: node.childCount,
    }.items():
        persist()
        try:
            row[key] = fn()
        except Exception as error:
            row[key + '_error'] = repr(error)
    persist()
    try:
        for index, child in enumerate(node):
            visit(child, path + [index], depth+1)
    except Exception as error:
        row['traversal_error'] = repr(error)
        persist()


persist()
visit(pyatspi.Registry.getDesktop(0), [])
persist()
