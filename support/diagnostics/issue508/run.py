#!/usr/bin/env python3
"""GUI-level reproduction of LocalSend issue 508 on published AppImages."""

import argparse
import csv
import hashlib
import io
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path
from PIL import Image, ImageEnhance, ImageOps


def command(args, *, timeout=30, check=True, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=check, **kwargs)


def wait_for(predicate, seconds, interval=0.5):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return None


def snapshot(out, name):
    path = out / f"{name}.png"
    command(["scrot", str(path)], timeout=10)
    return path


def ocr_lines(image):
    scaled = image.with_suffix(".ocr.png")
    with Image.open(image) as original:
        enlarged = original.resize((original.width * 3, original.height * 3), Image.LANCZOS)
        enhanced = ImageEnhance.Contrast(ImageOps.grayscale(enlarged)).enhance(2)
        enhanced.save(scaled)
    result = command(["tesseract", str(scaled), "stdout", "--psm", "11", "tsv"], timeout=30)
    groups = {}
    for word in csv.DictReader(io.StringIO(result.stdout), delimiter="\t"):
        text = word["text"].strip()
        if not text:
            continue
        key = tuple(word[field] for field in ("block_num", "par_num", "line_num"))
        groups.setdefault(key, []).append(word)
    lines = []
    for words in groups.values():
        left = min(int(w["left"]) for w in words) // 3
        top = min(int(w["top"]) for w in words) // 3
        right = max(int(w["left"]) + int(w["width"]) for w in words) // 3
        bottom = max(int(w["top"]) + int(w["height"]) for w in words) // 3
        lines.append({"text": " ".join(w["text"] for w in words), "x": left, "y": top,
                      "width": right - left, "height": bottom - top})
    return lines


def write_lines(out, name, lines):
    (out / f"{name}.ocr.json").write_text(json.dumps(lines, indent=2) + "\n")


def windows():
    result = command(["xdotool", "search", "--onlyvisible", "--name", "."], check=False)
    return [w for w in result.stdout.splitlines() if w.strip().isdigit()]


def localsend_window():
    for window in reversed(windows()):
        title = command(["xdotool", "getwindowname", window], check=False).stdout.strip()
        if "localsend" in title.lower():
            return window
    return None


def geometry(window):
    result = command(["xdotool", "getwindowgeometry", "--shell", window])
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return {key: int(fields[key]) for key in ("X", "Y", "WIDTH", "HEIGHT")}


def click(x, y):
    command(["xdotool", "mousemove", "--sync", str(x), str(y), "click", "1"])


def activate(window):
    command(["xdotool", "windowactivate", "--sync", window], check=False)
    command(["xdotool", "windowsize", window, "1200", "900"], check=False)
    command(["xdotool", "windowmove", window, "200", "50"], check=False)
    time.sleep(2)


def open_settings(out, window):
    activate(window)
    lines = []
    for attempt in range(3):
        image = snapshot(out, "home")
        lines = ocr_lines(image)
        if any(line["text"].lower() == "localsend" for line in lines):
            break
        time.sleep(2)
    write_lines(out, "home", lines)
    matches = [line for line in lines if re.search(r"\bsettings\b", line["text"], re.I)]
    if matches:
        line = min(matches, key=lambda item: item["x"])
        click(line["x"] + line["width"] // 2, line["y"] + line["height"] // 2)
    else:
        # On these releases the third NavigationRail item is 70px right and
        # 170px below the visible LocalSend heading. Anchor to that heading
        # because the app may override the requested window size at startup.
        headings = [line for line in lines if line["text"].lower() == "localsend"]
        if not headings:
            raise RuntimeError("Could not locate LocalSend heading for Settings navigation")
        heading = min(headings, key=lambda item: item["x"])
        click(heading["x"] + 70, heading["y"] + 170)
    time.sleep(2)
    image = snapshot(out, "settings")
    lines = ocr_lines(image)
    write_lines(out, "settings", lines)
    if not any(re.search(r"\b(general|brightness|language|autostart)\b", line["text"], re.I) for line in lines):
        raise RuntimeError("Settings tab was not verified by OCR; inspect home/settings screenshots")


def find_autostart(out, window):
    g = geometry(window)
    for attempt in range(5):
        image = snapshot(out, f"settings-scroll-{attempt}")
        lines = ocr_lines(image)
        write_lines(out, f"settings-scroll-{attempt}", lines)
        for line in lines:
            label = line["text"].lower()
            if re.search(r"autostart after login|launch at startup|start at login|start on login|start automatically", label):
                return line
        command(["xdotool", "mousemove", str(g["X"] + g["WIDTH"] - 220),
                 str(g["Y"] + g["HEIGHT"] // 2), "click", "--repeat", "3", "--delay", "100", "5"])
        time.sleep(1)
    return None


def mount_records():
    # /proc/mounts escapes spaces; AppImage mountpoints are space-free.
    return [line.split()[1] for line in Path("/proc/mounts").read_text().splitlines() if len(line.split()) > 1]


def is_mounted(path):
    return any(str(path) == mount or str(path).startswith(mount + "/")
               for mount in mount_records() if mount.startswith("/tmp/.mount_"))


def process_details(window):
    pid = command(["xdotool", "getwindowpid", window], check=False).stdout.strip()
    if not pid.isdigit():
        raise RuntimeError("Could not identify the LocalSend window process")
    executable = os.readlink(f"/proc/{pid}/exe")
    return int(pid), executable


def stop_app(process, executable):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=8)
    # AppImage runtimes can leave a GUI child in a distinct process group.
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            candidate = os.readlink(proc / "exe")
            if candidate == executable or ("/tmp/.mount_" in executable and candidate.startswith(executable.split("/usr/")[0] + "/")):
                os.kill(int(proc.name), signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass


def start_app(executable, out, label, home):
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_DATA_HOME"] = str(home / ".local/share")
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    env.pop("APPIMAGE_EXTRACT_AND_RUN", None)
    home.mkdir(parents=True, exist_ok=True)
    log = (out / f"{label}.app.log").open("w")
    process = subprocess.Popen([str(executable)], stdout=log, stderr=subprocess.STDOUT,
                               env=env, start_new_session=True)
    window = wait_for(localsend_window, 45)
    if not window:
        stop_app(process, "")
        raise RuntimeError(f"{label}: LocalSend window did not appear (exit={process.poll()})")
    time.sleep(8)  # Flutter can resize the window after its first mapped frame.
    activate(window)
    return process, window


def desktop_entry(home):
    files = sorted((home / ".config/autostart").glob("*.desktop"))
    if len(files) != 1:
        raise RuntimeError(f"Expected one app-created autostart file, found {files}")
    contents = files[0].read_text()
    exec_lines = [line[5:].strip() for line in contents.splitlines() if line.startswith("Exec=")]
    if len(exec_lines) != 1:
        raise RuntimeError(f"Expected one Exec line in {files[0]}")
    args = shlex.split(exec_lines[0])
    if not args:
        raise RuntimeError("Empty desktop Exec command")
    return files[0], contents, args


def exercise(executable, out, label, result, *, expected_option=True):
    out = out / label
    out.mkdir(parents=True, exist_ok=True)
    home = out / "home"
    result.update(label=label, launch_path=str(executable))
    process = None
    gui_executable = None
    try:
        process, window = start_app(executable, out, label, home)
        pid, gui_executable = process_details(window)
        result.update(window_pid=pid, running_executable=gui_executable,
                      fuse_mounted_while_alive=is_mounted(gui_executable))
        if label == "appimage" and not result["fuse_mounted_while_alive"]:
            raise RuntimeError("AppImage did not use a FUSE mount; extraction fallback is not a valid test")
        open_settings(out, window)
        option = find_autostart(out, window)
        if not option:
            if expected_option:
                raise RuntimeError("Autostart setting not located; inspect OCR and screenshots")
            result["outcome"] = "unsupported_missing_option"
            return result
        result["option_ocr"] = option
        # The switch sits in the right column of the 570px Settings card,
        # about 467px to the right of the OCR label in the 1200px window.
        # Clicking the far window edge misses the card entirely.
        switch_x = option["x"] + 467
        switch_y = option["y"] + option["height"] // 2
        result["switch_click"] = {"x": switch_x, "y": switch_y}
        click(switch_x, switch_y)
        desktop = wait_for(lambda: next((home / ".config/autostart").glob("*.desktop"), None)
                           if (home / ".config/autostart").exists() else None, 12)
        snapshot(out, "after-toggle-" + label)
        if not desktop:
            raise RuntimeError("GUI click did not create an autostart desktop file")
        desktop, contents, args = desktop_entry(home)
        (out / f"{label}.desktop").write_text(contents)
        result.update(desktop_file=str(desktop), exec_command=args,
                      exec_exists_while_alive=Path(args[0]).exists(),
                      exec_mounted_while_alive=is_mounted(args[0]))
        if not result["exec_exists_while_alive"]:
            raise RuntimeError("App-created Exec path was already absent while the app ran")
        if label == "appimage" and not result["exec_mounted_while_alive"]:
            raise RuntimeError("App-created Exec did not point into the FUSE mount")
    finally:
        if process:
            stop_app(process, gui_executable or "")
    if "exec_command" not in result:
        return result
    args = result["exec_command"]
    mount_gone = wait_for(lambda: not is_mounted(args[0]), 20)
    result["mount_gone_after_exit"] = bool(mount_gone)
    result["exec_exists_after_exit"] = Path(args[0]).exists()
    if not mount_gone:
        raise RuntimeError("AppImage FUSE mount remained after closing all app processes")
    try:
        launched = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env={**os.environ, "HOME": str(home)}, start_new_session=True)
        relaunched_window = wait_for(localsend_window, 8)
        if relaunched_window:
            pid, exe = process_details(relaunched_window)
            result["exec_relaunch"] = {"window_pid": pid, "window_executable": exe}
            stop_app(launched, exe)
        else:
            try:
                stdout, stderr = launched.communicate(timeout=2)
                result["exec_relaunch"] = {"exit_code": launched.returncode,
                                           "stdout": stdout.decode(errors="replace")[:2000],
                                           "stderr": stderr.decode(errors="replace")[:2000]}
            except subprocess.TimeoutExpired:
                stop_app(launched, "")
                result["exec_relaunch"] = {"still_running_without_window": True}
    except OSError as error:
        result["exec_relaunch"] = {"error": str(error), "errno": error.errno}
    if label == "appimage":
        result["outcome"] = ("reproduced_stale_mount_exec" if
                             not result["exec_exists_after_exit"] and
                             result["exec_relaunch"].get("errno") == 2 else "not_reproduced")
    else:
        result["outcome"] = ("stable_extracted_exec" if
                             result["exec_exists_after_exit"] and
                             "window_pid" in result["exec_relaunch"] else "extracted_exec_not_working")
    return result


def download_release(version, out):
    tag = "v" + version
    name = f"LocalSend-{version}-linux-x86-64.AppImage"
    url = f"https://github.com/localsend/localsend/releases/download/{tag}/{name}"
    path = out / name
    command(["curl", "--fail", "--location", "--retry", "5", "--retry-all-errors",
             "--retry-delay", "3", "--connect-timeout", "20", "--max-time", "300",
             "--output", str(path), url], timeout=360)
    hasher = hashlib.sha256()
    with path.open("rb") as asset_file:
        for chunk in iter(lambda: asset_file.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    (out / "release.json").write_text(json.dumps({"tag": tag, "asset": {"name": name,
        "browser_download_url": url, "size": path.stat().st_size, "sha256": digest}}, indent=2) + "\n")
    path.chmod(0o755)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result = {"version": args.version, "environment": {"runner": "ubuntu-22.04",
              "display": os.environ.get("DISPLAY"), "session": os.environ.get("XDG_SESSION_TYPE")},
              "cases": {}, "errors": []}
    openbox_log = (out / "openbox.log").open("w")
    openbox = subprocess.Popen(["openbox"], stdout=openbox_log, stderr=subprocess.STDOUT)
    try:
        time.sleep(2)
        image = download_release(args.version, out)
        result["appimage"] = str(image)
        expected_option = args.version != "1.10.0"
        current_case = "appimage"
        result["cases"][current_case] = {}
        exercise(image, out, "appimage", result["cases"][current_case], expected_option=expected_option)
        if result["cases"]["appimage"]["outcome"] != "unsupported_missing_option":
            current_case = "direct_relaunch"
            control, window = start_app(image, out, "direct-relaunch", out / "direct-relaunch-home")
            result["cases"]["direct_relaunch"] = {"outcome": "stable_appimage_path_works",
                "window_pid": process_details(window)[0], "appimage_path_exists": image.exists()}
            snapshot(out, "direct-relaunch")
            stop_app(control, process_details(window)[1])
            extracted = out / "squashfs-root"
            command([str(image), "--appimage-extract"], timeout=180, cwd=out)
            if not (extracted / "AppRun").exists():
                raise RuntimeError("AppImage extraction control has no AppRun")
            current_case = "extracted"
            result["cases"][current_case] = {}
            exercise(extracted / "AppRun", out, "extracted", result["cases"][current_case])
    except Exception as error:
        if "current_case" in locals() and current_case in result["cases"]:
            result["cases"][current_case].setdefault("outcome", "harness_error")
        result["errors"].append({"error": str(error), "traceback": traceback.format_exc()})
        print(traceback.format_exc(), file=sys.stderr)
    finally:
        try:
            openbox.terminate()
            openbox.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            openbox.kill()
        (out / "mounts.txt").write_text(Path("/proc/mounts").read_text())
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
