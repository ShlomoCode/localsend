import csv
import io
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
run('adb', 'forward', 'tcp:53317', 'tcp:53317')
click(*text('Send', 'send-button'))
screen('send-visible')
click(*text('File', 'file-button'))
screen('file-picker-visible')
