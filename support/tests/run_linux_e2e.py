#!/usr/bin/env python3
# Run Linux E2E scenarios against one release bundle in the active KDE and D-Bus session.

"""Manual Linux release test runner using pytest."""

import argparse
import json
from pathlib import Path
import sys


class Results:
    def __init__(self, report):
        self.report = report

    def pytest_runtest_logreport(self, report):
        self.report["tests"].append({
            "name": report.nodeid,
            "phase": report.when,
            "outcome": report.outcome,
            "duration_seconds": round(report.duration, 3),
            **({"error": str(report.longrepr)} if report.failed else {}),
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="app/build/linux/<arch>/release/bundle")
    parser.add_argument("--output", type=Path, default=Path("linux-e2e-results"))
    parser.add_argument("--packaging", choices=["all", "native", "flatpak"], default="all")
    parser.add_argument("--filter", default="", help="pytest -k expression; empty runs the whole suite")
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"bundle": str(bundle), "tests": [], "passed": False}
    code = 1
    try:
        if not (bundle / "localsend_app").is_file():
            raise RuntimeError(f"Release bundle has no LocalSend executable: {bundle}")
        import pytest
        code = int(pytest.main([
            str(Path(__file__).parent / "linux_e2e"),
            "--rootdir", str(Path(__file__).parent),
            "-o", f"cache_dir={output / 'pytest-cache'}",
            "--bundle", str(bundle), "--evidence", str(output),
            "--packaging", args.packaging, "-k", args.filter,
            "--junitxml", str(output / "junit.xml"), "-v", "--tb=short",
        ], plugins=[Results(report)]))
        report["passed"] = code == 0 and any(test["phase"] == "call" for test in report["tests"])
        if code == 0 and not report["passed"]:
            code = 1
    except (ImportError, RuntimeError) as error:
        report["error"] = str(error)
        print(f"FAIL infrastructure: {error}", file=sys.stderr)
    finally:
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    sys.exit(main())
