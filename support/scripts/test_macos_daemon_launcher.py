#!/usr/bin/env python3
"""Exercise native socket recovery and shutdown against real Unix sockets."""
import json
import pathlib
import select
import socket
import subprocess
import tempfile
import threading

repo = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="lsd-test-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    executable = directory / "native-ipc-test"
    subprocess.run([
        "xcrun", "swiftc", str(repo / "app/macos/Launcher/DaemonIPC.swift"),
        str(repo / "app/macos/Launcher/Tests/main.swift"),
        "-module-cache-path", str(directory / "modules"), "-o", str(executable),
    ], check=True)
    path = directory / "ipc.sock"

    def run(command, succeeds):
        result = subprocess.run([str(executable), command, str(path)], capture_output=True, timeout=8)
        assert (result.returncode == 0) == succeeds, result.stderr.decode()

    path.write_text("must survive socket recovery")
    run("recover", False)
    assert path.read_text() == "must survive socket recovery"
    path.unlink()

    stale = socket.socket(socket.AF_UNIX)
    stale.bind(str(path))
    stale.close()
    run("recover", True)
    assert not path.exists()

    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    server.listen()
    run("recover", False)
    assert path.exists()
    # Recovery's connection probe leaves one connection in the accept queue.
    probe, _ = server.accept()
    probe.close()

    release_shutdown = threading.Event()
    shutdown_sent = threading.Event()

    def reply(valid, keep_open=False):
        connection, _ = server.accept()
        with connection:
            request = json.loads(connection.makefile("rb").readline())
            response = {"version": 1, "id": request["id"] if valid else "wrong-id", "ok": True}
            encoded = json.dumps(response).encode() + b"\n"
            connection.sendall(encoded[:5])
            connection.sendall(encoded[5:])
            shutdown_sent.set()
            if keep_open:
                release_shutdown.wait(timeout=5)

    for valid in (False, True):
        responder = threading.Thread(target=reply, args=(valid,))
        responder.start()
        run("shutdown", valid)
        responder.join(timeout=2)
        assert not responder.is_alive()

    shutdown_sent.clear()
    responder = threading.Thread(target=reply, args=(True, True))
    responder.start()
    process = subprocess.Popen([str(executable), "shutdown-live", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert shutdown_sent.wait(timeout=2), "Peer failed to send shutdown acknowledgement"
    acknowledged_live = bool(select.select([process.stdout], [], [], 2)[0])
    release_shutdown.set()
    stdout, stderr = process.communicate(timeout=5)
    responder.join(timeout=2)
    assert process.returncode == 0 and stdout == b"ack\n", stderr.decode()
    assert acknowledged_live, "Shutdown waits for EOF instead of accepting the available acknowledgement"

    release_watch = threading.Event()
    watch_sent = threading.Event()

    def watch_reply(keep_open=False):
        connection, _ = server.accept()
        with connection:
            request = json.loads(connection.makefile("rb").readline())
            assert request["command"] == "watch" and request["include_progress"] is False
            frames = [
                {"version": 1, "id": request["id"], "ok": True, "snapshot": {"receive": None}},
                {"version": 1, "id": request["id"], "ok": True,
                 "snapshot": {"receive": {"status": "pending", "session_id": "offered", "files": []}}},
            ]
            encoded = b"".join(json.dumps(frame).encode() + b"\n" for frame in frames)
            connection.sendall(encoded[:7])
            connection.sendall(encoded[7:])
            watch_sent.set()
            if keep_open:
                release_watch.wait(timeout=5)

    watcher = threading.Thread(target=watch_reply)
    watcher.start()
    run("watch", True)
    watcher.join(timeout=2)
    assert not watcher.is_alive()

    watch_sent.clear()
    watcher = threading.Thread(target=watch_reply, args=(True,))
    watcher.start()
    process = subprocess.Popen([str(executable), "watch-live", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert watch_sent.wait(timeout=2), "Peer failed to send the pending frame"
    delivered_live = bool(select.select([process.stdout], [], [], 2)[0])
    release_watch.set()
    stdout, stderr = process.communicate(timeout=5)
    watcher.join(timeout=2)
    assert process.returncode == 0 and stdout == b"pending\n", stderr.decode()
    print(f"Persistent peer pending delivered before EOF: {delivered_live}; EOF control delivered: True", flush=True)
    assert delivered_live, "Native watch waits for EOF instead of dispatching an available JSON line"

    server.close()
print("Native IPC recovery, skinny decision watch, and acknowledged shutdown checks passed")
