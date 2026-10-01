#!/usr/bin/env python3
"""Bounded, synthetic-profile Flatpak cohort check for issue #3483.

Only summary metadata and screenshots are exported. Raw process output and
runner-generated app data stay under RUNNER_TEMP and are never uploaded.
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import time
from typing import Any


APP_ID = "org.localsend.localsend_app"
APP_COMMIT = "31f3f559da9fc85ec88a82923e3d7287a873240573cbb9d6bd54bf4a26ad1ccd"
OLD_PLATFORM_COMMIT = "bd44a6230581917d04f89812a4c21090c304d390edb73995af1c2f9fd8abf4e8"
CURRENT_PLATFORM_COMMIT = "d27f7a6a974e40b061070bec1be9e1b52a7a6872b271e6a45c2c34a48bf6fedf"
REMOTE = "flathub"
REMOTE_URL = "https://dl.flathub.org/repo/"
REFS = [
    ("runtime/org.freedesktop.Platform/x86_64/25.08",
     "bd44a6230581917d04f89812a4c21090c304d390edb73995af1c2f9fd8abf4e8",
     "d27f7a6a974e40b061070bec1be9e1b52a7a6872b271e6a45c2c34a48bf6fedf"),
    ("runtime/org.freedesktop.Platform.GL.default/x86_64/25.08",
     "bcfd828b0c4739753cadb31964f8c1b0f90c8d2bed79bda2c2760438eb48c4b3",
     "0083f33e9a33c454d0f0850d06581e5f991ecf2dbde02e38079db49e01c7ebac"),
    ("runtime/org.freedesktop.Platform.GL.default/x86_64/25.08-extra",
     "37b03bfd88271f49ba6eaa00c07155716870497c66759972bc81d67153e35138",
     "695a049fc6520a9c8041cbdb35df59f9d38b562b02c6316a36fb2deb50a0992b"),
    ("runtime/org.freedesktop.Platform.Locale/x86_64/25.08",
     "084eff7344f995ade230f234d74e3ee0af227eacff65f2d72cec25078783b03f",
     "56249bc390c2b19c7d77a241bba02118854f450db216b23cd84f5df5125ba5a0"),
    ("runtime/org.freedesktop.Platform.codecs-extra/x86_64/25.08-extra",
     "3f422b5306e0c1a1c6855fb36eeff26237d9d9c9a0abcb6d35bd9555ea75efed",
     "7ccd63f7532e93ce345b67dedc492748bba449917e81a031502715bc38e3f438"),
]
SETTINGS_LABELS = ("general", "theme", "color", "language")
COMMAND_LOG: Path | None = None
REMOTE_DIAGNOSTICS: dict[str, Any] = {}


class ProbeFailure(RuntimeError):
    def __init__(self, stage: str, detail: str = "check_failed") -> None:
        super().__init__(detail)
        self.stage = stage
        self.detail = detail


def run(args: list[str], *, timeout: int = 120, check: bool = True,
        capture: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(args, text=True, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                                stderr=subprocess.STDOUT if capture else subprocess.DEVNULL,
                                timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        if COMMAND_LOG is not None:
            with COMMAND_LOG.open("a", encoding="utf-8") as log:
                log.write(f"\n$ {shlex.join(args)}\n[timeout after {timeout}s]\n")
        raise ProbeFailure("command_timeout", "bounded_command_timeout") from exc
    if COMMAND_LOG is not None:
        with COMMAND_LOG.open("a", encoding="utf-8") as log:
            log.write(f"\n$ {shlex.join(args)}\n{result.stdout or ''}\n")
    if check and result.returncode:
        raise ProbeFailure("command_failed", "bounded_command_nonzero_exit")
    return result


def host_profile() -> Path:
    # Runner's ephemeral account only; HOME is never overridden or repurposed.
    return Path.home() / ".var" / "app" / APP_ID


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def profile_summary(path: Path) -> dict[str, int]:
    files = 0
    total = 0
    cache = 0
    if path.exists():
        for item in path.rglob("*"):
            try:
                if item.is_file():
                    size = item.stat().st_size
                    files += 1
                    total += size
                    if "cache" in item.relative_to(path).parts:
                        cache += size
            except OSError:
                continue
    return {"files": files, "bytes": total, "cache_bytes": cache}


def mesa_cache_summary(profile: Path) -> dict[str, int]:
    """Count non-empty Mesa shader-cache files without reading their contents."""
    cache_root = profile / "cache"
    if cache_root.is_symlink() or not cache_root.is_dir():
        return {"directories": 0, "files": 0, "bytes": 0}
    roots = [item for item in cache_root.iterdir()
             if item.name.startswith("mesa_shader_cache") and not item.is_symlink()]
    files = 0
    total_bytes = 0
    for root in roots:
        if root.is_file():
            files += 1
            total_bytes += root.stat().st_size
            continue
        if not root.is_dir():
            continue
        pending = [root]
        while pending:
            directory = pending.pop()
            for item in directory.iterdir():
                try:
                    if item.is_symlink():
                        continue
                    if item.is_dir():
                        pending.append(item)
                    elif item.is_file():
                        size = item.stat().st_size
                        files += 1
                        total_bytes += size
                except OSError:
                    continue
    return {"directories": sum(1 for root in roots if root.is_dir()), "files": files, "bytes": total_bytes}


def ensure_remote() -> dict[str, Any]:
    REMOTE_DIAGNOSTICS.clear()
    REMOTE_DIAGNOSTICS.update({
        "remote_found": False,
        "url_matches": False,
        "gpg_verify": False,
        "gpg_verify_key_present": False,
        "gpg_verify_summary": False,
        "gpg_summary_key_present": False,
        "collection_id_present": False,
        "disabled_gpg_option_present": False,
    })
    info = run(["flatpak", "remotes", "--system", "--show-details", "--columns=name,url,options"],
               timeout=30).stdout or ""
    rows = [line.split("\t") for line in info.splitlines() if line.strip()]
    row = next((r for r in rows if r and r[0] == REMOTE), None)
    if row is None:
        run(["sudo", "flatpak", "remote-add", "--system", "--if-not-exists", "--from", REMOTE,
             "https://dl.flathub.org/repo/flathub.flatpakrepo"], timeout=90)
        info = run(["flatpak", "remotes", "--system", "--show-details", "--columns=name,url,options"],
                   timeout=30).stdout or ""
        rows = [line.split("\t") for line in info.splitlines() if line.strip()]
        row = next((r for r in rows if r and r[0] == REMOTE), None)
    if row is None or len(row) < 3:
        raise ProbeFailure("remote_check", "flathub_remote_unavailable")
    REMOTE_DIAGNOSTICS["remote_found"] = True
    REMOTE_DIAGNOSTICS["url_matches"] = row[1].rstrip("/") == REMOTE_URL.rstrip("/")
    config = configparser.ConfigParser(interpolation=None)
    if not config.read("/var/lib/flatpak/repo/config"):
        raise ProbeFailure("remote_check", "system_remote_config_unavailable")
    group = f'remote "{REMOTE}"'
    if not config.has_section(group):
        raise ProbeFailure("remote_check", "flathub_system_remote_missing")
    # OSTree defaults gpg-verify to true and gpg-verify-summary to false when
    # the option is absent; mirror those effective defaults in the guard.
    gpg_verify_present = config.has_option(group, "gpg-verify")
    gpg_summary_present = config.has_option(group, "gpg-verify-summary")
    gpg_verify = config.getboolean(group, "gpg-verify", fallback=True)
    gpg_summary = config.getboolean(group, "gpg-verify-summary", fallback=False)
    collection_id = config.get(group, "collection-id", fallback="")
    options = {part for part in re.split(r"[,\s]+", row[2].lower()) if part}
    REMOTE_DIAGNOSTICS.update({
        "gpg_verify": gpg_verify,
        "gpg_verify_key_present": gpg_verify_present,
        "gpg_verify_summary": gpg_summary,
        "gpg_summary_key_present": gpg_summary_present,
        "collection_id_present": bool(collection_id),
        "disabled_gpg_option_present": bool({"no-gpg-verify", "no-gpg-verify-summary"} & options),
    })
    # Require signed commits from the official remote. Summary verification
    # may be explicitly enabled or use OSTree's documented default; neither
    # mode requires changing the official .flatpakrepo configuration.
    if not REMOTE_DIAGNOSTICS["url_matches"] or not gpg_verify \
            or REMOTE_DIAGNOSTICS["disabled_gpg_option_present"]:
        raise ProbeFailure("remote_check", "flathub_remote_policy_mismatch")
    return {"name": row[0], "url": REMOTE_URL, **REMOTE_DIAGNOSTICS}


def ref_commit(ref: str) -> str:
    result = run(["flatpak", "info", "--system", "--show-commit", ref], timeout=30)
    value = (result.stdout or "").strip().splitlines()[-1].strip()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ProbeFailure("ref_verification", "invalid_commit_metadata")
    return value


def install_exact(ref: str, commit: str) -> None:
    run(["sudo", "flatpak", "install", "--system", "--noninteractive", f"--commit={commit}",
         "--no-related", REMOTE, ref], timeout=180)


def update_exact(ref: str, commit: str) -> None:
    # Normal verified update/pull. Do not use --no-pull or bypass signatures.
    run(["sudo", "flatpak", "update", "--system", "--noninteractive", "--no-related",
         f"--commit={commit}", ref], timeout=180)


def proc_comm(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip().lower()
    except (OSError, UnicodeError):
        return ""


def proc_nspids(pid: int) -> list[int]:
    try:
        status = Path(f"/proc/{pid}/status").read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return []
    match = re.search(r"^NSpid:\s+(.+)$", status, re.MULTILINE)
    if not match:
        return []
    try:
        return [int(item) for item in match.group(1).split()]
    except ValueError:
        return []


def flatpak_marker(pid: int) -> dict[str, str] | None:
    marker = Path(f"/proc/{pid}/root/.flatpak-info")
    try:
        parser = configparser.ConfigParser(interpolation=None)
        parser.read_string(marker.read_text(encoding="utf-8"))
        return {
            "app_id": parser.get("Application", "name", fallback=""),
            "instance_id": parser.get("Instance", "instance-id", fallback=""),
            "app_commit": parser.get("Instance", "app-commit", fallback=""),
            "runtime_commit": parser.get("Instance", "runtime-commit", fallback=""),
        }
    except (OSError, UnicodeError, configparser.Error):
        return None


def child_pids(pid: int) -> list[int]:
    children_path = Path(f"/proc/{pid}/task/{pid}/children")
    try:
        values = children_path.read_text(encoding="ascii").split()
        return [int(value) for value in values]
    except (OSError, UnicodeError, ValueError):
        return []


def descendants(root_pid: int) -> set[int]:
    found: set[int] = set()
    pending = [root_pid]
    while pending and len(found) < 4096:
        pid = pending.pop()
        if pid in found:
            continue
        found.add(pid)
        pending.extend(child for child in child_pids(pid) if child not in found)
    return found


def wait_app_process(expected_runtime_commit: str) -> dict[str, Any]:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        result = run(["flatpak", "ps", "--columns=instance,application,pid,child-pid"],
                     timeout=10, check=False)
        for line in (result.stdout or "").splitlines():
            cells = line.split()
            if len(cells) < 4 or cells[1] != APP_ID or not cells[2].isdigit() or not cells[3].isdigit():
                continue
            instance_id, _, wrapper_pid, sandbox_pid = cells[:4]
            tree = descendants(int(sandbox_pid))
            for pid in tree:
                if proc_comm(pid) not in {"localsend", "localsend_app"}:
                    continue
                marker = flatpak_marker(pid)
                if not marker or marker["app_id"] != APP_ID or marker["instance_id"] != instance_id \
                        or marker["app_commit"] != APP_COMMIT \
                        or marker["runtime_commit"] != expected_runtime_commit:
                    continue
                nspids = proc_nspids(pid)
                if not nspids:
                    continue
                return {
                    "instance_id": instance_id,
                    "wrapper_pid": int(wrapper_pid),
                    "sandbox_pid": int(sandbox_pid),
                    "app_pid": pid,
                    "runtime_commit": marker["runtime_commit"],
                    "allowed_window_pids": sorted(set([pid, *nspids])),
                    "nspids": nspids,
                }
        time.sleep(0.5)
    raise ProbeFailure("app_launch", "verified_app_child_process_not_found")


def window_for(app_process: dict[str, Any]) -> tuple[str, int]:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        ids = run(["xdotool", "search", "--onlyvisible", "--name", ".*"], timeout=10, check=False).stdout or ""
        for wid in ids.splitlines():
            if not wid.strip().isdigit():
                continue
            p = run(["xprop", "-id", wid.strip(), "_NET_WM_PID"], timeout=5, check=False).stdout or ""
            cls = run(["xprop", "-id", wid.strip(), "WM_CLASS"], timeout=5, check=False).stdout or ""
            match = re.search(r"_NET_WM_PID\(CARDINAL\)\s*=\s*(\d+)\b", p)
            if match and int(match.group(1)) in app_process["allowed_window_pids"] \
                    and "localsend" in cls.lower():
                return wid.strip(), int(match.group(1))
        time.sleep(0.5)
    raise ProbeFailure("window_match", "visible_window_pid_namespace_and_class_not_matched")


def window_geometry(wid: str) -> dict[str, int]:
    result = run(["xdotool", "getwindowgeometry", "--shell", wid], timeout=10).stdout or ""
    values = {}
    for key, value in re.findall(r"^(X|Y|WIDTH|HEIGHT)=(-?\d+)$", result, re.MULTILINE):
        values[key.lower()] = int(value)
    if not {"width", "height"}.issubset(values):
        raise ProbeFailure("window_geometry", "geometry_unavailable")
    return values


def screenshot_and_ocr(path: Path) -> str:
    run(["scrot", "-u", str(path)], timeout=15)
    result = run(["tesseract", str(path), "stdout", "--psm", "11"], timeout=8, check=False)
    return re.sub(r"[^a-z]+", " ", (result.stdout or "").lower())


def capture_state(name: str, app_process: dict[str, Any], artifact_dir: Path) -> dict[str, Any]:
    wid, window_pid = window_for(app_process)
    run(["xdotool", "windowmap", wid], timeout=10)
    run(["xdotool", "windowsize", wid, "400", "538"], timeout=10)
    run(["xdotool", "windowraise", wid, "windowactivate", "--sync", wid], timeout=10, check=False)
    geometry_deadline = time.monotonic() + 8
    geometry = {}
    while time.monotonic() < geometry_deadline:
        geometry = window_geometry(wid)
        if geometry["width"] == 400 and geometry["height"] == 538:
            break
        time.sleep(0.25)
    if geometry.get("width") != 400 or geometry.get("height") != 538:
        raise ProbeFailure("window_geometry", "window_not_resized_to_400x538")
    home_screenshot = artifact_dir / f"{name}-home.png"
    home_deadline = time.monotonic() + 30
    home_text = ""
    while time.monotonic() < home_deadline:
        home_text = screenshot_and_ocr(home_screenshot)
        if re.search(r"\b(receive|send)\b", home_text):
            break
        time.sleep(0.5)
    if not re.search(r"\b(receive|send)\b", home_text):
        raise ProbeFailure("home_render_wait", "home_controls_not_detected_within_30s")

    # Parent-verified click point for the exact 400x538 client window. Geometry
    # is checked above before using this coordinate.
    if name.endswith("settings"):
        run(["xdotool", "mousemove", "--sync", "--window", wid, "333", "486", "click", "1"], timeout=10)
        settings_screenshot = artifact_dir / f"{name}-settings.png"
        settings_deadline = time.monotonic() + 30
        normalized = ""
        while time.monotonic() < settings_deadline:
            normalized = screenshot_and_ocr(settings_screenshot)
            if all(re.search(rf"\b{label}\b", normalized) for label in SETTINGS_LABELS):
                break
            time.sleep(0.5)
    else:
        settings_screenshot = home_screenshot
    labels = {label: bool(re.search(rf"\b{label}\b", normalized)) for label in SETTINGS_LABELS} if name.endswith("settings") else {}
    if name.endswith("settings") and not all(labels.values()):
        raise ProbeFailure("settings_verification", "settings_page_not_detected_within_30s")
    return {"home_screenshot": home_screenshot.name, "settings_screenshot": settings_screenshot.name,
            "matched_process": {"wrapper_pid": app_process["wrapper_pid"],
                                "sandbox_pid": app_process["sandbox_pid"],
                                "app_host_pid": app_process["app_pid"],
                                "app_nspids": app_process["nspids"],
                                "window_pid": window_pid,
                                "instance_id_matches_marker": True},
            "matched_window": True,
            "client_geometry": {"width": geometry["width"], "height": geometry["height"]},
            "settings_labels": labels}


def launch_capture(label: str, artifact_dir: Path, raw_dir: Path,
                   expected_runtime_commit: str) -> dict[str, Any]:
    run(["sudo", "-n", "true"], timeout=5)
    log_path = raw_dir / f"{label}-app.log"
    try:
        if COMMAND_LOG is not None:
            with COMMAND_LOG.open("a", encoding="utf-8") as log:
                log.write(f"\n$ flatpak run --system {APP_ID}  # stderr: {log_path.name}\n")
        process = subprocess.Popen(["flatpak", "run", "--system", APP_ID], stdout=subprocess.DEVNULL,
                                   stderr=log_path.open("w", encoding="utf-8"))
        app_process = wait_app_process(expected_runtime_commit)
        # The window PID must map to this app's verified Flatpak sandbox process,
        # not merely the wrapper PID returned by `flatpak ps`'s `pid` column.
        state = capture_state(f"{label}-settings", app_process, artifact_dir)
        run(["flatpak", "kill", APP_ID], timeout=15, check=False)
        process.wait(timeout=15)
        return {"process": app_process, "window": state}
    except ProbeFailure:
        run(["flatpak", "kill", APP_ID], timeout=15, check=False)
        raise
    except Exception as exc:  # noqa: BLE001 - public artifacts use only the stage/category.
        run(["flatpak", "kill", APP_ID], timeout=15, check=False)
        raise ProbeFailure("app_capture", type(exc).__name__) from None


def gl_info(probe: Path) -> dict[str, str]:
    result = run(["flatpak", "run", "--system", f"--filesystem={probe.parent}:ro", f"--command={probe}", APP_ID], timeout=30)
    values = {}
    for line in (result.stdout or "").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"vendor", "renderer", "version"}:
                values[key] = value[:160]
    if not values:
        raise ProbeFailure("renderer_probe", "glx_probe_no_metadata")
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gl-probe", type=Path, required=True)
    args = parser.parse_args()
    artifact_dir = Path(os.environ["CI3483_ARTIFACT_DIR"])
    raw_dir = Path(os.environ["CI3483_RAW_DIR"])
    artifact_dir.mkdir(parents=True, exist_ok=True)
    raw_dir.mkdir(parents=True, exist_ok=True)
    global COMMAND_LOG
    COMMAND_LOG = raw_dir / "commands.log"
    summary: dict[str, Any] = {
        "test": "localsend-1.18.2-signed-flatpak-runtime-transition",
        "runner": "ubuntu-24.04-x86_64",
        "display": "X11/Xvfb with Openbox; not GNOME/Zorin and no physical GPU fidelity",
        "app_id": APP_ID,
        "app_commit_expected": APP_COMMIT,
        "status": "failed",
        "failure_stage": "initialization",
        "old_baseline_validated": False,
    }
    summary_path = artifact_dir / "summary.json"
    profile = host_profile()
    cloned_profile = raw_dir / "preupgrade-profile"
    try:
        summary["remote"] = ensure_remote()
        runner = run(["uname", "-smr"], timeout=10).stdout.strip()
        summary["runner_kernel_arch"] = runner[:160]
        summary["cohorts"] = {}
        app_ref = f"app/{APP_ID}/x86_64/stable"
        # Install exact older cohort with signatures enabled, then install pinned app.
        for ref, old_commit, _ in REFS:
            install_exact(ref, old_commit)
        install_exact(app_ref, APP_COMMIT)
        summary["app_commit_before"] = ref_commit(app_ref)
        if summary["app_commit_before"] != APP_COMMIT:
            raise ProbeFailure("app_pin", "unexpected_app_commit_before_test")
        for ref, old_commit, _ in REFS:
            actual = ref_commit(ref)
            if actual != old_commit:
                raise ProbeFailure("old_cohort_pin", "unexpected_old_runtime_commit")
            summary["cohorts"][ref] = {"old": actual}
        summary["renderer_old"] = gl_info(args.gl_probe)
        if profile.exists():
            shutil.rmtree(profile)
        old_state = launch_capture("old-baseline", artifact_dir, raw_dir, OLD_PLATFORM_COMMIT)
        summary["old_baseline"] = old_state
        summary["old_profile_summary"] = profile_summary(profile)
        mesa_cache = mesa_cache_summary(profile)
        summary["old_mesa_shader_cache"] = mesa_cache
        if mesa_cache["files"] == 0 or mesa_cache["bytes"] == 0:
            raise ProbeFailure("old_cache_validation", "old_baseline_created_no_mesa_shader_cache_files")
        summary["old_baseline_validated"] = True

        # Preserve the runner-generated settings and cache before normal signed updates.
        if profile.exists():
            shutil.copytree(profile, cloned_profile, symlinks=True)
        else:
            cloned_profile.mkdir()
        summary["preupgrade_profile_summary"] = profile_summary(profile)
        for ref, _, current_commit in REFS:
            update_exact(ref, current_commit)
        for ref, _, current_commit in REFS:
            actual = ref_commit(ref)
            if actual != current_commit:
                raise ProbeFailure("current_cohort_pin", "unexpected_current_runtime_commit")
            summary["cohorts"][ref]["current"] = actual
        if ref_commit(app_ref) != APP_COMMIT:
            raise ProbeFailure("app_pin", "app_commit_changed_during_runtime_update")
        try:
            summary["same_cache_first_launch"] = launch_capture(
                "current-same-cache", artifact_dir, raw_dir, CURRENT_PLATFORM_COMMIT)
            summary["same_profile_summary_after"] = profile_summary(profile)
            summary["status"] = "passed"
        except ProbeFailure as first_error:
            summary["same_cache_first_launch"] = {"passed": False, "failure_stage": first_error.stage,
                                                  "failure_category": first_error.detail}
            # Only a material first-launch failure justifies this fresh-cache control.
            run(["flatpak", "kill", APP_ID], timeout=10, check=False)
            failed_profile = raw_dir / "same-cache-failure-profile"
            if profile.exists():
                shutil.move(str(profile), failed_profile)
            shutil.copytree(cloned_profile, profile, symlinks=True)
            cache_dir = profile / "cache"
            if cache_dir.exists():
                shutil.rmtree(cache_dir)
            summary["fresh_cache_profile_summary_before"] = profile_summary(profile)
            summary["same_cache_first_launch"]["failed_profile_preserved_privately"] = True
            try:
                summary["fresh_cache_control"] = launch_capture(
                    "current-fresh-cache", artifact_dir, raw_dir, CURRENT_PLATFORM_COMMIT)
                summary["status"] = "passed_fresh_cache_only"
            except ProbeFailure as fresh_error:
                summary["fresh_cache_control"] = {"passed": False, "failure_stage": fresh_error.stage,
                                                   "failure_category": fresh_error.detail}
                summary["status"] = "current_cohort_failure_with_fresh_cache_control"
                summary["failure_stage"] = "current_fresh_cache_control"
                summary["failure_category"] = fresh_error.detail
                try:
                    summary["renderer_current"] = gl_info(args.gl_probe)
                except ProbeFailure as renderer_error:
                    summary["renderer_current"] = {"failure_category": renderer_error.detail}
                write_json(summary_path, summary)
                print(json.dumps({"status": summary["status"], "failure_stage": summary["failure_stage"]}))
                return 1
        try:
            # Deliberately after the measured launch(es): GLX initialization can
            # populate the same per-app cache that the transition observes.
            summary["renderer_current"] = gl_info(args.gl_probe)
        except ProbeFailure as renderer_error:
            summary["renderer_current"] = {"failure_category": renderer_error.detail}
        summary["app_commit_after"] = ref_commit(app_ref)
        summary["profile_after"] = profile_summary(profile)
        summary["failure_stage"] = None
    except ProbeFailure as exc:
        summary["failure_stage"] = exc.stage
        summary["failure_category"] = exc.detail
        summary["old_baseline_ui_passed"] = "old_baseline" in summary
        summary["old_baseline_passed"] = bool(summary.get("old_baseline_validated"))
        summary["status"] = "harness_or_baseline_failed"
        if REMOTE_DIAGNOSTICS:
            summary["remote_diagnostics"] = dict(REMOTE_DIAGNOSTICS)
    except Exception as exc:  # noqa: BLE001 - keep traceback and host paths private.
        summary["failure_stage"] = "unexpected_harness_error"
        summary["failure_category"] = type(exc).__name__
        summary["old_baseline_ui_passed"] = "old_baseline" in summary
        summary["old_baseline_passed"] = bool(summary.get("old_baseline_validated"))
        summary["status"] = "harness_or_baseline_failed"
        if REMOTE_DIAGNOSTICS:
            summary["remote_diagnostics"] = dict(REMOTE_DIAGNOSTICS)
    finally:
        run(["flatpak", "kill", APP_ID], timeout=10, check=False)
        if summary.get("app_commit_before") and summary.get("app_commit_before") != APP_COMMIT:
            summary["app_commit_guard"] = "unexpected"
        write_json(summary_path, summary)
    print(json.dumps({"status": summary["status"], "failure_stage": summary.get("failure_stage")}))
    return 0 if summary["status"] in {"passed", "passed_fresh_cache_only"} else 1


if __name__ == "__main__":
    sys.exit(main())
