#!/usr/bin/env python3
"""Compiler/dependency compatibility for v1.17 on newer Flutter SDKs.

This is diagnostic-only. It deliberately does not change startup or network code.
The --drop-dev fallback is used only after pub get fails on obsolete analyzer
or macro dependencies; generated app/common code is already tracked in v1.17.
"""

import argparse
from pathlib import Path


def replace_once(path, old, new):
    source = path.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
    path.write_text(source.replace(old, new, 1))
    print(f"{path}: {old.strip()} -> {new.strip()}")


def drop_dev_dependencies(path):
    source = path.read_text()
    lines = source.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.startswith("dev_dependencies:\n")), None)
    if start is None:
        raise SystemExit(f"{path}: no dev_dependencies section")
    end = next((i for i in range(start + 1, len(lines)) if lines[i] and not lines[i][0].isspace() and lines[i].strip()), len(lines))
    path.write_text("".join(lines[:start] + lines[end:]))
    print(f"{path}: removed dev_dependencies block only")


parser = argparse.ArgumentParser()
parser.add_argument("--drop-dev", action="store_true", help="fallback after obsolete analyzer/macro pub resolution failure")
args = parser.parse_args()

app = Path("app/pubspec.yaml")
if args.drop_dev:
    for path in (app, Path("common/pubspec.yaml")):
        drop_dev_dependencies(path)
else:
    replace_once(app, "  intl: ^0.19.0 # allow newer versions, so it can compile with newer Flutter versions\n",
                 "  intl: ^0.20.2 # diagnostic SDK compatibility\n")
    replace_once(app, "  path: 1.9.0\n", "  path: 1.9.1\n")
