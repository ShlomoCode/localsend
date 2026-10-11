"""Guest desktop/process helper; never sends protocol requests."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path("/home/probe")
OUT = ROOT / "evidence"
OUT.mkdir(exist_ok=True)
STATE = OUT / "receiver-state.json"
CONTENT = b"LocalSend issue 2414 fixed ordinary file content\n"


def command(*argv):
    return subprocess.check_output(argv, text=True, timeout=15).strip()


def monitor(pid, count):
    with (OUT / f"files-{count}-metrics.jsonl").open("w") as output:
        while Path(f"/proc/{pid}").exists():
            sample = {"guest_monotonic": time.monotonic(), "utc_ns": time.time_ns(), "clock_ticks_per_second": os.sysconf("SC_CLK_TCK")}
            for field, path in [("status", f"/proc/{pid}/status"), ("stat", f"/proc/{pid}/stat"),
                                ("pss", f"/proc/{pid}/smaps_rollup"), ("meminfo", "/proc/meminfo")]:
                try:
                    sample[field] = Path(path).read_text()
                except OSError as error:
                    sample[field] = str(error)
            output.write(json.dumps(sample) + "\n")
            output.flush()
            time.sleep(.5)


def main():
    action = sys.argv[1]
    if action == "monitor":
        monitor(int(sys.argv[2]), int(sys.argv[3]))
        return
    if action == "start":
        count = int(sys.argv[2])
        bundle = ROOT / f"receiver-{count}"
        shutil.copytree(ROOT / "released/base", bundle)
        destination = ROOT / f"received-{count}"
        destination.mkdir()
        (bundle / "settings.json").write_text(json.dumps({
            "flutter.ls_alias": "Receiver2414", "flutter.ls_port": 53317,
            "flutter.ls_locale": "en", "flutter.ls_destination": str(destination),
            "flutter.ls_quick_save": False, "flutter.ls_minimize_to_tray": False,
        }))
        with (OUT / f"files-{count}-receiver.log").open("w") as log:
            process = subprocess.Popen([str(bundle / "localsend_app")], stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        state = {"pid": process.pid, "count": count, "destination": str(destination)}
        STATE.write_text(json.dumps(state))
        with (OUT / f"files-{count}-monitor.log").open("w") as log:
            sampler = subprocess.Popen([sys.executable, __file__, "monitor", str(process.pid), str(count)],
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state["sampler_pid"] = sampler.pid
        STATE.write_text(json.dumps(state))
        end = time.monotonic() + 30
        while time.monotonic() < end:
            try:
                for window in command("xdotool", "search", "--onlyvisible", "--pid", str(process.pid)).split():
                    if command("xdotool", "getwindowname", window) == "LocalSend":
                        command("xdotool", "windowmove", window, "0", "0")
                        command("xdotool", "windowsize", window, "1000", "700")
                        state["window"] = window
                        STATE.write_text(json.dumps(state))
                        print(json.dumps(state))
                        return
            except subprocess.CalledProcessError:
                pass
            time.sleep(1)
        raise RuntimeError("Receiver window missing (infrastructure)")
    state = json.loads(STATE.read_text())
    if action == "desktop":
        # SSH receives quoted argv; no UI label or OCR text becomes shell code.
        argv = sys.argv[2:]
        with (OUT / ("files-%s-input.jsonl" % state["count"])).open("a") as log:
            log.write(json.dumps({"guest_monotonic": time.monotonic(), "utc_ns": time.time_ns(), "argv": argv}) + "\n")
        started = time.monotonic()
        result = command(*argv)
        print(json.dumps({"output": result, "started": started, "completed": time.monotonic()}))
    elif action == "verify":
        files = list(Path(state["destination"]).rglob("*"))
        files = [file for file in files if file.is_file()]
        expected = {f"file-{index:05d}.txt" for index in range(state["count"])}
        print(json.dumps({"saved_files": len(files), "content_valid":
                          len(files) == state["count"] and {file.name for file in files} == expected
                          and all(file.read_bytes() == CONTENT for file in files)}))
    elif action == "stop":
        for key in ("pid", "sampler_pid"):
            try:
                os.kill(state[key], 15)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 10
        while Path(f"/proc/{state['pid']}").exists() and time.monotonic() < deadline:
            time.sleep(.2)
        try:
            os.kill(state["pid"], 9)
        except ProcessLookupError:
            pass
        print(json.dumps({"stopped": True}))
    else:
        raise ValueError(action)


if __name__ == "__main__":
    main()
