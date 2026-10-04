#!/usr/bin/env python3
"""Compatibility-only fixture: preserve official dependency sources, compile copied
SharedModels.swift with an explicitly recorded Foundation import. This fixture
change supplies Foundation scope for this standalone compiler fixture;
it does not reconstruct or verify the pod import context, is not a production patch,
and does not prove share-extension activation.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--models', required=True, help='Exact official ios/Models/Classes directory')
parser.add_argument('--subclass', required=True, help='Pinned app ShareViewController.swift')
parser.add_argument('--out', required=True)
args = parser.parse_args()
source = pathlib.Path(args.models)
out = pathlib.Path(args.out)
out.mkdir(parents=True, exist_ok=True)
fixture = out / 'fixture-source'
fixture.mkdir(exist_ok=True)
manifest = {'purpose': 'API compatibility only; no activation/runtime proof', 'source_changes': [], 'inputs': {}, 'commands': [], 'results': []}
for name in ['SharedModels.swift', 'ShareHandlerIosViewController.swift']:
    raw = (source / name).read_bytes()
    manifest['inputs'][name] = hashlib.sha256(raw).hexdigest()
    if name == 'SharedModels.swift':
        # Its isolated source does not import Foundation, although Data and
        # JSONEncoder/JSONDecoder/JSONSerialization are used. Do not edit source.
        raw = b'import Foundation\n' + raw
        manifest['source_changes'].append({'file': name, 'fixture_only': True, 'change': 'prepend import Foundation', 'reason': 'standalone swiftc does not reproduce pod/Foundation import context'})
    (fixture / name).write_bytes(raw)
subclass = out / 'ShareViewController.swift'
shutil.copyfile(args.subclass, subclass)
manifest['inputs']['ShareViewController.swift'] = hashlib.sha256(subclass.read_bytes()).hexdigest()

def run(command):
    manifest['commands'].append(command)
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end='')
    manifest['results'].append({'command': command, 'exit_code': result.returncode, 'output': result.stdout})
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    return result

sdk_result = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
if sdk_result.returncode:
    raise SystemExit(sdk_result.returncode)
sdk = sdk_result.stdout.strip()
arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
for version in ['16.0', '14.0']:
    build = out / ('ios-' + version)
    build.mkdir(exist_ok=True)
    target = arch + '-apple-ios' + version + '-simulator'
    command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', target, '-swift-version', '5', '-module-cache-path', str(out / 'module-cache'), '-emit-module', '-emit-library', '-o', str(build / 'libshare_handler_ios_models.dylib'), '-module-name', 'share_handler_ios_models', '-emit-module-path', str(build / 'share_handler_ios_models.swiftmodule'), str(fixture / 'SharedModels.swift'), str(fixture / 'ShareHandlerIosViewController.swift')]
    result = run(command)
    if result.returncode:
        raise SystemExit(result.returncode)
    result = run(['xcrun', 'vtool', '-show-build', str(build / 'libshare_handler_ios_models.dylib')])
    if result.returncode:
        raise SystemExit(result.returncode)
    if 'minos ' + version not in result.stdout:
        raise SystemExit('Mach-O minimum OS does not match requested deployment target ' + version)
    result = run(['xcrun', 'swiftc', '-sdk', sdk, '-target', target, '-swift-version', '5', '-module-cache-path', str(out / 'module-cache'), '-I', str(build), '-typecheck', str(subclass)])
    if result.returncode:
        raise SystemExit(result.returncode)
print('PASS exact controller API and app subclass compile at iOS16 and iOS14 (fixture-only Foundation import in SharedModels)')
