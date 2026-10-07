#!/usr/bin/env python3
# Run every Linux E2E test against one release bundle in the active KDE and D-Bus session.

"""Manual Linux release test runner."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="app/build/linux/<arch>/release/bundle")
    parser.add_argument("--output", type=Path, default=Path("linux-e2e-results"))
    args = parser.parse_args()

    bundle = args.bundle.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    tests = sorted(Path(__file__).parent.glob("linux_*_e2e.py"))
    report = {"bundle": str(bundle), "tests": []}

    if not (bundle / "localsend_app").is_file():
        print(f"FAIL: release bundle has no LocalSend executable: {bundle}", file=sys.stderr)
        report["error"] = "missing release bundle"
    elif not tests:
        print("FAIL: no Linux E2E tests found", file=sys.stderr)
        report["error"] = "no tests found"
    else:
        for test in tests:
            name = test.stem
            stdout_path = output / f"{name}.stdout.log"
            app_log_path = output / f"{name}.app.log"
            print(f"RUN {name}", flush=True)
            started = time.monotonic()
            try:
                with stdout_path.open("w", encoding="utf-8") as stdout:
                    result = subprocess.run(
                        [sys.executable, str(test), str(bundle), "--log", str(app_log_path)],
                        stdout=stdout,
                        stderr=subprocess.STDOUT,
                        check=False,
                    )
                code = result.returncode
                error = None
            except OSError as exc:
                code = 2
                error = str(exc)
                stdout_path.write_text(f"FAIL infrastructure: {exc}\n", encoding="utf-8")
            elapsed = round(time.monotonic() - started, 2)
            report["tests"].append({
                "name": name,
                "exit_code": code,
                "duration_seconds": elapsed,
                "stdout_log": stdout_path.name,
                "app_log": app_log_path.name,
                **({"error": error} if error else {}),
            })
            print(f"{'PASS' if code == 0 else 'FAIL'} {name} (exit {code}, {elapsed}s)", flush=True)

    passed = bool(report["tests"]) and "error" not in report and all(test["exit_code"] == 0 for test in report["tests"])
    report["passed"] = passed
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
