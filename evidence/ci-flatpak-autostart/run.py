#!/usr/bin/env python3
"""Exercise LocalSend's Flatpak autostart paths on an ephemeral Linux runner."""

from __future__ import annotations

import configparser
import json
import os
from pathlib import Path
import shlex
import subprocess
import time


APP_ID = "org.localsend.localsend_app"
LEGACY_DESKTOP = "localsend_app.desktop"
PORTAL_DESKTOP = f"{APP_ID}.desktop"
ARTIFACT_DIR = Path(os.environ["AUTOSTART_ARTIFACT_DIR"])
HOST_CONFIG = Path(os.environ["AUTOSTART_HOST_CONFIG"])
PROBE = Path(os.environ["AUTOSTART_PROBE"])


def run(args: list[str], *, check: bool = True, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {shlex.join(args)}\n{result.stdout}")
    return result


def sandbox_shell(script: str) -> subprocess.CompletedProcess[str]:
    return run(["flatpak", "run", "--system", "--command=sh", APP_ID, "-eu", "-c", script])


def portal(action: str) -> str:
    result = run(
        [
            "flatpak",
            "run",
            "--system",
            f"--filesystem={PROBE.parent}:ro",
            f"--command={PROBE}",
            APP_ID,
            action,
        ],
        timeout=45,
    )
    return result.stdout.strip()


def app_is_running() -> bool:
    result = run(["flatpak", "ps", "--columns=application"], check=False, timeout=10)
    return APP_ID in result.stdout.splitlines()


def wait_for_app(timeout: float = 30.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if app_is_running():
            return True
        time.sleep(0.25)
    return False


def read_desktop(path: Path) -> tuple[configparser.ConfigParser, str]:
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    contents = path.read_text(encoding="utf-8")
    parser.read_string(contents)
    return parser, contents


def main() -> None:
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    HOST_CONFIG.mkdir(parents=True, exist_ok=True)
    summary: dict[str, object] = {"app_id": APP_ID, "status": "running"}

    try:
        info = run(["flatpak", "info", "--system", "--show-ref", APP_ID]).stdout.strip()
        summary["installed_ref"] = info

        current_path_script = f"""
file="$HOME/.config/autostart/{LEGACY_DESKTOP}"
mkdir -p "$(dirname "$file")"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Exec=/app/localsend_app --hidden' >"$file"
test -f "$file"
"""
        sandbox_shell(current_path_script)
        sandbox_shell(f'test ! -e "$HOME/.config/autostart/{LEGACY_DESKTOP}"')
        current_host_path = HOST_CONFIG / "autostart" / LEGACY_DESKTOP
        if current_host_path.exists():
            raise RuntimeError("the current HOME-based helper unexpectedly created a host autostart entry")
        summary["current_home_path"] = {
            "survives_sandbox_restart": False,
            "host_autostart_visible": False,
        }

        xdg_path_script = f"""
file="$XDG_CONFIG_HOME/autostart/{LEGACY_DESKTOP}"
mkdir -p "$(dirname "$file")"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Exec=/app/localsend_app --hidden' >"$file"
test -f "$file"
"""
        sandbox_shell(xdg_path_script)
        sandbox_shell(f'test -f "$XDG_CONFIG_HOME/autostart/{LEGACY_DESKTOP}"')
        if current_host_path.exists():
            raise RuntimeError("the sandbox-private XDG config entry unexpectedly appeared in the host autostart directory")
        summary["xdg_config_path"] = {
            "survives_sandbox_restart": True,
            "host_autostart_visible": False,
        }
        sandbox_shell(f'rm -f "$XDG_CONFIG_HOME/autostart/{LEGACY_DESKTOP}"')

        enable_output = portal("enable")
        portal_path = HOST_CONFIG / "autostart" / PORTAL_DESKTOP
        if not portal_path.is_file():
            raise RuntimeError("Background portal did not create the host autostart desktop file")

        parser, contents = read_desktop(portal_path)
        entry = parser["Desktop Entry"]
        exec_line = entry.get("Exec", "")
        exec_args = shlex.split(exec_line)
        portal_marker = entry.get("X-XDP-Autostart") or entry.get("X-Flatpak")
        if portal_marker != APP_ID:
            raise RuntimeError("Background portal desktop file lacks a LocalSend app-id marker")
        if not exec_args or Path(exec_args[0]).name != "flatpak" or "run" not in exec_args:
            raise RuntimeError(f"Background portal generated an unexpected Exec: {exec_line}")
        if APP_ID not in exec_args or "--hidden" not in exec_args or "--command=localsend" not in exec_args:
            raise RuntimeError(f"Background portal Exec does not target hidden LocalSend: {exec_line}")

        (ARTIFACT_DIR / "portal.desktop").write_text(contents, encoding="utf-8")
        launched = subprocess.Popen(exec_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            if not wait_for_app():
                raise RuntimeError("the portal-generated Exec did not leave the LocalSend Flatpak running")
            time.sleep(3)
            if not app_is_running():
                raise RuntimeError("the LocalSend Flatpak exited shortly after portal-generated hidden startup")
        finally:
            run(["flatpak", "kill", APP_ID], check=False, timeout=15)
            try:
                launched.wait(timeout=15)
            except subprocess.TimeoutExpired:
                launched.terminate()

        disable_output = portal("disable")
        if portal_path.exists():
            raise RuntimeError("Background portal did not remove the host autostart desktop file")

        summary["background_portal"] = {
            "enable_response": enable_output,
            "disable_response": disable_output,
            "host_entry_created": True,
            "exec_uses_flatpak_run": True,
            "hidden_launch_stayed_running": True,
            "host_entry_removed": True,
        }
        summary["status"] = "passed"
    except Exception as error:  # noqa: BLE001 - preserve a bounded runner diagnostic.
        summary["status"] = "failed"
        summary["failure"] = str(error)[:2000]
        raise
    finally:
        (ARTIFACT_DIR / "summary.json").write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
