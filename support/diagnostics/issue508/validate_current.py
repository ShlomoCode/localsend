#!/usr/bin/env python3
"""Compare current-source AppImage autostart behavior through the real Linux GUI."""

import argparse
import json
import os
import re
import shutil
import signal
import socket
import sys
import time
import traceback
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio  # noqa: E402

import run as gui  # noqa: E402


def write_result(out, result):
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")


def desktop_info(path):
    info = Gio.DesktopAppInfo.new_from_filename(str(path))
    if info is None:
        raise RuntimeError(f"Gio rejected desktop entry {path}")
    return info


def launch_context(home):
    context = Gio.AppLaunchContext()
    for key, value in gui.app_environment(home).items():
        if key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
                   "DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "LANG", "LC_ALL"):
            context.setenv(key, value)
    return context


def launch_desktop(path, home):
    info = desktop_info(path)
    return info.launch([], launch_context(home))


def process_appimage(pid):
    return gui.appimage_runtime_environment(pid).get("APPIMAGE")


def app_pids(image):
    found = []
    for item in Path("/proc").iterdir():
        if not item.name.isdigit():
            continue
        if process_appimage(int(item.name)) == str(image):
            found.append(int(item.name))
    return found


def stop_gui_pid(pid, image):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    gui.wait_for(lambda: not app_pids(image), 20)
    for remaining in app_pids(image):
        try:
            os.kill(remaining, signal.SIGKILL)
        except ProcessLookupError:
            pass
    gui.wait_for(lambda: gui.localsend_window() is None, 10)


def find_hidden_option(out):
    for attempt in range(4):
        image = gui.snapshot(out, f"hidden-option-{attempt}")
        lines = gui.ocr_lines(image)
        gui.write_lines(out, f"hidden-option-{attempt}", lines)
        for line in lines:
            if re.search(r"autostart.*(start hidden|hidden)|launch minimized", line["text"], re.I):
                return line
        time.sleep(1)
    raise RuntimeError("Could not locate the hidden autostart switch")


def enable_by_gui(executable, out, label, *, hidden=False):
    case_out = out / label
    case_out.mkdir(parents=True, exist_ok=True)
    home = case_out / "home"
    result = {"image": str(executable), "home": str(home), "requested_hidden": hidden}
    process = None
    running_executable = ""
    try:
        process, window = gui.start_app(executable, case_out, label, home)
        pid, running_executable = gui.process_details(window)
        result.update(window_pid=pid, running_executable=running_executable,
                      runtime_environment=gui.appimage_runtime_environment(pid),
                      fuse_mounted=gui.is_mounted(running_executable))
        gui.open_settings(case_out, window)
        option = gui.find_autostart(case_out, window)
        if option is None:
            raise RuntimeError("Autostart switch was not visible")
        gui.click(option["x"] + 467, option["y"] + option["height"] // 2)
        autostart_dir = home / ".config/autostart"
        desktop = gui.wait_for(lambda: next(autostart_dir.glob("*.desktop"), None)
                               if autostart_dir.exists() else None, 15)
        if desktop is None:
            raise RuntimeError("Real GUI switch did not create a desktop entry")
        if hidden:
            option = find_hidden_option(case_out)
            gui.click(option["x"] + 467, option["y"] + option["height"] // 2)
            if not gui.wait_for(lambda: "--hidden" in desktop.read_text(), 10):
                raise RuntimeError("Real hidden switch did not add --hidden")
        gui.snapshot(case_out, "after-toggle")
        text = desktop.read_text()
        (case_out / "generated.desktop").write_text(text)
        info = desktop_info(desktop)
        result.update(desktop_file=str(desktop), desktop_exec=info.get_string("Exec"),
                      gio_executable=info.get_executable(),
                      desktop_has_hidden="--hidden" in text)
    finally:
        if process is not None:
            gui.stop_app(process, running_executable)
    if "desktop_file" not in result:
        raise RuntimeError(f"{label}: no desktop entry was captured")
    result["exec_exists_after_close"] = Path(result["gio_executable"]).exists()
    result["mount_gone_after_close"] = not gui.is_mounted(result["running_executable"])
    return result


def baseline_case(image, out):
    result = enable_by_gui(image, out, "baseline")
    if not result["fuse_mounted"] or not result["mount_gone_after_close"]:
        raise RuntimeError("Baseline did not exercise a real FUSE mount and unmount")
    if result["exec_exists_after_close"]:
        raise RuntimeError("Baseline unexpectedly has a durable Exec")
    launch_error = None
    try:
        launch_desktop(Path(result["desktop_file"]), Path(result["home"]))
    except Exception as error:
        launch_error = str(error)
    result["gio_launch_error"] = launch_error
    result["gio_window_after_launch"] = bool(gui.wait_for(gui.localsend_window, 5))
    if result["gio_window_after_launch"]:
        raise RuntimeError("Baseline unexpectedly relaunched through Gio")
    result["outcome"] = "baseline_stale_exec_reproduced"
    return result


def normal_candidate_case(image, out):
    result = enable_by_gui(image, out, "candidate-normal")
    if result["gio_executable"] != str(image):
        raise RuntimeError(f"Candidate Gio parsed {result['gio_executable']!r}, expected {image}")
    if not result["exec_exists_after_close"] or not result["mount_gone_after_close"]:
        raise RuntimeError("Candidate desktop Exec is not durable after FUSE unmount")
    if gui.localsend_window():
        raise RuntimeError("Previous GUI window remained before candidate desktop launch")
    launch_desktop(Path(result["desktop_file"]), Path(result["home"]))
    window = gui.wait_for(gui.localsend_window, 45)
    if not window:
        raise RuntimeError("Candidate desktop entry did not open a GUI window")
    pid, exe = gui.process_details(window)
    result.update(gio_relaunch_window_pid=pid, gio_relaunch_executable=exe,
                  gio_relaunch_runtime=gui.appimage_runtime_environment(pid),
                  gio_relaunch_fuse_mounted=gui.is_mounted(exe))
    gui.snapshot(out / "candidate-normal", "gio-relaunch")
    stop_gui_pid(pid, image)
    if result["gio_relaunch_runtime"].get("APPIMAGE") != str(image) or not result["gio_relaunch_fuse_mounted"]:
        raise RuntimeError("Gio launched a different artifact or bypassed FUSE")
    result["outcome"] = "candidate_normal_gio_launch_works"
    return result


def tcp_listening(port=53317):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def hidden_candidate_case(image, out):
    result = enable_by_gui(image, out, "candidate-hidden", hidden=True)
    if result["gio_executable"] != str(image) or not result["desktop_has_hidden"]:
        raise RuntimeError("Hidden desktop entry lost its image path or --hidden argument")
    launch_desktop(Path(result["desktop_file"]), Path(result["home"]))
    pids = gui.wait_for(lambda: app_pids(image), 30)
    if not pids:
        raise RuntimeError("Hidden desktop entry did not start the AppImage")
    result["hidden_pids"] = pids
    result["tcp_listening"] = bool(gui.wait_for(tcp_listening, 30))
    result["visible_window"] = bool(gui.localsend_window())
    gui.snapshot(out / "candidate-hidden", "after-gio-hidden-launch")
    for pid in app_pids(image):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    gui.wait_for(lambda: not app_pids(image), 20)
    if result["visible_window"] or not result["tcp_listening"]:
        raise RuntimeError("Hidden launch mapped a window or did not open TCP port 53317")
    result["outcome"] = "candidate_hidden_unmapped_tcp_ready"
    return result


def migration_case(image, out, *, hidden):
    label = "migration-hidden" if hidden else "migration-normal"
    case_out = out / label
    case_out.mkdir(parents=True, exist_ok=True)
    home = case_out / "home"
    desktop = home / ".config/autostart/localsend_app.desktop"
    desktop.parent.mkdir(parents=True, exist_ok=True)
    stale = "/tmp/.mount_LocalSendGone/localsend_app"
    marker = "X-Issue508-Preserve=metadata-remains"
    desktop.write_text("[Desktop Entry]\nType=Application\nName=LocalSend\n"
                       "Comment=existing entry\n" + marker + "\n"
                       f"Exec={stale}{' --hidden' if hidden else ''}\n"
                       "Terminal=false\n")
    (case_out / "seeded.desktop").write_text(desktop.read_text())
    result = {"seeded_exec": desktop_info(desktop).get_string("Exec"), "home": str(home),
              "hidden": hidden}
    process = None
    executable = ""
    try:
        process, window = gui.start_app(image, case_out, label, home)
        pid, executable = gui.process_details(window)
        result.update(window_pid=pid, runtime_environment=gui.appimage_runtime_environment(pid))
        if not gui.wait_for(lambda: desktop_info(desktop).get_executable() == str(image), 15):
            raise RuntimeError("Startup did not migrate stale desktop Exec")
        text = desktop.read_text()
        (case_out / "migrated.desktop").write_text(text)
        info = desktop_info(desktop)
        result.update(migrated_exec=info.get_string("Exec"), gio_executable=info.get_executable(),
                      marker_preserved=marker in text, hidden_preserved=("--hidden" in text) == hidden)
        if not result["marker_preserved"] or not result["hidden_preserved"]:
            raise RuntimeError("Startup migration changed existing metadata or hidden preference")
        gui.snapshot(case_out, "after-migration")
    finally:
        if process is not None:
            gui.stop_app(process, executable)
    result["outcome"] = "stale_entry_migrated_preserving_metadata"
    return result


def bundle_case(bundle, out):
    image = bundle / "localsend_app"
    result = enable_by_gui(image, out, "official-bundle")
    if result["gio_executable"] != str(image) or not result["exec_exists_after_close"]:
        raise RuntimeError("Regular build bundle autostart did not retain its stable path")
    launch_desktop(Path(result["desktop_file"]), Path(result["home"]))
    window = gui.wait_for(gui.localsend_window, 45)
    if not window:
        raise RuntimeError("Regular build bundle desktop entry did not open a GUI")
    pid, executable = gui.process_details(window)
    result.update(gio_relaunch_window_pid=pid, gio_relaunch_executable=executable)
    gui.snapshot(out / "official-bundle", "gio-relaunch")
    stop_gui_pid(pid, image)
    result["outcome"] = "official_bundle_gio_launch_works"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    candidate = out / "portable image" / "LocalSend current.AppImage"
    candidate.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.candidate.resolve(), candidate)
    candidate.chmod(0o755)
    result = {"baseline": str(args.baseline.resolve()), "candidate": str(candidate),
              "bundle": str(args.bundle.resolve()), "cases": {}, "errors": []}
    openbox_log = (out / "openbox.log").open("w")
    openbox = gui.subprocess.Popen(["openbox"], stdout=openbox_log, stderr=gui.subprocess.STDOUT)
    try:
        time.sleep(2)
        cases = [
            ("baseline", lambda: baseline_case(args.baseline.resolve(), out)),
            ("candidate_normal", lambda: normal_candidate_case(candidate, out)),
            ("candidate_hidden", lambda: hidden_candidate_case(candidate, out)),
            ("migration_normal", lambda: migration_case(candidate, out, hidden=False)),
            ("migration_hidden", lambda: migration_case(candidate, out, hidden=True)),
            ("official_bundle", lambda: bundle_case(args.bundle.resolve(), out)),
        ]
        for label, check in cases:
            try:
                result["cases"][label] = check()
            except Exception as error:
                result["cases"][label] = {"outcome": "harness_or_behavior_failure", "error": str(error),
                                          "traceback": traceback.format_exc()}
                result["errors"].append(label)
            finally:
                write_result(out, result)
    finally:
        openbox.terminate()
        try:
            openbox.wait(timeout=5)
        except gui.subprocess.TimeoutExpired:
            openbox.kill()
        write_result(out, result)
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
