"""Cloud-only native GUI driver. Missing accessibility is a setup failure."""
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
import pyatspi

OUT = Path('evidence')
PID = int(os.environ['ISSUE_1982_SENDER_PID'])
STAGES = ('qualification', 'ordinary', 'picker')
FIXTURES = Path('/tmp/issue-1982')
FIXTURES.mkdir(exist_ok=True)
SEED = os.environ['GITHUB_RUN_ID'] + '-' + os.environ.get('GITHUB_RUN_ATTEMPT', '1')
CONTENT = ('LocalSend issue 1982 unchanged real app control\nRun: ' + SEED + '\n').encode()
started = time.monotonic()
counter = 0

def stamp():
    return {'utc': datetime.now(timezone.utc).isoformat(), 'monotonicSeconds': time.monotonic()}

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def identity():
    os.kill(PID, 0)
    stat = Path('/proc/' + str(PID) + '/stat').read_text()
    start_ticks = stat.rsplit(')', 1)[1].split()[19]
    if start_ticks != os.environ['ISSUE_1982_SENDER_START_TICKS']:
        raise RuntimeError('Original sender PID was reused')
    active = command('xdotool', 'getactivewindow')
    active_pid = int(command('xdotool', 'getwindowpid', active))
    if active_pid != PID:
        raise RuntimeError('Foreground window does not belong to original LocalSend PID')
    return {'pid': PID, 'startTicks': start_ticks, 'window': active, 'title': command('xdotool', 'getwindowname', active), **stamp()}

def walk(node):
    yield node
    for i in range(node.childCount):
        yield from walk(node.getChildAtIndex(i))

def tree():
    apps = [a for a in pyatspi.Registry.getDesktop(0) if a.get_process_id() == PID]
    if len(apps) != 1:
        raise RuntimeError('Original LocalSend AT-SPI application is absent or ambiguous')
    return list(walk(apps[0]))

def visible(node):
    state = node.getState()
    return state.contains(pyatspi.STATE_SHOWING) and state.contains(pyatspi.STATE_ENABLED)

def snapshot(stage):
    global counter
    counter += 1
    prefix = OUT / ('1982-desktop-' + stage + '-' + str(counter))
    subprocess.check_call(['scrot', str(prefix) + '.png'])
    records = []
    for node in tree():
        try:
            rect = list(node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS))
        except NotImplementedError:
            rect = None
        records.append({'name': node.name, 'role': node.getRoleName(), 'visibleEnabled': visible(node), 'rect': rect})
    prefix.with_suffix('.json').write_text(json.dumps({'identity': identity(), 'nodes': records}, indent=2))
    return records

def find(name, roles=None, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        identity()
        matches = [n for n in tree() if n.name == name and visible(n) and (roles is None or n.getRoleName() in roles)]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RuntimeError('Ambiguous native control: ' + name)
        time.sleep(0.2)
    snapshot('missing-' + name.replace(' ', '-'))
    raise RuntimeError('Native semantic control missing: ' + name)

def act(name, stage, timeout=8):
    node = find(name, timeout=timeout)
    snapshot(stage)
    identity()
    # Re-query after capture rather than input through an old accessible object.
    node = find(name, timeout=1)
    action = node.queryAction()
    actions = [i for i in range(action.nActions) if action.getName(i).lower() in ('click', 'press', 'activate')]
    if len(actions) != 1:
        raise RuntimeError('No unambiguous native activation action: ' + name)
    print(json.dumps({'action': name, 'nativeAction': action.getName(actions[0]), **identity(), **stamp()}), flush=True)
    if not action.doAction(actions[0]):
        raise RuntimeError('Native activation rejected: ' + name)

def wait_marker(name, timeout=120, observe=False):
    deadline = min(started + 25 * 60, time.monotonic() + timeout)
    last_snapshot = 0
    while not (OUT / name).exists():
        os.kill(PID, 0)
        if (OUT / '1982-abort').exists() and not (OUT / name).exists():
            raise RuntimeError('Controller stopped scenario; preserve original applications')
        if time.monotonic() >= deadline:
            raise RuntimeError('Controller marker deadline: ' + name)
        if observe and time.monotonic() - last_snapshot >= 2:
            snapshot(name + '-pending')
            last_snapshot = time.monotonic()
        time.sleep(0.1)

# Qualify and activate only the uniquely observed original LocalSend window.
deadline = time.monotonic() + 40
while True:
    os.kill(PID, 0)
    lookup = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(PID)], text=True, capture_output=True)
    if lookup.returncode not in (0, 1):
        raise RuntimeError('Native window inventory failed: ' + lookup.stderr)
    windows = lookup.stdout.strip().splitlines()
    windows = [w for w in windows if command('xdotool', 'getwindowname', w) == 'LocalSend']
    if len(windows) == 1:
        subprocess.check_call(['xdotool', 'windowactivate', '--sync', windows[0]])
        break
    if time.monotonic() >= deadline:
        raise RuntimeError('Original LocalSend window qualification failed')
    time.sleep(0.2)
snapshot('ready')
# c1ce Settings uses the Stop tooltip on the real server control. This frees
# the default sender port for transparent forwarding without changing the PID.
act('Settings', 'settings')
act('Stop', 'normal-server-stop')
find('Server (Offline)')
snapshot('server-stopped')
(OUT / '1982-desktop-stopped').touch()
wait_marker('transport-ready', 60)

for stage in STAGES:
    wait_marker('1982-' + stage + '-go', 120)
    if stage != 'qualification':
        act('Done', stage + '-previous-done')
    act('Send', stage + '-send-tab')
    fixture = FIXTURES / ('issue1982-' + SEED + '-' + stage + '.txt')
    fixture.write_bytes(CONTENT)
    (OUT / ('1982-' + stage + '-input.json')).write_text(json.dumps({'path': str(fixture), 'name': fixture.name, 'bytes': len(CONTENT)}, indent=2))
    act('File', stage + '-file-picker')
    # The native GTK chooser must have an accessible Open action owned by PID.
    find('Open')
    snapshot(stage + '-native-file-picker')
    identity()
    subprocess.check_call(['xdotool', 'key', '--clearmodifiers', 'ctrl+l'])
    identity()
    subprocess.check_call(['xdotool', 'type', '--clearmodifiers', str(fixture)])
    identity()
    subprocess.check_call(['xdotool', 'key', 'Return'])
    act('Open', stage + '-native-open')
    find(fixture.name)
    snapshot(stage + '-selected')
    act('Manual sending', stage + '-manual-send')
    act('IP Address', stage + '-ip-mode')
    identity()
    # Verify a unique visible editable text field in the fresh native tree.
    fields = [n for n in tree() if visible(n) and n.getRoleName() in ('text', 'entry') and n.getState().contains(pyatspi.STATE_EDITABLE)]
    if len(fields) != 1:
        raise RuntimeError('Address dialog editable field absent or ambiguous')
    if not fields[0].queryEditableText().setTextContents('127.0.0.1'):
        raise RuntimeError('Native address entry failed')
    act('Confirm', stage + '-submit')
    (OUT / ('1982-' + stage + '-requested')).touch()
    wait_marker('1982-' + stage + '-observe', 90, observe=True)
    observation_error = None
    try:
        rows = snapshot(stage + '-outcome')
        names = [r['name'] for r in rows if r['visibleEnabled']]
        endpoint_identity = identity()
    except Exception as error:
        observation_error = str(error)
        names = []
        endpoint_identity = {'pid': PID, 'startTicks': os.environ['ISSUE_1982_SENDER_START_TICKS'], 'unavailable': observation_error}
    error = any('Error' in n or 'Finished with error' in n for n in names)
    finished = any('Finished' in n for n in names) and any(fixture.name in n and 'Done' in n for n in names)
    result = {'stage': stage, 'senderError': error, 'senderFinished': finished, 'observationError': observation_error, 'identity': endpoint_identity, 'visibleNames': names, **stamp()}
    (OUT / ('1982-' + stage + '-sender-result.json')).write_text(json.dumps(result, indent=2))
    if not finished or error:
        raise RuntimeError('Actual desktop outcome failed; preserve raw native tree and pixels')
    (OUT / ('1982-' + stage + '-sender-completed')).touch()

wait_marker('1982-final-cleanup', 120)
