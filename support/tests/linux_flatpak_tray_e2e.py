#!/usr/bin/env python3
# Check that a real LocalSend Flatpak publishes the correct host-readable KDE tray icon in both themes.

"""End-to-end Flatpak tray test: exit 1 for behavior, 2 for infrastructure."""

import argparse
import hashlib
from pathlib import Path
import shlex
import subprocess
import sys
import time

from linux_tray_e2e import (InfrastructureError, apply_theme, command, config_reader,
                            kde_setting, property_value, registered_items, wait_for_desktop)


APP_ID = "org.localsend.localsend_app"
BRANCH = "e2e"
SNI = "org.kde.StatusNotifierItem"


def instances():
    result = command("flatpak", "ps", "--columns=instance,application:full,branch:full")
    found = {}
    for line in result.stdout.splitlines():
        columns = line.split()
        if len(columns) >= 3 and columns[0].isdigit() and columns[1] == APP_ID:
            found[columns[0]] = columns[2]
    return found


def bundle_binaries(bundle):
    return [Path("localsend_app"), *(path.relative_to(bundle) for path in sorted((bundle / "lib").rglob("*")) if path.is_file())]


def wait_for_instance(previous, process, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        current = instances()
        created = set(current) - previous
        if len(created) == 1:
            return created.pop()
        if len(created) > 1:
            raise InfrastructureError(f"More than one LocalSend Flatpak instance appeared: {created}")
        if process.poll() is not None:
            raise InfrastructureError(f"Flatpak exited before registering an instance (exit {process.returncode})")
        time.sleep(0.25)
    raise InfrastructureError("Flatpak did not start an application instance")


def validate_sandbox(instance):
    branch = instances().get(instance)
    if branch != BRANCH:
        raise InfrastructureError(f"Launched Flatpak on branch {branch}, expected {BRANCH}")
    command("flatpak", "enter", instance, "sh", "-c",
            f"test -f /.flatpak-info && test -x /app/localsend_app && grep -q '{APP_ID}' /.flatpak-info")


def icon_for_item(item):
    if "/" not in item:
        raise InfrastructureError(f"Malformed StatusNotifierItem address: {item}")
    service, path = item.split("/", 1)
    result = command("busctl", "--user", "get-property", service, "/" + path, SNI, "IconName", check=False)
    if result.returncode:
        return None  # The icon may be momentarily replaced while the theme changes.
    values = shlex.split(result.stdout.strip())
    if len(values) != 2 or values[0] != "s":
        raise InfrastructureError(f"Unexpected StatusNotifierItem IconName: {result.stdout.strip()}")
    return values[1]


def is_localsend_item(item):
    service, path = item.split("/", 1)
    for name in ("Id", "Title"):
        try:
            values = property_value(service, "/" + path, SNI, name)
        except InfrastructureError:
            continue  # The item may be re-registering during startup.
        if len(values) == 2 and values[0] == "s" and "localsend" in values[1].casefold():
            return True
    return False


def digest(data):
    return hashlib.sha256(data).hexdigest()


def host_icon_path(name):
    path = Path(name)
    if path.is_absolute():
        return path if path.is_file() else None
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
    except (ImportError, ValueError) as error:
        raise InfrastructureError(f"Host GTK icon theme lookup is unavailable: {error}") from error
    initialized = Gtk.init_check()
    if not (initialized[0] if isinstance(initialized, tuple) else initialized):
        raise InfrastructureError("GTK cannot initialize the host KDE display")
    theme = Gtk.IconTheme.get_default()
    if theme is None:
        raise InfrastructureError("No GTK icon theme is available on the host")
    icon = theme.lookup_icon(name, 32, 0)
    if icon is None:
        return None
    filename = icon.get_filename()
    return Path(filename) if filename and Path(filename).is_file() else None


def assert_icon(instance, existing_items, expected_asset, label, item=None, seconds=25):
    deadline = time.monotonic() + seconds
    last = None
    last_path = None
    last_hash = None
    while time.monotonic() < deadline:
        if instance not in instances():
            raise InfrastructureError(f"Flatpak instance {instance} exited during {label}")
        candidates = registered_items()
        if item is None:
            new_items = {candidate for candidate in set(candidates) - existing_items
                         if is_localsend_item(candidate)}
            if len(new_items) == 1:
                item = new_items.pop()
            elif len(new_items) > 1:
                raise InfrastructureError(f"More than one new tray item appeared: {new_items}")
        if item is not None and item in candidates:
            last = icon_for_item(item)
            if last:
                path = host_icon_path(last)
                if path is not None:
                    actual = path.read_bytes()
                    last_path = path
                    last_hash = digest(actual)
                    if last_hash == digest(expected_asset.read_bytes()):
                        print(f"PASS {label}: Flatpak instance {instance}, {item}, host icon {path}, "
                              f"SHA-256 {last_hash}", flush=True)
                        return item
        time.sleep(0.25)
    raise AssertionError(f"{label}: expected host-readable {expected_asset.name} "
                         f"(SHA-256 {digest(expected_asset.read_bytes())}) from instance {instance}; "
                         f"last tray item={item!r}, IconName={last!r}, host file={last_path}, SHA-256={last_hash}")


def start_app(logfile):
    log = open(logfile, "a", encoding="utf-8")
    log.write("\n=== Flatpak startup ===\n")
    log.flush()
    try:
        process = subprocess.Popen(["flatpak", "run", "--user", f"--branch={BRANCH}", APP_ID],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    except OSError as error:
        log.close()
        raise InfrastructureError(f"Could not launch Flatpak: {error}") from error
    log.close()
    return process


def stop_app(instance, process):
    if instance is not None and instances().get(instance) == BRANCH:
        command("flatpak", "kill", instance)
    if process is not None:
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--log", type=Path, default=Path("linux-flatpak-tray-e2e.log"))
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    assets = bundle / "data/flutter_assets/assets/img"
    black = assets / "logo-32-black.png"
    white = assets / "logo-32-white.png"
    for path in (black, white):
        if not path.is_file():
            raise InfrastructureError(f"Built tray asset missing: {path}")
    deployment = command("flatpak", "info", "--user", "--show-location", f"{APP_ID}//{BRANCH}").stdout.strip()
    for name in bundle_binaries(bundle):
        installed = Path(deployment) / "files" / name
        built = bundle / name
        if not installed.is_file() or not built.is_file() or digest(installed.read_bytes()) != digest(built.read_bytes()):
            raise InfrastructureError(f"Installed Flatpak {name} differs from this checkout's release bundle")
    if instances():
        raise InfrastructureError(f"An existing {APP_ID} Flatpak is running; refusing to affect it")

    reader = config_reader()
    original_package = kde_setting(reader, "KDE", "LookAndFeelPackage")
    original_scheme = kde_setting(reader, "General", "ColorScheme")
    wait_for_desktop()
    process = None
    instance = None
    try:
        apply_theme("dark")
        prior_items = set(registered_items())
        process = start_app(args.log)
        instance = wait_for_instance(set(), process)
        validate_sandbox(instance)
        item = assert_icon(instance, prior_items, white, "dark startup control")
        apply_theme("light")
        assert_icon(instance, prior_items, black, "dark to light", item)
        apply_theme("dark")
        assert_icon(instance, prior_items, white, "light to dark", item)
        stop_app(instance, process)
        instance = None
        process = None
        apply_theme("light")
        prior_items = set(registered_items())
        process = start_app(args.log)
        instance = wait_for_instance(set(), process)
        validate_sandbox(instance)
        assert_icon(instance, prior_items, black, "light startup")
    finally:
        prior_failure = sys.exc_info()[0] is not None
        try:
            stop_app(instance, process)
        finally:
            try:
                if original_package:
                    command("plasma-apply-lookandfeel", "-a", original_package, timeout=20)
                if original_scheme:
                    command("plasma-apply-colorscheme", original_scheme, timeout=20)
            except InfrastructureError as error:
                if not prior_failure:
                    raise
                print(f"WARN theme restoration: {error}", file=sys.stderr)
    print("PASS real Flatpak KDE D-Bus tray regression", flush=True)


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL behavior: {error}", file=sys.stderr)
        sys.exit(1)
    except (InfrastructureError, OSError) as error:
        print(f"FAIL infrastructure: {error}", file=sys.stderr)
        sys.exit(2)
