"""Cloud-guest cache admission; verifies bytes again before normal APT install."""
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


manifest_name, archive_name, expected_manifest_hash, expected_archive_hash = sys.argv[1:]
if os.geteuid() != 0:
    raise ValueError("Root cache admission required")
manifest_path = pathlib.Path(manifest_name)
archive_path = pathlib.Path(archive_name)
for path, expected in ((manifest_path, expected_manifest_hash), (archive_path, expected_archive_hash)):
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or digest(path) != expected:
        raise ValueError(f"Transferred input SHA256 mismatch: {path.name}")
manifest = json.loads(manifest_path.read_text())
files = {}
for item in manifest["files"]:
    filename, sha256, size = item["filename"], item["sha256"], item["size"]
    if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_%:~-]*\.deb", filename):
        raise ValueError("Unsafe APT cache filename")
    if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("Invalid package SHA256")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0 or filename in files:
        raise ValueError("Invalid package size or duplicate cache filename")
    files[filename] = item
cache = pathlib.Path("/var/cache/apt/archives")
if not cache.is_dir() or cache.is_symlink():
    raise ValueError("Normal APT cache directory unavailable")
stage = pathlib.Path(tempfile.mkdtemp(prefix="3417-verified-", dir=cache))
receipts = []
try:
    with tarfile.open(archive_path, "r:") as bundle:
        members = bundle.getmembers()
        if len(members) != len(files) or {member.name for member in members} != set(files):
            raise ValueError("Cache archive contains missing, extra or duplicate members")
        for member in members:
            expected = files[member.name]
            if not member.isfile() or member.size != expected["size"]:
                raise ValueError("Non-regular member or size mismatch")
            target = stage / member.name
            source = bundle.extractfile(member)
            if source is None:
                raise ValueError("Package member unavailable")
            with source, target.open("xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            # Do not assume APT rehashes already filled final cache entries.
            observed_size, observed_hash = target.stat().st_size, digest(target)
            if observed_size != expected["size"] or observed_hash != expected["sha256"]:
                raise ValueError(f"Guest package integrity mismatch: {member.name}")
            target.chmod(0o644)
            os.replace(target, cache / member.name)
            receipts.append({"filename": member.name, "size": observed_size,
                             "sha256": observed_hash, "result": "Guest rehashed; atomically promoted"})
            print(json.dumps(receipts[-1]), flush=True)
    print(json.dumps({"manifestSha256": expected_manifest_hash, "archiveSha256": expected_archive_hash,
                      "files": receipts}, indent=2), flush=True)
finally:
    shutil.rmtree(stage)
