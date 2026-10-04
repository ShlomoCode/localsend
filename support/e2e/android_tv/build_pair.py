#!/usr/bin/env python3
"""Build the same TV keyboard fixture with and without LocalSend's Android proxy."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--ref', default='HEAD', help='Committed source containing the TV proxy')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ndk-version', help='Use this installed NDK for both fixture builds')
    args = parser.parse_args()
    sdk = os.environ.get('ANDROID_SDK_ROOT')
    if not sdk or not (Path(sdk) / 'platforms/android-36').is_dir():
        parser.error('Set ANDROID_SDK_ROOT to an SDK containing Android 36')
    if args.ndk_version and not re.fullmatch(r'\d+(\.\d+)+', args.ndk_version):
        parser.error('NDK version must be a dotted numeric version')
    os.environ['ANDROID_HOME'] = sdk
    repo, output = args.repo.resolve(), args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output must be empty; use a new directory for each build pair')
    output.mkdir(parents=True, exist_ok=True)
    commit = subprocess.check_output(['git', 'rev-parse', f'{args.ref}^{{commit}}'], cwd=repo, text=True).strip()
    fixture = Path(__file__).with_name('fixture.dart')
    with tempfile.TemporaryDirectory(prefix='localsend-tv-e2e-') as temporary:
        checkout = Path(temporary) / 'source'
        checkout.mkdir()
        archive = Path(temporary) / 'source.tar'
        with archive.open('wb') as stream:
            subprocess.run(['git', 'archive', commit], cwd=repo, stdout=stream, check=True)
        run('tar', '-xf', str(archive), '-C', str(checkout))
        app = checkout / 'app'
        target = app / 'tv_keyboard_e2e.dart'
        shutil.copy2(fixture, target)
        # Isolate the fixture from a developer's installed LocalSend and its data.
        gradle = app / 'android/app/build.gradle'
        source = gradle.read_text()
        suffix = 'applicationIdSuffix ".debug"'
        if source.count(suffix) != 1:
            raise RuntimeError('Cannot identify debug application ID; update this fixture builder')
        gradle.write_text(source.replace(suffix, 'applicationIdSuffix ".tv_e2e"'))
        if args.ndk_version:
            if not (Path(sdk) / 'ndk' / args.ndk_version).is_dir():
                parser.error(f'NDK {args.ndk_version} is not installed in {sdk}')
            # An explicit build prerequisite override applies equally to both APKs.
            root_gradle = app / 'android/build.gradle'
            root_gradle.write_text(root_gradle.read_text().replace(
                'compileSdkVersion 36', f'compileSdkVersion 36\n                ndkVersion "{args.ndk_version}"'))
        activity = app / 'android/app/src/main/kotlin/org/localsend/localsend_app/MainActivity.kt'
        source = activity.read_text()
        gate = 'if (packageManager.hasSystemFeature("android.software.leanback")) {'
        if source.count(gate) != 1 or 'TextEditorProxyView(' not in source:
            raise RuntimeError('Cannot identify TV proxy setup; update the control transformation')
        run('fvm', 'flutter', 'pub', 'get', cwd=app)
        run('fvm', 'dart', 'run', 'build_runner', 'build', cwd=checkout / 'packages/localsend_isolates')
        run('fvm', 'dart', 'run', 'build_runner', 'build', cwd=app)
        artifacts = {}
        for case in ('fixed', 'control'):
            if case == 'control':
                # This changes only the native adapter, not the field or Flutter toolchain.
                activity.write_text(source.replace(gate, 'if (false) {'))
            run('fvm', 'flutter', 'build', 'apk', '--debug', '--target-platform', 'android-arm64',
                '--target', target.name, '--no-pub', cwd=app)
            apk = output / f'{case}.apk'
            shutil.copy2(app / 'build/app/outputs/flutter-apk/app-debug.apk', apk)
            artifacts[case] = {'apk': apk.name, 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}
        manifest = {
            'commit': commit,
            'flutter': json.loads((checkout / '.fvmrc').read_text())['flutter'],
            'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
            'package': 'org.localsend.localsend_app.tv_e2e',
            'ndk_override': args.ndk_version,
            'artifacts': artifacts,
        }
        (output / 'pair.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
