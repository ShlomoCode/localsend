import csv
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import subprocess
import time
from PIL import Image

out = Path('evidence')

def run(*args):
    print('INPUT', datetime.now(timezone.utc).isoformat(), args, flush=True)
    return subprocess.check_output(args, text=True)

def screen(name, sidebar=False):
    path = out / (name + '.png')
    run('scrot', str(path))
    # Preserve the original evidence screenshot. Enlarge a separate OCR input
    # so 13 px desktop labels are recognized, then map bounds back to pixels.
    ocr_path = out / (name + '-ocr.png')
    source = Image.open(path)
    offset_y = 100 if sidebar else 0
    if sidebar:
        source = source.crop((0, 100, 256, 300))
    source.resize((source.width * 3, source.height * 3), Image.Resampling.LANCZOS).save(ocr_path)
    tsv = run('tesseract', str(ocr_path), 'stdout', '--psm', '11', 'tsv')
    (out / (name + '.tsv')).write_text(tsv)
    # Tesseract TSV does not CSV-quote text; a leading UI quote is literal.
    words = list(csv.DictReader(io.StringIO(tsv), delimiter='\t', quoting=csv.QUOTE_NONE))
    for word in words:
        for key in ['left', 'top', 'width', 'height']:
            word[key] = str(int(word[key]) // 3)
        word['top'] = str(int(word['top']) + offset_y)
    return words

def text(name, stage, scroll=False):
    for attempt in range(12 if scroll else 1):
        words = screen(stage + '-' + str(attempt), sidebar=name in ['Settings', 'Send'])
        matches = [w for w in words if w['text'].strip() == name]
        print('LOOKUP', repr(name), repr([w['text'] for w in words if w['text'].strip()]), flush=True)
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
run('xdotool', 'mousemove', '861', str(row_y))
time.sleep(1)
screen('server-stop-tooltip')
click(861, row_y)
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
fixture.write_text('LocalSend issue 2007 original app control v1\nRun: ' + os.environ['GITHUB_RUN_ID'] + '\n')
run('xdotool', 'key', 'ctrl+l')
run('xdotool', 'type', '--clearmodifiers', str(fixture))
run('xdotool', 'key', 'Return')
time.sleep(2)
screen('file-location-resolved')
# GTK's location entry first resolves the path; accept the enabled Open
# action through the actual chooser rather than assuming Return selected it.
click(*text('Open', 'file-picker-open'))
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
# The original screenshot38105941256 verifies Manual sending at this row
# control; full-screen OCR can miss its small tooltip. Require the resulting
# address dialog after the click instead.
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
(out / 'sender-first-finished').touch()
if os.environ.get('ISSUE_2007_RESEND'):
    variant = os.environ.get('ISSUE_2007_VARIANT', 'unchanged')
    if variant == 'changed':
        # Change bytes while keeping filename, extension and length identical.
        fixture.write_bytes(fixture.read_bytes().replace(b'control v1', b'control v2'))
    elif variant == 'renamed':
        renamed = fixture.with_name('B.txt')
        renamed.write_bytes(fixture.read_bytes())
        fixture = renamed
    (out / 'resend-input.json').write_text(json.dumps({'variant': variant, 'path': str(fixture), 'name': fixture.name}, indent=2))
    # Observed original Finished screen places the session Done action here.
    click(938, 680)
    screen('resend-send-page')
    click(*text('File', 'resend-file-button'))
    screen('resend-file-picker-visible')
    run('xdotool', 'key', 'ctrl+l', 'ctrl+a')
    run('xdotool', 'type', '--clearmodifiers', str(fixture))
    run('xdotool', 'key', 'Return')
    time.sleep(2)
    resolved = screen('resend-file-location-resolved')
    if not any(w['text'].strip().startswith('Files:') for w in resolved):
        click(*text('Open', 'resend-file-picker-open'))
        time.sleep(2)
    words = screen('resend-file-selected')
    if not any(w['text'].strip().startswith('Files:') for w in words):
        raise RuntimeError('Resend actual file picker did not select A.txt')
    nearby = [w for w in words if w['text'].strip() in ['Nearby', 'devices']]
    if len(nearby) < 2:
        raise RuntimeError('Resend Nearby devices row missing')
    row_end = max(int(w['left']) + int(w['width']) for w in nearby)
    row_y = int(nearby[0]['top']) + int(nearby[0]['height']) // 2
    click(row_end + 70, row_y)
    text('Enter', 'resend-manual-address-dialog')
    run('xdotool', 'type', '--clearmodifiers', '127.0.0.1')
    screen('resend-address-prepared')
    (out / 'resend-address-ready').touch()
    deadline = time.monotonic() + 180
    while not (out / 'resend-ready').exists():
        if time.monotonic() > deadline:
            screen('sender-delete-control-timeout')
            raise RuntimeError('Real receiver deletion did not complete')
        time.sleep(0.05)
    submitted_utc = datetime.now(timezone.utc).isoformat()
    run('xdotool', 'key', 'Return')
    (out / 'resend-submission.json').write_text(json.dumps({'utc': submitted_utc, 'action': 'Return in prepared real address dialog'}, indent=2))
    (out / 'resend-requested').touch()
    time.sleep(2)
    screen('resend-transfer-requested')
    deadline = time.monotonic() + 120
    while not (out / 'resend-completed').exists():
        if time.monotonic() > deadline:
            screen('sender-resend-timeout')
            raise RuntimeError('Receiver resend observation did not complete')
        time.sleep(0.5)
    screen('sender-resend-completed')
