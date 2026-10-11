"""Retain continuous real-screen case excerpts after cloud Mint UI timing finishes."""
import hashlib
import json
import os
import pathlib
import subprocess
import time


def main():
    # Do not perform local media workloads or query an application from this helper.
    here = pathlib.Path(__file__).resolve()
    if (os.environ.get("PROBE_CLOUD_RECORDING") != "1"
            or here != pathlib.Path("/home/mint/support/diagnostics/2754-recording-clips.py")
            or os.uname().sysname != "Linux"
            or os.environ.get("USER") != "mint"
            or not pathlib.Path("/home/mint/evidence/bootstrap-complete").is_file()
            or "ID=linuxmint" not in pathlib.Path("/etc/os-release").read_text().splitlines()):
        raise RuntimeError("Requires the authorized staged Mint cloud recording phase")
    evidence = pathlib.Path("/home/mint/evidence")
    dest = evidence / "recording-clips"
    dest.mkdir(exist_ok=True)
    source = evidence / "scenario.mp4"
    expected_cases = ("keyboard-off", "keyboard-on", "keyboard-on-repeat", "keyboard-off-again", "keyboard-on-stack")
    manifest = {
        "source": str(source), "created_wall": time.time(),
        "bridge_variant": os.environ.get("PROBE_BRIDGE_VARIANT"),
        "engine_variant": os.environ.get("PROBE_ENGINE_VARIANT"),
        "capture": "continuous X11 x11grab; real pointer enabled; 10 fps; no inserted frames",
        "input_evidence": "events.json contains actual click coordinates and wall/monotonic timestamps",
        "overlays": "none; no cursor, click, ripple, or keyboard input is fabricated from event logs",
        "timing": "source retains wall-clock PTS; excerpts subtract one constant PTS offset only",
        "expected_cases": list(expected_cases), "clips": [], "status": "incomplete",
    }

    def save():
        retained = {item["case"] for item in manifest["clips"] if item["status"] == "retained"}
        manifest["missing_verified_clips"] = [case for case in expected_cases if case not in retained]
        (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def sha256(path):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()

    def probe(path, output):
        command = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
                   "-show_streams", "-show_format", "-show_entries",
                   "packet=pts_time,duration_time:stream=codec_name,time_base,width,height,r_frame_rate:format=start_time,duration",
                   "-of", "json", str(path)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        output.write_text(result.stdout)
        output.with_suffix(".stderr").write_text(result.stderr)
        result.check_returncode()
        data = json.loads(result.stdout)
        pts = [float(packet["pts_time"]) for packet in data["packets"] if "pts_time" in packet]
        if len(pts) < 2 or any(b <= a for a, b in zip(pts, pts[1:])):
            raise RuntimeError("Missing or non-monotonic source/frame PTS: " + str(path))
        return data, pts

    save()
    try:
        events = json.loads((evidence / "events.json").read_text())
        observed_cases = [item.get("case") for item in events if item.get("name") == "text-open"]
        manifest["observed_cases"] = observed_cases
        manifest["missing_case_events"] = [case for case in expected_cases if case not in observed_cases]
        save()
        manifest["source_sha256"] = sha256(source)
        source_data, source_pts = probe(source, dest / "source-pts.json")
        # Fail closed if the muxer discarded epoch alignment. Invocation time is
        # not substituted for the actual first captured frame timestamp.
        if source_pts[0] < 1_000_000_000 or source_pts[-1] > time.time() + 60:
            raise RuntimeError("Source PTS are not preserved wall-clock timestamps")
        manifest["source_first_pts_wall"] = source_pts[0]
        manifest["source_last_pts_wall"] = source_pts[-1]
        manifest["source_streams"] = source_data.get("streams")
        manifest["provenance_files"] = {}
        for name in ("events.json", "environment.txt", "session-environment.txt", "recording-source.txt",
                     "recording-staged-source.sha256", "recording-command-args.txt",
                     "recording-ui-status.txt", "recording-exit-status.txt",
                     "recording-ffmpeg-version.txt", "bridge-variant.txt", "engine-selection.txt",
                     "bridge-process-library.sha256", "engine-loaded/loaded-artifact-SHA256SUMS",
                     "source-artifact/provenance/manifest.json"):
            path = evidence / name
            if path.is_file():
                manifest["provenance_files"][name] = sha256(path)
        for index, event in enumerate(events):
            if event.get("name") != "text-open" or event.get("case") == "geometry-post-timing":
                continue
            case = event["case"]
            if case not in expected_cases or observed_cases.count(case) != 1:
                raise RuntimeError("Unexpected or duplicate original case: " + str(case))
            click = next((item for item in reversed(events[:index])
                          if item.get("name") == "click" and item.get("label") == "Text"), None)
            if click is None or not 0 <= event["wall"] - click["wall"] < 2:
                raise RuntimeError("Text case lacks a matching original click: " + case)
            # Keep 0.75s of real source before the trigger. A baseline on-case
            # retains 35s to include the observed ~25s delay without a cut.
            # A candidate name does not establish a fast result; retain the
            # same 35s on-window until a reviewer can inspect actual behavior.
            seconds = 10 if "keyboard-off" in case else 35
            start = click["wall"] - 0.75
            end = start + seconds
            item = {"case": case, "trigger": click, "text_open": event,
                    "requested_source_wall_interval": [start, end], "duration_seconds": seconds,
                    "status": "incomplete"}
            manifest["clips"].append(item)
            save()
            if start < source_pts[0] or end > source_pts[-1]:
                raise RuntimeError("Source does not cover the full requested interval: " + case)
            output = dest / (case + ".mp4")
            command = ["ffmpeg", "-nostdin", "-y", "-copyts", "-seek_timestamp", "1", "-ss", f"{start:.6f}",
                       "-i", str(source), "-t", str(seconds), "-map", "0:v:0", "-an",
                       "-vf", "setpts=PTS-STARTPTS", "-vsync", "0", "-c:v", "libx264",
                       "-preset", "ultrafast", "-crf", "25", "-movflags", "+faststart", str(output)]
            item["command"] = command
            result = subprocess.run(command, capture_output=True, text=True, timeout=180)
            (dest / (case + "-encode.log")).write_text(result.stdout + result.stderr)
            item["encode_returncode"] = result.returncode
            result.check_returncode()
            _, clip_pts = probe(output, dest / (case + "-pts.json"))
            expected = [pts for pts in source_pts if start <= pts < end]
            if (len(clip_pts) != len(expected) or len(expected) < seconds * 8
                    or any(abs((pts - clip_pts[0]) - (original - expected[0])) > 0.002
                           for pts, original in zip(clip_pts, expected))):
                raise RuntimeError("Excerpt frame timing/count differs from continuous source: " + case)
            item.update(status="retained", file=output.name, sha256=sha256(output),
                        observed_source_wall_interval=[expected[0], expected[-1]],
                        frame_count=len(clip_pts), first_output_pts=clip_pts[0], last_output_pts=clip_pts[-1],
                        continuous_source_timing_verified=True)
            save()
        if manifest["missing_verified_clips"] or manifest["missing_case_events"]:
            raise RuntimeError("Incomplete original timed Text recordings: " + ", ".join(manifest["missing_verified_clips"]))
        manifest["status"] = "retained"
        save()
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = type(error).__name__ + ": " + str(error)
        save()
        raise


if __name__ == "__main__":
    main()
