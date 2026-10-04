"""A disposable, real KDE X11 login for LocalSend autostart tests."""

import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import time
import uuid

class InfrastructureError(RuntimeError):
    """The host cannot support the requested Linux session."""


WATCHER = ("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher")
DBUS = ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus")
SNI = "org.kde.StatusNotifierItem"


class LinuxLogin:
    """Start a fresh X server, session bus, and Plasma login using one persistent profile."""

    def __init__(self, profile: Path, log: Path):
        self.profile = Path(profile).resolve()
        self.log = Path(log).resolve()
        self.runtime = self.profile / f"runtime-{uuid.uuid4().hex}"
        self.env_file = self.runtime / "session-env.json"
        self.env = None
        self.xvfb = None
        self.session = None
        self._owned_app_pids = set()

    def __enter__(self):
        self.profile.mkdir(parents=True, exist_ok=True)
        for name in (".config", ".cache", ".local/share"):
            (self.profile / name).mkdir(parents=True, exist_ok=True)
        # Session restore could launch LocalSend without reading its autostart entry.
        (self.profile / ".config/ksmserverrc").write_text("[General]\nloginMode=emptySession\n", encoding="utf-8")
        (self.profile / ".config/startkderc").write_text("[General]\nsystemdBoot=false\n", encoding="utf-8")
        self.runtime.mkdir(mode=0o700)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._start_display()
            self._start_session()
            self._wait_for_desktop()
            return self
        except BaseException:
            self._cleanup()
            raise

    def _start_display(self):
        try:
            with self.log.open("ab") as output:
                self.xvfb = subprocess.Popen(
                    ["Xvfb", "-displayfd", "1", "-screen", "0", "1280x800x24", "-nolisten", "tcp", "-ac"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=output, start_new_session=True,
                )
        except OSError as error:
            raise InfrastructureError(f"Cannot start isolated Xvfb: {error}") from error
        ready, _, _ = select.select([self.xvfb.stdout], [], [], 10)
        if not ready:
            raise InfrastructureError("Isolated Xvfb did not assign a display within 10 seconds")
        number = self.xvfb.stdout.readline().decode("ascii", errors="replace").strip()
        if not number.isdigit() or self.xvfb.poll() is not None:
            raise InfrastructureError(f"Isolated Xvfb failed to assign a display: {number!r}")
        self.xvfb.stdout.close()
        display = f":{number}"
        self.env = os.environ.copy()
        for name in ("DBUS_SESSION_BUS_ADDRESS", "DBUS_SESSION_BUS_PID", "SESSION_MANAGER", "XAUTHORITY",
                     "APPIMAGE", "APPDIR", "ARGV0", "OWD", "AT_SPI_BUS_ADDRESS"):
            self.env.pop(name, None)
        self.env.update({
            "HOME": str(self.profile),
            "XDG_CONFIG_HOME": str(self.profile / ".config"),
            "XDG_CACHE_HOME": str(self.profile / ".cache"),
            "XDG_DATA_HOME": str(self.profile / ".local/share"),
            "XDG_DATA_DIRS": "/usr/local/share:/usr/share",
            "XDG_RUNTIME_DIR": str(self.runtime),
            "XDG_CURRENT_DESKTOP": "KDE",
            "XDG_SESSION_DESKTOP": "KDE",
            "DESKTOP_SESSION": "plasma",
            "XDG_SESSION_TYPE": "x11",
            "QT_QPA_PLATFORM": "xcb",
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "DISPLAY": display,
            "LC_ALL": "C.UTF-8",
            "NO_AT_BRIDGE": "0",
            "GTK_MODULES": "atk-bridge",
        })

    def _start_session(self):
        # The child writes its actual dbus-run-session address before Plasma starts.
        script = (
            'python3 -c \'import json,os,sys; json.dump({k:os.environ[k] for k in '
            '("DISPLAY","DBUS_SESSION_BUS_ADDRESS","HOME","XDG_CONFIG_HOME",'
            '"XDG_CACHE_HOME","XDG_DATA_HOME","XDG_RUNTIME_DIR")},open(sys.argv[1],"w"))\' "$1"; '
            'dbus-update-activation-environment DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP '
            'DESKTOP_SESSION XDG_SESSION_TYPE XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR HOME; '
            'exec startplasma-x11'
        )
        try:
            with self.log.open("ab") as output:
                self.session = subprocess.Popen(
                    ["dbus-run-session", "--", "bash", "-c", script, "login-session", str(self.env_file)],
                    env=self.env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
        except OSError as error:
            raise InfrastructureError(f"Cannot start isolated KDE login: {error}") from error
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.env_file.exists():
                try:
                    session_env = json.loads(self.env_file.read_text(encoding="utf-8"))
                except (ValueError, OSError):
                    time.sleep(0.05)
                    continue
                self.env.update(session_env)
                return
            if self.session.poll() is not None:
                raise InfrastructureError(f"KDE login exited before publishing its session bus (exit {self.session.returncode})")
            time.sleep(0.05)
        raise InfrastructureError("KDE login did not publish its session bus within 10 seconds")

    def run(self, *argv, check=True, timeout=10, **kwargs):
        if self.env is None or "DBUS_SESSION_BUS_ADDRESS" not in self.env:
            raise InfrastructureError("KDE login is not running")
        kwargs.setdefault("env", self.env)
        kwargs.setdefault("text", True)
        kwargs.setdefault("capture_output", True)
        kwargs.setdefault("timeout", timeout)
        try:
            result = subprocess.run(argv, **kwargs)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise InfrastructureError(f"Cannot run {shlex.join(map(str, argv))} in KDE login: {error}") from error
        if check and result.returncode:
            raise InfrastructureError(f"{shlex.join(map(str, argv))} failed ({result.returncode}): {result.stderr.strip()}")
        return result

    def _items(self):
        result = self.run("busctl", "--user", "get-property", *WATCHER, "RegisteredStatusNotifierItems")
        values = shlex.split(result.stdout.strip())
        if len(values) < 2 or values[0] != "as" or not values[1].isdigit() or len(values[2:]) != int(values[1]):
            raise InfrastructureError(f"Unexpected KDE watcher response: {result.stdout.strip()}")
        return values[2:]

    def _wait_for_desktop(self, seconds=60):
        deadline = time.monotonic() + seconds
        last = "no reply"
        while time.monotonic() < deadline:
            if self.session.poll() is not None or self.xvfb.poll() is not None:
                raise InfrastructureError("Isolated KDE login exited before its tray watcher was ready")
            try:
                self._items()
                self.run("busctl", "--user", "call", "org.freedesktop.portal.Desktop",
                         "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "Read", "ss",
                         "org.freedesktop.appearance", "color-scheme")
                return
            except InfrastructureError as error:
                last = str(error)
            time.sleep(0.25)
        raise InfrastructureError(f"Isolated KDE watcher and portal did not become ready: {last}")

    def _app_pids(self):
        found = set()
        for item in self._items():
            if "/" not in item:
                raise InfrastructureError(f"Malformed tray item address: {item}")
            service, path = item.split("/", 1)
            for name in ("Id", "Title"):
                prop = self.run("busctl", "--user", "get-property", service, "/" + path, SNI, name, check=False)
                if prop.returncode:
                    continue
                value = shlex.split(prop.stdout.strip())
                if len(value) != 2 or value[0] != "s" or "localsend" not in value[1].casefold():
                    continue
                owner = self.run("busctl", "--user", "call", *DBUS, "GetConnectionUnixProcessID", "s", service,
                                 check=False)
                if owner.returncode:
                    break
                pid = shlex.split(owner.stdout.strip())
                if len(pid) != 2 or pid[0] != "u" or not pid[1].isdigit():
                    raise InfrastructureError(f"Unexpected D-Bus owner PID: {owner.stdout.strip()}")
                found.add(int(pid[1]))
                break
        return found

    def wait_for_app(self, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            pids = self._app_pids()
            if len(pids) == 1:
                pid = pids.pop()
                self._owned_app_pids.add(pid)
                return pid
            if len(pids) > 1:
                raise AssertionError(f"Multiple LocalSend tray owners in isolated KDE login: {sorted(pids)}")
            time.sleep(0.25)
        raise AssertionError("LocalSend did not appear in the isolated KDE login")

    def assert_no_app(self, seconds=8):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            pids = self._app_pids()
            if pids:
                raise AssertionError(f"LocalSend unexpectedly started in the isolated KDE login: {sorted(pids)}")
            time.sleep(0.25)

    def visible(self, pid):
        result = self.run("xdotool", "search", "--pid", str(pid), "--onlyvisible", check=False)
        return result.returncode == 0 and bool(result.stdout.strip())

    def stop_app(self, pid):
        # Only stop a process already identified through this login's private bus.
        if pid not in self._owned_app_pids:
            raise InfrastructureError(f"PID {pid} is not a LocalSend owner identified in this login")
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if pid not in self._app_pids():
                return
            time.sleep(0.2)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if pid not in self._app_pids():
                return
            time.sleep(0.2)
        raise InfrastructureError(f"LocalSend PID {pid} did not leave the isolated login")

    def _session_pids(self):
        marker = f"XDG_RUNTIME_DIR={self.runtime}".encode()
        pids = set()
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit() or int(entry.name) == os.getpid():
                continue
            try:
                if marker in (entry / "environ").read_bytes().split(b"\0"):
                    pids.add(int(entry.name))
            except (OSError, PermissionError):
                continue
        return pids

    def _cleanup(self):
        for process in (self.session, self.xvfb):
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for pid in self._session_pids():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while self._session_pids() and time.monotonic() < deadline:
            time.sleep(0.1)
        for pid in self._session_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in (self.session, self.xvfb):
            if process is not None:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        shutil.rmtree(self.runtime, ignore_errors=True)

    def __exit__(self, _exc_type, _exc, _tb):
        self._cleanup()
