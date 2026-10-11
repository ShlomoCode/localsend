"""Cloud-only GUI driver; no protocol peers or injected application faults."""
import csv
import hashlib
import io
import json
import os
import pathlib
import subprocess
import time

role = os.environ['ROLE']
out = pathlib.Path('/evidence') / role
events = []
app_bounds = None


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=20)


def log(action, **details):
    events.append(dict(time=time.time(), action=action, **details))
    (out / 'events.json').write_text(json.dumps(events, indent=2))
    print(action, details, flush=True)


def snapshot(name):
    path = out / (name + '.png')
    command('scrot', str(path))
    text = command('tesseract', str(path), 'stdout', '--psm', '11', 'tsv').stdout
    (out / (name + '.tsv')).write_text(text)
    return list(csv.DictReader(io.StringIO(text), delimiter='\t'))


def click(label, name, optional=False):
    rows = snapshot(name)
    hits = [r for r in rows if r['text'].strip().strip('.,:').lower() == label.lower()]
    if app_bounds and label in ('Send', 'File', 'Linux'):
        left, top, width, height = app_bounds
        hits = [r for r in hits if left <= int(r['left']) <= left + width and top <= int(r['top']) <= top + height]
    if not hits:
        if optional:
            return False
        raise RuntimeError('UI label absent: ' + label)
    hit = hits[0]
    x = int(hit['left']) + int(hit['width']) // 2
    y = int(hit['top']) + int(hit['height']) // 2
    log('click', label=label, x=x, y=y)
    command('xdotool', 'mousemove', str(x), str(y), 'click', '1')
    time.sleep(2)
    return True


def start():
    global app_bounds
    app = subprocess.Popen(['/home/probe/squashfs-root/AppRun'], stdout=open(out / ('app-' + str(len(events)) + '.log'), 'w'), stderr=subprocess.STDOUT)
    time.sleep(12)
    windows = command('xdotool', 'search', '--onlyvisible', '--name', 'LocalSend').stdout.splitlines()
    if not windows:
        snapshot('missing-window')
        raise RuntimeError('No visible application window')
    command('xdotool', 'windowactivate', '--sync', windows[-1])
    command('xdotool', 'windowsize', windows[-1], '1100', '700')
    time.sleep(2)
    geometry = command('xdotool', 'getwindowgeometry', '--shell', windows[-1]).stdout
    values = dict(line.split('=', 1) for line in geometry.splitlines() if '=' in line)
    app_bounds = tuple(int(values[key]) for key in ('X', 'Y', 'WIDTH', 'HEIGHT'))
    snapshot('app-' + str(len(events)))
    log('app-start', pid=app.pid)
    return app


pathlib.Path('/home/probe/Downloads').mkdir(exist_ok=True)
log('start', role=role)
if role == 'receiver':
    app = start()
    for preferences in pathlib.Path('/home/probe').rglob('shared_preferences.json'):
        values = json.loads(preferences.read_text())
        alias = values.get('flutter.ls_alias', values.get('ls_alias'))
        if alias:
            (out / 'alias.txt').write_text(alias)
            log('receiver-alias', alias=alias, preferences=str(preferences))
    (out / 'ready').touch()
    deadline = time.monotonic() + 500
    iteration = 0
    while time.monotonic() < deadline and not pathlib.Path('/evidence/sender/done').exists():
        iteration += 1
        click('Accept', 'receiver-' + str(iteration), optional=True)
        click('Done', 'receiver-done-' + str(iteration), optional=True)
        time.sleep(2)
    files = []
    for path in pathlib.Path('/home/probe/Downloads').rglob('*'):
        if path.is_file():
            data = path.read_bytes()
            files.append(dict(name=path.name, size=len(data), sha256=hashlib.sha256(data).hexdigest()))
            (out / path.name).write_bytes(data)
    (out / 'saved-files.json').write_text(json.dumps(files, indent=2))
    snapshot('receiver-final')
    app.terminate()
else:
    fixture = pathlib.Path('/home/probe/fixture')
    fixture.mkdir()
    payload = b'LocalSend issue 402 ordinary owned file\n' * 32
    (fixture / 'whatever.txt').write_bytes(payload)
    (fixture / 'another.txt').symlink_to('whatever.txt')
    log('fixture', link=os.readlink(fixture / 'another.txt'), size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
    deadline = time.monotonic() + 90
    while not pathlib.Path('/evidence/receiver/ready').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Receiver GUI readiness deadline')
        time.sleep(2)
    try:
        for index, filename in enumerate(['whatever.txt', 'another.txt', 'another.txt']):
            case = str(index) + '-' + filename
            app = start()
            click('Send', case + '-send')
            click('File', case + '-file')
            snapshot(case + '-picker')
            command('xdotool', 'key', 'ctrl+l')
            command('xdotool', 'type', '--clearmodifiers', '--delay', '30', str(fixture / filename))
            command('xdotool', 'key', 'Return')
            time.sleep(2)
            click('OK', case + '-confirm-picker', optional=True)
            time.sleep(5)
            rows = snapshot(case + '-selection')
            log('selection', case=case, visible_text=' '.join(r['text'] for r in rows if r['text']))
            # The receiver advertises its random alias; the device card includes Linux.
            alias_path = pathlib.Path('/evidence/receiver/alias.txt')
            device_label = alias_path.read_text().split()[-1] if alias_path.exists() else 'Linux'
            if not click(device_label, case + '-device', optional=True):
                log('harness-blocker', case=case, reason='Receiver device card not located; preserve actual screen before fallback')
                raise RuntimeError('Device discovery/card location needs inspection')
            time.sleep(30)
            snapshot(case + '-transfer')
            app.terminate()
            command('pkill', '-f', '/home/probe/squashfs-root/usr/bin/localsend_app')
            time.sleep(4)
    finally:
        (out / 'done').touch()
