#!/usr/bin/env python3
# Verify LocalSend's real D-Bus tray icon at startup and during KDE light/dark changes.

"""End-to-end Linux tray regression test. Exit 1: behavior; exit 2: environment."""

import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time


class InfrastructureError(Exception):
    pass


WATCHER = ("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher")
PORTAL = ("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings")
DBUS = ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus")


def command(*argv, env=None, check=True, timeout=10):
    try:
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InfrastructureError(f"Cannot run {' '.join(argv)}: {error}") from error
    if check and result.returncode:
        raise InfrastructureError(f"{' '.join(argv)} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def property_value(destination, path, interface, name):
    result = command("busctl", "--user", "get-property", destination, path, interface, name)
    return shlex.split(result.stdout.strip())


def color_scheme():
    result = command("busctl", "--user", "call", *PORTAL, "Read", "ss", "org.freedesktop.appearance", "color-scheme")
    values = shlex.split(result.stdout.strip())
    while values and values[0] == "v":
        values.pop(0)
    if len(values) != 2 or values[0] != "u" or not values[1].isdigit():
        raise InfrastructureError(f"Unexpected KDE portal color-scheme reply: {result.stdout.strip()}")
    return int(values[1])


def wait_for_desktop(seconds=60):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            registered_items()
            color_scheme()
            return
        except InfrastructureError as error:
            last = str(error)
        time.sleep(0.25)
    raise InfrastructureError(f"KDE watcher and color portal did not become ready: {last}")


def wait_for_portal(expected, seconds=25):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = color_scheme()
            if last == expected:
                return
        except InfrastructureError as error:
            last = str(error)
        time.sleep(0.25)
    raise InfrastructureError(f"KDE portal did not report color scheme {expected}; last reply: {last}")


def config_reader():
    for executable in ("kreadconfig6", "kreadconfig5"):
        if command("which", executable, check=False).returncode == 0:
            return executable
    raise InfrastructureError("KDE kreadconfig is unavailable")


def kde_setting(reader, group, key):
    return command(reader, "--file", "kdeglobals", "--group", group, "--key", key).stdout.strip()


def apply_theme(mode):
    package, scheme, expected = {
        "light": ("org.kde.breeze.desktop", "BreezeLight", 2),
        "dark": ("org.kde.breezedark.desktop", "BreezeDark", 1),
    }[mode]
    command("plasma-apply-lookandfeel", "-a", package, timeout=20)
    command("plasma-apply-colorscheme", scheme, timeout=20)
    wait_for_portal(expected)
    print(f"KDE portal: {mode} ({expected})", flush=True)


def registered_items():
    values = property_value(*WATCHER, "RegisteredStatusNotifierItems")
    if len(values) < 2 or values[0] != "as" or not values[1].isdigit():
        raise InfrastructureError(f"Unexpected KDE StatusNotifierWatcher reply: {values}")
    count = int(values[1])
    if len(values[2:]) != count:
        raise InfrastructureError(f"Malformed StatusNotifierWatcher item count: {values}")
    return values[2:]


def owner_pid(service):
    result = command("busctl", "--user", "call", *DBUS, "GetConnectionUnixProcessID", "s", service, check=False)
    if result.returncode:
        return None  # A registered item may vanish while it is being inspected.
    values = shlex.split(result.stdout.strip())
    if len(values) != 2 or values[0] != "u" or not values[1].isdigit():
        raise InfrastructureError(f"Unexpected D-Bus owner PID reply: {result.stdout.strip()}")
    return int(values[1])


def icon_for_pid(pid):
    for item in registered_items():
        if "/" not in item:
            raise InfrastructureError(f"Malformed StatusNotifierItem address: {item}")
        service, path = item.split("/", 1)
        if owner_pid(service) != pid:
            continue
        result = command("busctl", "--user", "get-property", service, "/" + path,
                         "org.kde.StatusNotifierItem", "IconName", check=False)
        if result.returncode:
            return None  # Icon can be replaced while the theme is changing.
        values = shlex.split(result.stdout.strip())
        if len(values) != 2 or values[0] != "s":
            raise InfrastructureError(f"Unexpected StatusNotifierItem IconName: {result.stdout.strip()}")
        return values[1]
    return None


def assert_icon(process, expected, label, seconds=25):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise InfrastructureError(f"LocalSend exited during {label} (exit {process.returncode})")
        last = icon_for_pid(process.pid)
        if last is not None and Path(last).name == expected:
            print(f"PASS {label}: PID {process.pid}, IconName={last}", flush=True)
            return
        time.sleep(0.25)
    raise AssertionError(f"{label}: expected {expected} from PID {process.pid}; last IconName={last!r}")


def start_app(bundle, profile, label, logfile):
    env = os.environ.copy()
    env.update({
        "XDG_CONFIG_HOME": str(profile / "config"),
        "XDG_CACHE_HOME": str(profile / "cache"),
        "XDG_DATA_HOME": str(profile / "data"),
        "LD_LIBRARY_PATH": str(bundle / "lib"),
    })
    executable = bundle / "localsend_app"
    if not executable.is_file():
        raise InfrastructureError(f"Built LocalSend executable missing: {executable}")
    log = open(logfile, "a", encoding="utf-8")
    log.write(f"\n=== {label} ===\n")
    log.flush()
    try:
        process = subprocess.Popen([str(executable)], cwd=bundle, env=env, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as error:
        log.close()
        raise InfrastructureError(f"Could not launch LocalSend: {error}") from error
    log.close()
    return process


def stop_app(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="app/build/linux/<arch>/release/bundle")
    parser.add_argument("--log", type=Path, default=Path("linux-tray-e2e.log"))
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    reader = config_reader()
    original_package = kde_setting(reader, "KDE", "LookAndFeelPackage")
    original_scheme = kde_setting(reader, "General", "ColorScheme")
    wait_for_desktop()
    process = None
    with tempfile.TemporaryDirectory(prefix="localsend-tray-e2e-") as tempdir:
        profile = Path(tempdir)
        try:
            apply_theme("light")
            process = start_app(bundle, profile, "light startup", args.log)
            assert_icon(process, "logo-32-black.png", "light startup")
            apply_theme("dark")
            assert_icon(process, "logo-32-white.png", "light to dark")
            apply_theme("light")
            assert_icon(process, "logo-32-black.png", "dark to light")
            stop_app(process)
            process = None
            apply_theme("dark")
            process = start_app(bundle, profile, "dark startup", args.log)
            assert_icon(process, "logo-32-white.png", "dark startup")
        finally:
            prior_failure = sys.exc_info()[0] is not None
            stop_app(process)
            try:
                if original_package:
                    command("plasma-apply-lookandfeel", "-a", original_package, timeout=20)
                if original_scheme:
                    command("plasma-apply-colorscheme", original_scheme, timeout=20)
            except InfrastructureError as error:
                if not prior_failure:
                    raise
                print(f"WARN theme restoration: {error}", file=sys.stderr)
    print("PASS real KDE D-Bus tray regression", flush=True)


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL behavior: {error}", file=sys.stderr)
        sys.exit(1)
    except InfrastructureError as error:
        print(f"FAIL infrastructure: {error}", file=sys.stderr)
        sys.exit(2)
