#!/usr/bin/env python3
# Exercise LocalSend's real KDE tray item and restore the desktop after each test.

"""Shared Linux tray E2E mechanics for pytest; failures use assertions or InfrastructureError."""

import hashlib
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time


class InfrastructureError(Exception):
    """The host or test package cannot support the requested E2E check."""


WATCHER = ("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher")
PORTAL = ("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings")
DBUS = ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus")
SNI = "org.kde.StatusNotifierItem"
APP_ID = "org.localsend.localsend_app"
BRANCH = "e2e"


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


def registered_items():
    values = property_value(*WATCHER, "RegisteredStatusNotifierItems")
    if len(values) < 2 or values[0] != "as" or not values[1].isdigit():
        raise InfrastructureError(f"Unexpected KDE StatusNotifierWatcher reply: {values}")
    count = int(values[1])
    if len(values[2:]) != count:
        raise InfrastructureError(f"Malformed StatusNotifierWatcher item count: {values}")
    return values[2:]


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
    had_reply = False
    while time.monotonic() < deadline:
        try:
            last = color_scheme()
            had_reply = True
            if last == expected:
                return
        except InfrastructureError as error:
            last = str(error)
        time.sleep(0.25)
    if not had_reply:
        raise InfrastructureError(f"KDE portal stopped responding: {last}")
    raise AssertionError(f"KDE portal expected color scheme {expected}; last reply: {last}")


def config_reader():
    for executable in ("kreadconfig6", "kreadconfig5"):
        if command("which", executable, check=False).returncode == 0:
            return executable
    raise InfrastructureError("KDE kreadconfig is unavailable")


def kde_setting(reader, group, key):
    return command(reader, "--file", "kdeglobals", "--group", group, "--key", key).stdout.strip()


class Desktop:
    """Save the KDE theme, expose deterministic theme changes, and restore it on exit."""

    def __init__(self):
        self.original_package = None
        self.original_scheme = None

    def __enter__(self):
        wait_for_desktop()
        reader = config_reader()
        self.original_package = kde_setting(reader, "KDE", "LookAndFeelPackage")
        self.original_scheme = kde_setting(reader, "General", "ColorScheme")
        return self

    def set_theme(self, theme):
        package, scheme, portal_value = {
            "light": ("org.kde.breeze.desktop", "BreezeLight", 2),
            "dark": ("org.kde.breezedark.desktop", "BreezeDark", 1),
        }[theme]
        command("plasma-apply-lookandfeel", "-a", package, timeout=20)
        command("plasma-apply-colorscheme", scheme, timeout=20)
        wait_for_portal(portal_value)

    def __exit__(self, exc_type, _exc, _tb):
        errors = []
        if self.original_package:
            try:
                command("plasma-apply-lookandfeel", "-a", self.original_package, timeout=20)
            except InfrastructureError as error:
                errors.append(str(error))
        if self.original_scheme:
            try:
                command("plasma-apply-colorscheme", self.original_scheme, timeout=20)
            except InfrastructureError as error:
                errors.append(str(error))
        if errors:
            if exc_type is None:
                raise InfrastructureError("KDE theme restoration: " + "; ".join(errors))
            print(f"WARN KDE theme restoration: {'; '.join(errors)}", file=sys.stderr)


def owner_pid(service):
    result = command("busctl", "--user", "call", *DBUS, "GetConnectionUnixProcessID", "s", service, check=False)
    if result.returncode:
        return None
    values = shlex.split(result.stdout.strip())
    if len(values) != 2 or values[0] != "u" or not values[1].isdigit():
        raise InfrastructureError(f"Unexpected D-Bus owner PID reply: {result.stdout.strip()}")
    return int(values[1])


def item_address(item):
    if "/" not in item:
        raise InfrastructureError(f"Malformed StatusNotifierItem address: {item}")
    service, path = item.split("/", 1)
    return service, "/" + path


def is_localsend_item(item):
    service, path = item_address(item)
    for name in ("Id", "Title"):
        try:
            values = property_value(service, path, SNI, name)
        except InfrastructureError:
            continue
        if len(values) == 2 and values[0] == "s" and "localsend" in values[1].casefold():
            return True
    return False


def icon_for_item(item):
    service, path = item_address(item)
    result = command("busctl", "--user", "get-property", service, path, SNI, "IconName", check=False)
    if result.returncode:
        return None
    values = shlex.split(result.stdout.strip())
    if len(values) != 2 or values[0] != "s":
        raise InfrastructureError(f"Unexpected StatusNotifierItem IconName: {result.stdout.strip()}")
    return values[1]


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


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


class App:
    """Own one LocalSend process and its fixed status notifier item."""

    def __init__(self, bundle, packaging, profile, log):
        if packaging not in ("native", "flatpak"):
            raise ValueError("packaging must be native or flatpak")
        self.bundle = Path(bundle).resolve()
        self.packaging = packaging
        self.profile = Path(profile) if profile is not None else None
        self.log = Path(log).resolve()
        self.process = None
        self.instance = None
        self.item = None
        self._prior_items = None
        self._temp_profile = None

    @classmethod
    def create(cls, bundle, packaging, profile, log):
        return cls(bundle, packaging, profile, log)

    @property
    def identity(self):
        return {"pid": self.process.pid if self.process else None, "instance": self.instance, "item": self.item}

    def _assets(self):
        assets = {color: self.bundle / "data/flutter_assets/assets/img" / f"logo-32-{color}.png"
                  for color in ("black", "white")}
        for path in assets.values():
            if not path.is_file():
                raise InfrastructureError(f"Built tray asset missing: {path}")
        return assets

    def _validate(self):
        executable = self.bundle / "localsend_app"
        if not executable.is_file():
            raise InfrastructureError(f"Built LocalSend executable missing: {executable}")
        assets = self._assets()
        if self.packaging == "flatpak":
            deployment = command("flatpak", "info", "--user", "--show-location", f"{APP_ID}//{BRANCH}").stdout.strip()
            if not deployment:
                raise InfrastructureError("Flatpak installation location is empty")
            files = Path(deployment) / "files"
            for name in [*bundle_binaries(self.bundle),
                         *(path.relative_to(self.bundle) for path in assets.values())]:
                installed = files / name
                built = self.bundle / name
                if not installed.is_file() or digest(installed) != digest(built):
                    raise InfrastructureError(f"Installed Flatpak {name} differs from this checkout's release bundle")
            if instances():
                raise InfrastructureError(f"An existing {APP_ID} Flatpak is running; refusing to affect it")

    def __enter__(self):
        self._validate()
        self._prior_items = set(registered_items())
        if self.profile is None:
            self._temp_profile = tempfile.TemporaryDirectory(prefix="localsend-tray-e2e-")
            self.profile = Path(self._temp_profile.name)
        home = self.profile / "home"
        home.mkdir(parents=True, exist_ok=True)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        try:
            with self.log.open("a", encoding="utf-8") as logfile:
                logfile.write(f"\n=== {self.packaging} LocalSend startup ===\n")
                logfile.flush()
                if self.packaging == "flatpak":
                    self.process = subprocess.Popen(["flatpak", "run", "--user", f"--branch={BRANCH}", APP_ID],
                                                    stdin=subprocess.DEVNULL, stdout=logfile, stderr=subprocess.STDOUT,
                                                    start_new_session=True)
                else:
                    env = os.environ.copy()
                    env.update({"HOME": str(home),
                                "XDG_CONFIG_HOME": str(self.profile / "config"),
                                "XDG_CACHE_HOME": str(self.profile / "cache"),
                                "XDG_DATA_HOME": str(self.profile / "data"),
                                "LD_LIBRARY_PATH": str(self.bundle / "lib")})
                    self.process = subprocess.Popen([str(self.bundle / "localsend_app")], cwd=self.bundle, env=env,
                                                    stdin=subprocess.DEVNULL, stdout=logfile, stderr=subprocess.STDOUT,
                                                    start_new_session=True)
            if self.packaging == "flatpak":
                self._wait_for_instance()
                self._validate_sandbox()
            return self
        except BaseException:
            self._cleanup(suppress=True)
            raise

    def _wait_for_instance(self, seconds=25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            current = instances()
            created = set(current)
            if len(created) == 1:
                self.instance = created.pop()
                return
            if len(created) > 1:
                raise InfrastructureError(f"More than one LocalSend Flatpak instance appeared: {created}")
            if self.process.poll() is not None:
                raise InfrastructureError(f"Flatpak exited before registering an instance (exit {self.process.returncode})")
            time.sleep(0.25)
        raise InfrastructureError("Flatpak did not start an application instance")

    def _validate_sandbox(self):
        if instances().get(self.instance) != BRANCH:
            raise InfrastructureError(f"Launched Flatpak is not on branch {BRANCH}")
        command("flatpak", "enter", self.instance, "sh", "-c",
                f"test -f /.flatpak-info && test -x /app/localsend_app && grep -q '{APP_ID}' /.flatpak-info")

    def _find_item(self):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            self.assert_same_instance()
            candidates = set(registered_items()) - self._prior_items
            if self.packaging == "flatpak":
                matching = [item for item in candidates if is_localsend_item(item)]
            else:
                matching = [item for item in candidates if owner_pid(item_address(item)[0]) == self.process.pid]
            if len(matching) == 1:
                self.item = matching[0]
                return
            if len(matching) > 1:
                raise InfrastructureError(f"More than one new LocalSend tray item appeared: {matching}")
            time.sleep(0.25)
        raise AssertionError("LocalSend did not register a new tray item")

    def assert_same_instance(self):
        if self.process is None:
            raise InfrastructureError("LocalSend is not running in this test")
        if self.packaging == "flatpak":
            if instances().get(self.instance) != BRANCH:
                raise AssertionError(f"Original Flatpak instance {self.instance} is no longer running")
        elif self.process.poll() is not None:
            raise AssertionError(f"Original LocalSend PID {self.process.pid} exited")
        if self.item is not None:
            if self.item not in registered_items():
                raise AssertionError(f"Original tray item {self.item} is no longer registered")
            if self.packaging == "native" and owner_pid(item_address(self.item)[0]) != self.process.pid:
                raise AssertionError(f"Tray item {self.item} no longer belongs to PID {self.process.pid}")

    def expect_icon(self, color, seconds=25):
        if color not in ("black", "white"):
            raise ValueError("Expected icon color must be black or white")
        expected = self._assets()[color]
        if self.item is None:
            self._find_item()
        expected_hash = digest(expected)
        deadline = time.monotonic() + seconds
        last = None
        last_path = None
        last_hash = None
        while time.monotonic() < deadline:
            self.assert_same_instance()
            last = icon_for_item(self.item)
            if last:
                path = host_icon_path(last)
                if path is not None:
                    last_path = path
                    last_hash = digest(path)
                    if last_hash == expected_hash:
                        return
            time.sleep(0.25)
        raise AssertionError(f"Expected host-readable {expected.name} (SHA-256 {expected_hash}) from "
                             f"{self.identity}; last IconName={last!r}, host file={last_path}, SHA-256={last_hash}")

    def _cleanup(self, suppress=False):
        errors = []
        try:
            if self.packaging == "flatpak" and self.instance is not None and instances().get(self.instance) == BRANCH:
                command("flatpak", "kill", self.instance)
        except InfrastructureError as error:
            errors.append(str(error))
        try:
            if self.process is not None and self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    self.process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))
        try:
            if self.packaging == "flatpak" and self.instance is not None:
                deadline = time.monotonic() + 10
                while self.instance in instances() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if self.instance in instances():
                    raise InfrastructureError(f"Flatpak instance {self.instance} is still listed after stopping it")
        except InfrastructureError as error:
            errors.append(str(error))
        finally:
            if self._temp_profile is not None:
                self._temp_profile.cleanup()
                self._temp_profile = None
        if errors:
            if not suppress:
                raise InfrastructureError("LocalSend cleanup: " + "; ".join(errors))
            print(f"WARN LocalSend cleanup: {'; '.join(errors)}", file=sys.stderr)

    def __exit__(self, exc_type, _exc, _tb):
        self._cleanup(suppress=exc_type is not None)
