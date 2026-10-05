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
UI_XML = '/sdcard/localsend-e2e.xml'


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

    def read_ui_nodes():
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            adb('shell', 'rm', '-f', UI_XML)
            dump = adb('shell', 'uiautomator', 'dump', UI_XML)
            if b'ERROR:' not in dump:
                return list(ET.fromstring(adb('shell', 'cat', UI_XML)).iter('node'))
        raise RuntimeError('UiAutomator did not produce a fresh snapshot')

    def node_bounds(node):
        return list(map(int, re.findall(r'\d+', node.get('bounds'))))

    def tap_node(node):
        x1, y1, x2, y2 = node_bounds(node)
        adb('shell', 'input', 'touchscreen', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
        time.sleep(1)

    def open_settings_tab():
        # Leave the animated Receive page before UiAutomator waits for idle.
        adb('shell', 'input', 'touchscreen', 'tap', str(width // 10), str(height * 4 // 9))
        time.sleep(1)
        settings = next((node for node in read_ui_nodes()
                         if node.get('content-desc', '').startswith('Settings\nTab')), None)
        check(settings is not None, 'Settings tab not found; use English LocalSend')
        tap_node(settings)

    def get_device_name():
        fields = [n for n in read_ui_nodes() if n.get('class') == 'android.widget.EditText']
        check(len(fields) == 1 and fields[0].get('focused') == 'true', 'Expected one focused editor')
        return fields[0].get('text')

    def open_device_name_dialog(expected_button_name=None):
        nodes = read_ui_nodes()
        if any(node.get('class') == 'android.widget.EditText' for node in nodes):
            return get_device_name()
        for _ in range(8):
            section = next((node for node in nodes if 'Network' in node.get('content-desc', '')
                            and 'Device name' in node.get('content-desc', '')), None)
            if section is not None:
                _, top, _, bottom = node_bounds(section)
                buttons = [node for node in nodes if node.get('class') == 'android.widget.Button'
                           and top <= node_bounds(node)[1] and node_bounds(node)[3] <= bottom
                           and node_bounds(node)[3] - node_bounds(node)[1] > 70
                           and (expected_button_name is None or node.get('content-desc') == expected_button_name)]
                if buttons:
                    tap_node(buttons[-1])
                    break
            adb('shell', 'input', 'touchscreen', 'swipe', str(width * 3 // 4), str(height * 4 // 5),
                str(width * 3 // 4), str(height // 4), '800')
            nodes = read_ui_nodes()
        else:
            raise AssertionError('Device name button not found')
        time.sleep(2)
        return get_device_name()

    def press_remote_keys(*keys):
        for key in keys:
            adb('shell', 'input', 'dpad', 'keyevent', key)
            time.sleep(0.5)

    def verify_tv_environment():
        gate = adb('shell', 'cmd', 'overlay', 'lookup', 'android',
                   'android:bool/config_preventImeStartupUnlessTextEditor').decode().strip()
        keyboard = adb('shell', 'dumpsys', 'package', 'com.google.android.inputmethod.latin').decode()
        check(gate == 'true' and 'tv_release' in keyboard, 'Requires the reproducing TV/Gboard environment')
        check(adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == (
            'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'), 'Select TV Gboard')
        check('android.software.leanback' in adb('shell', 'pm', 'list', 'features').decode(), 'Requires TV features')
        screen_width, screen_height = map(int, re.findall(r'\d+', adb('shell', 'wm', 'size').decode())[-2:])
        check(screen_width > screen_height, 'Use a landscape TV emulator')
        return screen_width, screen_height

    def check_reopened_editor(saved_name):
        # Given the fixed dialog was submitted and the saved name is shown.
        press_remote_keys('KEYCODE_ENTER')
        check(not any(node.get('class') == 'android.widget.EditText' for node in read_ui_nodes()), 'Dialog did not close')
        check(open_device_name_dialog(expected_button_name=saved_name) == saved_name, 'Reopened name changed')

        # When another letter is entered with the remote.
        press_remote_keys('KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER')

        # Then the reopened editor appends it exactly once.
        check(get_device_name() == saved_name + 'w', 'Reopened editor rejected or duplicated input')

    width, height = verify_tv_environment()
    results = {'device': adb('shell', 'getprop', 'ro.build.fingerprint').decode().strip(), 'cases': {}}
    initial_name = None
    try:
        for case, apk in [('control', args.control), ('fixed', args.fixed)]:
            print(f'Running {case}', flush=True)

            # Given this APK opens the same saved Device name in the real Settings dialog.
            adb('shell', 'am', 'force-stop', PACKAGE)
            adb('install', '-r', str(apk.resolve()))
            adb('shell', 'am', 'start', '-n', f'{PACKAGE}/{ACTIVITY}')
            time.sleep(5)
            open_settings_tab()
            before = open_device_name_dialog()
            if initial_name is None:
                initial_name = before
            check(before == initial_name, 'Both APKs must start with the same saved name')

            # When the TV remote selects W and E on Gboard.
            press_remote_keys('KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER',
                              'KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER')

            # Then the control ignores both keys, while the fixed APK appends each once.
            after = get_device_name()
            (args.output / f'{case}.png').write_bytes(adb('exec-out', 'screencap', '-p'))
            results['cases'][case] = {'before': before, 'after': after,
                                      'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}
            expected = initial_name if case == 'control' else initial_name + 'we'
            check(after == expected, f'{case}: expected {expected!r}, got {after!r}')
            if case == 'fixed':
                check_reopened_editor(after)
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
