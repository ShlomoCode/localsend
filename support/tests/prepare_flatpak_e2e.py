#!/usr/bin/env python3
# Package this build's Linux bundle in a real Flatpak using LocalSend's Flathub runtime and permissions.

"""Prepare the local e2e Flatpak branch before starting the KDE test session."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys


APP_ID = "org.localsend.localsend_app"
BRANCH = "e2e"
REMOTE = "localsend-e2e"
WHITE_ICON = f"share/icons/hicolor/32x32/apps/{APP_ID}-tray.png"


def run(*args):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(args, check=True)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_binaries(bundle):
    return [Path("localsend_app"), *(path.relative_to(bundle) for path in sorted((bundle / "lib").rglob("*")) if path.is_file())]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--output", type=Path, default=Path("linux-e2e-flatpak"))
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    root = args.output.resolve()

    executable = bundle / "localsend_app"
    assets = bundle / "data/flutter_assets/assets/img"
    for required in (executable, assets / "logo-32-black.png", assets / "logo-32-white.png"):
        if not required.is_file():
            parser.error(f"Release bundle is incomplete: {required}")

    # The official deployment supplies the real runtime, Ayatana libraries,
    # desktop exports and sandbox permissions. Its app binary/assets are replaced.
    official = Path(output("flatpak", "info", "--user", "--show-location", f"{APP_ID}//stable"))
    if not (official / "metadata").is_file() or not (official / "files" / WHITE_ICON).is_file():
        parser.error(f"Official LocalSend Flatpak deployment is incomplete: {official}")
    if digest(official / "files" / WHITE_ICON) != digest(assets / "logo-32-white.png"):
        parser.error("The Flathub tray icon no longer matches this bundle's white asset; review packaging")

    stage = root / "stage"
    repo = root / "repo"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copy2(official / "metadata", stage / "metadata")
    shutil.copytree(official / "files", stage / "files", symlinks=True)
    shutil.copytree(official / "export", stage / "export", symlinks=True)

    files = stage / "files"
    shutil.copy2(executable, files / "localsend_app")
    shutil.rmtree(files / "data")
    shutil.copytree(bundle / "data", files / "data", symlinks=True)
    # Preserve Flathub's Ayatana dependencies and replace only matching bundle libraries.
    for source in (bundle / "lib").rglob("*"):
        relative = source.relative_to(bundle / "lib")
        destination = files / "lib" / relative
        if source.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
        elif source.is_symlink():
            destination.unlink(missing_ok=True)
            destination.symlink_to(source.readlink())
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

    for name in bundle_binaries(bundle):
        if digest(files / name) != digest(bundle / name):
            raise RuntimeError(f"Staged {name} differs from this checkout's release bundle")
    for name in ("logo-32-black.png", "logo-32-white.png"):
        if digest(files / "data/flutter_assets/assets/img" / name) != digest(assets / name):
            raise RuntimeError(f"Staged {name} differs from release bundle")

    run("flatpak", "build-export", str(repo), str(stage), BRANCH)
    run("flatpak", "remote-add", "--user", "--if-not-exists", "--no-gpg-verify", REMOTE, str(repo))
    run("flatpak", "install", "--user", "--noninteractive", "--assumeyes", REMOTE, f"{APP_ID}//{BRANCH}")
    installed = Path(output("flatpak", "info", "--user", "--show-location", f"{APP_ID}//{BRANCH}"))
    for name in bundle_binaries(bundle):
        if digest(installed / "files" / name) != digest(bundle / name):
            raise RuntimeError(f"Installed Flatpak {name} differs from this checkout's release bundle")
    print(f"PASS installed {APP_ID}//{BRANCH} from release bundle {bundle}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"FAIL Flatpak packaging: {error}", file=sys.stderr)
        sys.exit(2)
