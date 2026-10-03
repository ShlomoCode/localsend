#!/usr/bin/env python3
"""Capture the actual GNOME tray, and exercise its menu with mouse input."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import dbus
from PIL import Image, ImageDraw

output = Path('/opt/pr3354/evidence')
bus = dbus.SessionBus()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def wait_for(fn, label, seconds=90):
    deadline = time.monotonic() + seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = fn()
            if value:
                return value
        except (dbus.DBusException, subprocess.CalledProcessError, AssertionError) as error:
            last_error = error
        time.sleep(1)
    raise RuntimeError(f'Timed out waiting for {label}: {last_error}')


def probe():
    obj = bus.get_object('org.localsend.TrayProbe', '/org/localsend/TrayProbe')
    return dbus.Interface(obj, 'org.localsend.TrayProbe')


def inspect():
    return json.loads(probe().Inspect())


def snapshot(name):
    data = inspect()
    (output / f'{name}-desktop.json').write_text(json.dumps(data, indent=2))
    subprocess.run(['import', '-window', 'root', str(output / f'{name}-full.png')], check=True)
    return data


def indicator():
    watcher = bus.get_object('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher')
    items = dbus.Interface(watcher, 'org.freedesktop.DBus.Properties').Get(
        'org.kde.StatusNotifierWatcher', 'RegisteredStatusNotifierItems')
    if len(items) != 1:
        return None
    # GNOME's watcher separates the bus name and object path with "@/";
    # other StatusNotifier hosts use "/" directly.
    service, path = str(items[0]).replace('@/', '/', 1).split('/', 1)
    props = dbus.Interface(bus.get_object(service, '/' + path), 'org.freedesktop.DBus.Properties')
    data = props.GetAll('org.kde.StatusNotifierItem')
    return {'item': str(items[0]), 'icon': str(data['IconName']), 'title': str(data['Title'])}


def icon_actor(expected):
    actors = [a for a in inspect()['panel'] if a['visible'] and a['width'] > 0]
    if expected == 'fallback':
        return next((a for a in actors if 'image-loading-symbolic' in a['icon'] + a['gicon']), None)
    return next((a for a in actors if 'logo-32-white' in a['gicon']), None)


def click(actor):
    command('xdotool', 'mousemove', str(round(actor['x'] + actor['width'] / 2)),
            str(round(actor['y'] + actor['height'] / 2)), 'click', '1')


def menu_label(text):
    return next((a for a in inspect()['actors'] if a['visible'] and a['text'] == text), None)


def local_window():
    return next((w for w in inspect()['windows'] if w['title'] == 'LocalSend'), None)


def capture_case(name, expected):
    log = open(output / f'{name}-app.log', 'w')
    if name == 'control':
        invocation = ['/opt/pr3354/bundles/before/localsend_app']
    else:
        invocation = ['snap', 'run', 'localsend']
    launcher = subprocess.Popen(['systemd-run', '--user', '--scope', '--quiet',
                                 '--unit=' + name + '-localsend', *invocation], stdout=log, stderr=log)
    try:
        entry = wait_for(indicator, 'LocalSend StatusNotifierItem')
        window = wait_for(local_window, 'LocalSend application window')
        pid = window['pid']
        profile = Path(f'/proc/{pid}/attr/current').read_text().strip()
        executable = os.readlink(f'/proc/{pid}/exe')
        entry.update({'pid': pid, 'apparmor': profile, 'executable': executable})
        if name != 'control':
            assert profile == 'snap.localsend.localsend (enforce)', profile
            assert executable.startswith('/snap/localsend/'), executable
        if expected == 'fallback':
            assert entry['icon'].startswith('assets/'), entry
        else:
            assert os.path.isabs(entry['icon']) and Path(entry['icon']).is_file(), entry
        actor = wait_for(lambda: icon_actor(expected), f'GNOME rendered {expected} icon')
        probe().LeaveOverview()
        time.sleep(2)
        snapshot(name)
        full = Image.open(output / f'{name}-full.png')
        x, y = round(actor['x']), round(actor['y'])
        full.crop((x - 8, 0, x + round(actor['width']) + 8, 40)).save(output / f'{name}-icon.png')
        entry['rendered_icon'] = actor
        if name != 'control':
            # Real native minimize, then a real click on the GNOME tray menu's Open entry.
            rows = command('wmctrl', '-lp').splitlines()
            xid = next(row.split()[0] for row in rows if len(row.split()) > 2 and int(row.split()[2]) == pid)
            command('xdotool', 'windowminimize', xid)
            wait_for(lambda: local_window() and local_window()['minimized'], 'minimized window')
            click(actor)
            open_item = wait_for(lambda: menu_label('Open'), 'visible tray Open menu item', seconds=20)
            snapshot(name + '-menu')
            click(open_item)
            wait_for(lambda: local_window() and not local_window()['minimized'], 'window restored by tray Open')
            snapshot(name + '-restored')
            entry['mouse_menu_open_restored_window'] = True
            click(actor)
            quit_item = wait_for(lambda: menu_label('Quit LocalSend'), 'visible tray Quit menu item', seconds=20)
            click(quit_item)
            wait_for(lambda: not Path(f'/proc/{pid}').exists(), 'process exited by tray Quit')
            entry['mouse_menu_quit_exited_process'] = True
        (output / f'{name}-result.json').write_text(json.dumps(entry, indent=2))
    except BaseException:
        try:
            snapshot(name + '-failure')
        except Exception:
            pass
        raise
    finally:
        subprocess.run(['pkill', '-u', str(os.getuid()), '-x', 'localsend_app'], check=False)
        try:
            launcher.wait(timeout=15)
        except subprocess.TimeoutExpired:
            launcher.terminate()
        log.close()
        time.sleep(3)


if sys.argv[1] == 'ready':
    wait_for(inspect, 'full GNOME session and diagnostic extension', seconds=120)
    session = bus.get_object('org.gnome.SessionManager', '/org/gnome/SessionManager')
    extensions = dbus.Interface(bus.get_object('org.gnome.Shell', '/org/gnome/Shell'), 'org.gnome.Shell.Extensions')
    states = extensions.ListExtensions()
    assert int(states['ubuntu-appindicators@ubuntu.com']['state']) == 1, states
    assert int(states['pr3354-probe@localsend.test']['state']) == 1, states
    probe().LeaveOverview()
    time.sleep(3)
    snapshot('desktop-ready')
    (output / 'desktop-environment.json').write_text(json.dumps({
        'gnome': command('gnome-shell', '--version'),
        'session': os.environ.get('XDG_SESSION_TYPE'),
        'runtime': os.environ.get('XDG_RUNTIME_DIR'),
        'desktop': os.environ.get('XDG_CURRENT_DESKTOP'),
        'extensions': {key: int(value['state']) for key, value in states.items()},
    }, indent=2))
elif sys.argv[1] == 'compose':
    result = Image.new('RGB', (500, 320), '#202020')
    draw = ImageDraw.Draw(result)
    for y, name, label in [(0, 'before', 'BEFORE: installed strict Snap / GNOME'),
                           (160, 'after', 'AFTER: installed strict Snap / GNOME')]:
        draw.text((12, y + 8), label, fill='white')
        icon = Image.open(output / f'{name}-icon.png').convert('RGB')
        result.paste(icon.resize((icon.width * 3, icon.height * 3), Image.NEAREST), (12, y + 30))
    result.save(output / 'snap-gnome-before-after.png')
else:
    capture_case(sys.argv[1], sys.argv[2])
