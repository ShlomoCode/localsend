#!/usr/bin/env python3
"""Add dependencies for every bundled ELF binary to a distributor-built deb."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def update_dependencies(package):
    package = package.resolve()
    with tempfile.TemporaryDirectory(prefix="localsend-deb-") as temporary:
        work = Path(temporary)
        # The conventional debian/<package> layout lets dpkg-shlibdeps recognize
        # private libraries in the same package without ignoring missing metadata.
        name = subprocess.check_output(["dpkg-deb", "--field", str(package), "Package"], text=True).strip()
        root = work / "debian" / name
        root.parent.mkdir()
        subprocess.run(["dpkg-deb", "--raw-extract", str(package), str(root)], check=True)
        control = root / "DEBIAN" / "control"
        original = control.read_text()
        (work / "debian" / "control").write_text(f"Source: {name}\n\n{original}")

        binaries = []
        for path in sorted(root.rglob("*")):
            if path.is_file() and not path.is_symlink():
                with path.open("rb") as file:
                    if file.read(4) == b"\x7fELF":
                        binaries.append(path)
        if not binaries:
            raise RuntimeError(f"No ELF binaries found in {package}")

        command = ["dpkg-shlibdeps", "-O", f"-S{root}"]
        command += [f"-l{directory}" for directory in sorted({path.parent for path in binaries})]
        command += [f"-e{path}" for path in binaries]
        output = subprocess.check_output(command, cwd=work, text=True)
        generated = next(line.removeprefix("shlibs:Depends=") for line in output.splitlines() if line.startswith("shlibs:Depends="))
        if not generated:
            raise RuntimeError(f"No shared-library dependencies found in {package}")

        # Distributor emits each field on one line. Retain explicit dependencies
        # for tools and libraries loaded dynamically rather than linked by ELF.
        lines = original.splitlines()
        for index, line in enumerate(lines):
            if line.startswith("Depends:"):
                explicit = line.removeprefix("Depends:").strip()
                lines[index] = f"Depends: {explicit}, {generated}" if explicit else f"Depends: {generated}"
                break
        else:
            lines.append(f"Depends: {generated}")
        control.write_text("\n".join(lines) + "\n")

        # Keep the original artifact intact if scanning or rebuilding fails.
        with tempfile.TemporaryDirectory(prefix=".localsend-deb-", dir=package.parent) as output_directory:
            rebuilt = Path(output_directory) / package.name
            subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(root), str(rebuilt)], check=True)
            os.replace(rebuilt, package)
        print(f"{package.name}: {generated}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    update_dependencies(parser.parse_args().package)
