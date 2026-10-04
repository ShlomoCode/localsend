#!/usr/bin/env python3
"""Exercise the TV keyboard through real Android remote events, without mocks."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

# TODO: Fold this focused TV harness into a shared E2E runner when we add more scenarios.
PACKAGE = 'org.localsend.localsend_app.tv_e2e'
ACTIVITY = 'org.localsend.localsend_app.MainActivity'


class Device:
    def __init__(self, adb, serial, output):
        self.command = [adb, '-s', serial]
        self.output = output

    def adb(self, *args):
        return subprocess.check_output([*self.command, *args], timeout=30)

    def nodes(self):
        # Never accept a stale dump when UiAutomator fails to become idle.
        path = '/sdcard/localsend-tv-e2e.xml'
        self.adb('shell', 'rm', '-f', path)
        dump = self.adb('shell', 'uiautomator', 'dump', path)
        if b'ERROR:' in dump:
            raise RuntimeError(dump.decode())
        xml = self.adb('shell', 'cat', path)
        return list(ET.fromstring(xml).iter('node')), xml

    def wait_for(self, predicate, description):
        deadline = time.monotonic() + 45
        last_error = None
        while time.monotonic() < deadline:
            try:
                nodes, xml = self.nodes()
                if predicate(nodes):
                    return nodes, xml
            except (RuntimeError, subprocess.SubprocessError, ET.ParseError) as error:
                last_error = error
            time.sleep(0.5)
        raise AssertionError(f'Timed out waiting for {description}; last UI error: {last_error}')

    def open_editor(self, value):
        nodes, _ = self.wait_for(
            lambda ns: any(n.get('class') == 'android.widget.Button' and n.get('content-desc') == value for n in ns),
            f'name button {value!r}',
        )
        button = next(n for n in nodes if n.get('class') == 'android.widget.Button' and n.get('content-desc') == value)
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', button.get('bounds')))
        self.adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
        self.wait_for(lambda ns: any(n.get('class') == 'android.widget.EditText' and n.get('focused') == 'true' for n in ns),
                      'focused editor')
        time.sleep(2)  # TV Gboard is a separate window and is not always in the app's UI XML.

    def type_we(self):
        for key in ('KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_CENTER') * 2:
            self.adb('shell', 'input', 'dpad', 'keyevent', key)
            time.sleep(0.5)

    def snapshot(self, name):
        folder = self.output / name
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'screen.png').write_bytes(self.adb('exec-out', 'screencap', '-p'))
        nodes, xml = self.wait_for(lambda ns: any(n.get('class') == 'android.widget.EditText' for n in ns), 'editor snapshot')
        (folder / 'ui.xml').write_bytes(xml)
        (folder / 'input_method.txt').write_bytes(self.adb('shell', 'dumpsys', 'input_method'))
        values = [n.get('text') for n in nodes if n.get('class') == 'android.widget.EditText']
        if len(values) != 1:
            raise AssertionError(f'Expected one editor, got {values}')
        return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--serial', required=True, help='Dedicated emulator, never selected implicitly')
    parser.add_argument('--pair', type=Path, required=True, help='Directory produced by build_pair.py')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        parser.error('Use a dedicated emulator; this test installs and clears its fixture package')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty; use a new directory for each run')
    output.mkdir(parents=True, exist_ok=True)
    device = Device(args.adb, args.serial, output)
    features = device.adb('shell', 'pm', 'list', 'features').decode()
    ime = device.adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip()
    gate = device.adb('shell', 'cmd', 'overlay', 'lookup', 'android',
                      'android:bool/config_preventImeStartupUnlessTextEditor').decode().strip()
    if 'feature:android.software.leanback\n' not in features or not gate.endswith('true'):
        raise RuntimeError('Requires a TV emulator with config_preventImeStartupUnlessTextEditor=true; see README')
    if ime != 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME':
        raise RuntimeError(f'Requires TV Gboard as the selected IME, got {ime}')
    keyboard = device.adb('shell', 'dumpsys', 'package', 'com.google.android.inputmethod.latin').decode()
    if not re.search(r'versionName=.*tv_release', keyboard):
        raise RuntimeError('Selected Gboard is not the TV release; see README')
    environment = {
        'fingerprint': device.adb('shell', 'getprop', 'ro.build.fingerprint').decode().strip(),
        'features': features.splitlines(), 'ime': ime, 'ime_startup_gate': gate,
        'keyboard': keyboard,
    }
    (output / 'environment.json').write_text(json.dumps(environment, indent=2) + '\n')
    pair = args.pair.resolve()
    metadata = json.loads((pair / 'pair.json').read_text())
    if metadata['package'] != PACKAGE:
        raise RuntimeError('Unexpected fixture package')
    for case in ('control', 'fixed'):
        apk = pair / metadata['artifacts'][case]['apk']
        if hashlib.sha256(apk.read_bytes()).hexdigest() != metadata['artifacts'][case]['sha256']:
            raise RuntimeError(f'{case} APK does not match pair.json')
    results = {'pair': metadata, 'cases': {}}
    try:
        for case in ('control', 'fixed'):
            apk = pair / metadata['artifacts'][case]['apk']
            print(f'Running {case}', flush=True)
            device.adb('shell', 'am', 'force-stop', PACKAGE)
            device.adb('install', '-r', str(apk))
            if device.adb('shell', 'pm', 'clear', PACKAGE).strip() != b'Success':
                raise RuntimeError('Could not reset the fixture package')
            device.adb('shell', 'am', 'start', '-n', f'{PACKAGE}/{ACTIVITY}')
            device.open_editor('Nice Grape')
            before = device.snapshot(f'{case}-before')
            if before != 'Nice Grape':
                raise AssertionError(f'{case}: unexpected initial value {before!r}')
            device.type_we()
            after = device.snapshot(f'{case}-after')
            expected = 'Nice Grape' if case == 'control' else 'Nice Grapewe'
            results['cases'][case] = {'before': before, 'after': after, 'expected': expected}
            if after != expected:
                raise AssertionError(f'{case}: expected {expected!r}, got {after!r}')
            if case == 'fixed':
                device.adb('shell', 'input', 'dpad', 'keyevent', 'KEYCODE_ENTER')
                device.wait_for(lambda ns: not any(n.get('class') == 'android.widget.EditText' for n in ns), 'closed dialog')
                device.open_editor('Nice Grapewe')
                device.adb('shell', 'input', 'dpad', 'keyevent', 'KEYCODE_DPAD_RIGHT')
                device.adb('shell', 'input', 'dpad', 'keyevent', 'KEYCODE_DPAD_CENTER')
                reopened = device.snapshot('fixed-reopened')
                results['cases'][case]['reopened'] = reopened
                if reopened != 'Nice Grapewew':
                    raise AssertionError(f'fixed reentry: expected Nice Grapewew, got {reopened!r}')
        results['passed'] = True
        print('PASS: control rejected remote input; LocalSend accepted it without duplicate words', flush=True)
    except Exception as error:
        results['passed'] = False
        results['error'] = str(error)
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        device.adb('shell', 'am', 'force-stop', PACKAGE)


if __name__ == '__main__':
    main()
