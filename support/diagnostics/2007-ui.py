import csv
import io
import os
from pathlib import Path
import subprocess
import time

out = Path('evidence')

def run(*args):
    print('INPUT', args, flush=True)
    return subprocess.check_output(args, text=True)

def screen(name):
    path = out / (name + '.png')
    run('scrot', str(path))
    tsv = run('tesseract', str(path), 'stdout', '--psm', '11', 'tsv')
    (out / (name + '.tsv')).write_text(tsv)
    return list(csv.DictReader(io.StringIO(tsv), delimiter='\t'))

def text(name, stage, scroll=False):
    for attempt in range(12 if scroll else 1):
        words = screen(stage + '-' + str(attempt))
        matches = [w for w in words if w['text'].strip() == name]
        if matches:
            w = matches[0]
            return (int(w['left']) + int(w['width']) // 2,
                    int(w['top']) + int(w['height']) // 2)
        if scroll:
            run('xdotool', 'mousemove', '850', '500', 'click', '--repeat', '3', '--delay', '120', '5')
            time.sleep(0.8)
    raise RuntimeError('Visible UI text missing: ' + name)

def click(x, y):
    run('xdotool', 'mousemove', str(x), str(y), 'click', '1')
    time.sleep(1)

click(*text('Settings', 'settings-button'))
_, row_y = text('Server', 'server-row', scroll=True)
# The observed SettingsEntry places two controls in a 150 px child at the
# right edge. Retain the tooltip screenshot to verify which control is used.
run('xdotool', 'mousemove', '925', str(row_y))
time.sleep(1)
screen('server-stop-tooltip')
click(925, row_y)
screen('server-stopped')
if os.environ.get('PHYSICAL_2007'):
    (out / 'desktop-stopped').touch()
    deadline = time.monotonic() + 60
    while not (out / 'transport-ready').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Physical transport readiness timeout')
        time.sleep(0.5)
else:
    run('adb', 'forward', 'tcp:53317', 'tcp:53317')
click(*text('Send', 'send-button'))
screen('send-visible')
click(*text('File', 'file-button'))
screen('file-picker-visible')
fixture = Path('/tmp/issue-2007/A.txt')
fixture.parent.mkdir(exist_ok=True)
fixture.write_text('LocalSend issue 2007 original app control v1\n')
run('xdotool', 'key', 'ctrl+l')
run('xdotool', 'type', '--clearmodifiers', str(fixture))
run('xdotool', 'key', 'Return')
time.sleep(2)
words = screen('file-selected')
if not any(w['text'].strip().startswith('Files:') for w in words):
    raise RuntimeError('Actual file picker did not produce a selection')
nearby = [w for w in words if w['text'].strip() in ['Nearby', 'devices']]
if len(nearby) < 2:
    raise RuntimeError('Nearby devices row missing')
row_end = max(int(w['left']) + int(w['width']) for w in nearby)
row_y = int(nearby[0]['top']) + int(nearby[0]['height']) // 2
run('xdotool', 'mousemove', str(row_end + 70), str(row_y))
time.sleep(1)
tooltip = screen('manual-send-tooltip')
if not any(w['text'].strip() == 'Manual' for w in tooltip):
    raise RuntimeError('Manual sending tooltip missing at observed row control')
click(row_end + 70, row_y)
text('Enter', 'manual-address-dialog')
run('xdotool', 'type', '--clearmodifiers', '127.0.0.1')
run('xdotool', 'key', 'Return')
time.sleep(2)
screen('transfer-requested')
(out / 'transfer-requested').touch()
deadline = time.monotonic() + 120
while not (out / 'control-completed').exists():
    if time.monotonic() > deadline:
        screen('sender-control-timeout')
        raise RuntimeError('Receiver app control did not complete')
    time.sleep(1)
screen('sender-control-completed')
