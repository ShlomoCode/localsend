"""Drive the official 1.17.0 Windows portable app through its real pickers.

This is a diagnostic, not a CI assertion about a Flutter widget. Native dialog
presence and closure are checked automatically; screenshots and UIA dumps allow
review of the subsequent Flutter selection state when its semantics are absent.
"""

from __future__ import annotations

import argparse
import csv
import ctypes
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import traceback
from pathlib import Path

import pyautogui
from PIL import ImageGrab, ImageStat
from pywinauto import Desktop
from pywinauto.findwindows import ElementNotFoundError


CASES = ("folder_cancel", "folder_select", "file_cancel", "file_select", "file_multi")
STEP_TIMEOUT = 25.0
pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.15


def now() -> float:
    return round(time.monotonic(), 3)


def wait_for(predicate, timeout: float, label: str):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    raise TimeoutError(f"Timed out after {timeout}s waiting for {label}")


def windows_for_pid(pid: int):
    return [w for w in Desktop(backend="win32").windows() if w.process_id() == pid and w.is_visible()]


def app_window(pid: int):
    candidates = [w for w in windows_for_pid(pid) if w.class_name() != "#32770" and w.rectangle().width() >= 200]
    return max(candidates, key=lambda w: w.rectangle().width() * w.rectangle().height(), default=None)


def native_dialog(pid: int):
    # The Windows common item dialog is a separate top-level #32770 window.
    candidates = [w for w in windows_for_pid(pid) if w.class_name() == "#32770"]
    return candidates[-1] if candidates else None


def save_screenshot(path: Path):
    image = ImageGrab.grab(all_screens=False)
    image.save(path)
    brightness = ImageStat.Stat(image.convert("L")).stddev[0]
    return {"size": list(image.size), "luma_stddev": round(brightness, 2)}


def dump_uia(pid: int, path: Path):
    lines = []
    for window in Desktop(backend="uia").windows():
        try:
            if window.process_id() != pid:
                continue
            lines.append(f"WINDOW {window.window_text()!r} {window.element_info.control_type}")
            for node in window.descendants()[:250]:
                lines.append(f"{node.element_info.control_type} {node.window_text()!r} {node.rectangle()}")
        except Exception as exc:
            lines.append(f"UIA inspection error: {exc!r}")
    path.write_text("\n".join(lines), encoding="utf-8")
    return lines


def ocr_screenshot(image: Path):
    executable = tesseract_executable()
    if not executable:
        return "", "Tesseract unavailable"
    completed = subprocess.run([executable, str(image), "stdout", "-l", "eng"], capture_output=True, text=True, timeout=15)
    return completed.stdout, completed.stderr


def tesseract_executable():
    installed = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tesseract-OCR" / "tesseract.exe"
    return shutil.which("tesseract") or (str(installed) if installed.is_file() else None)


def click_ocr_label(label: str, app) -> bool:
    executable = tesseract_executable()
    if not executable:
        return False
    image = ImageGrab.grab(all_screens=False)
    rect = app.rectangle()
    # Crop to the actual app bounds so Explorer/tray text cannot match.
    cropped = image.crop((rect.left, rect.top, rect.right, rect.bottom))
    temp = Path(os.environ.get("RUNNER_TEMP", os.environ.get("TEMP", "."))) / "localsend-picker-ocr.png"
    cropped.save(temp)
    completed = subprocess.run([executable, str(temp), "stdout", "tsv"], capture_output=True, text=True, timeout=15)
    if completed.returncode:
        return False
    matches = []
    for row in csv.DictReader(completed.stdout.splitlines(), delimiter="\t"):
        if row.get("text", "").strip().lower() == label.lower():
            try:
                matches.append((float(row["conf"]), int(row["left"]), int(row["top"]), int(row["width"]), int(row["height"])))
            except (ValueError, KeyError):
                pass
    if not matches:
        return False
    _, left, top, width, height = max(matches)
    pyautogui.click(rect.left + left + width // 2, rect.top + top + height // 2)
    return True


def click_label(pid: int, label: str):
    # Flutter's Windows UIA semantics vary by engine version. Use them if exposed.
    for window in Desktop(backend="uia").windows():
        if window.process_id() != pid or window.element_info.control_type == "Window" and window.class_name() == "#32770":
            continue
        for node in window.descendants()[:250]:
            if node.window_text().strip().lower() == label.lower() and node.is_visible():
                node.click_input()
                return "uia"
    return None


def click_flutter_control(pid: int, label: str, app, case_log: dict):
    aliases = {"File": ("File", "Files"), "Folder": ("Folder", "Folders")}.get(label, (label,))
    for candidate in aliases:
        method = click_label(pid, candidate)
        if method:
            case_log.setdefault("clicks", []).append({"label": candidate, "method": method})
            return
    for candidate in aliases:
        if click_ocr_label(candidate, app):
            case_log.setdefault("clicks", []).append({"label": candidate, "method": "screenshot_ocr"})
            return
    rect = app.rectangle()
    # Fixed 1000x700 app window, derived from the 1.17 SendTab/NavigationRail
    # layout. Each click is accepted only if the expected native dialog follows.
    points = {"Send": (85, 210), "File": (335, 122), "Folder": (455, 122), "Edit": (754, 262)}
    x, y = points[label]
    pyautogui.click(rect.left + x, rect.top + y)
    case_log.setdefault("clicks", []).append({"label": label, "method": "geometry", "relative_point": [x, y]})


def dialog_select_file(dialog, fixture: Path):
    # Alt+N focuses the Windows common dialog's File name field.
    dialog.set_focus()
    pyautogui.hotkey("alt", "n")
    pyautogui.hotkey("ctrl", "a")
    pyautogui.write(str(fixture), interval=0.005)
    pyautogui.press("enter")


def dialog_select_multiple_files(dialog, fixtures: tuple[Path, Path]):
    dialog.set_focus()
    pyautogui.hotkey("ctrl", "l")
    pyautogui.write(str(fixtures[0].parent), interval=0.005)
    pyautogui.press("enter")
    time.sleep(0.5)
    pyautogui.hotkey("alt", "n")
    pyautogui.hotkey("ctrl", "a")
    pyautogui.write(" ".join(f'"{fixture.name}"' for fixture in fixtures), interval=0.02)
    pyautogui.press("enter")


def dialog_select_folder(dialog, fixture_dir: Path):
    dialog.set_focus()
    pyautogui.hotkey("ctrl", "l")
    pyautogui.write(str(fixture_dir), interval=0.005)
    pyautogui.press("enter")
    time.sleep(0.5)
    # Windows folder dialogs differ between IFileDialog and legacy styles.
    for label in ("Select Folder", "Select a folder", "Open"):
        try:
            button = Desktop(backend="win32").window(handle=dialog.handle).child_window(title=label, class_name="Button")
            if button.exists(timeout=0.5):
                button.click_input()
                return label
        except (ElementNotFoundError, AttributeError):
            pass
    pyautogui.press("enter")
    return "Enter"


def desktop_environment():
    kernel32 = ctypes.windll.kernel32
    user32 = ctypes.windll.user32
    session_id = ctypes.c_ulong()
    kernel32.ProcessIdToSessionId(os.getpid(), ctypes.byref(session_id))
    user32.OpenInputDesktop.restype = ctypes.c_void_p
    user32.OpenInputDesktop.argtypes = [ctypes.c_ulong, ctypes.c_bool, ctypes.c_ulong]
    user32.CloseDesktop.argtypes = [ctypes.c_void_p]
    desktop = user32.OpenInputDesktop(0, False, 0x0100)
    if desktop:
        user32.CloseDesktop(desktop)
    return {
        "platform": platform.platform(),
        "pid": os.getpid(),
        "session_id": session_id.value,
        "active_console_session_id": kernel32.WTSGetActiveConsoleSessionId(),
        "input_desktop_open": bool(desktop),
        "screen_size": list(pyautogui.size()),
        "username": os.environ.get("USERNAME"),
        "sessionname": os.environ.get("SESSIONNAME"),
    }


def run_case(name: str, exe: Path, output: Path, fixture: Path, multi_fixtures: tuple[Path, Path]) -> dict:
    case_dir = output / name
    case_dir.mkdir()
    result = {"case": name, "started_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "events": []}

    def event(label, **fields):
        result["events"].append({"at_monotonic": now(), "label": label, **fields})

    with (case_dir / "stdout.txt").open("wb") as stdout, (case_dir / "stderr.txt").open("wb") as stderr:
        proc = subprocess.Popen([str(exe)], cwd=exe.parent, stdout=stdout, stderr=stderr)
        event("process_started", pid=proc.pid)
        try:
            app = wait_for(lambda: app_window(proc.pid), STEP_TIMEOUT, "LocalSend main window")
            app.set_focus()
            app.move_window(x=0, y=0, width=1000, height=700, repaint=True)
            time.sleep(1)
            event("main_window", rectangle=str(app.rectangle()))
            event("initial_screenshot", **save_screenshot(case_dir / "initial.png"))
            dump_uia(proc.pid, case_dir / "initial_uia.txt")
            click_flutter_control(proc.pid, "Send", app, result)
            time.sleep(1)
            event("send_tab_screenshot", **save_screenshot(case_dir / "send_tab.png"))
            click_flutter_control(proc.pid, "File" if name.startswith("file") else "Folder", app, result)
            dialog = wait_for(lambda: native_dialog(proc.pid), STEP_TIMEOUT, "native picker dialog")
            event("native_picker_open", title=dialog.window_text(), rectangle=str(dialog.rectangle()))
            event("picker_screenshot", **save_screenshot(case_dir / "picker.png"))
            dump_uia(proc.pid, case_dir / "picker_uia.txt")
            if name.endswith("cancel"):
                dialog.set_focus()
                pyautogui.press("esc")
                event("cancel_pressed")
            elif name == "file_multi":
                dialog_select_multiple_files(dialog, multi_fixtures)
                event("multiple_files_selected", paths=[str(p) for p in multi_fixtures])
            elif name.startswith("file"):
                dialog_select_file(dialog, fixture)
                event("file_selected", path=str(fixture))
            else:
                button = dialog_select_folder(dialog, fixture.parent)
                event("folder_selected", path=str(fixture.parent), button=button)
            wait_for(lambda: not native_dialog(proc.pid), STEP_TIMEOUT, "native picker closure")
            event("native_picker_closed")
            if name.endswith("cancel"):
                click_flutter_control(proc.pid, "File" if name.startswith("file") else "Folder", app, result)
                reopened = wait_for(lambda: native_dialog(proc.pid), STEP_TIMEOUT, "picker reopening after cancel")
                event("picker_reopened_after_cancel", title=reopened.window_text())
                reopened.set_focus()
                pyautogui.press("esc")
                wait_for(lambda: not native_dialog(proc.pid), STEP_TIMEOUT, "reopened picker closure")
                event("reopened_picker_closed")
            time.sleep(2)
            event("post_action_screenshot", **save_screenshot(case_dir / "after.png"))
            uia_lines = dump_uia(proc.pid, case_dir / "after_uia.txt")
            ocr_text, ocr_errors = ocr_screenshot(case_dir / "after.png")
            (case_dir / "after_ocr.txt").write_text(ocr_text + "\n--- OCR stderr ---\n" + ocr_errors, encoding="utf-8")
            expected_count = 2 if name == "file_multi" else 1
            count_pattern = re.compile(rf"\bFiles:\s*{expected_count}\b", re.IGNORECASE)
            selected_uia = any(count_pattern.search(line) for line in uia_lines)
            selected_ocr = bool(count_pattern.search(ocr_text))
            result["expected_selected_files"] = expected_count if not name.endswith("cancel") else 0
            result["flutter_selection_uia_observed"] = selected_uia if not name.endswith("cancel") else None
            result["flutter_selection_ocr_observed"] = selected_ocr if not name.endswith("cancel") else None
            if not name.endswith("cancel"):
                click_flutter_control(proc.pid, "Edit", app, result)
                time.sleep(1)
                event("selected_files_view_screenshot", **save_screenshot(case_dir / "selected_files.png"))
                selected_lines = dump_uia(proc.pid, case_dir / "selected_files_uia.txt")
                selected_ocr_text, selected_ocr_errors = ocr_screenshot(case_dir / "selected_files.png")
                (case_dir / "selected_files_ocr.txt").write_text(
                    selected_ocr_text + "\n--- OCR stderr ---\n" + selected_ocr_errors, encoding="utf-8"
                )
                expected_names = [p.name for p in multi_fixtures] if name == "file_multi" else [fixture.name]
                selected_view_text = "\n".join(selected_lines) + "\n" + selected_ocr_text
                result["selected_files_view_names_observed"] = {
                    filename: filename.lower() in selected_view_text.lower() for filename in expected_names
                }
                event("selected_files_view_opened")
            if name.endswith("cancel"):
                result["classification"] = "native_picker_cancelled"
            elif selected_uia or selected_ocr:
                result["classification"] = "native_picker_completed_flutter_selection_observed"
            else:
                result["classification"] = "native_picker_completed_flutter_selection_visual_review_required"
        except Exception as exc:
            result["classification"] = "harness_or_environment_inconclusive"
            result["error"] = repr(exc)
            result["traceback"] = traceback.format_exc()
            event("error")
            try:
                event("failure_screenshot", **save_screenshot(case_dir / "failure.png"))
                dump_uia(proc.pid, case_dir / "failure_uia.txt")
            except Exception as capture_exc:
                event("capture_error", error=repr(capture_exc))
        finally:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=10)
            result["process_exit_code"] = proc.poll()
    (case_dir / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"{name}: {result['classification']} {result.get('error', '')}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"environment": desktop_environment(), "cases": []}
    if not report["environment"]["input_desktop_open"]:
        report["error"] = "No interactive input desktop; native picker UI reproduction unavailable on this runner"
        (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        return 1
    fixture_dir = args.output / "fixture"
    fixture_dir.mkdir()
    fixture = fixture_dir / "picker-2784-sample.txt"
    fixture.write_text("LocalSend issue 2784 Windows native picker diagnostic\n", encoding="utf-8")
    multi_dir = args.output / "multi-fixture"
    multi_dir.mkdir()
    multi_fixtures = (multi_dir / "first.txt", multi_dir / "second.txt")
    for index, path in enumerate(multi_fixtures, start=1):
        path.write_text(f"LocalSend issue 2784 multi file {index}\n", encoding="utf-8")
    exe_matches = list(args.release.rglob("localsend_app.exe"))
    report["release_executables"] = [str(p) for p in exe_matches]
    if len(exe_matches) == 1:
        for name in CASES:
            report["cases"].append(run_case(name, exe_matches[0], args.output, fixture, multi_fixtures))
            (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    else:
        report["error"] = "Expected exactly one localsend_app.exe in verified release"
    (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    if report.get("error") or any(c["classification"] == "harness_or_environment_inconclusive" for c in report["cases"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
