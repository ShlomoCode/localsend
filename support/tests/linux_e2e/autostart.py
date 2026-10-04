# Inspect the OS-facing desktop entry after driving the real LocalSend Settings UI.

import configparser
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from runtime import command


UNSET = object()
A11Y = ("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status")


def wait_for(predicate, description, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(description)


class Autostart:
    def __init__(self, bundle, home, evidence, launch_app):
        self.bundle = Path(bundle)
        self.home = Path(home)
        self.evidence = Path(evidence)
        self.launch_app = launch_app
        self.app = None
        self.entry = None
        self.actual_config = None
        self.action_number = 0
        self.evidence.mkdir(parents=True, exist_ok=True)
        metadata_path = self.bundle / "data/flutter_assets/version.json"
        assert metadata_path.is_file(), f"Release bundle is missing {metadata_path}"
        self.package_name = json.loads(metadata_path.read_text(encoding="utf-8"))["package_name"]
        assert self.package_name and "/" not in self.package_name, f"Invalid package_name in {metadata_path}"

    def start(self, xdg_config_home=UNSET):
        assert self.app is None, "Only one application launch is supported per autostart scenario"
        self.home.mkdir(parents=True, exist_ok=True)
        for prop in ("IsEnabled", "ScreenReaderEnabled"):
            command("busctl", "--user", "set-property", *A11Y, prop, "b", "true")
        env = {"HOME": str(self.home), "NO_AT_BRIDGE": "0", "GTK_MODULES": "atk-bridge", "LC_ALL": "C.UTF-8"}
        env["XDG_CONFIG_HOME"] = None if xdg_config_home is UNSET else str(xdg_config_home)
        self.actual_config = env["XDG_CONFIG_HOME"]
        self.entry = self.expected_entry(xdg_config_home)
        self.app = self.launch_app(env=env)
        self.snapshot("startup")
        return self

    def expected_entry(self, xdg_config_home=UNSET):
        config = Path(xdg_config_home) if xdg_config_home is not UNSET and xdg_config_home is not None else None
        if config is None or not config.is_absolute():
            config = self.home / ".config"
        return config / "autostart" / f"{self.package_name}.desktop"

    def snapshot(self, stage):
        if self.app is None:
            return
        paths = {self.entry, self.home / ".config/autostart" / f"{self.package_name}.desktop"}
        entries = {str(path): path.read_text(encoding="utf-8") if path.is_file() else None for path in paths}
        report = {"stage": stage, "pid": self.app.process.pid, "home": str(self.home),
                  "xdg_config_home": self.actual_config, "expected_entry": str(self.entry), "entries": entries,
                  "app_log": str(self.app.log)}
        safe_stage = "".join(char if char.isalnum() or char in "-_" else "_" for char in stage)
        (self.evidence / f"{safe_stage}.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def ui(self, action):
        assert self.app is not None, "Launch LocalSend before using its Settings UI"
        self.app.assert_same_instance()
        self.action_number += 1
        env = os.environ.copy()
        env.update({"NO_AT_BRIDGE": "0", "GTK_MODULES": "atk-bridge", "LC_ALL": "C.UTF-8"})
        argv = [sys.executable, str(Path(__file__).with_name("autostart_ui.py")), action, "--pid", str(self.app.process.pid)]
        try:
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=75)
            output = f"exit={result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        except subprocess.TimeoutExpired as error:
            output = f"timeout after 75 seconds\nstdout:\n{error.stdout!r}\nstderr:\n{error.stderr!r}"
            result = None
        stem = f"ui-{self.action_number:02d}-{action}"
        (self.evidence / f"{stem}.log").write_text(output, encoding="utf-8")
        self.snapshot(stem)
        assert result is not None and result.returncode == 0, f"LocalSend Settings action {action!r} failed for PID {self.app.process.pid}; see {stem}.log: {output}"
        return result.stdout

    def enable(self, hidden=False):
        self.ui("enable-hidden" if hidden else "enable")
        wait_for(self.entry.is_file, f"Enabling autostart did not create {self.entry}")
        self.snapshot("enabled")

    def disable(self):
        self.ui("disable")
        wait_for(lambda: not self.entry.exists(), f"Disabling autostart did not remove {self.entry}")
        self.snapshot("disabled")

    def entry_fields(self):
        assert self.entry is not None and self.entry.is_file(), f"Missing expected autostart desktop entry: {self.entry}"
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read(self.entry, encoding="utf-8")
        assert parser.has_section("Desktop Entry"), f"{self.entry} has no [Desktop Entry] section"
        return parser["Desktop Entry"]
