"""Real host sender and SSH-controlled guest receiver; cloud execution only."""
import csv
import io
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import threading
import time

OUT = Path("evidence")
VM = Path("/tmp/issue2414-vm-pair")
CONTENT = b"LocalSend issue 2414 fixed ordinary file content\n"
SSH = ["ssh", "-i", str(VM / "id"), "-p", "2222", "-o", "BatchMode=yes", "-o",
       "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=" + str(VM / "known"),
       "-o", "ConnectTimeout=5", "probe@127.0.0.1"]
SCP = ["scp", "-i", str(VM / "id"), "-P", "2222", "-o", "BatchMode=yes", "-o",
       "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=" + str(VM / "known"), "-o", "ConnectTimeout=5"]


def execute(argv, deadline=25):
    with (OUT / "host-input.jsonl").open("a") as log:
        log.write(json.dumps({"host_monotonic": time.monotonic(), "utc_ns": time.time_ns(), "argv": argv}) + "\n")
    return subprocess.check_output(argv, text=True, timeout=deadline).strip()


def guest(action, *args):
    argv = ["python3", "/home/probe/2414-receiver-driver.py", action, *map(str, args)]
    return json.loads(execute(SSH + ["source /home/probe/desktop-env.sh; " + shlex.join(argv)], 45))


def desktop(side, *argv):
    if side == "guest":
        return guest("desktop", *argv)
    started = time.monotonic()
    result = execute(list(map(str, argv)))
    return {"output": result, "started": started, "completed": time.monotonic()}


def screen(side, stage):
    path = OUT / (stage + ".png")
    if side == "guest":
        timing = desktop(side, "scrot", "/home/probe/evidence/" + path.name)
        execute(SCP + ["probe@127.0.0.1:/home/probe/evidence/" + path.name, str(path)])
    else:
        timing = desktop(side, "scrot", str(path))
    enlarged = OUT / (stage + "-ocr.png")
    execute(["convert", str(path), "-resize", "200%", str(enlarged)])
    text = execute(["tesseract", str(enlarged), "stdout", "--psm", "11", "tsv"])
    (OUT / (stage + ".tsv")).write_text(text)
    (OUT / (stage + "-timing.json")).write_text(json.dumps({"clock": side + " monotonic", **timing}))
    words = list(csv.DictReader(io.StringIO(text), delimiter="\t", quoting=csv.QUOTE_NONE))
    for word in words:
        # Blank frames have a page row without text. Stripping command output
        # removes its final empty TSV field; normalize it to a harmless no-match.
        word["text"] = word.get("text") or ""
        for key in ("left", "top", "width", "height"):
            word[key] = int(word[key]) // 2
    return words, timing


def dialog_screen(stage, count):
    # Keep the full, unmodified screenshot and its ordinary OCR first. PSM 11
    # found the title in run 38114096632 but missed the smaller dialog labels.
    words, timing = screen("guest", stage)
    titles = [word for word in words if word["text"].strip() == "Enter"]
    for title in titles:
        line = [word for word in words if abs(word["top"] - title["top"]) <= 12
                and word["text"].strip() in ("Enter", "file", "name")]
        if {word["text"].strip() for word in line} != {"Enter", "file", "name"}:
            continue
        # Anchor to observed title pixels, not X11 client Y (which disagreed
        # with PNG origin). Include Original, text field and action buttons.
        left = max(0, min(word["left"] for word in line) - 32)
        top = max(0, min(word["top"] for word in line) - 35)
        title_right = max(word["left"] + word["width"] for word in line)
        width = title_right - min(word["left"] for word in line) + 170 + (25 if count == 5000 else 0)
        height = 250
        crop = OUT / (stage + "-dialog-crop.png")
        enlarged = OUT / (stage + "-dialog-ocr.png")
        execute(["convert", str(OUT / (stage + ".png")), "-crop", f"{width}x{height}+{left}+{top}",
                 "+repage", str(crop)])
        execute(["convert", str(crop), "-resize", "300%", str(enlarged)])
        text = execute(["tesseract", str(enlarged), "stdout", "--psm", "6", "tsv"])
        (OUT / (stage + "-dialog.tsv")).write_text(text)
        roi = {"left": left, "top": top, "width": width, "height": height, "scale": 3,
               "psm": 6, "anchor": line, "coordinates": "original full-frame absolute pixels"}
        (OUT / (stage + "-dialog-roi.json")).write_text(json.dumps(roi, indent=2))
        foreground = list(csv.DictReader(io.StringIO(text), delimiter="\t", quoting=csv.QUOTE_NONE))
        for word in foreground:
            # Preserve the existing harmless handling of missing TSV text.
            word["text"] = word.get("text") or ""
            word["left"] = int(word["left"]) // 3 + left
            word["top"] = int(word["top"]) // 3 + top
            for key in ("width", "height"):
                word[key] = int(word[key]) // 3
        return foreground, timing
    # No title means no proven dialog crop. Retain the full frame as discovery
    # evidence and let the same bounded predicate wait for its appearance.
    return [], timing


def locate(side, label, stage, deadline=20):
    end = time.monotonic() + deadline
    index = 0
    while time.monotonic() < end:
        words, timing = screen(side, stage + "-" + str(index))
        index += 1
        for word in words:
            if word["text"].strip() == label:
                return (word["left"] + word["width"] // 2, word["top"] + word["height"] // 2), timing
        time.sleep(.5)
    raise RuntimeError("Visible label missing: " + label)


def click(side, xy, window=None):
    argv = ["xdotool", "mousemove"]
    if window:
        argv += ["--window", window]
    timing = desktop(side, *argv, *map(str, xy), "click", "1")
    # Prevent Home tooltip from covering the selected fixture row.
    desktop(side, "xdotool", "mousemove", "1190", "790")
    time.sleep(.3)
    return timing


def focus(side, window):
    desktop(side, "xdotool", "windowactivate", "--sync", window)
    time.sleep(.5)


def normalize(side, window, stage):
    desktop(side, "xdotool", "windowmove", window, "0", "0")
    desktop(side, "xdotool", "windowsize", window, "1000", "700")
    time.sleep(.5)
    geometry = desktop(side, "xdotool", "getwindowgeometry", "--shell", window)["output"]
    (OUT / (stage + "-geometry.txt")).write_text(geometry)
    values = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
    if (int(values["WIDTH"]), int(values["HEIGHT"])) != (1000, 700):
        raise RuntimeError("Window normalization failed: " + geometry)
    # Openbox may report a decoration offset for the client origin; fixed sender
    # controls use the retained geometry of the same proven desktop configuration.
    screen(side, stage)


def host_window(pid):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        try:
            for window in desktop("host", "xdotool", "search", "--onlyvisible", "--pid", str(pid))["output"].split():
                if desktop("host", "xdotool", "getwindowname", window)["output"] == "LocalSend":
                    desktop("host", "xdotool", "windowmove", window, "0", "0")
                    desktop("host", "xdotool", "windowsize", window, "1000", "700")
                    return window
        except subprocess.CalledProcessError:
            pass
        time.sleep(1)
    raise RuntimeError("Sender window missing")


def sample_sender(pid, stop, path):
    with path.open("w") as output:
        while not stop.wait(.5):
            record = {"host_monotonic": time.monotonic(), "utc_ns": time.time_ns(), "clock_ticks_per_second": os.sysconf("SC_CLK_TCK")}
            for field, source in [("status", f"/proc/{pid}/status"), ("stat", f"/proc/{pid}/stat"),
                                  ("pss", f"/proc/{pid}/smaps_rollup"), ("meminfo", "/proc/meminfo")]:
                try:
                    record[field] = Path(source).read_text()
                except OSError as error:
                    record[field] = str(error)
            output.write(json.dumps(record) + "\n")
            output.flush()


def filename_rows(words):
    """Read observed numeric suffixes; Tesseract splits the path before 'e-'."""
    rows = {}
    for word in words:
        match = re.search(r"(\d{5})\.txt\b", word["text"])
        if match:
            rows["file-" + match.group(1) + ".txt"] = {
                "left": word["left"], "top": word["top"],
                "center_y": word["top"] + word["height"] // 2,
            }
    return rows


def same_file_rows(observed, expected, tolerance=3):
    return observed.keys() == expected.keys() and all(
        abs(observed[name]["center_y"] - expected[name]["center_y"]) <= tolerance
        for name in expected)


def visibly_scrolled(observed, expected):
    if not observed:
        return False
    if len(observed.keys() - expected.keys()) >= 2:
        return True
    return any(abs(observed[name]["center_y"] - expected[name]["center_y"]) >= 12
               for name in observed.keys() & expected.keys())


def observe_probe(predicate, stage, deadline=45, dialog_count=None):
    started = time.monotonic()
    end = started + deadline
    previous = None
    index = 0
    while time.monotonic() < end:
        frame_stage = stage + "-" + str(index)
        if dialog_count is None:
            words, timing = screen("guest", frame_stage)
        else:
            words, timing = dialog_screen(frame_stage, dialog_count)
        index += 1
        if predicate(words):
            return words, {"first_matching_capture": timing, "last_nonmatching_capture": previous,
                           "assertion_seconds_including_ocr": time.monotonic() - started}
        previous = timing
        time.sleep(.5)
    raise RuntimeError("Probe observation deadline; inspect frames, not proof of hang: " + stage)


def reaction_timing(input_timing, observation, host_started):
    capture = observation["first_matching_capture"]
    return {"input_guest_monotonic": input_timing,
            "first_matching_capture_guest_monotonic": capture,
            "last_nonmatching_capture_guest_monotonic": observation["last_nonmatching_capture"],
            "capture_start_since_input_started_seconds": capture["started"] - input_timing["started"],
            "capture_end_since_input_started_seconds": capture["completed"] - input_timing["started"],
            "total_seconds_including_ssh_and_ocr": time.monotonic() - host_started,
            "note": "Observed capture bounds include SSH/input/capture overhead and polling; not isolated render latency."}


def options_interaction_probes(count, case, window):
    probes = {"count": count, "classification": "in-progress", "deadline_note":
              "A 45-second observation deadline is an automation/discovery result, not evidence of hang or OOM."}
    path = OUT / (case + "-options-interactions.json")

    def retain():
        path.write_text(json.dumps(probes, indent=2))
        print(json.dumps({"phase": "options-interactions", **probes}), flush=True)

    try:
        geometry = desktop("guest", "xdotool", "getwindowgeometry", "--shell", window)["output"]
        probes["geometry"] = geometry
        bounds = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
        if (int(bounds["WIDTH"]), int(bounds["HEIGHT"])) != (1000, 700):
            raise RuntimeError("Probe requires observed 1000x700 geometry")
        words, before_capture = screen("guest", case + "-wheel-before")
        before = filename_rows(words)
        if not before:
            raise RuntimeError("No OCR filename rows before wheel")
        probes["before_wheel"] = {"rows": before, "capture": before_capture}
        first = min(before.values(), key=lambda row: row["top"])
        # Wheel input targets a visible file row inside the actual list.
        wheel_point = (first["left"] + 20, first["center_y"])
        host_started = time.monotonic()
        wheel = desktop("guest", "xdotool", "mousemove", *map(str, wheel_point),
                        "click", "--repeat", "6", "--delay", "120", "5")
        desktop("guest", "xdotool", "mousemove", "1190", "790")
        if count == 5000:
            changed, observed = observe_probe(
                lambda frame: visibly_scrolled(filename_rows(frame), before),
                case + "-wheel-down", 45)
            after = filename_rows(changed)
            probes["wheel_down"] = {"classification": "visible-file-rows-changed", "rows": after,
                                    **reaction_timing(wheel, observed, host_started)}
        else:
            # Five ordinary rows fit this viewport. Still retain real wheel input
            # and the resulting frame; a stationary fitting list is expected.
            time.sleep(1)
            changed, capture = screen("guest", case + "-wheel-down-control")
            after = filename_rows(changed)
            if len(before) != count or len(after) != count:
                raise RuntimeError("Five-row fit cannot be established from OCR")
            probes["wheel_down"] = {"classification": "all-five-rows-fit-viewport",
                                    "rows": after, "positions_unchanged_within_3px": same_file_rows(after, before),
                                    **reaction_timing(wheel, {"first_matching_capture": capture,
                                       "last_nonmatching_capture": None}, host_started)}
        retain()
        host_started = time.monotonic()
        wheel_up = desktop("guest", "xdotool", "mousemove", *map(str, wheel_point),
                           "click", "--repeat", "6", "--delay", "120", "4")
        desktop("guest", "xdotool", "mousemove", "1190", "790")
        restored_words, restored = observe_probe(
            lambda frame: same_file_rows(filename_rows(frame), before), case + "-wheel-restored", 45)
        probes["wheel_up"] = {"classification": "original-rows-and-positions-restored",
                              **reaction_timing(wheel_up, restored, host_started)}
        rows = filename_rows(restored_words)
        original = min(rows, key=lambda name: rows[name]["top"])
        row = rows[original]
        # Screenshot 38111506442 shows the pencil 9 pixels below the filename
        # center, at client x739. Derive y from this run's visible row, not OCR of
        # an icon; reject geometry drift before using the observed icon column.
        pencil = (int(bounds["X"]) + 739, row["center_y"] + 9)
        probes["editor_original_filename"] = original
        probes["editor_original_ocr_tokens"] = [word["text"] for word in restored_words
                                               if abs(word["top"] - row["top"]) <= 3 and word["text"].strip()]
        probes["dialog_source_expectation"] = {
            "release": "v1.17.0", "path": "app/lib/widget/dialogs/file_name_input_dialog.dart",
            "title": "Enter file name", "original_label": "Original:", "autofocus": True,
            "cancel_label": "Cancel", "note": "Runtime OCR must establish these observations; source alone is not a passed probe."}
        probes["editor_target"] = {"absolute_xy": pencil, "observed_row": row,
                                   "reference": "38111506442/files-5000-options-visible.png"}
        host_started = time.monotonic()
        opened = click("guest", pencil)
        dialog_words, dialog = observe_probe(
            lambda frame: {"Enter", "file", "name", "Cancel", "Original:"}.issubset(
                {word["text"].strip() for word in frame}) and original in filename_rows(frame),
            case + "-editor-open", 45, dialog_count=count)
        probes["editor_open"] = {"classification": "file-name-dialog-observed",
                                 **reaction_timing(opened, dialog, host_started)}
        screen("guest", case + "-editor-textfield-before")
        # v1.17 FileNameInputDialog has autofocus:true. Confirm focus through
        # observed draft text rather than assuming that autofocus took effect.
        host_started = time.monotonic()
        draft_input = desktop("guest", "xdotool", "key", "--clearmodifiers", "ctrl+a")
        typed = desktop("guest", "xdotool", "type", "--clearmodifiers", "--delay", "40", "Probe2414.txt")
        draft_words, draft = observe_probe(
            lambda frame: any(word["text"].strip() == "Probe2414.txt" for word in frame)
            and any(word["text"].strip() == "Cancel" for word in frame),
            case + "-editor-draft", 45, dialog_count=count)
        probes["draft_input"] = {"classification": "draft-visible-in-dialog", "select_all": draft_input,
                                 **reaction_timing(typed, draft, host_started)}
        cancel = next(word for word in draft_words if word["text"].strip() == "Cancel")
        host_started = time.monotonic()
        cancelled = click("guest", (cancel["left"] + cancel["width"] // 2,
                                     cancel["top"] + cancel["height"] // 2))
        returned_words, returned = observe_probe(
            lambda frame: same_file_rows(filename_rows(frame), before)
            and any(word["text"].strip() == "Options" for word in frame)
            and not any(word["text"].strip() in ("Cancel", "Probe2414.txt") for word in frame),
            case + "-editor-cancel-return", 45)
        probes["editor_cancel"] = {"classification": "original-filenames-restored-without-draft",
                                   "rows": filename_rows(returned_words),
                                   **reaction_timing(cancelled, returned, host_started)}
        probes["classification"] = "wheel-and-editor-cancel-observed"
        retain()
        return probes
    except Exception as error:
        probes.update({"classification": "automation-or-discovery-failure", "failure": str(error)})
        try:
            screen("guest", case + "-interaction-discovery-failure")
        except Exception as capture_error:
            probes["capture_error"] = str(capture_error)
        retain()
        raise


results = []
for count in (5, 5000):
    case = "files-" + str(count)
    sender = None
    stage = "setup"
    result = {"count": count, "failure": None, "classification": None}
    receiver_started = False
    stop_sampling = threading.Event()
    sampler = None
    try:
        fixture = Path.home() / ("Case2414Files" + str(count))
        fixture.mkdir()
        for index in range(count):
            (fixture / f"file-{index:05d}.txt").write_bytes(CONTENT)
        bundle = Path("/tmp") / (case + "-host-sender")
        shutil.copytree("released/base", bundle)
        (bundle / "settings.json").write_text(json.dumps({
            "flutter.ls_alias": "Sender2414", "flutter.ls_port": 53317,
            "flutter.ls_locale": "en", "flutter.ls_minimize_to_tray": False,
        }))
        receiver = guest("start", count)
        receiver_started = True
        rwin = receiver["window"]
        with (OUT / (case + "-sender.log")).open("w") as log:
            sender = subprocess.Popen([str(bundle / "localsend_app")], stdout=log, stderr=subprocess.STDOUT)
        sampler = threading.Thread(target=sample_sender, args=(sender.pid, stop_sampling, OUT / (case + "-sender-metrics.jsonl")), daemon=True)
        sampler.start()
        swin = host_window(sender.pid)
        stage = "sender-selection"
        focus("host", swin)
        locate("host", "Sender2414", case + "-sender-ready", 30)
        normalize("host", swin, case + "-sender-normalized")
        screen("host", case + "-send-observed")
        click("host", (96, 188))
        screen("host", case + "-folder-observed")
        click("host", (514, 150))
        locate("host", "Recent", case + "-picker-ready", 15)
        chooser = desktop("host", "xdotool", "search", "--onlyvisible", "--name", "Choose Directory")["output"].split()[-1]
        focus("host", chooser)
        click("host", locate("host", "Home", case + "-home")[0])
        time.sleep(2)
        click("host", locate("host", fixture.name, case + "-folder-row")[0])
        screen("host", case + "-folder-selected")
        click("host", locate("host", "Open", case + "-picker-open")[0])
        time.sleep(2)
        screen("host", case + "-picker-accepted")
        stage = "discovery-and-approval"
        click("host", locate("host", "Receiver2414", case + "-target", 60)[0])
        focus("guest", rwin)
        locate("guest", "Options", case + "-approval-ready", 45)
        normalize("guest", rwin, case + "-approval-normalized")
        options = locate("guest", "Options", case + "-approval", 15)[0]
        stage = "options"
        assertion_started = time.monotonic()
        clicked = click("guest", options)
        result["options_click_guest_monotonic"] = clicked["started"]
        _, visible = locate("guest", "Save", case + "-options", 45)
        result["options_first_observed_screenshot_guest_monotonic"] = visible["completed"]
        result["options_first_observed_seconds"] = visible["completed"] - clicked["started"]
        result["options_assertion_seconds_including_ocr"] = time.monotonic() - assertion_started
        result["timing_note"] = "First matching screenshot capture completion, including SSH input/capture overhead; not isolated paint latency."
        print(json.dumps({"phase": "options-observed", **result}), flush=True)
        screen("guest", case + "-options-visible")
        stage = "options-interaction-probes"
        result["options_interactions"] = options_interaction_probes(count, case, rwin)
        stage = "return-and-accept"
        focus("guest", rwin)
        desktop("guest", "xdotool", "getwindowgeometry", "--shell", rwin)
        back_clicked = click("guest", (28, 28), rwin)
        focus("guest", rwin)
        screen("guest", case + "-returned")
        # Options also names the old route title; "wants" uniquely confirms
        # that the app responded to Back by showing receiver approval again.
        _, approval_visible = locate("guest", "wants", case + "-accept-ready", 45)
        result["back_first_observed_seconds"] = approval_visible["completed"] - back_clicked["started"]
        print(json.dumps({"phase": "back-response-observed", **result}), flush=True)
        if count == 5000:
            # Preserve the reported Options/input observation before the separate
            # long save phase. The workflow uploads this checkpoint, then resumes.
            result["kernel_at_options"] = guest("checkpoint")
            checkpoint_guest = OUT / "vm" / "checkpoint-guest"
            checkpoint_guest.parent.mkdir(exist_ok=True)
            execute(SCP + ["-r", "probe@127.0.0.1:/home/probe/evidence", str(checkpoint_guest)], 90)
            (OUT / "options-checkpoint-results.json").write_text(json.dumps([*results, result], indent=2))
            print(json.dumps({"phase": "options-checkpoint-ready", **result}), flush=True)
            (OUT / "options-checkpoint-ready").write_text("5000-file Options and Back observed; save not started\n")
            resume = Path("/tmp/issue2414-checkpoint-continue")
            checkpoint_deadline = time.monotonic() + 300
            while not resume.exists() and time.monotonic() < checkpoint_deadline:
                time.sleep(1)
            if not resume.exists():
                raise RuntimeError("Workflow did not resume after Options evidence checkpoint (infrastructure)")
        geometry = desktop("guest", "xdotool", "getwindowgeometry", "--shell", rwin)["output"]
        (OUT / (case + "-approval-geometry.txt")).write_text(geometry)
        bounds = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
        width, height = int(bounds["WIDTH"]), int(bounds["HEIGHT"])
        if (width, height) not in ((900, 600), (1000, 700)):
            raise RuntimeError("Unverified approval geometry: " + str((width, height)))
        # Observed approval controls: (519,550) at 900x600, (569,650) at 1000x700.
        click("guest", (width // 2 + 69, height - 50), rwin)
        screen("guest", case + "-accepted")
        stage = "save"
        # Original release saved only ~2.8 tiny files/second on the host control.
        # Allow ordinary progress to complete; this is not an Options timeout.
        end = time.monotonic() + 2400
        while time.monotonic() < end:
            saved = guest("verify")
            with (OUT / (case + "-save-progress.jsonl")).open("a") as progress:
                progress.write(json.dumps({"host_monotonic": time.monotonic(), **saved}) + "\n")
            print(json.dumps({"phase": "save-progress", "count": count, **saved}), flush=True)
            if saved["content_valid"]:
                break
            time.sleep(10)
        result.update(saved)
        if not saved["content_valid"]:
            raise RuntimeError("Saved names or bytes differ from fixture")
        locate("guest", "Finished", case + "-receiver-finished", 30)
        locate("host", "Finished", case + "-sender-finished", 30)
        result["classification"] = "completed-real-app-transfer"
    except Exception as error:
        result.update({"failure": str(error), "stage": stage,
                       "classification": "unclassified-options-deadline" if stage == "options" else "infrastructure-or-transfer-failure"})
        # A deadline alone does not establish hang/OOM; inspect screenshots and kernel evidence.
        for side in ("host", "guest"):
            try:
                screen(side, case + "-" + side + "-failure")
            except Exception as capture_error:
                result[side + "_capture_error"] = str(capture_error)
    finally:
        stop_sampling.set()
        if sampler:
            sampler.join(timeout=3)
        if sender:
            sender.terminate()
            try:
                sender.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sender.kill()
        if receiver_started:
            try:
                guest("stop")
            except Exception as error:
                result["cleanup_error"] = str(error)
        results.append(result)
        (OUT / "results.json").write_text(json.dumps(results, indent=2))
    if result["failure"]:
        raise SystemExit("Control/case failed; inspect evidence before interpreting: " + case)
