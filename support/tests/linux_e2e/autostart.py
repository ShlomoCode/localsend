# Observe autostart through fresh KDE logins after the original application's mount disappears.

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

from login_session import LinuxLogin


def wait_for(predicate, description, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(description)


class Autostart:
    def __init__(self, bundle, appimage, packaging, profile, evidence):
        self.bundle = Path(bundle).resolve()
        self.executable = self.bundle / "localsend_app" if packaging == "native" else Path(appimage).resolve()
        assert self.executable.is_file(), f"Missing {packaging} executable: {self.executable}"
        metadata = json.loads((self.bundle / "data/flutter_assets/version.json").read_text())
        self.desktop = profile / ".config/autostart" / f"{metadata['package_name']}.desktop"
        self.packaging, self.profile, self.evidence = packaging, profile, evidence
        self.counter = 0

    @contextmanager
    def login(self):
        self.counter += 1
        with LinuxLogin(self.profile, self.evidence / f"login-{self.counter}.log") as session:
            yield Login(self, session)


class Login:
    def __init__(self, harness, session):
        self.harness, self.session = harness, session

    def open_app(self):
        for prop in ("IsEnabled", "ScreenReaderEnabled"):
            self.session.run("busctl", "--user", "set-property", "org.a11y.Bus", "/org/a11y/bus",
                             "org.a11y.Status", prop, "b", "true")
        log = self.harness.evidence / f"app-{self.harness.counter}.log"
        env = self.session.env.copy()
        if self.harness.packaging == "native":
            env["LD_LIBRARY_PATH"] = str(self.harness.bundle / "lib")
        with log.open("ab") as output:
            process = subprocess.Popen([str(self.harness.executable)], env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT)
        return RunningApp(self.harness, self.session, self.session.wait_for_app(), process)

    def expect_autostart(self):
        return RunningApp(self.harness, self.session, self.session.wait_for_app())

    def expect_no_autostart(self):
        self.session.assert_no_app(seconds=15)


class RunningApp:
    def __init__(self, harness, session, pid, process=None):
        self.harness, self.session, self.pid, self.process = harness, session, pid, process
        self.desktop = harness.desktop
        executable = Path(f"/proc/{pid}/exe")
        assert hashlib.sha256(executable.read_bytes()).digest() == hashlib.sha256(
            (harness.bundle / "localsend_app").read_bytes()).digest(), "Autostart launched a different build"
        self.mount = None
        if harness.packaging == "appimage":
            real_executable = executable.resolve()
            self.mount = real_executable.parent
            assert self.mount.name.startswith(".mount_"), f"AppImage did not mount: {real_executable}"
            environment = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
            assert f"APPIMAGE={harness.executable}".encode() in environment, "AppImage runtime identity differs"
        print(f"Observed {harness.packaging} LocalSend PID {pid}, executable={executable.resolve()}", flush=True)

    def _ui(self, action):
        result = self.session.run(sys.executable, str(Path(__file__).with_name("autostart_ui.py")), action,
                                  check=False, timeout=75)
        (self.harness.evidence / f"ui-{self.harness.counter}-{action}.log").write_text(
            result.stdout + result.stderr, encoding="utf-8")
        assert result.returncode == 0, f"Accessibility action {action} failed: {result.stdout} {result.stderr}"

    def enable_autostart(self, hidden=False):
        self._ui("enable-hidden" if hidden else "enable")
        wait_for(self.desktop.is_file, "Application did not create its autostart entry")
        assert ("--hidden" in self.desktop.read_text()) == hidden
        (self.harness.evidence / "autostart.desktop").write_bytes(self.desktop.read_bytes())

    def disable_autostart(self):
        self._ui("disable")
        wait_for(lambda: not self.desktop.exists(), "Application did not remove its autostart entry")

    def close(self):
        self.session.stop_app(self.pid)
        if self.process is not None:
            self.process.wait(timeout=10)
        if self.mount is not None:
            wait_for(lambda: not self.mount.exists(), f"Original AppImage mount still exists: {self.mount}")

    def expect_hidden(self, hidden):
        if hidden:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                assert not self.session.visible(self.pid), "Autostart unexpectedly showed a window"
                time.sleep(0.2)
        else:
            wait_for(lambda: self.session.visible(self.pid), "Autostart did not show its window")
