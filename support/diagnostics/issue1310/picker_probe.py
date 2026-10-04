#!/usr/bin/env python3
"""Exercise the released Linux LocalSend picker UI under Xvfb/openbox.

Usage: picker_probe.py /path/to/localsend /path/to/output-directory

Requires xdotool, wmctrl, ImageMagick's import, and tesseract. The caller starts
Xvfb/openbox (1200x900) and sets DISPLAY. Evidence is written to the output
directory even when a control action fails.
"""

import csv
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


MAX_SECONDS = 120
CHOOSER_WAIT_SECONDS = 9
POLL_SECONDS = 0.6
CHOOSER_TITLE = re.compile(r"(open|select|choose|folder|directory|file|save)", re.I)
CHOOSER_CLASS = re.compile(r"(gtk|portal|filechooser)", re.I)


def run(*args, timeout=4, check=False, env=None):
    """Run a bounded external UI command without a shell."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("probe deadline reached")
    result = subprocess.run(args, capture_output=True, text=True, errors="replace", env=env,
                            timeout=min(timeout, remaining))
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def pause(seconds):
    time.sleep(max(0, min(seconds, deadline - time.monotonic())))


def windows():
    """Gather both EWMH clients and X-visible windows (including transients)."""
    wm_raw = run("wmctrl", "-lpGx")
    visible_raw = run("xdotool", "search", "--onlyvisible", "--name", ".")
    visible_ids = set()
    for line in visible_raw.splitlines():
        try:
            visible_ids.add(int(line.strip(), 10))
        except ValueError:
            pass
    result = {}
    for line in wm_raw.splitlines():
        parts = line.split(None, 9)
        if len(parts) < 9:
            continue
        try:
            wid = int(parts[0], 16)
        except ValueError:
            continue
        result[wid] = {
            "id": hex(wid), "desktop": parts[1], "pid": parts[2],
            "x": parts[3], "y": parts[4], "width": parts[5],
            "height": parts[6], "wm_class": parts[7], "host": parts[8],
            "title": parts[9] if len(parts) > 9 else "",
            "xdotool_visible": wid in visible_ids,
            "wmctrl_client": True,
        }
    # Some GTK/portal transients are absent from wmctrl, so include xdotool's
    # visible set with title, PID, and geometry where the X server provides it.
    for wid in visible_ids - result.keys():
        title = run("xdotool", "getwindowname", str(wid))
        pid = run("xdotool", "getwindowpid", str(wid))
        geom = run("xdotool", "getwindowgeometry", "--shell", str(wid))
        fields = dict(re.findall(r"^(\w+)=(.*)$", geom, re.M))
        result[wid] = {
            "id": hex(wid), "title": title, "pid": pid,
            "x": fields.get("X"), "y": fields.get("Y"),
            "width": fields.get("WIDTH"), "height": fields.get("HEIGHT"),
            "xdotool_visible": True, "wmctrl_client": False,
        }
    for wid, window in result.items():
        window["xprop"] = run("xprop", "-id", str(wid), "WM_CLASS", "WM_TRANSIENT_FOR", "_NET_WM_WINDOW_TYPE")
        pid = window.get("pid", "")
        if str(pid).isdigit():
            try:
                window["process_cmdline"] = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            except OSError:
                window["process_cmdline"] = None
    return result, {"wmctrl": wm_raw, "xdotool_visible": visible_raw,
                    "xwininfo_tree": run("xwininfo", "-root", "-tree")}


def ocr(image_path, tsv_path, region=None):
    ocr_image = image_path.with_name(image_path.stem + "_ocr.png")
    if region:
        x, y, width, height = region
        # A full root image has a large black surround. OCR on the visible app
        # or chooser client area keeps LocalSend's small teal labels legible.
        run(image_magick, str(image_path), "-background", "white", "-alpha", "remove", "-alpha", "off",
            "-crop", f"{width}x{height}+{x}+{y}", "+repage", "-resize", "200%", str(ocr_image),
            timeout=7, check=True)
    else:
        run(image_magick, str(image_path), "-background", "white", "-alpha", "remove", "-alpha", "off",
            str(ocr_image), timeout=7, check=True)
    tesseract_env = os.environ.copy()
    tesseract_env["OMP_THREAD_LIMIT"] = "1"
    tsv = run("tesseract", str(ocr_image), "stdout", "--psm", "11", "tsv", timeout=12,
              check=True, env=tesseract_env)
    tsv_path.write_text(tsv + "\n", encoding="utf-8")
    words = parse_tsv(tsv)
    if region:
        for word in words:
            word["x"] = x + word["x"] // 2
            word["y"] = y + word["y"] // 2
            word["width"] = max(1, word["width"] // 2)
            word["height"] = max(1, word["height"] // 2)
    return words, ocr_image.name


def parse_tsv(tsv):
    words = []
    for row in csv.DictReader(io.StringIO(tsv), delimiter="\t"):
        token = (row.get("text") or "").strip()
        if not token:
            continue
        try:
            words.append({
                "text": token, "confidence": float(row["conf"]),
                "x": int(row["left"]), "y": int(row["top"]),
                "width": int(row["width"]), "height": int(row["height"]),
            })
        except (KeyError, ValueError):
            continue
    return words


def capture(label):
    image = output / f"{label}.png"
    tsv = output / f"{label}.tsv"
    run("import", "-window", "root", str(image), timeout=6, check=True)
    wins, raw = windows()
    region = ocr_region(wins)
    words, ocr_image = ocr(image, tsv, region)
    (output / f"{label}_windows.txt").write_text(
        "wmctrl -lpGx\n" + raw["wmctrl"] + "\n\n"
        + "xdotool search --onlyvisible --name .\n" + raw["xdotool_visible"]
        + "\n\nxwininfo -root -tree\n" + raw["xwininfo_tree"] + "\n",
        encoding="utf-8",
    )
    return {"label": label, "screenshot": image.name, "ocr_image": ocr_image,
            "ocr_region": region, "ocr_tsv": tsv.name,
            "windows_file": f"{label}_windows.txt", "windows": list(wins.values()),
            "ocr_words": words, "_windows_by_id": wins}


def public_capture(snapshot):
    return {key: value for key, value in snapshot.items() if not key.startswith("_")}


def ocr_region(wins):
    visible = [window for window in wins.values() if window.get("xdotool_visible")
               and window.get("wmctrl_client")]
    def geometry(window):
        try:
            x, y = int(window["x"]), int(window["y"])
            width, height = int(window["width"]), int(window["height"])
        except (TypeError, ValueError, KeyError):
            return None
        if width < 300 or height < 250 or x < 0 or y < 0:
            return None
        return (x, y, width, height)
    # Prefer a native dialog when one is visible; otherwise OCR LocalSend.
    dialogs = [window for window in visible if CHOOSER_TITLE.search(window.get("title", ""))
               and "localsend" not in window.get("title", "").casefold()
               and geometry(window)]
    if dialogs:
        return geometry(dialogs[-1])
    apps = [window for window in visible if "localsend" in window.get("title", "").casefold()
            and geometry(window)]
    return geometry(apps[-1]) if apps else None


def token(snapshot, expected):
    candidates = [word for word in snapshot["ocr_words"]
                  if word["text"].strip(".,:;!?()[]").casefold() == expected.casefold()
                  and word["confidence"] >= 20]
    if expected == "Send":
        # The navigation rail is on the left; Send can appear elsewhere too.
        candidates.sort(key=lambda word: (word["x"] > 300, word["x"], word["y"]))
    else:
        candidates.sort(key=lambda word: (-word["confidence"], word["y"]))
    return candidates[0] if candidates else None


def click_word(snapshot, expected):
    word = token(snapshot, expected)
    if word is None:
        return {"word": expected, "found": False, "ocr_candidates":
                [w for w in snapshot["ocr_words"] if expected.casefold() in w["text"].casefold()]}
    x = word["x"] + word["width"] // 2
    y = word["y"] + word["height"] // 2
    run("xdotool", "mousemove", str(x), str(y), "click", "1", check=True)
    return {"word": expected, "found": True, "x": x, "y": y, "ocr": word}


def chooser_observation(before, after, app_pid):
    old = before["_windows_by_id"]
    current = after["_windows_by_id"]
    newcomers = [window for wid, window in current.items() if wid not in old]
    candidates = []
    for window in newcomers:
        title = window.get("title", "")
        wm_class = window.get("wm_class", "")
        title_match = bool(CHOOSER_TITLE.search(title))
        class_match = bool(CHOOSER_CLASS.search(wm_class + " " + window.get("xprop", "")))
        if window.get("xdotool_visible") and (title_match or class_match):
            candidates.append(window)
    # A native dialog can reuse a hidden window. Track newly visible clients too.
    for wid, window in current.items():
        if wid in old and not old[wid].get("xdotool_visible") and window.get("xdotool_visible"):
            title = window.get("title", "")
            wm_class = window.get("wm_class", "")
            if CHOOSER_TITLE.search(title) or CHOOSER_CLASS.search(wm_class + " " + window.get("xprop", "")):
                candidates.append(window)
    dialog_words = [w for w in after["ocr_words"]
                    if w["text"].strip(".,:;!?()[]").casefold()
                    in {"open", "cancel", "select", "folder", "file"}]
    labels = {word["text"].strip(".,:;!?()[]").casefold() for word in dialog_words}
    # A newly mapped native dialog plus its visible Cancel control is stronger
    # evidence than a title or window class alone (which can match app windows).
    confirmed = bool(candidates) and "cancel" in labels
    return {"new_windows": newcomers, "chooser_candidates": candidates,
            "visible_chooser": bool(candidates), "confirmed_chooser": confirmed,
            "app_pid": app_pid, "ocr_dialog_words": dialog_words}


def wait_for_chooser(before, prefix, app_pid):
    end = min(deadline, time.monotonic() + CHOOSER_WAIT_SECONDS)
    latest = None
    observation = None
    while time.monotonic() < end:
        pause(POLL_SECONDS)
        latest = capture(f"{prefix}_post")
        observation = chooser_observation(before, latest, app_pid)
        if observation["confirmed_chooser"]:
            break
    return latest, observation


def chooser_action(name, before, app_pid):
    click = click_word(before, name)
    if not click["found"]:
        return {"click": click, "pre": public_capture(before), "control_succeeded": False}
    after, observation = wait_for_chooser(before, name.lower(), app_pid)
    result = {"click": click, "pre": public_capture(before),
              "post": public_capture(after), "dialog": observation,
              "control_succeeded": observation["confirmed_chooser"]}
    if observation["visible_chooser"]:
        run("xdotool", "key", "Escape", check=True)
        pause(0.8)
        result["after_cancel"] = public_capture(capture(f"{name.lower()}_after_cancel"))
    return result


def main():
    global deadline, output
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + MAX_SECONDS
    evidence = {"binary": str(binary), "output": str(output), "display": os.environ.get("DISPLAY"),
                "screen_expected": "1200x900", "steps": {}, "conclusion": "inconclusive"}
    report = output / "result.json"
    process = None
    try:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"not an executable file: {binary}")
        for program in ("xdotool", "wmctrl", "xwininfo", "xprop", "import", "tesseract"):
            if shutil.which(program) is None:
                raise RuntimeError(f"missing command: {program}")
        global image_magick
        image_magick = shutil.which("magick") or shutil.which("convert")
        if not image_magick:
            raise RuntimeError("missing ImageMagick magick/convert")
        if not os.environ.get("DISPLAY"):
            raise RuntimeError("DISPLAY is unset; start Xvfb and openbox first")
        baseline = capture("baseline")
        evidence["baseline"] = public_capture(baseline)
        env = os.environ.copy()
        for key, dirname in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                             ("XDG_CACHE_HOME", "cache")):
            path = output / dirname
            path.mkdir(exist_ok=True)
            env[key] = str(path)
        env["LANG"] = "C.UTF-8"
        env["LC_ALL"] = "C.UTF-8"
        stdout_path = output / "app_stdout.txt"
        evidence["app_stdout"] = stdout_path.name
        evidence["gtk_use_portal"] = env.get("GTK_USE_PORTAL")
        evidence["desktop"] = {key: env.get(key) for key in ("XDG_CURRENT_DESKTOP", "DESKTOP_SESSION", "XDG_SESSION_DESKTOP")}
        with stdout_path.open("wb") as stdout:
            command = [str(binary)]
            if shutil.which("strace"):
                evidence["strace"] = "strace.log"
                command = ["strace", "-f", "-o", str(output / "strace.log"),
                           "-e", "trace=process,file", *command]
            process = subprocess.Popen(command, cwd=str(binary.parent), env=env,
                                       stdout=stdout, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            evidence["app_pid"] = process.pid
            ready = None
            while time.monotonic() < min(deadline, start + 20):
                pause(0.8)
                ready = capture("startup")
                if token(ready, "Send"):
                    break
                if process.poll() is not None:
                    break
            evidence["startup"] = public_capture(ready) if ready else None
            if not ready or not token(ready, "Send"):
                evidence["error"] = "Send navigation token was not visible; app startup/control failed"
                return 1
            evidence["steps"]["send"] = {"pre": public_capture(ready),
                                          "click": click_word(ready, "Send")}
            pause(1.3)
            send_post = capture("send_post")
            evidence["steps"]["send"]["post"] = public_capture(send_post)
            evidence["steps"]["send"]["control_succeeded"] = bool(token(send_post, "Folder") and token(send_post, "File"))
            if not evidence["steps"]["send"]["control_succeeded"]:
                evidence["error"] = "Send page did not expose both Folder and File controls"
                return 1
            # Folder is the working control; File is the target action.
            evidence["steps"]["folder"] = chooser_action("Folder", send_post, process.pid)
            file_pre = capture("file_pre")
            evidence["steps"]["file"] = chooser_action("File", file_pre, process.pid)
            folder_ok = evidence["steps"]["folder"]["control_succeeded"]
            file_ok = evidence["steps"]["file"]["control_succeeded"]
            if folder_ok and not file_ok and evidence["steps"]["file"]["click"]["found"]:
                evidence["conclusion"] = "file_dialog_absent_with_folder_control_present"
            elif file_ok and folder_ok:
                evidence["conclusion"] = "both_native_pickers_present"
            else:
                evidence["conclusion"] = "inconclusive_control_failed"
            return 0
    except (OSError, RuntimeError, ValueError, AttributeError, subprocess.TimeoutExpired, TimeoutError) as exc:
        evidence["error"] = f"{type(exc).__name__}: {exc}"
        return 1
    finally:
        if process is not None:
            evidence["app_exit_code_before_cleanup"] = process.poll()
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=2)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        report.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    start = time.monotonic()
    sys.exit(main())
