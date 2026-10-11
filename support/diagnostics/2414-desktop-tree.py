import pyatspi

def walk(node, depth=0):
    if depth > 14:
        return
    try:
        bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
    except Exception:
        bounds = None
    print('  ' * depth, node.getRoleName(), repr(node.name), bounds)
    for child in node:
        walk(child, depth + 1)

walk(pyatspi.Registry.getDesktop(0))
