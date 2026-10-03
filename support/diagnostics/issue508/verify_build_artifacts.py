#!/usr/bin/env python3
"""Verify downloaded diagnostic binaries match the recorded build run."""

import argparse
import hashlib
import json
import shutil
from pathlib import Path


def one(root, name):
    found = list(root.rglob(name))
    if len(found) != 1:
        raise RuntimeError(f"Expected exactly one {name} under {root}, found {found}")
    return found[0]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--built", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--fix-sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    built = args.built.resolve()
    evidence = args.evidence.resolve()
    commits = dict(line.split("=", 1) for line in one(evidence, "source-commits.txt").read_text().splitlines())
    if commits != {"base": args.base_sha, "fix": args.fix_sha}:
        raise RuntimeError(f"Source commits did not match requested comparison: {commits}")
    results = {"build_run_id": args.run_id, "source_commits": commits, "binaries": {}}
    for label in ("baseline", "candidate"):
        path = one(built, f"{label}.AppImage")
        expected = one(evidence, f"{label}.sha256").read_text().split()[0]
        actual = sha256(path)
        if expected != actual:
            raise RuntimeError(f"{label} AppImage hash differs from build run: {actual} != {expected}")
        destination = built / f"{label}.AppImage"
        if path != destination:
            shutil.copy2(path, destination)
        destination.chmod(0o755)
        results["binaries"][label] = {"sha256": actual, "size": destination.stat().st_size}
    bundle = one(built, "candidate-bundle")
    if not bundle.is_dir() or not (bundle / "localsend_app").exists():
        raise RuntimeError("Candidate bundle is incomplete")
    destination = built / "candidate-bundle"
    if bundle != destination:
        shutil.copytree(bundle, destination)
    (destination / "localsend_app").chmod(0o755)
    results["bundle_path"] = str(destination)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
