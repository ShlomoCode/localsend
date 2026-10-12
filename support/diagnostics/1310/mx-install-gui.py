#!/usr/bin/env python3
"""Cloud live-VM GUI observer/driver for the unmodified MX 23.2 installer.

Run on the live desktop's session bus, AFTER no-argument minstall-launcher.
Requires Debian python3-pyatspi and scrot. Never launches an installer, fabricates
Qt events, supplies configuration, or bypasses authentication. Accessibility
absence is a recorded failure, not permission to switch to a guessed UI path.
Success means observed Installation complete + reboot disabled + Finish closure;
the caller must separately require the original installer's exact Finished log.
"""
import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


class Stop(RuntimeError):
    pass


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence-dir', required=True)
parser.add_argument('--cloud-vm', action='store_true', required=True)
parser.add_argument('--timeout', type=int, default=1080)
args = parser.parse_args()
out = Path(args.evidence_dir)
out.mkdir(parents=True, exist_ok=True)
phase = 'preflight'
sequence = 0
started = time.monotonic()
limit = min(max(args.timeout, 30), 1080)
at = None
observed_app = None
destroyed_branches = 0


def emit(kind, **data):
    record = {'elapsed': round(time.monotonic() - started, 3),
              'phase': phase, 'kind': kind, **data}
    with (out / 'gui-events.jsonl').open('a') as log:
        log.write(json.dumps(record, ensure_ascii=False) + '\n')
    print(json.dumps(record, ensure_ascii=False), flush=True)


def alarm(_signum, _frame):
    raise Stop('bounded overall GUI deadline exceeded')


def clean(value):
    return ' '.join((value or '').replace('&', '').split())


def state(node, flag):
    return node.getState().contains(flag)


def info(node, path):
    role = node.getRoleName()
    text = ''
    try:
        interface = node.queryText()
        text = interface.getText(0, interface.characterCount)
    except NotImplementedError:
        pass
    # Password values must never be written as cleartext evidence.
    if role == 'password text':
        text = '[password text redacted]'
    bounds = None
    try:
        rectangle = node.queryComponent().getExtents(at.DESKTOP_COORDS)
        bounds = [rectangle.x, rectangle.y, rectangle.width, rectangle.height]
    except NotImplementedError:
        pass
    actions = []
    try:
        action = node.queryAction()
        actions = [action.getName(index) for index in range(action.nActions)]
    except NotImplementedError:
        pass
    return {'path': path, 'role': role, 'name': node.name or '',
            'states': [str(item) for item in node.getState().getStates()],
            'text': text, 'bounds': bounds, 'actions': actions,
            'showing': state(node, at.STATE_SHOWING),
            'enabled': state(node, at.STATE_ENABLED)}


def destroyed_object(error):
    # This is the exact transient seen in run 38208883235. Do not suppress
    # timeouts, permission errors, other D-Bus errors, or action failures.
    error_name = getattr(error, '_dbus_error_name', '')
    return error_name == 'org.freedesktop.DBus.Error.UnknownObject' or bool(
        re.search(r'object /org/a11y/atspi/accessible/[0-9]+ does not exist', str(error)))


def scan(root=None, max_depth=35):
    global destroyed_branches
    root = root if root is not None else (observed_app if observed_app is not None else at.Registry.getDesktop(0))
    found = []
    pending = [(root, '0', 0)]
    skipped = 0

    def skip(error, path):
        nonlocal skipped
        global destroyed_branches
        if not destroyed_object(error):
            raise error
        skipped += 1
        destroyed_branches += 1
        emit('destroyed-object-observation', path=path, error=str(error),
             snapshot_skips=skipped, total_skips=destroyed_branches)
        if skipped > 8 or destroyed_branches > 40:
            raise Stop('destroyed-object observation bound exceeded')

    while pending:
        node, path, depth = pending.pop()
        if len(found) >= 2500 or depth > 35:
            raise Stop('accessible tree exceeded observation bound')
        try:
            record = info(node, path)
            child_count = node.childCount if depth < max_depth else 0
        except Exception as error:
            skip(error, path)
            continue
        found.append((node, record))
        for index in reversed(range(child_count)):
            try:
                child = node.getChildAtIndex(index)
            except Exception as error:
                skip(error, path + '.' + str(index))
                continue
            if child is not None:
                pending.append((child, path + '.' + str(index), depth + 1))
    return found


def capture(label, rows=None):
    global sequence
    sequence += 1
    stem = f'{sequence:03d}-{label}'
    # A screenshot is required for each state/action transition. scrot observes
    # the actual desktop; its timeout also prevents a capture blocking the run.
    result = subprocess.run(['scrot', str(out / (stem + '.png'))],
                            capture_output=True, text=True, timeout=8)
    if result.returncode:
        raise Stop('screenshot failed: ' + result.stderr.strip())
    rows = scan() if rows is None and at is not None else rows
    with (out / (stem + '.json')).open('w') as log:
        json.dump([record for _, record in rows or []], log, ensure_ascii=False, indent=2)
    emit('observation', screenshot=stem + '.png', tree=stem + '.json')


def visible(rows):
    return [(node, record) for node, record in rows if record['showing']]


def named(rows, name, roles=None):
    return [(node, record) for node, record in visible(rows)
            if clean(record['name']) == name and
            (roles is None or record['role'] in roles)]


def unique(matches, description):
    if len(matches) != 1:
        raise Stop(f'{description}: expected one observed widget, found {len(matches)}')
    return matches[0][0]


def click(node, description):
    if not state(node, at.STATE_SHOWING) or not state(node, at.STATE_ENABLED):
        raise Stop(description + ': widget is not visible and enabled')
    action = node.queryAction()
    allowed = [index for index in range(action.nActions)
               if clean(action.getName(index)).lower() in ('click', 'press', 'activate', 'toggle')]
    if len(allowed) != 1:
        raise Stop(description + ': ambiguous/missing ordinary accessibility action')
    emit('action', description=description, role=node.getRoleName(), name=node.name,
         accessible_action=action.getName(allowed[0]))
    if not action.doAction(allowed[0]):
        raise Stop(description + ': accessibility action refused')
    time.sleep(.4)
    capture('after-action')


def button(rows, name):
    return unique(named(rows, name, ['push button']), name)


def toggle(rows, name, wanted):
    node = unique(named(rows, name), name)
    if state(node, at.STATE_CHECKED) != wanted:
        click(node, 'set ' + name + ' ' + str(wanted))
    if state(node, at.STATE_CHECKED) != wanted:
        raise Stop(name + ': checked state did not change')
    emit('checked-readback', name=name, checked=state(node, at.STATE_CHECKED))


def field(rows, label):
    # This .ui has no buddy relations for line edits. Prefer actual LABELED_BY
    # evidence; otherwise require a unique entry aligned beside its real label.
    label_node = unique(named(rows, label, ['label']), label)
    entries = [(node, rec) for node, rec in visible(rows)
               if rec['role'] in ('text', 'entry', 'password text')
               and state(node, at.STATE_EDITABLE) and rec['enabled']]
    related = []
    for node, rec in entries:
        for relation in node.getRelationSet():
            if relation.getRelationType() == at.RELATION_LABELLED_BY:
                if any(relation.getTarget(i) == label_node for i in range(relation.getNTargets())):
                    related.append((node, rec))
    if related:
        return unique(related, label + ' labeled entry')
    lb = info(label_node, 'label')['bounds']
    if lb is None:
        raise Stop(label + ': neither label relation nor observed bounds')
    aligned = []
    for node, rec in entries:
        b = rec['bounds']
        if b and b[0] >= lb[0] + lb[2] - 3 and abs(b[1] + b[3]/2 - lb[1] - lb[3]/2) <= 6:
            aligned.append((node, rec))
    return unique(aligned, label + ' geometrically aligned entry')


def edit(node, value, description, secret=False):
    if not state(node, at.STATE_EDITABLE) or not state(node, at.STATE_ENABLED):
        raise Stop(description + ': not an enabled editable text widget')
    emit('edit', description=description, value='[public test password]' if secret else value,
         role=node.getRoleName(), name=node.name)
    if not node.queryEditableText().setTextContents(value):
        raise Stop(description + ': editable text action refused')
    if not secret:
        text = node.queryText()
        if text.getText(0, text.characterCount) != value:
            raise Stop(description + ': text readback differs')
    time.sleep(.2)
    capture('after-edit')


def authentication(rows):
    passwords = [(node, rec) for node, rec in visible(rows) if rec['role'] == 'password text']
    if not passwords:
        return False
    node = unique(passwords, 'authentication password field')
    ancestor = node
    while ancestor is not None and ancestor.getRoleName() not in ('dialog', 'frame'):
        ancestor = ancestor.parent
    if ancestor is None:
        raise Stop('authentication password has no observed window')
    dialog = scan(ancestor)
    text = '\n'.join(rec['name'] + '\n' + rec['text'] for _, rec in visible(dialog))
    identities = set()
    for user in ('demo', 'root'):
        # Identity must be explicit in a label/title or in a password/account
        # prompt, not incidental command paths or the existence of /root.
        exact_label = any(clean(rec['name']).lower() == user for _, rec in visible(dialog))
        explicit = re.search(r'(?:password\s+for|as\s+(?:the\s+)?user|user\s*:|authenticate\s+as|'
                             r'authenticating\s+as)\s*[\"\x27]?'+user+r'\b', text, re.I)
        titled = re.search(r'\b'+user+r'\s+password\b', ancestor.name or '', re.I)
        if exact_label or explicit or titled:
            identities.add(user)
    capture('authentication-identity', dialog)
    if len(identities) != 1:
        raise Stop('authentication account is not explicit and unique in observed dialog')
    user = identities.pop()
    emit('authentication', observed_title=ancestor.name, observed_account=user)
    edit(node, user, 'public live ' + user + ' authentication password', secret=True)
    buttons = [(n, rec) for n, rec in visible(dialog)
               if rec['role'] == 'push button' and clean(rec['name']) in ('Authenticate', 'OK')]
    click(unique(buttons, 'ordinary authentication submit'), 'authenticate observed ' + user)
    return True


def minstall_apps():
    # Application nodes need not report SHOWING. Inspect only the desktop's
    # immediate children, never recursively traverse unrelated desktop apps.
    inventory = scan(at.Registry.getDesktop(0), max_depth=1)
    matches = [(node, rec) for node, rec in inventory
               if rec['role'] == 'application' and rec['name'] == 'minstall']
    if len(matches) > 1:
        raise Stop('multiple observed minstall applications')
    return matches, inventory


def top_windows(app):
    return [(node, rec) for node, rec in visible(scan(app, max_depth=1))
            if rec['path'].count('.') == 1 and rec['role'] in ('dialog', 'frame')]


def run():
    global at, phase, observed_app
    if sys.platform != 'linux' or not args.cloud_vm:
        raise Stop('cloud Linux live VM required')
    mounts = Path('/proc/mounts').read_text()
    if not re.search(r'^overlay /live/aufs ', mounts, re.M) or not Path('/dev/vda').exists():
        raise Stop('expected disposable cloud live overlay and vda absent')
    import pyatspi
    at = pyatspi
    signal.signal(signal.SIGALRM, alarm)
    signal.alarm(30)
    phase = 'launcher-authentication'
    authenticated = False
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        apps, inventory = minstall_apps()
        if apps:
            observed_app = apps[0][0]
            windows = top_windows(observed_app)
            capture('observed-minstall', scan(observed_app))
            if windows:
                root = unique(windows, 'observed minstall top-level window')
                emit('installer-identity', application=apps[0][1], window=windows[0][1],
                     shell_root_process_gate_required=True)
                break
            time.sleep(.5)
            continue
        rows = scan(at.Registry.getDesktop(0))
        capture('launcher-wait', rows)
        if authenticated and any(rec['role'] == 'password text' for _, rec in visible(rows)):
            raise Stop('authentication dialog appeared again after submission')
        if authentication(rows):
            authenticated = True
        time.sleep(1)
    else:
        raise Stop('no accessible original installer within 30 seconds')
    if not authenticated:
        # A native policy or cached authentication may legitimately show no
        # prompt. The caller records the unchanged launcher and actual root
        # process credentials; do not invent an authentication dialog.
        emit('authentication-not-prompted', observed_installer_title=root.name,
             shell_root_process_gate_required=True)
    signal.alarm(max(1, int(limit - (time.monotonic() - started))))

    def page(name, timeout=30):
        global phase
        phase = name
        until = min(started + limit, time.monotonic() + timeout)
        last_capture = 0
        while time.monotonic() < until:
            observed = scan(root)
            if named(observed, name):
                capture('page', observed)
                return observed
            if time.monotonic() - last_capture >= 10:
                capture('page-transition', observed)
                last_capture = time.monotonic()
            # Only bounded transition time; no action on an unknown state.
            time.sleep(.5)
        capture('unexpected-page')
        raise Stop('expected page not observed: ' + name)

    # The unchanged launcher retains the normal initial ISO media check.
    rows = page('Terms of Use', 180)
    click(button(rows, 'Next'), 'terms Next')
    rows = page('Select type of installation')
    toggle(rows, 'Regular install using the entire disk', True)
    rows = scan(root)
    combos = [(n, rec) for n, rec in visible(rows) if rec['role'] == 'combo box']
    combo = unique(combos, 'entire-disk selection')
    disk = scan(combo)
    selected = [rec for n, rec in disk if state(n, at.STATE_SELECTED)]
    identity = '\n'.join(rec['name'] + ' ' + rec['text'] for _, rec in disk
                         if rec['showing'] or rec in selected)
    if not re.search(r'\bvda\b', identity) or re.search(r'\b(?:sda|sdb|vdb|nvme\w*)\b', identity):
        raise Stop('observed current disk is not uniquely vda: ' + identity)
    slider = unique([(n, rec) for n, rec in visible(rows) if rec['role'] == 'slider'], 'root/home slider')
    value = slider.queryValue()
    if value.maximumValue != 100:
        raise Stop('root/home slider does not expose source maximum 100')
    emit('action', description='root/home slider allocation', observed_previous=value.currentValue, wanted=100)
    value.currentValue = 100
    if value.currentValue != 100:
        raise Stop('root allocation is not observed as 100 percent')
    capture('root100')
    toggle(scan(root), 'Encrypt', False)
    click(button(scan(root), 'Next'), 'disk Next')
    phase = 'confirmation'
    until = time.monotonic() + 30
    while time.monotonic() < until:
        rows = scan(root)
        if named(rows, 'Start', ['push button']):
            break
        time.sleep(.5)
    else:
        raise Stop('real confirmation Start not observed')
    capture('confirmation', rows)
    # Source-generated confirmation item must identify the destructive scope.
    confirmation = [rec['name'] + ' ' + rec['text'] for _, rec in visible(rows)
                    if rec['role'] in ('list item', 'label', 'text')]
    if not any(re.search(r'Format and use the entire disk \(vda\)', text) for text in confirmation):
        raise Stop('real confirmation does not explicitly identify entire vda')
    click(button(rows, 'Start'), 'confirm entire vda Start')
    rows = page('Computer Network Names', 60)
    for label, value in [('Computer name:', 'mx1310'), ('Computer domain:', 'localdomain'), ('Workgroup:', 'WORKGROUP')]:
        edit(field(scan(root), label), value, label)
    click(button(scan(root), 'Next'), 'network Next')
    rows = page('Localization Defaults')
    click(button(rows, 'Next'), 'preserve observed localization defaults Next')
    rows = page('Default User Account')
    edit(field(rows, 'Default user login name:'), 'issue1310', 'default user')
    for label in ('Default user password:', 'Confirm user password:'):
        edit(field(scan(root), label), 'demo', label, secret=True)
    toggle(scan(root), 'Root (administrator) Account', True)
    for label in ('Root password:', 'Confirm root password:'):
        edit(field(scan(root), label), 'demo', label, secret=True)
    toggle(scan(root), 'Autologin', True)
    toggle(scan(root), 'Save live desktop changes', False)
    capture('user-account-configured')
    click(button(scan(root), 'Next'), 'user accounts Next')
    phase = 'installation-progress'
    # End page is sufficient positive GUI completion evidence, but does not
    # replace the caller's mandatory independent ++ Finished ++ log gate.
    last_capture = 0
    while time.monotonic() - started < limit:
        rows = scan(root)
        if named(rows, 'Installation complete') and named(rows, 'Finish', ['push button']):
            break
        dialogs = [(n, rec) for n, rec in visible(scan(observed_app))
                   if rec['role'] == 'dialog' and n != root]
        if dialogs:
            capture('unexpected-modal')
            raise Stop('unexpected dialog during installation; no guessed dismissal')
        if not named(rows, 'Installation in progress'):
            capture('unexpected-progress')
            raise Stop('unexpected page after user accounts')
        if time.monotonic() - last_capture >= 10:
            capture('progress', rows)
            last_capture = time.monotonic()
        time.sleep(1)
    else:
        raise Stop('installation did not reach real End page within deadline')
    phase = 'installation-complete'
    capture('positive-end-page', rows)
    toggle(rows, 'Automatically reboot the system when the installer is closed', False)
    capture('reboot-disabled')
    click(button(scan(root), 'Finish'), 'actual Finish')
    until = time.monotonic() + 10
    clean_closed_observations = 0
    while time.monotonic() < until:
        previous_skips = destroyed_branches
        apps, inventory = minstall_apps()
        windows = top_windows(apps[0][0]) if apps else []
        if len(windows) > 1:
            raise Stop('ambiguous minstall windows after Finish')
        # A skipped destroyed object alone cannot prove closure. Require two
        # consecutive clean observations of app absence or no visible window.
        if not windows and previous_skips == destroyed_branches:
            clean_closed_observations += 1
        else:
            clean_closed_observations = 0
        if clean_closed_observations >= 2:
            capture('finish-closed', inventory)
            emit('GUIFinished', shell_finished_gate_still_required=True)
            (out / 'GUIFinished').write_text('Observed End, reboot disabled, Finish, window closed.\n')
            return
        time.sleep(.5)
    raise Stop('installer window did not close after actual Finish')


try:
    run()
except BaseException as error:
    # Write FailedPhase before attempting any additional evidence; even missing
    # dependencies or a blocked screenshot must leave immediate failure status.
    (out / 'FailedPhase').write_text(phase + ': ' + str(error) + '\n')
    emit('FailedPhase', error=str(error), exception=type(error).__name__)
    try:
        signal.signal(signal.SIGALRM, alarm)
        signal.alarm(10)
        capture('failure')
    except BaseException as capture_error:
        emit('failure-capture-error', error=str(capture_error))
    sys.exit(1)
finally:
    signal.alarm(0)
