"""Cloud-only ordinary desktop actions; adapted from qualified issue2414 pair.

The 11/14 MB report gives no byte counts: use decimal MB explicitly, two
repeats, with a fresh basename per repeat. No product instrumentation.
"""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import time

OUT = Path("evidence")
OUT.mkdir(exist_ok=True)
RESULTS = []


def run(*args):
    with (OUT / "inputs.jsonl").open("a") as log:
        log.write(json.dumps({"monotonic": time.monotonic(), "argv": args}) + "\n")
    return subprocess.check_output(args, text=True, timeout=30).strip()


def screen(stage, roi=None, psm=11):
    path = OUT / (stage + ".png")
    run("scrot", str(path))
    image = OUT / (stage + "-ocr.png")
    command = ["convert", str(path)]
    if roi:
        x, y, width, height = roi
        command += ["-crop", f"{width}x{height}+{x}+{y}", "+repage"]
    command += ["-resize", "300%", str(image)]
    run(*command)
    rows = []
    # Sparse OCR skips light text on filled Material buttons. Preserve both
    # contrast passes against the same screenshot instead of guessing clicks.
    for contrast in ("normal", "inverted"):
        ocr_image = image
        if contrast == "inverted":
            ocr_image = OUT / (stage + "-ocr-inverted.png")
            run("convert", str(image), "-negate", str(ocr_image))
        text = run("tesseract", str(ocr_image), "stdout", "--psm", str(psm), "tsv")
        suffix = "" if contrast == "normal" else "-inverted"
        (OUT / (stage + suffix + ".tsv")).write_text(text)
        rows.extend(csv.DictReader(io.StringIO(text), delimiter="\t", quoting=csv.QUOTE_NONE))
    for row in rows:
        row["text"] = row.get("text") or ""
        for key in ("left", "top", "width", "height"):
            row[key] = int(row[key]) // 3
        row["left"] += roi[0] if roi else 0
        row["top"] += roi[1] if roi else 0
    return rows


def locate(label, stage, seconds=20, roi=None, psm=11):
    end = time.monotonic() + seconds
    index = 0
    while True:
        rows = screen(stage + "-" + str(index), roi, psm)
        index += 1
        matches = [row for row in rows if row["text"].strip().lower() == label.lower()]
        if matches:
            row = matches[0]
            return row["left"] + row["width"] // 2, row["top"] + row["height"] // 2
        if time.monotonic() >= end:
            raise RuntimeError("Visible label missing: " + label)
        time.sleep(.5)


def click(point, window=None):
    args = ["xdotool", "mousemove"]
    if window:
        args += ["--window", window]
    run(*args, *map(str, point), "click", "1")
    run("xdotool", "mousemove", "1190", "790")
    time.sleep(.4)


def focus(window):
    run("xdotool", "windowactivate", "--sync", window)
    time.sleep(.5)


def normalize(window, stage):
    for _ in range(3):
        run("xdotool", "windowmove", window, "0", "0")
        run("xdotool", "windowsize", window, "1000", "700")
        time.sleep(.8)
    geometry = run("xdotool", "getwindowgeometry", "--shell", window)
    (OUT / (stage + "-geometry.txt")).write_text(geometry)
    fields = dict(line.split("=", 1) for line in geometry.splitlines())
    if (int(fields["WIDTH"]), int(fields["HEIGHT"])) != (1000, 700):
        raise RuntimeError("Window normalization failed")
    screen(stage)


def window(pid):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        try:
            for wid in run("xdotool", "search", "--onlyvisible", "--pid", str(pid)).split():
                if run("xdotool", "getwindowname", wid) == "LocalSend":
                    return wid
        except subprocess.CalledProcessError:
            pass
        time.sleep(.5)
    raise RuntimeError("App window missing")


def digest(path):
    if not path.exists():
        return {"exists": False, "path": str(path)}
    return {"exists": True, "path": str(path), "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def overwrite(path, size, version):
    # Normal truncate/write/fsync of exactly the same path, deterministic nonzero
    # content. The prefix also changes, so a truncated new file cannot match old.
    block = hashlib.sha256(f"issue1054-corpus-version-{version}".encode()).digest() * 2048
    with path.open("wb") as output:
        remaining = size
        while remaining:
            chunk = block[:min(remaining, len(block))]
            output.write(chunk)
            remaining -= len(chunk)
        output.flush()
        os.fsync(output.fileno())
    return digest(path)


def select_file(swin, fixture, stage):
    focus(swin)
    # Qualified issue2414 sidebar coordinates, under gated1000x700 geometry.
    click((96, 188), swin)
    locate("Selection", stage + "-send-tab", roi=(200, 20, 800, 400))
    click(locate("File", stage + "-file-button", roi=(200, 80, 780, 180)))
    locate("Recent", stage + "-chooser-ready", 20)
    chooser = run("xdotool", "search", "--onlyvisible", "--name", "Select|Choose|Open").split()[-1]
    focus(chooser)
    # Use the native chooser's normal location field. The automatically
    # selected first row uses white-on-blue text that sparse OCR omits.
    run("xdotool", "key", "--clearmodifiers", "ctrl+l")
    run("xdotool", "type", "--clearmodifiers", "--", str(fixture))
    screen(stage + "-native-file-location")
    run("xdotool", "key", "--clearmodifiers", "Return")
    time.sleep(1)
    focus(swin)
    locate("Selection", stage + "-selected", roi=(200, 20, 800, 350))
    screen(stage + "-selected-metadata")


def clear_selection(swin, stage):
    focus(swin)
    click(locate("Edit", stage + "-edit-selection", roi=(200, 20, 800, 450)))
    # Normal Delete all center is visible in the retained 1000x700 selection
    # page. Gate the heading before clicking and the cleared state afterwards.
    locate("Selection", stage + "-selection-page", roi=(20, 20, 500, 100))
    screen(stage + "-delete-all-before")
    click((728, 111))
    locate("File", stage + "-cleared", roi=(200, 80, 780, 180))


def transfer(swin, rwin, dest, fixture, repeat, phase, expected, required):
    stage = f"repeat-{repeat}-{phase}"
    focus(swin)
    normalize(swin, stage + "-sender-normalized")
    screen(stage + "-before-send-selection")
    click(locate("Receiver", stage + "-target", 60))
    focus(rwin)
    normalize(rwin, stage + "-receiver-normalized")
    locate("Options", stage + "-approval", 30)
    screen(stage + "-approval-metadata")
    # Qualified2414 approval button position relative to actual client size.
    click((569, 650), rwin)
    end = time.monotonic() + 90
    saved = dest / fixture.name
    observed = []
    while time.monotonic() < end:
        words = screen(stage + "-outcome-" + str(len(observed)))
        labels = [word["text"] for word in words if word["text"]]
        observed.append({"monotonic": time.monotonic(), "labels": labels, "destination": digest(saved)})
        if any(label.lower() == "finished" for label in labels) and any(label.lower() == "done" for label in labels):
            break
        time.sleep(1)
    result = {"repeat": repeat, "phase": phase, "source": digest(fixture),
              "expected": expected, "destination": digest(saved), "observations": observed}
    result["content_valid"] = result["destination"].get("sha256") == expected["sha256"] and result["destination"].get("bytes") == expected["bytes"]
    result["terminal_observed"] = bool(observed and any(label.lower() == "finished" for label in observed[-1]["labels"]) and any(label.lower() == "done" for label in observed[-1]["labels"]))
    screen(stage + "-receiver-outcome")
    result["receiver_status_words"] = observed[-1]["labels"] if observed else []
    # Per-file Error has an adjacent ordinary info action. Anchor to its actual
    # rendered token, retain the modal details, then close before Done.
    if result["terminal_observed"]:
        rows = screen(stage + "-receiver-status")
        errors = [row for row in rows if row["text"].lower() == "error"]
        if errors:
            row = errors[0]
            click((row["left"] + row["width"] + 20, row["top"] + row["height"] // 2))
            detail_rows = screen(stage + "-receiver-error-details")
            result["receiver_error_detail_words"] = [row["text"] for row in detail_rows if row["text"]]
            closes = [row for row in detail_rows if row["text"].lower() == "close"]
            if closes:
                row = closes[0]
                click((row["left"] + row["width"] // 2, row["top"] + row["height"] // 2))
    focus(swin)
    result["sender_status_words"] = [row["text"] for row in screen(stage + "-sender-outcome") if row["text"]]
    RESULTS.append(result)
    (OUT / "results.json").write_text(json.dumps(RESULTS, indent=2))
    # Preserve partial or complete bytes before next send to avoid overwrite UI.
    archive = OUT / stage / "received"
    archive.mkdir(parents=True)
    for entry in dest.iterdir():
        shutil.move(str(entry), str(archive / entry.name))
    focus(rwin)
    click(locate("Done", stage + "-receiver-done", 15))
    focus(swin)
    # Multiple mode normally stays on send tab. If a session page is present,
    # Done returns normally; do not clear selection between first two sends.
    words = screen(stage + "-sender-return")
    done = [row for row in words if row["text"].lower() == "done"]
    close = [row for row in words if row["text"].lower() == "close"]
    action = done or close
    if action:
        row = action[0]
        click((row["left"] + row["width"] // 2, row["top"] + row["height"] // 2))
    locate("Selection", stage + "-sender-selection-retained", roi=(200, 20, 800, 350))
    if required and not result["content_valid"]:
        raise RuntimeError("Required real transfer control failed: " + stage)
    if not result["terminal_observed"]:
        raise RuntimeError("Unclassified transfer deadline: " + stage)
    return result


apps = []
try:
    dest = Path("/tmp/issue1054-received")
    dest.mkdir()
    for role in ("Receiver", "Sender"):
        bundle = Path("/tmp") / role
        shutil.copytree("released/base", bundle)
        # Exact c1ce storage schema3: quick_save is enum-name string, not the
        # bool accepted by the old1.17 harness. Pin current schema so migration
        # cannot silently replace off with paired; leave first-run generated
        # identity/security keys to the app.
        settings = {"flutter.ls_version": 3, "flutter.ls_alias": role, "flutter.ls_port": 53317,
                    "flutter.ls_locale": "en", "flutter.ls_destination": str(dest),
                    "flutter.ls_quick_save": "off", "flutter.ls_minimize_to_tray": False,
                    "flutter.ls_send_mode": "multiple", "flutter.ls_auto_finish": False}
        (bundle / "settings.json").write_text(json.dumps(settings))
        executable = str(bundle / "localsend_app")
        command = [executable]
        if role == "Receiver":
            command = ["sudo", "-E", "ip", "netns", "exec", "issue1054-receiver", "runuser", "-u",
                       pwd.getpwuid(os.getuid()).pw_name, "--preserve-environment", "--", "dbus-run-session", "--"] + command
        with (OUT / (role + ".log")).open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        time.sleep(1)
        pid = int(run("pgrep", "-f", "^" + executable + "$").split()[0])
        wid = window(pid)
        apps.append((process, wid, pid))
        focus(wid)
        normalize(wid, role + "-startup-normalized")
        # A fresh valid profile opens the ordinary release-notes page. Finish
        # it through its rendered Done control before checking the home alias.
        startup = screen(role + "-startup")
        if any(row["text"].lower() == "new" for row in startup):
            # This ordinary button center is established by retained startup
            # pixels at the asserted 1000x700 geometry. OCR omits its white
            # label even in a cropped contrast pass; gate the resulting home.
            screen(role + "-onboarding-before-click")
            click((740, 278))
            screen(role + "-onboarding-after-click")
        locate(role, role + "-ready", 30)
        normalize(wid, role + "-ready-normalized")
        (OUT / (role + "-process.json")).write_text(json.dumps({"pid": pid, "exe": os.readlink(f"/proc/{pid}/exe"), "settings": settings}))
    rwin, swin = apps[0][1], apps[1][1]
    for repeat in (1, 2):
        fixture = Path.home() / f"Probe1054Repeat{repeat}.bin"
        initial = overwrite(fixture, 11_000_000, 1)
        select_file(swin, fixture, f"repeat-{repeat}-initial-picker")
        transfer(swin, rwin, dest, fixture, repeat, "initial11MB", initial, True)
        focus(swin)
        locate("Selection", f"repeat-{repeat}-retained-selection", roi=(200, 20, 800, 350))
        updated = overwrite(fixture, 14_000_000, 2)
        (OUT / f"repeat-{repeat}-ordinary-overwrite.json").write_text(json.dumps({"before": initial, "after": updated, "same_path": True}, indent=2))
        screen(f"repeat-{repeat}-stale-selection-after-edit")
        transfer(swin, rwin, dest, fixture, repeat, "edited14MB-without-reselection", updated, False)
        clear_selection(swin, f"repeat-{repeat}-clear")
        select_file(swin, fixture, f"repeat-{repeat}-reselection-picker")
        transfer(swin, rwin, dest, fixture, repeat, "edited14MB-reselected", updated, True)
        if repeat == 1:
            clear_selection(swin, "repeat-1-final-clear")
    (OUT / "completed").write_text("Both initial and reselected controls passed; inspect middle outcomes.\n")
except Exception as error:
    (OUT / "harness-error.json").write_text(json.dumps({"error": str(error), "results": RESULTS}, indent=2))
    screen("failure")
    raise
finally:
    for process, wid, pid in apps:
        subprocess.run(["kill", str(pid)], check=False)
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
