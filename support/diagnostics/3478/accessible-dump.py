#!/usr/bin/python3
"""Guest-only read-only observations; never focus windows or write clipboard data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from gi.repository import Gio, GLib

p = argparse.ArgumentParser()
p.add_argument('mode', choices=['tree', 'identity', 'point', 'window'])
p.add_argument('--pid', type=int, required=True)
p.add_argument('--label')
p.add_argument('--snapshot')
p.add_argument('--host', nargs=4, type=int, metavar=('X', 'Y', 'WIDTH', 'HEIGHT'))
a = p.parse_args()

def observed_window(snapshot):
    if snapshot['compositorWayland'] != {'value': True, 'error': None}:
        raise ValueError('Wayland compositor unavailable')
    if snapshot['shellVersion'] != '48.7':
        raise ValueError('Expected GNOME Shell 48.7')
    windows = [w for w in snapshot['windows'] if w['pid']['value'] == a.pid]
    if len(windows) != 1:
        raise ValueError('PID must own exactly one window')
    w = windows[0]
    if w['backend'] != {'value': {'enum': w['backend']['value']['enum'], 'name': 'wayland'}, 'error': None}:
        raise ValueError('Target is not native Wayland')
    if w['minimized']['value'] or not w['actorVisible']['value']:
        raise ValueError('Target header is not visible')
    return w

def identity():
    root = Path(f'/proc/{a.pid}')
    before = (root / 'stat').read_text()
    exe = os.readlink(root / 'exe')
    digest = hashlib.sha256((root / 'exe').read_bytes()).hexdigest()
    maps = (root / 'maps').read_text()
    libs = sorted({line.split()[-1] for line in maps.splitlines() if len(line.split()) >= 6 and '.so' in line.split()[-1]})
    hashes = {}
    for lib in libs:
        path = root / 'root' / lib.lstrip('/')
        if path.is_file():
            hashes[lib] = hashlib.sha256(path.read_bytes()).hexdigest()
    after = (root / 'stat').read_text()
    ticks = lambda s: s.rsplit(') ', 1)[1].split()[19]
    if ticks(before) != ticks(after) or os.readlink(root / 'exe') != exe:
        raise ValueError('Process identity changed')
    return dict(pid=a.pid, startTicks=ticks(before), exe=exe, exeSHA256=digest,
                maps=maps, librarySHA256=hashes, statBefore=before, statAfter=after,
                environment=(root / 'environ').read_bytes().decode().split('\0'))

def tree():
    import pyatspi
    desktop = pyatspi.Registry.getDesktop(0)
    apps = []
    for app in desktop:
        try:
            if app.get_process_id() == a.pid:
                apps.append(app)
        except Exception:
            continue
    if len(apps) != 1:
        raise ValueError('Missing or ambiguous AT-SPI app tree for actual PID')
    rows = []
    pending = [(apps[0], [])]
    while pending:
        node, route = pending.pop()
        if len(rows) >= 2000 or len(route) > 30:
            raise ValueError('AT-SPI traversal limit')
        row = dict(path=route, name=node.name, role=node.getRoleName())
        row['states'] = [str(v) for v in node.getState().getStates()]
        try:
            text = node.queryText()
            row['text'] = text.getText(0, text.characterCount)
        except NotImplementedError:
            pass
        try:
            e = node.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            row['bounds'] = dict(x=e.x, y=e.y, width=e.width, height=e.height, coordinateSpace='window')
        except NotImplementedError:
            pass
        rows.append(row)
        for index in reversed(range(node.childCount)):
            child = node.getChildAtIndex(index)
            if child is not None:
                pending.append((child, route + [index]))
    if len(rows) < 3:
        raise ValueError('AT-SPI tree lacks usable content')
    return dict(pid=a.pid, wallNs=time.time_ns(), nodes=rows)

def point():
    snapshot = json.loads(Path(a.snapshot).read_text())
    w = observed_window(snapshot)
    frame = w['frameStage']['value']
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    state = bus.call_sync('org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
        'org.gnome.Mutter.DisplayConfig', 'GetCurrentState', None, None,
        Gio.DBusCallFlags.NONE, 3000, None).unpack()
    _, physical, logical, _ = state
    if len(physical) != 1 or len(logical) != 1:
        raise ValueError('Require one actual physical/logical monitor')
    spec, modes, _ = physical[0]
    x, y, scale, transform, primary, specs, _ = logical[0]
    modes = [m for m in modes if m[6].get('is-current', False)]
    if len(modes) != 1 or (x, y, scale, transform, primary) != (0, 0, 1.0, 0, True) or list(specs) != [spec]:
        raise ValueError('Actual monitor mapping is not origin0 scale1 transform0')
    hx, hy, hw, hh = a.host
    width, height = modes[0][1:3]
    if (hw, hh) != (width, height) or snapshot['stageSize'] != {'width': width, 'height': height}:
        raise ValueError('QEMU client and actual guest mode are not pixel-for-pixel')
    if frame['width'] < 150 or frame['height'] < 60:
        raise ValueError('Target frame too small')
    # Native frame's header strip, away from window buttons. No guessed screen coordinates.
    gx, gy = frame['x'] + frame['width'] // 2, frame['y'] + 12
    if a.label:
        rows = tree()['nodes']
        candidates = [r for r in rows if r['name'] == a.label and r['role'] in ('push button', 'page tab', 'radio button') and 'bounds' in r]
        if len(candidates) != 1:
            raise ValueError('Visible semantic control is absent or ambiguous: ' + a.label)
        b = candidates[0]['bounds']
        if b['width'] <= 0 or b['height'] <= 0:
            raise ValueError('Control has invalid observed bounds')
        origin = w['atspiWindowOriginStage']
        if origin['error'] is not None or not origin['value']:
            raise ValueError('Observed native client origin is unavailable')
        gx = origin['value']['x'] + b['x'] + b['width'] // 2
        gy = origin['value']['y'] + b['y'] + b['height'] // 2
    if not (0 <= gx < width and 0 <= gy < height and frame['x'] <= gx < frame['x'] + frame['width'] and frame['y'] <= gy < frame['y'] + frame['height']):
        raise ValueError('Input coordinate outside verified frame/monitor')
    return dict(hostPoint=[hx + gx, hy + gy], guestPoint=[gx, gy], monitorState=state, window=w, hostClient=a.host)

try:
    if a.mode == 'identity':
        result = identity()
    elif a.mode == 'tree':
        result = tree()
    elif a.mode == 'point':
        result = point()
    else:
        result = observed_window(json.loads(Path(a.snapshot).read_text()))
    print(json.dumps(result, sort_keys=True), flush=True)
except Exception as error:
    print(json.dumps(dict(error=str(error), pid=a.pid, mode=a.mode)), flush=True)
    sys.exit(2)
