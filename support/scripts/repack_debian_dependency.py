#!/usr/bin/env python3
"""Apply the PR's Debian runtime dependency to a released package's control file."""

import argparse
import hashlib
import io
import os
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path


OLD_DEPENDENCY = "libappindicator3-1 | libayatana-appindicator3-1"
NEW_DEPENDENCY = "libayatana-appindicator3-1"


def run(*args: str) -> bytes:
    return subprocess.run(args, check=True, stdout=subprocess.PIPE).stdout


def payload_manifest(package: Path) -> dict[str, tuple]:
    """Record installed paths and contents, independent of tar member ordering."""
    archive = run("dpkg-deb", "--fsys-tarfile", str(package))
    manifest = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        for member in tar:
            content_hash = hashlib.sha256(tar.extractfile(member).read()).hexdigest() if member.isfile() else None
            name = member.name.removeprefix("./")
            if name in manifest:
                raise ValueError(f"Duplicate data member: {name}")
            manifest[name] = (
                member.type,
                member.mode,
                member.uid,
                member.gid,
                member.mtime,
                member.size,
                member.linkname,
                content_hash,
            )
    return manifest


def validate_pr_config(config: Path) -> None:
    text = config.read_text()
    match = re.search(r"(?ms)^dependencies:\s*\n(?P<items>(?:^[ \t]+- .*\n)+)", text)
    if match is None:
        raise ValueError("PR packaging config has no dependencies list")
    items = re.findall(r"^[ \t]+- (.+)$", match.group("items"), re.MULTILINE)
    runtime = [item.strip() for item in items if "appindicator3-1" in item]
    if runtime != [NEW_DEPENDENCY]:
        raise ValueError(f"PR config must require only {NEW_DEPENDENCY}; found {runtime!r}")
    if OLD_DEPENDENCY in text:
        raise ValueError("PR config still contains the legacy runtime alternative")
    print(f"PR packaging dependency: {NEW_DEPENDENCY}")


def repack(original: Path, output: Path) -> None:
    if original.resolve() == output.resolve():
        raise ValueError("Input and output packages must differ")
    original_manifest = payload_manifest(original)
    if not original_manifest or any(entry[2:4] != (0, 0) for entry in original_manifest.values()):
        raise ValueError("Released package has empty or non-root-owned data; --root-owner-group would change it")
    original_fields = run("dpkg-deb", "--field", str(original))

    with tempfile.TemporaryDirectory(prefix="localsend-deb-repack-") as temporary:
        extracted = Path(temporary) / "package"
        subprocess.run(["dpkg-deb", "--raw-extract", str(original), str(extracted)], check=True)
        control = extracted / "DEBIAN" / "control"
        source = control.read_bytes()
        depends = re.search(rb"(?m)^Depends: ([^\n]*(?:\n [^\n]*)*)", source)
        if depends is None:
            raise ValueError("Released package lacks a Depends field")
        old = OLD_DEPENDENCY.encode()
        if depends.group(1).count(old) != 1:
            raise ValueError("Released package must declare the expected runtime alternative exactly once")
        patched_depends = depends.group(1).replace(old, NEW_DEPENDENCY.encode())
        patched = source[: depends.start(1)] + patched_depends + source[depends.end(1) :]
        control.write_bytes(patched)
        root = original_manifest.get("") or original_manifest.get(".")
        if root is not None:
            os.utime(extracted, (root[4], root[4]))
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(extracted), str(output)], check=True)

    if payload_manifest(output) != original_manifest:
        raise ValueError("Repacked package changed installed data or executable payload")
    observed_fields = run("dpkg-deb", "--field", str(output))
    if original_fields.count(OLD_DEPENDENCY.encode()) != 1 or observed_fields != original_fields.replace(
        OLD_DEPENDENCY.encode(), NEW_DEPENDENCY.encode()
    ):
        raise ValueError("Repacked control fields differ beyond the intended Depends replacement")
    observed = run("dpkg-deb", "--field", str(output), "Depends").decode().strip()
    print("Installed payload verified identical; only Debian control Depends was edited.")
    print(f"Repacked Depends: {observed}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("pr_config", type=Path)
    arguments = parser.parse_args()
    validate_pr_config(arguments.pr_config)
    repack(arguments.original, arguments.output)


if __name__ == "__main__":
    main()
