from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

out = Path('evidence')

def adb(*args, raw=False):
    print('ANDROID INPUT', args, flush=True)
    return subprocess.check_output(['adb', *args], text=not raw)

def snapshot(name):
    adb('shell', 'uiautomator', 'dump', '/sdcard/issue-2007-ui.xml')
    xml = adb('exec-out', 'cat', '/sdcard/issue-2007-ui.xml')
    (out / (name + '.xml')).write_text(xml)
    (out / (name + '.png')).write_bytes(adb('exec-out', 'screencap', '-p', raw=True))
    return ET.fromstring(xml)

def label(node):
    return node.get('text') or node.get('content-desc') or ''

def point(node):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
    return ((x1 + x2) // 2, (y1 + y2) // 2)

def tap_label(prefix, name, long=False):
    root = snapshot(name + '-before')
    nodes = [n for n in root.iter('node') if label(n).startswith(prefix)]
    if not nodes:
        raise RuntimeError('Android visible UI label absent: ' + prefix)
    x, y = point(nodes[0])
    if long:
        adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '1000')
    else:
        adb('shell', 'input', 'tap', str(x), str(y))
    time.sleep(1)
    snapshot(name + '-after')

def approve(stage):
    for attempt in range(8):
        root = snapshot(stage + '-approval-' + str(attempt))
        labels = [label(n) for n in root.iter('node')]
        for choice in ['Accept', 'Allow', 'ALLOW', 'While using the app']:
            if any(s == choice or s.startswith(choice + '\n') for s in labels):
                tap_label(choice, stage + '-tap-' + str(attempt))
                break
        else:
            if any('Finished' in s or 'Success' in s for s in labels):
                return
        time.sleep(1)
