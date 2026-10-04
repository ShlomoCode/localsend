"""Temporary Windows app transfer probe for issue 3536 (fork runner only)."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener


REPORTED_NAME = (
    '土曜のあさはほめるちゃん 20260926 ＃124「関西のいま気になるエリアのええところ'
    '“ほめるポイント＝ほめポ”を見つけながら、ぶらりするほっこりトークがたっぷりの'
    'ほめぶら番組！今回は、“グラングリーン大阪”をぶらり！」.mp4'
)
EXPECTED_BASELINE_NAME = (
    '土曜のあさはほめるちゃん 20260926 ＃124「関西のいま気になるエリアのええところ'
    '“ほめるポイント＝ほめポ”を見つけながら、ぶらりするほっこりトークがたっぷりのほめぶら番組！今回'
)
ASCII_NAME = 'a' * 112 + '.mp4'  # 116 UTF-16 units, like the reported name.
CASES = [('short-control', 'control.txt'), ('reported', REPORTED_NAME), ('ascii-116', ASCII_NAME)]
PORT = 53317
BASE = f'http://127.0.0.1:{PORT}/api/localsend/v2'
OPENER = build_opener(ProxyHandler({}))


def request(path, payload=None, body=None):
    data = json.dumps(payload, ensure_ascii=False).encode('utf-8') if payload is not None else body
    headers = {'Content-Type': 'application/json'} if payload is not None else {}
    req = Request(BASE + path, data=data, headers=headers, method='POST' if data is not None else 'GET')
    try:
        with OPENER.open(req, timeout=35) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except HTTPError as error:
        raise RuntimeError(f'{path}: HTTP {error.code}: {error.read().decode("utf-8", "replace")}') from error


def wait_for_app(proc):
    deadline = time.monotonic() + 90
    last_error = None
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f'app exited before server startup: {proc.returncode}')
        try:
            status, info = request('/info')
            if status == 200 and info.get('alias'):
                return info
        except (URLError, TimeoutError, OSError) as error:
            last_error = error
        time.sleep(1)
    raise RuntimeError(f'app did not serve HTTP on port {PORT}: {last_error}')


def run_case(bundle, root, variant, case, name):
    destination = root / variant / case
    destination.mkdir(parents=True, exist_ok=True)
    settings = {
        'flutter.ls_version': 3,
        'flutter.ls_alias': 'Issue 3536 receiver',
        'flutter.ls_destination': str(destination),
        'flutter.ls_port': PORT,
        'flutter.ls_quick_save': 'on',
        'flutter.ls_https': False,
        'flutter.ls_auto_finish': True,
        'flutter.ls_save_to_history': False,
    }
    (bundle / 'settings.json').write_text(json.dumps(settings, ensure_ascii=False), encoding='utf-8')
    exe = bundle / 'localsend_app.exe'
    proc = subprocess.Popen([str(exe)], cwd=bundle)
    content = f'issue-3536:{case}:payload\n'.encode('utf-8')
    expected_hash = hashlib.sha256(content).hexdigest()
    try:
        info = wait_for_app(proc)
        sender = {
            'alias': 'Issue 3536 sender', 'version': '2.2', 'deviceModel': 'Windows runner',
            'deviceType': 'desktop', 'fingerprint': '3536-diagnostic-sender',
            'port': PORT + 1, 'protocol': 'http', 'download': False,
        }
        file_id = f'3536-{case}'
        file_info = {'id': file_id, 'fileName': name, 'size': len(content), 'fileType': 'application/octet-stream'}
        status, prepared = request('/prepare-upload', {'info': sender, 'files': {file_id: file_info}})
        if status != 200 or not prepared or file_id not in prepared['files']:
            raise RuntimeError(f'prepare-upload did not accept {case}: {status} {prepared}')
        query = urlencode({'sessionId': prepared['sessionId'], 'fileId': file_id, 'token': prepared['files'][file_id]})
        upload_status, _ = request('/upload?' + query, body=content)
        if upload_status != 200:
            raise RuntimeError(f'upload returned {upload_status}')
        deadline = time.monotonic() + 20
        saved_files = []
        while time.monotonic() < deadline:
            saved_files = [p for p in destination.iterdir() if p.is_file()]
            if len(saved_files) == 1 and saved_files[0].read_bytes() == content:
                break
            time.sleep(0.5)
        if len(saved_files) != 1:
            raise RuntimeError(f'expected one saved file, found {[p.name for p in saved_files]}')
        actual = saved_files[0]
        actual_hash = hashlib.sha256(actual.read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(f'content SHA-256 mismatch: {actual_hash} != {expected_hash}')
        if case == 'reported' and variant == 'baseline':
            expected_name = EXPECTED_BASELINE_NAME
        else:
            expected_name = name
        if actual.name != expected_name:
            raise RuntimeError(f'filename mismatch: expected {expected_name!r}, saved {actual.name!r}')
        return {
            'case': case, 'status': 'pass', 'sent_name': name, 'saved_name': actual.name,
            'sent_utf8_bytes': len(name.encode('utf-8')),
            'sent_utf16_units': len(name.encode('utf-16-le')) // 2,
            'saved_utf16_units': len(actual.name.encode('utf-16-le')) // 2,
            'content_bytes': len(content), 'sha256': actual_hash,
            'app_alias': info['alias'], 'protocol': 'HTTP v2 loopback',
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--variant', choices=['baseline', 'fixed'], required=True)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    print(f'Windows {os.name}; Python {sys.version}; variant={args.variant}', flush=True)
    print(f'reported name: {len(REPORTED_NAME.encode())} UTF-8 bytes, {len(REPORTED_NAME.encode("utf-16-le")) // 2} UTF-16 units', flush=True)
    results = {'variant': args.variant, 'bundle': str(args.bundle), 'cases': []}
    try:
        for case, name in CASES:
            try:
                result = run_case(args.bundle, args.root, args.variant, case, name)
                print(json.dumps(result, ensure_ascii=False), flush=True)
                results['cases'].append(result)
            except Exception as error:
                result = {'case': case, 'status': 'fail', 'error': repr(error)}
                print(json.dumps(result, ensure_ascii=False), flush=True)
                results['cases'].append(result)
                break
    finally:
        args.results.parent.mkdir(parents=True, exist_ok=True)
        args.results.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    if len(results['cases']) != len(CASES) or any(x['status'] != 'pass' for x in results['cases']):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
