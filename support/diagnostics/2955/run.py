"""Cloud-only native UI capture. Do not run during source preparation."""
import hashlib
import csv
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

import pyatspi

OUT = Path(os.environ['EVIDENCE'])
OUT.mkdir(parents=True, exist_ok=True)
stage = 'startup'
sequence = 0
children = []
ledger = []
serial = 'emulator-5554'
PACKAGE = 'org.localsend.localsend_app'
original_show_touches = None
sender_process = None
control_deadline = None


def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))


def log(kind, value):
    with (OUT / 'inputs.jsonl').open('a') as stream:
        stream.write(json.dumps({'time': time.time(), 'stage': stage, 'kind': kind, 'value': value}, ensure_ascii=False) + '\n')


def cmd(*args, timeout=30, binary=False):
    result = subprocess.run(args, timeout=timeout, check=True, capture_output=True)
    return result.stdout if binary else result.stdout.decode(errors='replace')


def adb(*args, **kwargs):
    return cmd('adb', '-s', serial, *args, **kwargs)


def native_output(value):
    return value.decode(errors='replace') if isinstance(value, bytes) else value


def wait_native_adb(phase, args, expected, not_ready, seconds):
    deadline = time.monotonic() + seconds
    command = ['adb', '-s', serial, *args]
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(command, capture_output=True, timeout=min(5, max(.1, deadline - time.monotonic())))
        except subprocess.TimeoutExpired as error:
            log('native-adb-readiness', {'phase': phase, 'command': command, 'returncode': None, 'stdout': native_output(error.stdout), 'stderr': native_output(error.stderr), 'error': 'TimeoutExpired'})
            raise
        stdout = native_output(result.stdout)
        stderr = native_output(result.stderr)
        log('native-adb-readiness', {'phase': phase, 'command': command, 'returncode': result.returncode, 'stdout': stdout, 'stderr': stderr})
        if result.returncode == 0:
            if stdout.strip() == expected:
                return
            if stdout.strip() not in not_ready:
                raise RuntimeError(f'Unexpected native ADB {phase} output: {stdout!r}')
        else:
            errors = [line.strip() for line in stderr.splitlines() if line.strip() and not line.startswith('* daemon')]
            transient = {
                prefix + message
                for prefix in ('error: ', 'adb: ')
                for message in (f"device '{serial}' not found", 'device offline', 'no devices/emulators found', 'closed')
            }
            if not errors or any(line not in transient for line in errors):
                raise subprocess.CalledProcessError(result.returncode, command, output=result.stdout, stderr=result.stderr)
        time.sleep(min(.25, max(0, deadline - time.monotonic())))
    raise RuntimeError(f'Timed out waiting for native ADB {phase} after {seconds} seconds')


def spawn(args, filename):
    stream = (OUT / filename).open('wb')
    proc = subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT)
    children.append((proc, stream))
    return proc


def until(fn, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.25)
    raise RuntimeError(f'Timed out at {stage}')


def digest(path):
    return {'bytes': path.stat().st_size, 'sha256': hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()} if hasattr(hashlib, 'file_digest') else {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def android_file_exists(path):
    return subprocess.run(['adb', '-s', serial, 'shell', 'test', '-f', path], capture_output=True, timeout=15).returncode == 0


def download(asset, target):
    url = asset['browser_download_url']
    with urllib.request.urlopen(url, timeout=60) as response, target.open('wb') as stream:
        headers = dict(response.headers)
        shutil.copyfileobj(response, stream)
    write(target.name + '.metadata.json', {'url': url, 'headers': headers, 'release_asset': asset, **digest(target)})
    if target.stat().st_size != asset['size']:
        raise RuntimeError('Release asset size mismatch')


def android_tree():
    adb('shell', 'uiautomator', 'dump', '/sdcard/window2955.xml')
    raw = adb('shell', 'cat', '/sdcard/window2955.xml')
    return raw, ET.fromstring(raw)


def android_snapshot():
    global sequence
    sequence += 1
    name = f'{sequence:04d}-{stage}-android'
    (OUT / (name + '.png')).write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
    raw, root = android_tree()
    (OUT / (name + '.xml')).write_text(raw)
    return root


def bounds(node):
    values = list(map(int, re.findall(r'\d+', node.attrib.get('bounds', ''))))
    if len(values) != 4 or values[2] <= values[0] or values[3] <= values[1]:
        raise RuntimeError('Missing usable semantic bounds')
    return values


def android_matches(root, label):
    return [n for n in root.iter('node') if n.get('text') == label or n.get('content-desc') == label]


def receiver_ready(label):
    root = android_snapshot()
    # Only the stock OS permission-controller dialog can trigger this action.
    permissions = [n for n in root.iter('node') if n.get('package') == 'com.android.permissioncontroller' and n.get('text') == 'Allow']
    if len(permissions) == 1:
        android_tap('Allow')
        return False
    return android_matches(root, label)


def android_find(label, scroll=False):
    for attempt in range(36 if scroll else 1):
        root = android_snapshot()
        matches = android_matches(root, label)
        if len(matches) == 1:
            return root, matches[0]
        if len(matches) > 1:
            matches = [n for n in matches if n.get('clickable') == 'true']
            if len(matches) == 1:
                return root, matches[0]
            raise RuntimeError(f'Ambiguous Android label {label!r}')
        containers = [n for n in root.iter('node') if n.get('scrollable') == 'true']
        if not scroll or len(containers) != 1:
            break
        x1, y1, x2, y2 = bounds(containers[0])
        log('android-scroll', containers[0].attrib)
        start, end = (y2-30, y1+30) if attempt < 18 else (y1+30, y2-30)
        adb('shell', 'input', 'swipe', str((x1+x2)//2), str(start), str((x1+x2)//2), str(end), '350')
    raise RuntimeError(f'Absent Android label {label!r}')


def android_tap(label, scroll=False):
    root, node = android_find(label, scroll)
    parents = {child: parent for parent in root.iter() for child in parent}
    while node.get('clickable') != 'true' and node in parents:
        node = parents[node]
    if node.get('clickable') != 'true' or node.get('enabled') != 'true':
        raise RuntimeError(f'No enabled clickable semantic target for {label!r}')
    x1, y1, x2, y2 = bounds(node)
    log('android-tap', {'label': label, 'target': node.attrib})
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
    time.sleep(.4)


def desktop_nodes():
    rows = []
    def visit(node, depth=0):
        if depth > 30:
            return
        try:
            state = node.getState()
            if state.contains(pyatspi.STATE_SHOWING):
                rect = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                rows.append((node, {'name': node.name, 'role': node.getRoleName(), 'bounds': list(rect), 'enabled': state.contains(pyatspi.STATE_ENABLED)}))
            for child in node:
                visit(child, depth+1)
        except (NotImplementedError, RuntimeError):
            pass
    visit(pyatspi.Registry.getDesktop(0))
    return rows


def desktop_snapshot():
    global sequence
    sequence += 1
    rows = desktop_nodes()
    write(f'{sequence:04d}-{stage}-desktop.json', [r for _, r in rows])
    cmd('scrot', str(OUT / f'{sequence:04d}-{stage}-desktop.png'))
    return rows


def observe_sender_environment():
    """Retain unfiltered native evidence without sending any app input."""
    samples = []
    for attempt, delay in enumerate((0, 15, 45)):
        if delay:
            time.sleep(delay)
        prefix = f'sender-observation-{attempt}'
        sample = {'time': time.time(), 'sender_pid': sender_process.pid, 'sender_exit': sender_process.poll()}
        samples.append(sample)
        write('sender-environment-observation.json', samples)
        # Capture pixels first: bridge errors must not erase rendered evidence.
        cmd('scrot', str(OUT / (prefix + '.png')), timeout=10)
        for label, args in {
            'windows': ['xwininfo', '-root', '-tree'],
            'foreground': ['xdotool', 'getactivewindow', 'getwindowname'],
            'a11y-status': ['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/status', '--method', 'org.freedesktop.DBus.Properties.GetAll', 'org.a11y.Status'],
            'toolkit-accessibility': ['gsettings', 'get', 'org.gnome.desktop.interface', 'toolkit-accessibility'],
        }.items():
            try:
                result = subprocess.run(args, capture_output=True, timeout=10)
                sample[label] = {'returncode': result.returncode, 'stdout': native_output(result.stdout), 'stderr': native_output(result.stderr)}
            except subprocess.TimeoutExpired as error:
                sample[label] = {'error': 'TimeoutExpired', 'stdout': native_output(error.stdout), 'stderr': native_output(error.stderr)}
            write('sender-environment-observation.json', samples)
        # A fresh native observer process has its own bus connection and a
        # separate deadline, so blocked bridge calls cannot prevent later pixels
        # or the main controller's normal cleanup.
        try:
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('observe_tree.py')), str(OUT / (prefix + '-tree.json'))], capture_output=True, timeout=20)
            sample['tree_observer'] = {'returncode': result.returncode, 'stdout': native_output(result.stdout), 'stderr': native_output(result.stderr)}
        except subprocess.TimeoutExpired as error:
            sample['tree_observer'] = {'error': 'TimeoutExpired', 'stdout': native_output(error.stdout), 'stderr': native_output(error.stderr)}
        write('sender-environment-observation.json', samples)


def control_cmd(*args, timeout=30):
    remaining = control_deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError('Rendered control exceeded its120s deadline')
    return cmd(*args, timeout=min(timeout, remaining))


def rendered_sender_label(label):
    """Resolve ordinary mouse input from current rendered text and native PID."""
    global sequence
    if control_deadline is not None and time.monotonic() >= control_deadline:
        raise RuntimeError('Rendered control exceeded its120s deadline')
    if sender_process.poll() is not None:
        raise RuntimeError('Sender exited before rendered control qualification')
    ids = control_cmd('xdotool', 'search', '--all', '--onlyvisible', '--pid', str(sender_process.pid), '--name', '^LocalSend$', timeout=5).split()
    if len(ids) != 1:
        raise RuntimeError('Expected one visible LocalSend window for actual sender PID')
    window = ids[0]
    control_cmd('xdotool', 'windowactivate', '--sync', window, timeout=5)
    if control_cmd('xdotool', 'getactivewindow', timeout=5).strip() != window:
        raise RuntimeError('Rendered sender input has wrong foreground window')
    raw_geometry = control_cmd('xdotool', 'getwindowgeometry', '--shell', window, timeout=5)
    geometry = dict(line.split('=', 1) for line in raw_geometry.splitlines() if '=' in line)
    x, y, width, height = (int(geometry[key]) for key in ('X', 'Y', 'WIDTH', 'HEIGHT'))
    sequence += 1
    prefix = f'{sequence:04d}-{stage}-rendered'
    screenshot = OUT / (prefix + '.png')
    control_cmd('scrot', str(screenshot), timeout=10)
    # Preserve the original pixels. Scale only the OCR observation so small
    # visible labels are readable; inverse-map every returned bound explicitly.
    ocr_scale = 3
    ocr_image = OUT / (prefix + '-ocr3x.png')
    control_cmd('ffmpeg', '-y', '-v', 'error', '-i', str(screenshot), '-vf', 'scale=iw*3:ih*3', '-frames:v', '1', str(ocr_image), timeout=10)
    raw = control_cmd('tesseract', str(ocr_image), 'stdout', '--psm', '11', 'tsv', timeout=15)
    (OUT / (prefix + '.tsv')).write_text(raw)
    matches = []
    for row in csv.DictReader(io.StringIO(raw), delimiter='\t'):
        if row['text'].strip() != label or float(row['conf']) < 80:
            continue
        left, top, w, h = (int(row[key])/ocr_scale for key in ('left', 'top', 'width', 'height'))
        if w > 0 and h > 0 and x <= left and y <= top and left+w <= x+width and top+h <= y+height:
            matches.append({'label': label, 'bounds': [left, top, w, h], 'confidence': float(row['conf'])})
    observation = {'window': window, 'sender_pid': sender_process.pid, 'geometry': [x, y, width, height], 'label': label, 'matches': matches, 'screenshot': screenshot.name, 'ocr_image': ocr_image.name, 'ocr_scale': ocr_scale}
    write(prefix + '.json', observation)
    if len(matches) > 1:
        raise RuntimeError('Ambiguous rendered sender label')
    return observation, matches[0] if matches else None


def rendered_sender_tap(label, scroll=False):
    for attempt in range(25 if scroll else 1):
        observation, target = rendered_sender_label(label)
        if sender_process.poll() is not None or control_cmd('xdotool', 'getactivewindow', timeout=5).strip() != observation['window']:
            raise RuntimeError('Sender process/foreground changed after rendered target capture')
        ids = control_cmd('xdotool', 'search', '--all', '--onlyvisible', '--pid', str(sender_process.pid), '--name', '^LocalSend$', timeout=5).split()
        if ids != [observation['window']]:
            raise RuntimeError('Sender native PID/window identity changed before input')
        if target is not None:
            left, top, width, height = target['bounds']
            log('rendered-sender-click', {**observation, 'target': target})
            control_cmd('xdotool', 'mousemove', '--sync', str(round(left+width/2)), str(round(top+height/2)), 'click', '1', timeout=5)
            time.sleep(.5)
            return
        if scroll and attempt < 24:
            x, y, width, height = observation['geometry']
            log('rendered-sender-scroll', {**observation, 'direction': 'down' if attempt < 12 else 'up'})
            control_cmd('xdotool', 'mousemove', '--sync', str(x+width*3//4), str(y+height//2), 'click', '--repeat', '3', '--delay', '100', '5' if attempt < 12 else '4', timeout=5)
            time.sleep(.3)
    raise RuntimeError(f'Absent rendered sender label {label!r}')


def qualify_sender_input_actions():
    global stage
    stage = 'rendered-control-listener-baseline'
    baseline = control_cmd('ss', '-ltnp')
    (OUT / 'rendered-control-baseline-listeners.txt').write_text(baseline)
    if not any(re.search(r':53317\s', line) and f'pid={sender_process.pid},' in line for line in baseline.splitlines()):
        raise RuntimeError('No baseline port53317 listener owned by actual senderPID')
    stage = 'rendered-control-settings'
    rendered_sender_tap('Settings')
    stage = 'rendered-control-stop'
    rendered_sender_tap('Stop', scroll=True)
    stage = 'rendered-control-stopped'
    _, target = rendered_sender_label('Start')
    if target is None:
        raise RuntimeError('Actual Stop input did not expose rendered Start control')
    stopped = control_cmd('ss', '-ltnp')
    (OUT / 'rendered-control-stopped-listeners.txt').write_text(stopped)
    if re.search(r':53317\s', stopped):
        raise RuntimeError('Actual Stop input did not release sender port53317')
    stage = 'rendered-control-restore-start'
    rendered_sender_tap('Start')
    stage = 'rendered-control-restored'
    _, target = rendered_sender_label('Stop')
    if target is None:
        raise RuntimeError('Actual Start input did not expose rendered Stop control')
    restored = control_cmd('ss', '-ltnp')
    (OUT / 'rendered-control-restored-listeners.txt').write_text(restored)
    if not any(re.search(r':53317\s', line) and f'pid={sender_process.pid},' in line for line in restored.splitlines()):
        raise RuntimeError('Actual Start input did not restore port53317 owned by senderPID')
    write('sender-rendered-control.json', {'control': 'Settings Stop Start', 'port_release': 'observed', 'port_restore': 'observed', 'delivery': 'not attempted'})


def qualify_sender_input():
    global control_deadline
    video = OUT / 'sender-rendered-control.mp4'
    recorder = spawn(['ffmpeg', '-y', '-f', 'x11grab', '-video_size', '1600x1000', '-framerate', '15', '-i', ':99', '-t', '160', str(video)], 'sender-rendered-control-ffmpeg.log')
    time.sleep(1)
    if recorder.poll() is not None:
        raise RuntimeError('Native desktop recording exited before control input')
    control_started = time.monotonic()
    control_deadline = control_started + 120
    try:
        qualify_sender_input_actions()
    finally:
        primary_error = sys.exc_info()[1]
        control_finished = time.monotonic()
        cleanup = []
        def retain(label, fn):
            try:
                result = fn()
                cleanup.append({'step': label, 'status': 'completed'})
                return result
            except Exception as error:
                cleanup.append({'step': label, 'status': 'failed', 'error': repr(error)})
                return None
        if recorder.poll() is None:
            retain('stop', lambda: recorder.send_signal(signal.SIGINT))
        retain('wait', lambda: recorder.wait(timeout=15))
        def probe():
            raw = cmd('ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(video), timeout=10)
            (OUT / 'sender-rendered-control-video-probe.json').write_text(raw)
            return json.loads(raw)
        metadata = retain('probe', probe)
        def decode():
            decoded = subprocess.run(['ffmpeg', '-v', 'warning', '-i', str(video), '-f', 'null', '-'], capture_output=True, timeout=30)
            (OUT / 'sender-rendered-control-video-decode.txt').write_bytes(decoded.stderr)
            if decoded.returncode:
                raise RuntimeError('Native control recording failed full decode')
        retain('decode', decode)
        if metadata is not None:
            def coverage():
                duration = float(metadata['format']['duration'])
                elapsed = control_finished-control_started
                write('sender-rendered-control-video-timing.json', {'recorded_seconds': duration, 'control_seconds': elapsed})
                if duration < elapsed:
                    raise RuntimeError('Native recording does not cover the complete input episode')
            retain('coverage', coverage)
        write('sender-rendered-control-video-coverage.json', {'primary_error': repr(primary_error) if primary_error else None, 'cleanup': cleanup})
        if primary_error is None and any(row['status'] == 'failed' for row in cleanup):
            raise RuntimeError('Native control recording retention/decode/coverage failed')


def desktop_find(label, seconds=30, role=None):
    attempts = 0
    def find():
        nonlocal attempts
        matches = [(node, row) for node, row in desktop_nodes() if row['name'] == label and (role is None or row['role'] == role)]
        if len(matches) > 1:
            actionable = [(node, row) for node, row in matches if row['role'] in ('push button', 'page tab', 'toggle button')]
            matches = actionable
        if len(matches) > 1:
            raise RuntimeError(f'Ambiguous desktop label {label!r}')
        if matches:
            return matches[0]
        # Scroll only within a unique exposed native scroll container.
        panes = [(node, row) for node, row in desktop_nodes() if row['role'] == 'scroll pane' and row['enabled']]
        if len(panes) == 1 and attempts < 24:
            node, row = panes[0]
            x, y, w, h = row['bounds']
            if w > 0 and h > 0:
                log('desktop-scroll', row)
                cmd('xdotool', 'mousemove', str(x+w//2), str(y+h//2), 'click', '5' if attempts < 12 else '4')
                attempts += 1
        return None
    return until(find, seconds)


def desktop_tap(label, role=None):
    desktop_snapshot()
    node, row = desktop_find(label, role=role)
    if not row['enabled']:
        raise RuntimeError(f'Disabled desktop target {label!r}')
    log('desktop-tap', row)
    action = None
    for _ in range(5):
        try:
            candidate = node.queryAction()
            if candidate.nActions == 1 and node.getState().contains(pyatspi.STATE_ENABLED):
                action = candidate
                break
        except NotImplementedError:
            pass
        node = node.parent
        if node is None:
            break
    if action is None:
        raise RuntimeError(f'No unique native action for {label!r}')
    if not action.doAction(0):
        raise RuntimeError(f'Native action rejected {label!r}')
    time.sleep(.4)


def desktop_chooser_ancestor(node):
    # file_selector_linux constructs GtkFileChooserNative with this title.
    # AT-SPI exposes parent ancestry without relying on window coordinates.
    for _ in range(20):
        if node.getRoleName() in ('dialog', 'file chooser') and node.name == 'Open File':
            return node
        node = node.parent
        if node is None:
            break
    raise RuntimeError('Native Open action has no identifiable Open File chooser ancestor')


def desktop_in_chooser(node):
    try:
        desktop_chooser_ancestor(node)
        return True
    except RuntimeError:
        return False


def desktop_focus_chooser():
    desktop_snapshot()
    node, row = desktop_find('Open', role='push button')
    chooser = desktop_chooser_ancestor(node)
    if sender_process is None or sender_process.poll() is not None:
        raise RuntimeError('Actual Linux sender process is unavailable for chooser focus')
    title = chooser.name
    window_ids = cmd('xdotool', 'search', '--all', '--onlyvisible', '--pid', str(sender_process.pid), '--name', '^' + re.escape(title) + '$', timeout=5).split()
    log('desktop-chooser-window-search', {'sender_pid': sender_process.pid, 'observed_chooser_title': title, 'chooser_role': chooser.getRoleName(), 'window_ids': window_ids})
    if len(window_ids) != 1:
        raise RuntimeError('Expected one visible native chooser window matching sender PID and observed title')
    window_id = window_ids[0]
    actual_title = cmd('xdotool', 'getwindowname', window_id, timeout=5).strip()
    if actual_title != title:
        raise RuntimeError('Native X11 chooser title differs from its observed semantic title')
    log('desktop-chooser-activate', {'window_id': window_id, 'sender_pid': sender_process.pid, 'title': actual_title, 'command': 'xdotool windowactivate --sync'})
    cmd('xdotool', 'windowactivate', '--sync', window_id, timeout=5)
    active_window = cmd('xdotool', 'getactivewindow', timeout=5).strip()
    log('desktop-chooser-focus-result', {'requested_window_id': window_id, 'active_window_id': active_window, 'sender_pid': sender_process.pid, 'title': actual_title})
    if active_window != window_id:
        raise RuntimeError('Native chooser window did not become the active X11 window')
    desktop_snapshot()


def desktop_text(text, chooser_only=False):
    desktop_snapshot()
    fields = [(node, row) for node, row in desktop_nodes() if row['role'] in ('entry', 'text') and node.getState().contains(pyatspi.STATE_EDITABLE)]
    if chooser_only:
        fields = [(node, row) for node, row in fields if desktop_in_chooser(node)]
    if len(fields) != 1:
        raise RuntimeError('Expected one editable desktop field')
    log('desktop-text', {'target': fields[0][1], 'text': text})
    node = fields[0][0]
    accepted = node.queryEditableText().setTextContents(text)
    if accepted is False:
        log('desktop-text-result', {'accepted': accepted, 'current_text': node.queryText().getText(0, -1)})
        raise RuntimeError('Native editable text action rejected the requested content')
    def matches_requested_text():
        current = node.queryText().getText(0, -1)
        log('desktop-text-result', {'accepted': accepted, 'current_text': current})
        return current == text
    until(matches_requested_text, 5)


def android_setting(label, checkable=False):
    root, anchor = android_find(label, scroll=True)
    x1, y1, x2, y2 = bounds(anchor)
    targets = []
    for node in root.iter('node'):
        if node is anchor or node.get('enabled') != 'true' or node.get('clickable') != 'true':
            continue
        if checkable and node.get('checkable') != 'true':
            continue
        a, b, c, d = bounds(node)
        # _SettingsEntry renders a label and control on the same row.
        if max(y1, b) < min(y2, d) and (c <= x1 or a >= x2):
            targets.append(node)
    if anchor.get('clickable') == 'true' and (not checkable or anchor.get('checkable') == 'true'):
        targets.append(anchor)
    if len(targets) != 1:
        raise RuntimeError(f'Cannot identify unique semantic setting control for {label!r}')
    return targets[0]


def android_setting_tap(label, checkable=False):
    node = android_setting(label, checkable)
    x1, y1, x2, y2 = bounds(node)
    log('android-setting-tap', {'label': label, 'target': node.attrib})
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
    time.sleep(.4)


def locale(name, settings, language):
    android_tap(settings)
    android_setting_tap(language)
    android_tap(name, scroll=True)
    android_snapshot()
    log('android-key', 'BACK')
    adb('shell', 'input', 'keyevent', '4')
    time.sleep(.4)


def case(name, quick, arabic, apk):
    global stage
    row = {'case': name, 'delivery': 'pending', 'alignment': 'requires rendered-media review'}
    ledger.append(row)
    write('cases.json', ledger)
    stage = name + '-select-file'
    write(name + '-identities.json', {'receiver_processes': adb('shell', 'ps', '-A'), 'receiver_foreground': adb('shell', 'dumpsys', 'activity', 'activities'), 'host_processes': cmd('ps', '-ef'), 'forward': cmd('adb', 'forward', '--list')})
    fixture = apk.parent / (name + '.apk')
    shutil.copyfile(apk, fixture)
    row['source'] = digest(fixture)
    desktop_tap('Send')
    desktop_tap('File')
    desktop_find('Open', role='push button')
    desktop_focus_chooser()
    log('desktop-key', 'GTK file chooser Ctrl+L')
    cmd('xdotool', 'key', 'ctrl+l')
    time.sleep(.3)
    desktop_text(str(fixture), chooser_only=True)
    desktop_tap('Open', role='push button')
    # Recording precedes manual recipient selection and every request to send.
    stage = name + '-record-before-recipient'
    video = '/sdcard/' + name + '.mp4'
    recording_started_at = time.monotonic()
    recording = spawn(['adb', '-s', serial, 'shell', 'screenrecord', '--time-limit', '180', video], name + '-screenrecord.log')
    desktop_video = spawn(['ffmpeg', '-y', '-f', 'x11grab', '-video_size', '1600x1000', '-framerate', '15', '-i', ':99', '-t', '180', str(OUT / (name + '-desktop.mp4'))], name + '-ffmpeg.log')
    try:
        until(lambda: 'screenrecord' in adb('shell', 'ps', '-A'), 15)
        android_snapshot()
        stage = name + '-manual-recipient'
        desktop_tap('Manual sending')
        desktop_tap('IP Address')
        desktop_text('127.0.0.1')
        desktop_tap('Confirm')
        if not quick:
            stage = name + '-receiver-accept'
            until(lambda: receiver_ready('Accept'), 35)
            android_tap('Accept')
        stage = name + '-completion'
        # UIAutomator waits for idle. The ordinary one-second countdown can
        # prevent it from observing the five-second dialog. Delivery therefore
        # uses stable sender completion and the actual saved bytes, while the
        # continuously recorded rendered frames provide dialog evidence.
        if not quick:
            until(lambda: receiver_ready('Finished'), 120)
            row['receiver_completion_label'] = 'Finished'
            android_snapshot()
        desktop_find('Finished', seconds=120)
        sender_finished_at = time.monotonic()
        desktop_snapshot()
        row['sender_completion_label'] = 'Finished'
        if quick:
            row['dialog_observation'] = 'requires raw video review; no transient semantic gate'
            try:
                (OUT / (name + '-completion-screen.png')).write_bytes(adb('exec-out', 'screencap', '-p', binary=True, timeout=5))
            except Exception as error:
                row['completion_screenshot_error'] = str(error)
        stage = name + '-saved-hash'
        destination = '/sdcard/Download/' + fixture.name
        until(lambda: android_file_exists(destination), 30)
        pulled = OUT / (name + '-saved.apk')
        adb('pull', destination, str(pulled), timeout=90)
        row['receiver'] = digest(pulled)
        if row['receiver'] != row['source']:
            raise RuntimeError('Saved APK hash or byte count mismatch')
        row['receiver_completion_proof'] = 'saved file exists with matching SHA-256 and byte count'
        # Keep recording through the entire ordinary dialog even when a fast
        # transfer and hash check finish sooner. Do not tap a dismissal action.
        if quick:
            time.sleep(max(0, 6 - (time.monotonic() - sender_finished_at)))
        android_snapshot()
        row['delivery'] = 'verified'
        write('cases.json', ledger)
        desktop_tap('Done')
        if not quick:
            android_tap('Done')
    finally:
        primary_error = sys.exc_info()[1]
        cleanup = []
        def retain_step(label, fn):
            try:
                value = fn()
                cleanup.append({'step': label, 'status': 'completed'})
                return value
            except Exception as error:
                cleanup.append({'step': label, 'status': 'failed', 'error': str(error)})
                return None
        # Each operation is independent. A recording may already have reached
        # its native 180-second limit; absent processes must not prevent pulls.
        retain_step('receiver-stop', lambda: subprocess.run(['adb', '-s', serial, 'shell', 'pkill', '-INT', 'screenrecord'], capture_output=True, timeout=15))
        retain_step('receiver-wait', lambda: recording.wait(timeout=15))
        if desktop_video.poll() is None:
            retain_step('desktop-stop', lambda: desktop_video.send_signal(signal.SIGINT))
        retain_step('desktop-wait', lambda: desktop_video.wait(timeout=15))
        receiver_video = OUT / (name + '-receiver.mp4')
        retain_step('receiver-pull', lambda: adb('pull', video, str(receiver_video), timeout=60))
        def probe():
            raw = cmd('ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(receiver_video))
            (OUT / (name + '-video-probe.json')).write_text(raw)
            metadata = json.loads(raw)
            return metadata
        metadata = retain_step('receiver-probe', probe)
        def decode():
            result = subprocess.run(['ffmpeg', '-v', 'warning', '-i', str(receiver_video), '-f', 'null', '-'], capture_output=True, timeout=60)
            (OUT / (name + '-video-decode.txt')).write_bytes(result.stderr)
            if result.returncode:
                raise RuntimeError(f'Full decode failed with exit {result.returncode}')
        retain_step('receiver-decode', decode)
        if metadata is not None and 'sender_finished_at' in locals():
            needed = sender_finished_at - recording_started_at + (5 if quick else 0)
            duration = float(metadata.get('format', {}).get('duration', '0'))
            cleanup.append({'step': 'receiver-video-coverage', 'status': 'completed' if duration >= needed else 'failed', 'needed_seconds': needed, 'recorded_seconds': duration})
        row['recording_cleanup'] = cleanup
        row['primary_failure'] = str(primary_error) if primary_error is not None else None
        write('cases.json', ledger)
        if primary_error is None and any(item['status'] == 'failed' for item in cleanup):
            raise RuntimeError('Recording retention, decode, or coverage failed; inspect recording_cleanup in cases.json')


try:
    stage = 'download-official-release'
    with urllib.request.urlopen('https://api.github.com/repos/localsend/localsend/releases/tags/v1.17.0', timeout=60) as response:
        release = json.load(response)
    write('official-release.json', release)
    assets = release['assets']
    def asset(suffix):
        matches = [a for a in assets if a['name'].endswith(suffix)]
        if len(matches) != 1:
            raise RuntimeError(f'Expected one official release asset {suffix}')
        return matches[0]
    apk = OUT / 'official-android-x64.apk'
    linux = OUT / 'official-linux-x86-64.tar.gz'
    download(asset('android-x64.apk'), apk)
    download(asset('linux-x86-64.tar.gz'), linux)
    stage = 'apk-identity'
    aapt = str(Path(os.environ['ANDROID_HOME']) / 'build-tools/36.0.0/aapt')
    identity = cmd(aapt, 'dump', 'badging', str(apk))
    (OUT / 'apk-badging.txt').write_text(identity)
    if "name='org.localsend.localsend_app'" not in identity or "versionName='1.17.0'" not in identity or "native-code: 'x86_64'" not in identity:
        raise RuntimeError('Official APK package/version/ABI mismatch')
    stage = 'boot-receiver'
    wait_native_adb('transport', ['get-state'], 'device', {'offline', 'unknown'}, 120)
    wait_native_adb('boot-completed', ['shell', 'getprop', 'sys.boot_completed'], '1', {'', '0'}, 240)
    props = adb('shell', 'getprop')
    (OUT / 'receiver-properties.txt').write_text(props)
    if adb('shell', 'getprop', 'ro.build.version.sdk').strip() != '36' or adb('shell', 'getprop', 'ro.product.cpu.abi').strip() != 'x86_64':
        raise RuntimeError('Receiver API/ABI mismatch')
    adb('shell', 'input', 'keyevent', '82')
    original_show_touches = adb('shell', 'settings', 'get', 'system', 'show_touches').strip()
    adb('shell', 'settings', 'put', 'system', 'show_touches', '1')
    adb('install', str(apk), timeout=120)
    installed = adb('shell', 'dumpsys', 'package', PACKAGE)
    (OUT / 'installed-package.txt').write_text(installed)
    if 'versionName=1.17.0' not in installed or 'primaryCpuAbi=x86_64' not in installed:
        raise RuntimeError('Installed receiver version/ABI mismatch')
    adb('shell', 'monkey', '-p', PACKAGE, '-c', 'android.intent.category.LAUNCHER', '1')
    spawn(['adb', '-s', serial, 'logcat', '-v', 'threadtime'], 'receiver-logcat.txt')
    write('receiver-display.json', {k: adb('shell', *args) for k, args in {'size': ['wm', 'size'], 'density': ['wm', 'density'], 'font_scale': ['settings', 'get', 'system', 'font_scale'], 'rotation': ['settings', 'get', 'system', 'user_rotation']}.items()})
    stage = 'launch-linux-sender'
    window_manager = spawn(['openbox', '--sm-disable'], 'openbox.log')
    time.sleep(.5)
    if window_manager.poll() is not None:
        raise RuntimeError('Openbox exited before the Linux sender launched')
    root = OUT / 'linux-release'
    root.mkdir()
    cmd('tar', '-xzf', str(linux), '-C', str(root))
    executables = list(root.rglob('localsend_app'))
    if len(executables) != 1:
        raise RuntimeError('Expected one official Linux executable')
    write('sender-executable.json', {'path': str(executables[0]), **digest(executables[0])})
    cmd('gsettings', 'set', 'org.gnome.desktop.interface', 'toolkit-accessibility', 'true')
    sender_process = spawn([str(executables[0])], 'sender-app.txt')
    if os.environ.get('OBSERVE_2955') == '1':
        stage = 'observe-linux-sender-environment'
        observe_sender_environment()
        if os.environ.get('CONTROL_2955') == '1':
            qualify_sender_input()
        write('result.json', {'stage': stage, 'delivery': 'not attempted', 'observation': 'requires original rendered/native evidence review'})
    else:
        desktop_find('Settings', seconds=60)
        stage = 'stop-sender-server-ui'
        desktop_tap('Settings')
        # Accessible server controls may be below the viewport. Never guess a scroll.
        desktop_tap('Stop')
        desktop_find('Start')
        desktop_snapshot()
        listeners = cmd('ss', '-ltnp')
        (OUT / 'before-forward-listeners.txt').write_text(listeners)
        if re.search(r':53317\s', listeners):
            raise RuntimeError('Sender UI Stop did not free host port 53317')
        adb('forward', 'tcp:53317', 'tcp:53317')
        write('network.json', {'forward': cmd('adb', 'forward', '--list'), 'host_routes': cmd('ip', 'route'), 'receiver_routes': adb('shell', 'ip', 'route'), 'host_listeners': cmd('ss', '-ltnp'), 'sender_identity_deviation': {'alias': '-', 'port': -1, 'https': True}})
        stage = 'receiver-default-settings'
        until(lambda: receiver_ready('Settings'), 40)
        android_tap('Settings')
        # Confirm default Downloads through visible UI; no private settings writes.
        android_find('(Downloads)', scroll=True)
        quick = android_setting('Quick Save', checkable=True)
        if quick.get('checked') != 'false':
            raise RuntimeError('Cannot prove default Quick Save off from current semantics')
        android_tap('Receive')
        stage = 'select-english-baseline-ui'
        locale('English', 'Settings', 'Language')
        android_tap('Receive')
        case('01-english-approval', False, False, apk)
        stage = 'enable-quick-save-ui'
        android_tap('Settings')
        android_setting_tap('Quick Save', checkable=True)
        android_tap('Close')
        android_tap('Settings')
        if android_setting('Quick Save', checkable=True).get('checked') != 'true':
            raise RuntimeError('Quick Save did not become enabled through UI')
        android_tap('Receive')
        case('02-english-quick', True, False, apk)
        stage = 'select-arabic-ui'
        locale('العربية', 'Settings', 'Language')
        android_tap('استلام')
        case('03-arabic-quick', True, True, apk)
        case('04-arabic-quick-repeat', True, True, apk)
        stage = 'return-english-ui'
        locale('English', 'الإعدادات', 'لغة')
        android_tap('Receive')
        case('05-english-return', True, False, apk)
        write('result.json', {'delivery': 'all five verified', 'alignment': 'requires root review of original rendered media', 'stage': stage})
except BaseException as error:
    failure = {'stage': stage, 'error_type': type(error).__name__, 'message': str(error), 'time': time.time()}
    if isinstance(error, subprocess.CalledProcessError):
        failure.update({'command': error.cmd, 'returncode': error.returncode, 'stdout': native_output(error.stdout), 'stderr': native_output(error.stderr)})
    elif isinstance(error, subprocess.TimeoutExpired):
        failure.update({'command': error.cmd, 'timeout': error.timeout, 'stdout': native_output(error.stdout), 'stderr': native_output(error.stderr)})
    write('failure.json', failure)
    write('cases.json', ledger)
    raise
finally:
    if original_show_touches is not None:
        try:
            if original_show_touches == 'null':
                adb('shell', 'settings', 'delete', 'system', 'show_touches')
            else:
                adb('shell', 'settings', 'put', 'system', 'show_touches', original_show_touches)
            write('show-touches-restored.json', {'previous': original_show_touches, 'after': adb('shell', 'settings', 'get', 'system', 'show_touches').strip()})
        except Exception as error:
            write('show-touches-restore-failure.json', {'error': str(error)})
    for name, args in {'receiver-processes.txt': ['adb', '-s', serial, 'shell', 'ps', '-A'], 'foreground-activity.txt': ['adb', '-s', serial, 'shell', 'dumpsys', 'activity', 'activities'], 'host-processes.txt': ['ps', '-ef']}.items():
        try:
            (OUT / name).write_text(cmd(*args))
        except Exception as error:
            (OUT / name).write_text(str(error))
    for proc, stream in reversed(children):
        if proc.poll() is None:
            proc.terminate()
        stream.close()
