# Check the real Linux autostart integration through LocalSend's settings UI.

import json
from pathlib import Path
import time

import pytest

from autostart_ui import open_settings, set_switch
from runtime import command


pytestmark = pytest.mark.packaging("native")


def wait_for_entry(paths, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        existing = [path for path in paths if path.is_file()]
        if existing:
            assert len(existing) == 1, (
                f"Multiple autostart entries were created: {existing}"
            )
            return existing[0]
        time.sleep(0.2)
    raise AssertionError(
        f"LocalSend did not create an autostart entry at any of: {paths}"
    )


def entry_paths(app):
    metadata = json.loads((app.bundle / "data/flutter_assets/version.json").read_text())
    filename = f"{metadata['package_name']}.desktop"
    return (
        app.profile / "config" / "autostart" / filename,
        app.profile / "home" / ".config" / "autostart" / filename,
    )


def launch_in_settings(launch_app):
    for prop in ("IsEnabled", "ScreenReaderEnabled"):
        command(
            "busctl",
            "--user",
            "set-property",
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Status",
            prop,
            "b",
            "true",
        )
    app = launch_app()
    open_settings(app.process.pid)
    return app


def test_autostart_uses_xdg_config_home(launch_app):
    app = launch_in_settings(launch_app)
    xdg_entry, fallback_entry = entry_paths(app)

    set_switch(app.process.pid, "Autostart after login", True)
    actual = wait_for_entry((xdg_entry, fallback_entry))

    assert actual == xdg_entry, (
        f"Autostart entry ignored XDG_CONFIG_HOME and was written to {actual}"
    )


def test_autostart_entry_has_icon(launch_app):
    app = launch_in_settings(launch_app)
    paths = entry_paths(app)

    set_switch(app.process.pid, "Autostart after login", True)
    entry = wait_for_entry(paths)
    package_name = Path(entry).stem

    assert f"Icon={package_name}" in entry.read_text().splitlines()


def test_disabling_autostart_succeeds_when_entry_is_missing(launch_app):
    app = launch_in_settings(launch_app)
    paths = entry_paths(app)

    set_switch(app.process.pid, "Autostart after login", True)
    entry = wait_for_entry(paths)
    entry.unlink()

    set_switch(app.process.pid, "Autostart after login", False)
