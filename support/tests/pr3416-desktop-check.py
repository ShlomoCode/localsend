#!/usr/bin/env python3
"""Assert GNOME's native Wayland dock icon from Shell's live window tracker.

Usage: pr3416-desktop-check.py ready
       pr3416-desktop-check.py CASE matched|generic [EXECUTABLE [WM_CLASS]]

The caller installs the .desktop entry and chooses the executable. Controlled
bundles can all be copied to the same executable path before each invocation.
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import dbus
from PIL import Image


OUTPUT = Path('/opt/pr3416/evidence')
OUTPUT.mkdir(parents=True, exist_ok=True)
BUS = dbus.SessionBus()
EXPECTED_DESKTOP_ID = 'localsend_app.desktop'


def wait_for(check, description, timeout=90):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (AssertionError, dbus.DBusException, OSError) as error:
            last_error = error
        time.sleep(1)
    raise RuntimeError(f'Timed out waiting for {description}: {last_error}')


def probe():
    obj = BUS.get_object('org.localsend.DockProbe', '/org/localsend/DockProbe')
    return dbus.Interface(obj, 'org.localsend.DockProbe')


def inspect():
    return json.loads(str(probe().Inspect(timeout=30)))


def snapshot(name):
    data = inspect()
    (OUTPUT / f'{name}-desktop.json').write_text(json.dumps(data, indent=2) + '\n')
    filename = OUTPUT / f'{name}-full.png'
    captured = str(probe().Capture(str(filename), timeout=90))
    assert captured == str(filename) and filename.stat().st_size > 1000, captured
    with Image.open(filename) as image:
        assert image.format == 'PNG' and image.width >= 800 and image.height >= 600
    return data


def local_window(data):
    matches = [window for window in data['windows']
               if 'localsend' in ''.join((window['title'] or '', window['wmClass'] or '',
                                          window['appId'] or '')).lower()]
    # A second LocalSend window would make the dock identity ambiguous.
    assert len(matches) <= 1, matches
    return matches[0] if matches else None


def dock_icon(data, app_id):
    icons = [actor for actor in data['actors']
             if actor['appId'] == app_id and actor['mapped'] and actor['paintOpacity'] > 0
             and actor['width'] >= 16
             and actor['height'] >= 16
             and 'dashtodock' in ' '.join(actor['ancestry']).lower()]
    assert len(icons) <= 1, icons
    return icons[0] if icons else None


def icon_descendants(data, actor):
    prefix = actor['path'] + '.'
    return [child for child in data['actors']
            if child['path'].startswith(prefix) and child['mapped'] and child['paintOpacity'] > 0
            and (child['gicon'] or child['iconName'])]


def crop_dock(name, data, actor):
    screenshot = OUTPUT / f'{name}-full.png'
    with Image.open(screenshot) as image:
        x0 = max(0, int(actor['x']) - 8)
        y0 = max(0, int(actor['y']) - 8)
        x1 = min(image.width, int(actor['x'] + actor['width']) + 8)
        y1 = min(image.height, int(actor['y'] + actor['height']) + 8)
        assert x1 - x0 >= 16 and y1 - y0 >= 16, (actor, image.size)
        image.crop((x0, y0, x1, y1)).save(OUTPUT / f'{name}-dock.png')


def desktop_file_evidence(name):
    candidates = [Path('/usr/share/applications/localsend_app.desktop'),
                  Path('/usr/local/share/applications/localsend_app.desktop')]
    found = next((path for path in candidates if path.is_file()), None)
    assert found is not None, f'Missing installed {EXPECTED_DESKTOP_ID}'
    contents = found.read_text()
    (OUTPUT / f'{name}-installed.desktop').write_text(contents)
    assert 'Icon=localsend_app' in contents, contents
    return str(found), contents


def check_ready():
    assert os.environ['XDG_SESSION_TYPE'] == 'wayland'
    assert os.environ['GDK_BACKEND'] == 'wayland'
    assert Path(os.environ['XDG_RUNTIME_DIR'], os.environ['WAYLAND_DISPLAY']).is_socket()
    data = wait_for(inspect, 'GNOME Shell diagnostic extension', timeout=120)
    assert data['backend'] == 'wayland', data['backend']
    assert data['stage']['width'] >= 800 and data['stage']['height'] >= 600, data['stage']
    extension_manager = dbus.Interface(
        BUS.get_object('org.gnome.Shell', '/org/gnome/Shell'),
        'org.gnome.Shell.Extensions')
    def extensions_ready():
        states = extension_manager.ListExtensions()
        required = ('ubuntu-dock@ubuntu.com', 'pr3416-probe@localsend.test')
        return states if all(int(states.get(key, {}).get('state', 0)) == 1 for key in required) else None
    extensions = wait_for(extensions_ready, 'active Ubuntu Dock and diagnostic extensions')
    probe().LeaveOverview()
    time.sleep(2)
    snapshot('desktop-ready-initial')
    wait_for(lambda: any(actor['paintOpacity'] > 0 and
                         'dashtodock' in ' '.join(actor['ancestry'] + [actor['styleClass'], actor['name']]).lower()
                         for actor in inspect()['actors']), 'Ubuntu Dock actor')
    snapshot('desktop-ready')
    (OUTPUT / 'desktop-environment.json').write_text(json.dumps({
        'gnome': subprocess.check_output(['gnome-shell', '--version'], text=True).strip(),
        'session': os.environ['XDG_SESSION_TYPE'],
        'waylandDisplay': os.environ['WAYLAND_DISPLAY'],
        'desktop': os.environ.get('XDG_CURRENT_DESKTOP'),
        'extensions': {key: int(value.get('state', 0)) for key, value in extensions.items()},
    }, indent=2) + '\n')


def check_case(name, expected, executable, expected_wm_class):
    assert expected in ('matched', 'generic'), expected
    executable = Path(executable)
    assert executable.is_file() and os.access(executable, os.X_OK), executable
    desktop_path, desktop_contents = desktop_file_evidence(name)
    # GIO and Shell observe desktop-file changes asynchronously. This catches a
    # stale AppSystem cache before the application is launched, especially for
    # the final StartupWMClass repair case.
    expected_startup_class = 'org.localsend.localsend_app' if name == 'desktop-fix' else ''

    def desktop_current():
        entry = inspect()['desktopEntry']
        assert entry['appId'] == EXPECTED_DESKTOP_ID, entry
        assert entry['file'] == desktop_path, entry
        return entry if entry['startupWMClass'] == expected_startup_class else None

    wait_for(desktop_current, 'Shell AppSystem desktop entry refresh', timeout=90)
    if expected_startup_class:
        assert f'StartupWMClass={expected_startup_class}' in desktop_contents
    else:
        assert 'StartupWMClass=' not in desktop_contents

    probe().LeaveOverview()
    env = os.environ.copy()
    env['GDK_BACKEND'] = 'wayland'
    env.pop('DISPLAY', None)
    log = (OUTPUT / f'{name}-app.log').open('w')
    launcher = subprocess.Popen([str(executable)], cwd=executable.parent,
                                env=env, stdout=log, stderr=subprocess.STDOUT)
    window_pid = None
    try:
        data, window = wait_for(
            lambda: (state, match) if (match := local_window(state := inspect())) and match['appId'] else None,
            'LocalSend native window', timeout=120)
        window_pid = int(window['pid'])
        assert window_pid > 0 and Path(f'/proc/{window_pid}/exe').exists(), window
        assert window['clientType'] == 'wayland', window
        if expected_wm_class:
            assert window['wmClass'] == expected_wm_class, window
        if expected == 'matched':
            assert window['appId'] == EXPECTED_DESKTOP_ID, window
            assert window['desktopFile'] == desktop_path, window
            assert not window['windowBacked'], window
            assert window['appInfoIcon'], window
        else:
            assert window['appId'] != EXPECTED_DESKTOP_ID, window
            assert window['windowBacked'] and not window['desktopFile'], window
            assert 'application-x-executable' in window['appIcon'], window

        app_id = window['appId']
        data, actor = wait_for(
            lambda: (state, icon) if (icon := dock_icon(state := inspect(), app_id)) else None,
            'mapped LocalSend entry in Ubuntu Dock', timeout=45)
        assert icon_descendants(data, actor), f'Dock actor has no rendered icon: {actor}'
        probe().LeaveOverview()
        time.sleep(2)
        data = snapshot(name)
        window = local_window(data)
        assert window and window['pid'] == window_pid and window['appId'] == app_id, data['windows']
        actor = dock_icon(data, app_id)
        assert actor, 'LocalSend dock icon disappeared before screenshot'
        icons = icon_descendants(data, actor)
        assert icons, 'No mapped icon child was rendered in dock'
        expected_icon = 'localsend_app' if expected == 'matched' else 'application-x-executable'
        assert any(expected_icon in icon['gicon'] + icon['iconName'] for icon in icons), icons
        crop_dock(name, data, actor)
        result = {
            'case': name,
            'expected': expected,
            'executable': os.readlink(f'/proc/{window_pid}/exe'),
            'pid': window_pid,
            'desktopFile': desktop_path,
            'desktopEntry': data['desktopEntry'],
            'window': window,
            'dockActor': actor,
            'dockRenderedIcons': icons,
            'screenshot': str(OUTPUT / f'{name}-full.png'),
            'dockCrop': str(OUTPUT / f'{name}-dock.png'),
        }
        (OUTPUT / f'{name}-result.json').write_text(json.dumps(result, indent=2) + '\n')
    except BaseException:
        try:
            snapshot(name + '-failure')
        except Exception:
            pass
        raise
    finally:
        if window_pid and Path(f'/proc/{window_pid}').exists():
            os.kill(window_pid, signal.SIGTERM)
        if launcher.poll() is None:
            launcher.terminate()
        try:
            launcher.wait(timeout=20)
        except subprocess.TimeoutExpired:
            launcher.kill()
            launcher.wait(timeout=5)
        # A desktop entry may spawn a child outside the launcher process.
        subprocess.run(['pkill', '-u', str(os.getuid()), '-x', 'localsend_app'], check=False)
        log.close()
        wait_for(lambda: not local_window(inspect()), 'LocalSend window closed', timeout=30)


if __name__ == '__main__':
    if sys.argv[1:] == ['ready']:
        check_ready()
    elif 3 <= len(sys.argv) <= 5:
        check_case(sys.argv[1], sys.argv[2],
                   sys.argv[3] if len(sys.argv) >= 4 else '/opt/pr3416/app/localsend_app',
                   sys.argv[4] if len(sys.argv) == 5 else None)
    else:
        raise SystemExit(__doc__)
