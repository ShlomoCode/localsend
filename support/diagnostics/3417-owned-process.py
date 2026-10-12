"""Cloud-only identity capture and pidfd cleanup for this diagnostic's processes."""
import base64
import json
import os
import pathlib
import select
import signal
import stat
import sys
import time

VM = pathlib.Path("/home/runner/3417-vm")
ROLES = {
    "qemu": {"qemu-system-x86_64"},
    "xvfb": {"Xvfb"},
    "viewer": {"vncviewer", "tigervncviewer", "xtigervncviewer"},
}


def identity(pid):
    proc = pathlib.Path("/proc") / str(pid)
    value = (proc / "stat").read_text()
    # The comm field can contain spaces/parentheses; use its final delimiter.
    tail = value.rpartition(") ")[2].split()
    if len(tail) < 20:
        raise ValueError("Invalid process stat")
    uid_line = next(line for line in (proc / "status").read_text().splitlines()
                    if line.startswith("Uid:"))
    uids = [int(part) for part in uid_line.split()[1:]]
    return {"pid": pid, "startTicks": int(tail[19]), "uids": uids,
            "exe": os.readlink(proc / "exe"),
            "argvBase64": base64.b64encode((proc / "cmdline").read_bytes()).decode("ascii")}


def admissible(value, role, expected_exe, expected_uid, owned_arg):
    if pathlib.Path(expected_exe).name not in ROLES[role]:
        raise ValueError("Unexpected role executable")
    if value["exe"] != expected_exe or value["uids"] != [expected_uid] * 4:
        raise ValueError("Executable or ownership mismatch")
    argv = base64.b64decode(value["argvBase64"], validate=True).split(b"\0")
    if owned_arg.encode() not in argv:
        raise ValueError("Exact owned argument absent")
    if role == "qemu" and owned_arg != f"file={VM}/ubuntu-24.04-server-cloudimg-amd64.img,if=virtio,format=qcow2":
        raise ValueError("Unexpected diagnostic image argument")
    if role == "xvfb" and owned_arg != ":99":
        raise ValueError("Unexpected diagnostic display")
    if role == "viewer" and owned_arg != "127.0.0.1:5901":
        raise ValueError("Unexpected diagnostic viewer endpoint")


def identity_or_exited(fd, pid, role, receipt):
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    if poller.poll(0):
        print(json.dumps({"role": role, "result": "Captured process already exited", "receipt": receipt}))
        sys.exit(0)
    try:
        return identity(pid)
    except FileNotFoundError:
        # Only the same pidfd's exit indication permits the benign result.
        if poller.poll(0):
            print(json.dumps({"role": role, "result": "Captured process already exited", "receipt": receipt}))
            sys.exit(0)
        raise


mode, role, *args = sys.argv[1:]
if role not in ROLES or os.geteuid() != 0:
    raise ValueError("Root identity inspection and known role required")
record_path = VM / f"{role}-identity.json"
if mode == "record":
    pid_path, expected_exe, uid_text, owned_arg = args
    expected_uid = int(uid_text)
    path = pathlib.Path(pid_path)
    info = path.lstat()
    if path != VM / f"{role}.pid" or not stat.S_ISREG(info.st_mode) or info.st_size > 64:
        raise ValueError("Invalid owned PID file")
    if info.st_uid != expected_uid:
        raise ValueError("PID file owner mismatch")
    text = path.read_text().strip()
    if not text.isdecimal() or int(text) <= 1:
        raise ValueError("Invalid owned PID")
    pid = int(text)
    fd = os.pidfd_open(pid, 0)
    try:
        value = identity(pid)
        admissible(value, role, os.path.realpath(expected_exe), expected_uid, owned_arg)
        receipt = {"role": role, "capturedUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "expectedUid": expected_uid, "expectedExe": os.path.realpath(expected_exe),
                   "ownedArg": owned_arg, "identity": value}
        temporary = record_path.with_suffix(".partial")
        with temporary.open("x") as output:
            json.dump(receipt, output, indent=2)
        temporary.chmod(0o600)
        os.replace(temporary, record_path)
        print(json.dumps(receipt))
    finally:
        os.close(fd)
elif mode == "cleanup":
    if args:
        raise ValueError("Unexpected cleanup arguments")
    if not record_path.exists():
        print(json.dumps({"role": role, "result": "No captured identity; no signal sent"}))
        sys.exit(0)
    info = record_path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError("Untrusted identity receipt ownership")
    receipt = json.loads(record_path.read_text())
    if receipt["role"] != role:
        raise ValueError("Identity role mismatch")
    expected = receipt["identity"]
    try:
        fd = os.pidfd_open(expected["pid"], 0)
    except ProcessLookupError:
        print(json.dumps({"role": role, "result": "Captured process already exited", "receipt": receipt}))
        sys.exit(0)
    try:
        current = identity_or_exited(fd, expected["pid"], role, receipt)
        admissible(current, role, receipt["expectedExe"], receipt["expectedUid"], receipt["ownedArg"])
        if current != expected:
            raise ValueError("PID/start/executable/ownership/argv identity changed; no signal sent")
        print(json.dumps({"role": role, "beforeSignal": current}), flush=True)
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except ProcessLookupError:
            identity_or_exited(fd, expected["pid"], role, receipt)
            raise
        actions = ["SIGTERM through verified pidfd"]
        if not poller.poll(10000):
            # A pidfd cannot target a reused numeric PID. Recheck identity too.
            if identity_or_exited(fd, expected["pid"], role, receipt) != expected:
                raise ValueError("Identity changed after TERM; no further signal")
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                identity_or_exited(fd, expected["pid"], role, receipt)
                raise
            actions.append("SIGKILL through same verified pidfd")
            if not poller.poll(5000):
                raise TimeoutError("Owned process did not report exit")
        print(json.dumps({"role": role, "result": "Owned process exited", "actions": actions}), flush=True)
    finally:
        os.close(fd)
else:
    raise ValueError("Unknown identity mode")
