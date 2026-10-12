#!/usr/bin/env python3
"""Private finite original-session proposal; public DisplayConfig and read-only oracle."""
import configparser
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from gi.repository import Gio, GLib

DEST = 'org.gnome.Mutter.DisplayConfig'
OBJECT = '/org/gnome/Mutter/DisplayConfig'
IFACE = DEST
STATE_TYPE = '(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})'
CONFIG_TYPE = '(uua(iiduba(ssa{sv}))a{sv})'
# Fresh process identity is observed and persisted in this session.
EXPECTED = {}
CALL_MS = 2000
OUT = Path(sys.argv[2])
COUNT = 0
BUS = None
OWNER = None
CLEANUP = False
CLEANUP_LOG_ERRORS = []

def receipt(name, value):
    try:
        path = OUT / name
        temporary = path.with_name(path.name + '.writing')
        with temporary.open('x') as file:
            json.dump(value, file, sort_keys=True, indent=2)
            file.write('\n')
            file.flush()
            os.fsync(file.fileno())
        # Publish a complete immutable receipt atomically; readers never see
        # partial JSON. Linking fails if the final receipt already exists.
        os.link(temporary, path)
        temporary.unlink()
        return True
    except Exception as error:
        if not CLEANUP:
            raise
        CLEANUP_LOG_ERRORS.append({'receipt': name, 'error': str(error)})
        return False

def event(name, **values):
    try:
        print(json.dumps({'event': name, 'monotonic': time.monotonic(),
                          'wallNs': time.time_ns(), **values}, sort_keys=True), flush=True)
    except Exception as error:
        if not CLEANUP:
            raise
        CLEANUP_LOG_ERRORS.append({'event': name, 'error': str(error)})

def start(pid):
    raw = Path(f'/proc/{pid}/stat').read_text()
    fields = raw.rsplit(') ', 1)[1].split()
    if len(fields) < 20 or (pid in EXPECTED and fields[19] != EXPECTED[pid]):
        raise ValueError(f'PID/start mismatch: {pid}')
    return {'pid': pid, 'startTicks': fields[19], 'stat': raw,
            'exe': os.readlink(f'/proc/{pid}/exe')}

def call(destination, path, interface, method, parameters, result_type):
    global COUNT
    COUNT += 1
    prefix = f'{sys.argv[1]}-{os.getpid()}-{COUNT:03d}-{method}'
    receipt(prefix + '-request.json', {'destination': destination, 'path': path,
            'interface': interface, 'method': method, 'timeoutMs': CALL_MS,
            'parametersType': parameters.get_type_string() if parameters else None,
            'parametersText': parameters.print_(True) if parameters else None,
            'monotonicStart': time.monotonic()})
    event('call-start', method=method, receipt=prefix)
    try:
        reply = BUS.call_sync(destination, path, interface, method, parameters,
            GLib.VariantType.new(result_type) if result_type else None,
            Gio.DBusCallFlags.NO_AUTO_START, CALL_MS, None)
        receipt(prefix + '-reply.json', {'type': reply.get_type_string(),
                'text': reply.print_(True), 'value': reply.unpack(),
                'monotonicEnd': time.monotonic(), 'exitStatus': 0})
        event('call-end', method=method, receipt=prefix, exitStatus=0)
        return reply
    except Exception as error:
        receipt(prefix + '-error.json', {'error': str(error),
                'monotonicEnd': time.monotonic(), 'exitStatus': 1})
        event('call-end', method=method, receipt=prefix, exitStatus=1, error=str(error))
        raise

def daemon(method, parameters, reply_type):
    return call('org.freedesktop.DBus', '/org/freedesktop/DBus',
                'org.freedesktop.DBus', method, parameters, reply_type)

def identity():
    names = []
    for name in (DEST, 'org.gnome.Shell'):
        names.append(daemon('GetNameOwner', GLib.Variant('(s)', (name,)), '(s)').unpack()[0])
    if names[0] != names[1] or not names[0].startswith(':'):
        raise ValueError('DisplayConfig is not owned by the same unique Shell connection')
    pid = daemon('GetConnectionUnixProcessID', GLib.Variant('(s)', (names[0],)), '(u)').unpack()[0]
    process = start(pid)
    if not process['exe'].endswith('/gnome-shell'):
        raise ValueError('Unexpected Shell executable')
    return {'owner': names[0], 'pid': pid, 'startTicks': process['startTicks'], 'process': process}

def same_owner(expected):
    current = identity()
    if current['owner'] != expected['owner'] or current['pid'] != expected['pid'] or current['startTicks'] != expected['startTicks']:
        raise ValueError('Shell owner/process changed; do not mutate the replacement session')
    return current

def allowed():
    value = call(OWNER, OBJECT, 'org.freedesktop.DBus.Properties', 'Get',
                 GLib.Variant('(ss)', (IFACE, 'ApplyMonitorsConfigAllowed')), '(v)').unpack()[0]
    if value is not True:
        raise ValueError('ApplyMonitorsConfigAllowed is not true')

def state():
    return call(OWNER, OBJECT, IFACE, 'GetCurrentState', None, STATE_TYPE)

def configuration(reply, target=False):
    serial, physical, logical, properties = reply.unpack()
    if len(physical) != 1 or len(logical) != 1:
        raise ValueError('Only one connected and one logical monitor are supported')
    spec, modes, monitor_props = physical[0]
    x, y, scale, transform, primary, specs, logical_props = logical[0]
    if list(specs) != [spec] or logical_props or monitor_props.get('is-for-lease', False):
        raise ValueError('Ambiguous monitor assignment/properties or leased monitor')
    if (x, y, scale, transform, primary) != (0, 0, 1.0, 0, True):
        raise ValueError('This qualification requires the actual ordinary origin0 scale1 transform0 primary layout')
    current = [mode for mode in modes if mode[6].get('is-current', False)]
    if len(current) != 1:
        raise ValueError('Expected one current physical mode')
    # PyGObject unpacking may return tuple or list; compare dimensions explicitly.
    candidates = [mode for mode in modes if mode[1] == 800 and mode[2] == 600 and 1.0 in mode[5]]
    if target and len(candidates) != 1:
        raise ValueError('800x600 scale1 mode is unavailable or ambiguous')
    mode = candidates[0] if target else current[0]
    per_monitor = {}
    if 'is-underscanning' in monitor_props:
        per_monitor['underscanning'] = GLib.Variant('b', monitor_props['is-underscanning'])
    if 'color-mode' in monitor_props:
        per_monitor['color-mode'] = GLib.Variant('u', monitor_props['color-mode'])
    elif monitor_props.get('supported-color-modes') not in (None, [], [0], (0,)):
        raise ValueError('Color mode cannot be reconstructed')
    global_props = {}
    if properties.get('supports-changing-layout-mode', False):
        if properties.get('layout-mode') not in (1, 2):
            raise ValueError('Invalid saved layout mode')
        global_props['layout-mode'] = GLib.Variant('u', properties['layout-mode'])
    elif properties.get('layout-mode', 1) != 1:
        raise ValueError('Unsupported unchangeable layout mode')
    logical_config = [(x, y, scale, transform, primary, [(spec[0], mode[0], per_monitor)])]
    return serial, logical_config, global_props

def apply(reply, target, method):
    if method not in (0, 1):
        raise ValueError('Persistent method2 is forbidden')
    serial, logical, properties = configuration(reply, target)
    call(OWNER, OBJECT, IFACE, 'ApplyMonitorsConfig',
         GLib.Variant(CONFIG_TYPE, (serial, method, logical, properties)), '()')

def snapshot():
    raw = call(OWNER, '/org/localsend/Diagnostics/Geometry',
               'org.localsend.Diagnostics.Geometry', 'Snapshot', None, '(s)').unpack()[0]
    value = json.loads(raw)
    if value.get('schema') != 1 or value.get('shellVersion') != '48.7':
        raise ValueError('Unexpected existing oracle version/schema')
    if value['compositorWayland'] != {'value': True, 'error': None}:
        raise ValueError('Actual Wayland compositor is unavailable')
    if value['shellThemeScaleFactor'] != {'value': 1, 'error': None}:
        raise ValueError('Actual Shell theme scale is not1')
    return value

def settings():
    result = {}
    for schema in ('org.gnome.desktop.a11y.applications', 'org.gnome.desktop.a11y.magnifier'):
        s = Gio.Settings.new(schema)
        result[schema] = {}
        for key in sorted(s.list_keys()):
            user = s.get_user_value(key)
            result[schema][key] = {'effective': s.get_value(key).print_(True),
                                   'user': user.print_(True) if user is not None else None}
    return result


def baseline():
    return json.loads((OUT / 'baseline.json').read_text())

def prepare():
    global OWNER
    OUT.mkdir(mode=0o700)
    ident = identity()
    OWNER = ident['owner']
    allowed()
    original = state()
    configuration(original)
    configuration(original, True)
    image = snapshot()
    zoom = Gio.Settings.new('org.gnome.desktop.a11y.applications')
    if zoom.get_boolean('screen-magnifier-enabled') or not zoom.is_writable('screen-magnifier-enabled'):
        raise ValueError('Fresh Zoom-off/writable baseline required')
    same_owner(ident)
    receipt('baseline.json', {'identity': ident, 'stateType': original.get_type_string(),
        'stateText': original.print_(True), 'state': original.unpack(),
        'settings': settings(), 'snapshot': image,
        'applyStop': time.monotonic() + 200, 'fallbackDue': time.monotonic() + 270})

def apply800():
    global OWNER
    saved = baseline()
    OWNER = saved['identity']['owner']
    same_owner(saved['identity'])
    allowed()
    current = state()
    if json.dumps(current.unpack()[1:], sort_keys=True) != json.dumps(saved['state'][1:], sort_keys=True):
        raise ValueError('Display changed since baseline')
    apply(current, True, 0)
    current = state()
    same_owner(saved['identity'])
    # Admission is immediately before the only temporary mutating call.
    if time.monotonic() + 3 >= saved['applyStop']:
        raise TimeoutError('Display input budget closed')
    apply(current, True, 1)
    actual = state()
    image = snapshot()
    if image['stageSize'] != {'width': 800, 'height': 600}:
        raise ValueError('Fresh actual800 stage unavailable')
    receipt('applied.json', {'state': actual.unpack(), 'snapshot': image})

def restore():
    global OWNER, CLEANUP
    CLEANUP = True
    saved = baseline()
    OWNER = saved['identity']['owner']
    outcome = {'zoomRestoration': 'failed', 'monitorRestoration': 'failed', 'baselineIdentity': saved['identity']}
    # Try both restorations independently; failed receipt writes cannot veto calls.
    try:
        same_owner(saved['identity'])
        zoom = Gio.Settings.new('org.gnome.desktop.a11y.applications')
        before = saved['settings']['org.gnome.desktop.a11y.applications']['screen-magnifier-enabled']
        if before['user'] is None:
            zoom.reset('screen-magnifier-enabled')
        elif not zoom.set_boolean('screen-magnifier-enabled', before['user'] == 'true'):
            raise ValueError('Zoom restore rejected')
        Gio.Settings.sync()
        actual = settings()
        outcome['actualSettings'] = actual
        if actual != saved['settings']:
            raise ValueError('Effective/user settings differ from saved baseline')
        same_owner(saved['identity'])
        outcome['zoomRestoration'] = 'complete'
    except Exception as error:
        outcome['zoomError'] = str(error)
    try:
        same_owner(saved['identity'])
        allowed()
        original = GLib.Variant.parse(GLib.VariantType.new(saved['stateType']), saved['stateText'], None, None)
        _, logical, props = configuration(original)
        current = state()
        call(OWNER, OBJECT, IFACE, 'ApplyMonitorsConfig', GLib.Variant(CONFIG_TYPE,
            (current.unpack()[0], 0, logical, props)), '()')
        current = state()
        same_owner(saved['identity'])
        call(OWNER, OBJECT, IFACE, 'ApplyMonitorsConfig', GLib.Variant(CONFIG_TYPE,
            (current.unpack()[0], 1, logical, props)), '()')
        after = state()
        outcome['actualState'] = after.unpack()
        if json.dumps(after.unpack()[1:], sort_keys=True) != json.dumps(saved['state'][1:], sort_keys=True):
            raise ValueError('Full saved display state differs excluding serial')
        same_owner(saved['identity'])
        outcome['monitorRestoration'] = 'complete'
    except Exception as error:
        outcome['monitorError'] = str(error)
    try:
        outcome['residualSnapshot'] = snapshot()
        outcome['layoutRestoration'] = 'not-asserted-residual-windows-retained'
    except Exception as error:
        outcome['snapshotError'] = str(error)
    outcome['cleanupLoggingErrors'] = CLEANUP_LOG_ERRORS
    recorded = receipt('restore-completed.json', outcome)
    if not recorded or outcome['zoomRestoration'] != 'complete' or outcome['monitorRestoration'] != 'complete' or CLEANUP_LOG_ERRORS:
        raise ValueError('Cleanup incomplete; inspect actual receipt')

def qualify():
    global OWNER
    saved = baseline()
    OWNER = saved['identity']['owner']
    same_owner(saved['identity'])
    image = snapshot()
    focused = [w for w in image['windows'] if w['compositorFocused']['value'] is True]
    if len(focused) != 1:
        raise ValueError('Exactly one observed focused window required')
    window = focused[0]
    mode = sys.argv[1]
    path = OUT / ('editor-identity.json' if mode == 'editor' else 'app-identity.json')
    if mode == 'editor':
        process = start(window['pid']['value'])
        if not process['exe'].endswith('/gnome-text-editor') or window['gtkApplicationId']['value'] != 'org.gnome.TextEditor':
            raise ValueError('Expected fresh focused GTK editor')
        receipt(path.name, {'process': process, 'window': window})
        return
    # Retain each raw identity observation before later qualification can fail.
    # This is a compositor window/PID observation, not a process-name lookup.
    prefix = f'{mode}-{os.getpid()}-identity-'
    receipt(prefix + 'focused-window.json', window)
    pid = window['pid']['value']
    if window['pid']['error'] is not None or type(pid) is not int or pid <= 0:
        raise ValueError('Focused host PID unavailable')
    raw_stat = Path(f'/proc/{pid}/stat').read_text()
    receipt(prefix + 'stat-before.json', {'pid': pid, 'stat': raw_stat})
    process = start(pid)
    receipt(prefix + 'process-before.json', process)
    info = Path(f'/proc/{pid}/root/.flatpak-info').read_text()
    receipt(prefix + 'flatpak-info.json', {'pid': pid, 'text': info})
    digest = hashlib.sha256(Path(f'/proc/{pid}/exe').read_bytes()).hexdigest()
    receipt(prefix + 'executable-hash.json', {'pid': pid, 'sha256': digest})
    after = start(pid)
    receipt(prefix + 'process-after.json', after)
    app_windows = [w for w in image['windows']
        if w['gtkApplicationId']['error'] is None and w['gtkApplicationId']['value'] == 'org.localsend.localsend_app']
    if len(app_windows) != 1 or app_windows[0] != window:
        raise ValueError('Expected exactly one compositor LocalSend window owning focus')
    if window['compositorFocused']['error'] is not None or window['stableSequence']['error'] is not None or window['stableSequence']['value'] is None:
        raise ValueError('Focused window identity unavailable')
    initial_ticks = raw_stat.rsplit(') ', 1)[1].split()[19]
    if initial_ticks != process['startTicks'] or after['startTicks'] != process['startTicks'] or after['exe'] != process['exe']:
        raise ValueError('App changed during qualification')
    metadata = configparser.ConfigParser(interpolation=None)
    metadata.read_string(info)
    if metadata.get('Application', 'name') != 'org.localsend.localsend_app' or metadata.get('Instance', 'app-commit') != 'df68d5e6649a894643f4bff68711e52ad86c2f26c93470139f2ff1e2b38e4418' or metadata.get('Instance', 'runtime-commit') != 'd27f7a6a974e40b061070bec1be9e1b52a7a6872b271e6a45c2c34a48bf6fedf':
        raise ValueError('Fresh namespace does not match original app/runtime commits')
    actual = {'process': process, 'flatpakInfo': info, 'instanceId': metadata.get('Instance', 'instance-id'),
        'exeSHA256': digest, 'window': window, 'stageSize': image['stageSize']}
    if mode == 'app-check':
        before = json.loads(path.read_text())
        for field in ('pid', 'startTicks', 'exe'):
            if before['process'][field] != process[field]:
                raise ValueError('Original app process changed')
        if before['instanceId'] != actual['instanceId'] or before['exeSHA256'] != actual['exeSHA256']:
            raise ValueError('Original namespace/executable changed')
        event('fresh-app-identity-checked', actual=actual)
    else:
        receipt(path.name, actual)

BUS = Gio.bus_get_sync(Gio.BusType.SESSION, None)
try:
    {'prepare': prepare, 'apply': apply800, 'restore': restore, 'editor': qualify, 'app': qualify, 'app-check': qualify}[sys.argv[1]]()
except Exception as error:
    event('operation-failed', error=str(error))
    sys.exit(1)
