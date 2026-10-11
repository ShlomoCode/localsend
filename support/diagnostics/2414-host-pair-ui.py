"""Real host sender and SSH-controlled guest receiver; cloud execution only."""
import csv
import io
import json
import os
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
        for key in ("left", "top", "width", "height"):
            word[key] = int(word[key]) // 2
    return words, timing


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
        screen("guest", case + "-options-visible")
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
