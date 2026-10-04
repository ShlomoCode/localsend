#!/usr/bin/env python3
# Package this build's Linux bundle as a real FUSE-mounted AppImage for the KDE e2e run.

"""Build a minimal AppDir from the selected release bundle and pack it with appimagetool."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys


APPIMAGE_NAME = "LocalSend-e2e-x86_64.AppImage"


def digest(path):
    hash_value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hash_value.update(block)
    return hash_value.digest()


def verify_copy(source, destination):
    for path in sorted(source.rglob("*")):
        copied = destination / path.relative_to(source)
        if path.is_symlink():
            if not copied.is_symlink() or copied.readlink() != path.readlink():
                raise RuntimeError(f"Staged symlink differs from release bundle: {path}")
        elif path.is_dir():
            if not copied.is_dir():
                raise RuntimeError(f"Staged directory missing: {path}")
        elif not copied.is_file() or digest(path) != digest(copied):
            raise RuntimeError(f"Staged file differs from release bundle: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="Flutter Linux x64 release/bundle directory")
    parser.add_argument("--output", type=Path, required=True, help="Directory for AppDir and AppImage")
    parser.add_argument("--appimagetool", type=Path, required=True, help="Pinned official appimagetool executable")
    parser.add_argument("--runtime-file", type=Path, required=True, help="Pinned official type-2 AppImage runtime")
    args = parser.parse_args()

    bundle = args.bundle.resolve(strict=True)
    output = args.output.resolve()
    tool = args.appimagetool.resolve(strict=True)
    runtime = args.runtime_file.resolve(strict=True)
    if not bundle.is_dir() or not (bundle / "localsend_app").is_file():
        parser.error(f"Release bundle is incomplete: {bundle}")
    for required in (
        bundle / "lib",
        bundle / "data/flutter_assets/assets/img/logo-256.png",
        bundle / "data/flutter_assets/assets/img/logo-32-white.png",
    ):
        if not required.exists():
            parser.error(f"Release bundle is incomplete: {required}")
    if not os.access(tool, os.X_OK) or not runtime.is_file():
        parser.error("--appimagetool must be executable and --runtime-file must be a file")
    if output == bundle or bundle in output.parents:
        parser.error("--output must be outside the release bundle")

    output.mkdir(parents=True, exist_ok=True)
    appdir = output / "AppDir"
    appimage = output / APPIMAGE_NAME
    if appdir.exists():
        shutil.rmtree(appdir)
    if appimage.exists():
        appimage.unlink()
    shutil.copytree(bundle, appdir, symlinks=True)

    (appdir / "AppRun").write_text(
        '#!/bin/sh\n'
        'set -eu\n'
        'appdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
        'export LD_LIBRARY_PATH="$appdir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
        'exec "$appdir/localsend_app" "$@"\n',
        encoding="utf-8",
    )
    (appdir / "AppRun").chmod(0o755)
    (appdir / "localsend.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=LocalSend\n"
        "Exec=localsend_app %U\n"
        "Icon=localsend\n"
        "Categories=Network;FileTransfer;\n",
        encoding="utf-8",
    )
    shutil.copy2(bundle / "data/flutter_assets/assets/img/logo-256.png", appdir / "localsend.png")

    verify_copy(bundle, appdir)
    env = os.environ.copy()
    env["ARCH"] = "x86_64"
    print(f"+ {tool} --runtime-file {runtime} {appdir} {appimage}", flush=True)
    subprocess.run((str(tool), "--runtime-file", str(runtime), str(appdir), str(appimage)), check=True, env=env)
    if not appimage.is_file() or not os.access(appimage, os.X_OK):
        raise RuntimeError(f"appimagetool did not produce an executable AppImage: {appimage}")
    print(f"PASS built {appimage} from release bundle {bundle}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"FAIL AppImage packaging: {error}", file=sys.stderr)
        sys.exit(2)
