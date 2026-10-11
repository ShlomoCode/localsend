"""Cloud-only GUI driver; no protocol peers or injected application faults."""
import csv
import hashlib
import io
import json
import os
import pathlib
import subprocess
import time
import pyatspi

role = os.environ['ROLE']
evidence = pathlib.Path(os.environ.get('EVIDENCE_ROOT', '/evidence'))
out = evidence / role
out.mkdir(parents=True, exist_ok=True)
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
    if label in ('Accept', 'Done') or label.endswith('.txt'):
        matches = []
        def visit(node, depth=0):
            if depth > 18:
                return
            try:
                if node.name == label and node.getState().contains(pyatspi.STATE_SHOWING):
                    action = node.queryAction()
                    if action.nActions:
                        bounds = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                        matches.append((bounds.y, action, bounds))
                for child in node:
                    visit(child, depth + 1)
            except (NotImplementedError, RuntimeError):
                pass
        visit(pyatspi.Registry.getDesktop(0))
        if matches:
            matches.sort(key=lambda item: item[0])
            log('semantic-click', label=label)
            if label.endswith('.txt'):
                bounds = matches[-1][2]
                command('xdotool', 'mousemove', str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2), 'click', '1')
                log('accessible-row-pointer', label=label, x=bounds.x, y=bounds.y, width=bounds.width, height=bounds.height)
            else:
                matches[-1][1].doAction(0)
            time.sleep(2)
            return True
    rows = snapshot(name)
    hits = [r for r in rows if r['text'].strip().strip('.,:').lower() == label.lower()]
    if not hits and label in ('Accept', 'Done') and app_bounds:
        left, top, width, height = app_bounds
        crop_top = top + int(height * .7)
        crop_height = int(height * .3)
        crop = out / (name + '-footer.png')
        command('convert', str(out / (name + '.png')), '-crop', f'{width}x{crop_height}+{left}+{crop_top}', '+repage', '-resize', '300%', '-colorspace', 'Gray', str(crop))
        text = command('tesseract', str(crop), 'stdout', '--psm', '6', 'tsv').stdout
        (out / (name + '-footer.tsv')).write_text(text)
        for row in csv.DictReader(io.StringIO(text), delimiter='\t'):
            if row['text'].strip().strip('.,:').lower() == label.lower():
                row['left'] = str(left + int(row['left']) // 3)
                row['top'] = str(crop_top + int(row['top']) // 3)
                row['width'] = str(int(row['width']) // 3)
                row['height'] = str(int(row['height']) // 3)
                hits.append(row)
    if app_bounds and label in ('Send', 'File', 'Linux'):
        left, top, width, height = app_bounds
        hits = [r for r in hits if left <= int(r['left']) <= left + width and top <= int(r['top']) <= top + height]
    if not hits:
        if optional:
            return False
        raise RuntimeError('UI label absent: ' + label)
    hit = max(hits, key=lambda row: int(row['top'])) if label in ('Accept', 'Done') else hits[0]
    x = int(hit['left']) + int(hit['width']) // 2
    y = int(hit['top']) + int(hit['height']) // 2
    log('click', label=label, x=x, y=y)
    command('xdotool', 'mousemove', str(x), str(y), 'click', '1')
    time.sleep(2)
    return True


def start():
    global app_bounds
    app = subprocess.Popen([os.environ.get('APP_EXECUTABLE', '/home/probe/squashfs-root/AppRun')], stdout=open(out / ('app-' + str(len(events)) + '.log'), 'w'), stderr=subprocess.STDOUT)
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
log('start', role=role, selection_mode=os.environ.get('SELECTION_MODE', 'path'))
if role == 'receiver':
    app = start()
    for preferences in pathlib.Path('/home/probe').rglob('shared_preferences.json'):
        values = json.loads(preferences.read_text())
        alias = values.get('flutter.ls_alias', values.get('ls_alias'))
        if alias:
            (out / 'alias.txt').write_text(alias)
            log('receiver-alias', alias=alias, preferences=str(preferences))
    (out / 'ready').touch()
    receipts = []
    saved_versions = {}
    deadline = time.monotonic() + int(os.environ.get('RECEIVER_LIFETIME', '500'))
    iteration = 0
    while time.monotonic() < deadline and not (evidence / 'sender/done').exists():
        iteration += 1
        click('Accept', 'receiver-' + str(iteration), optional=True)
        click('Done', 'receiver-done-' + str(iteration), optional=True)
        for path in pathlib.Path('/home/probe/Downloads').rglob('*'):
            if path.is_file() and saved_versions.get(str(path)) != path.stat().st_mtime_ns:
                data = path.read_bytes()
                saved_versions[str(path)] = path.stat().st_mtime_ns
                receipts.append(dict(name=path.name, size=len(data), sha256=hashlib.sha256(data).hexdigest()))
                archive = out / 'saved' / str(len(receipts))
                archive.mkdir(parents=True, exist_ok=True)
                (archive / path.name).write_bytes(data)
                (out / 'receipts.json').write_text(json.dumps(receipts, indent=2))
                log('saved-file', **receipts[-1])
        if receipts and (evidence / ('sender/ack-' + str(len(receipts)))).exists():
            # Reset only this test's archived fixture after a confirmed GUI transfer.
            for path in pathlib.Path('/home/probe/Downloads').glob('*.txt'):
                if path.name in ('whatever.txt', 'another.txt'):
                    path.unlink()
            (out / ('cleared-' + str(len(receipts)))).touch()
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
    while not (evidence / 'receiver/ready').exists():
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
            mode = os.environ.get('SELECTION_MODE', 'path')
            location = str(fixture) + '/' if mode == 'row' else str(fixture / filename)
            command('xdotool', 'type', '--clearmodifiers', '--delay', '30', location)
            command('xdotool', 'key', 'Return')
            time.sleep(2)
            if mode == 'row':
                click('OK', case + '-enter-directory', optional=True)
                time.sleep(2)
                click(filename, case + '-picker-row')
            click('OK', case + '-confirm-picker', optional=True)
            time.sleep(5)
            rows = snapshot(case + '-selection')
            log('selection', case=case, visible_text=' '.join(r['text'] for r in rows if r['text']))
            # The receiver advertises its random alias; the device card includes Linux.
            alias_path = evidence / 'receiver/alias.txt'
            device_label = alias_path.read_text().split()[-1] if alias_path.exists() else 'Linux'
            receipt_path = evidence / 'receiver/receipts.json'
            receipt_count = len(json.loads(receipt_path.read_text())) if receipt_path.exists() else 0
            if os.environ.get('MANUAL_PEER'):
                # Historical SendTab renders ads_click 70px after Nearby devices.
                # Anchor the real GUI action to observed text, then require dialog labels.
                nearby = [r for r in rows if r['text'].strip() == 'devices']
                if not nearby:
                    raise RuntimeError('Manual-address GUI anchor absent')
                anchor = nearby[0]
                x = int(anchor['left']) + int(anchor['width']) + 70
                y = int(anchor['top']) + int(anchor['height']) // 2
                log('manual-address-click', x=x, y=y)
                command('xdotool', 'mousemove', str(x), str(y), 'click', '1')
                time.sleep(2)
                click('IP', case + '-ip-mode')
                command('xdotool', 'type', '--clearmodifiers', '--delay', '30', os.environ['MANUAL_PEER'])
                click('Confirm', case + '-address-confirm')
            elif not click(device_label, case + '-device', optional=True):
                log('harness-blocker', case=case, reason='Receiver device card not located; preserve actual screen before fallback')
                raise RuntimeError('Device discovery/card location needs inspection')
            receipt_deadline = time.monotonic() + 60
            while time.monotonic() < receipt_deadline:
                received = json.loads(receipt_path.read_text()) if receipt_path.exists() else []
                if len(received) > receipt_count:
                    result = received[-1]
                    if result['sha256'] != hashlib.sha256(payload).hexdigest() or result['name'] != filename or result['size'] != len(payload):
                        raise RuntimeError('Saved filename or contents differ: ' + str(result))
                    log('verified-transfer', case=case, **result)
                    (out / ('ack-' + str(len(received)))).touch()
                    clear_deadline = time.monotonic() + 20
                    while not (evidence / ('receiver/cleared-' + str(len(received)))).exists():
                        if time.monotonic() > clear_deadline:
                            raise RuntimeError('Receiver fixture cleanup deadline')
                        time.sleep(1)
                    break
                time.sleep(2)
            else:
                snapshot(case + '-receipt-timeout')
                raise RuntimeError('No actual saved-file receipt after GUI send: ' + case)
            snapshot(case + '-transfer')
            app.terminate()
            command('pkill', '-f', '/home/probe/squashfs-root/usr/bin/localsend_app')
            time.sleep(4)
    finally:
        (out / 'done').touch()
