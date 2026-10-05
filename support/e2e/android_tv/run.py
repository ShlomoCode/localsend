#!/usr/bin/env python3
"""Compare the existing Device name dialog with and without the TV editor proxy."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

# TODO: Merge this focused test into a generic E2E runner when more tests are added.
PACKAGE = 'org.localsend.localsend_app.debug'
ACTIVITY = 'org.localsend.localsend_app.MainActivity'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--serial', required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--fixed', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        parser.error('Use a disposable emulator: this test replaces its debug LocalSend APK')
    args.output.mkdir(parents=True, exist_ok=False)

    def check(condition, message):
        if not condition:
            raise AssertionError(message)

    def adb(*command):
        return subprocess.check_output([args.adb, '-s', args.serial, *command], timeout=20, stderr=subprocess.STDOUT)

    def ui(open_settings=False):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if open_settings:
                # Leave the animated Receive page before UiAutomator waits for idle.
                adb('shell', 'input', 'touchscreen', 'tap', str(width // 10), str(height * 4 // 9))
                time.sleep(1)
            adb('shell', 'rm', '-f', '/sdcard/localsend-e2e.xml')
            dump = adb('shell', 'uiautomator', 'dump', '/sdcard/localsend-e2e.xml')
            if b'ERROR:' not in dump:
                return list(ET.fromstring(adb('shell', 'cat', '/sdcard/localsend-e2e.xml')).iter('node'))
        raise RuntimeError('UiAutomator did not produce a fresh snapshot')

    def bounds(node):
        return list(map(int, re.findall(r'\d+', node.get('bounds'))))

    def tap(node):
        x1, y1, x2, y2 = bounds(node)
        adb('shell', 'input', 'touchscreen', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
        time.sleep(1)

    def open_editor(start=False, name=None):
        nodes = ui(open_settings=start)
        if not any(n.get('class') == 'android.widget.EditText' for n in nodes):
            # Reuse the actual Settings screen instead of a second test app or widget.
            settings = next((n for n in nodes if n.get('content-desc', '').startswith('Settings\nTab')), None)
            check(settings is not None, 'Settings tab not found; use English LocalSend')
            tap(settings)
            for _ in range(8):
                nodes = ui()
                section = next((n for n in nodes if 'Network' in n.get('content-desc', '')
                                and 'Device name' in n.get('content-desc', '')), None)
                if section is not None:
                    _, top, _, bottom = bounds(section)
                    buttons = [n for n in nodes if n.get('class') == 'android.widget.Button'
                               and top <= bounds(n)[1] and bounds(n)[3] <= bottom
                               and bounds(n)[3] - bounds(n)[1] > 70
                               and (name is None or n.get('content-desc') == name)]
                    if buttons:
                        tap(buttons[-1])
                        break
                adb('shell', 'input', 'touchscreen', 'swipe', str(width * 3 // 4), str(height * 4 // 5),
                    str(width * 3 // 4), str(height // 4), '800')
            else:
                raise AssertionError('Device name button not found')
        time.sleep(2)
        return editor_value()

    def editor_value():
        fields = [n for n in ui() if n.get('class') == 'android.widget.EditText']
        check(len(fields) == 1 and fields[0].get('focused') == 'true', 'Expected one focused editor')
        return fields[0].get('text')

    def press(*keys):
        for key in keys:
            adb('shell', 'input', 'dpad', 'keyevent', key)
            time.sleep(0.5)

    gate = adb('shell', 'cmd', 'overlay', 'lookup', 'android',
               'android:bool/config_preventImeStartupUnlessTextEditor').decode().strip()
    keyboard = adb('shell', 'dumpsys', 'package', 'com.google.android.inputmethod.latin').decode()
    check(gate == 'true' and 'tv_release' in keyboard, 'Requires the reproducing TV/Gboard environment')
    check(adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == (
        'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'), 'Select TV Gboard')
    check('android.software.leanback' in adb('shell', 'pm', 'list', 'features').decode(), 'Requires TV features')
    width, height = map(int, re.findall(r'\d+', adb('shell', 'wm', 'size').decode())[-2:])
    check(width > height, 'Use a landscape TV emulator')
    results = {'device': adb('shell', 'getprop', 'ro.build.fingerprint').decode().strip(), 'cases': {}}
    initial = None
    try:
        for case, apk in [('control', args.control), ('fixed', args.fixed)]:
            print(f'Running {case}', flush=True)
            adb('shell', 'am', 'force-stop', PACKAGE)
            adb('install', '-r', str(apk.resolve()))
            adb('shell', 'am', 'start', '-n', f'{PACKAGE}/{ACTIVITY}')
            time.sleep(5)
            before = open_editor(start=True)
            if initial is None:
                initial = before
            check(before == initial, 'Both APKs must start with the same saved name')
            press('KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER', 'KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER')
            after = editor_value()
            (args.output / f'{case}.png').write_bytes(adb('exec-out', 'screencap', '-p'))
            results['cases'][case] = {'before': before, 'after': after,
                                      'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}
            expected = initial if case == 'control' else initial + 'we'
            check(after == expected, f'{case}: expected {expected!r}, got {after!r}')
            if case == 'fixed':
                press('KEYCODE_ENTER')
                check(not any(n.get('class') == 'android.widget.EditText' for n in ui()), 'Dialog did not close')
                check(open_editor(name=after) == after, 'Reopened name changed')
                press('KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER')
                check(editor_value() == after + 'w', 'Reopened editor rejected or duplicated input')
        results['passed'] = True
        print('PASS: plain Flutter input fails; LocalSend proxy works, including reentry', flush=True)
    except Exception as error:
        results.update(passed=False, error=str(error))
        raise
    finally:
        (args.output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        adb('shell', 'am', 'force-stop', PACKAGE)


if __name__ == '__main__':
    main()
