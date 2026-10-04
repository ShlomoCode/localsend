#!/usr/bin/env python3
"""Run real LocalSend CLI instances inside disposable Linux network namespaces."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid


HERE = Path(__file__).resolve().parent
SCENARIOS = json.loads((HERE / "scenarios.json").read_text())


def command(args, *, check=True, timeout=20, stdout=None, env=None):
    result = subprocess.run(args, text=True, stdout=stdout or subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, env=env)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}: exit {result.returncode}\n{result.stderr}\n{result.stdout or ''}")
    return result


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class ServePeer:
    """Persistent CLI JSON-line process with asynchronous events and explicit receive decisions."""

    def __init__(self, lab, node):
        self.lab = lab
        self.node = node
        self.log = open(lab.artifacts / f"composite-session-{node}.jsonl", "w", buffering=1)
        self.err = open(lab.artifacts / f"composite-session-{node}.stderr.log", "w", buffering=1)
        self.process = subprocess.Popen(lab.cli(node, ["serve", "--stdio"]),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err,
                                        text=True, bufsize=1, env=lab.node_env(node), start_new_session=True)
        self.events = []
        self.condition = threading.Condition()
        self.write_lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, name=f"serve-{node}", daemon=True)
        self.reader.start()

    def _write(self, request):
        with self.write_lock:
            self.process.stdin.write(json.dumps(request) + "\n")
            self.process.stdin.flush()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.log.write(line)
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    item = {"harness_error": f"non-JSON stdout: {line.strip()}"}
                with self.condition:
                    self.events.append(item)
                    self.condition.notify_all()
                if item.get("event") == "receive_request":
                    self._write({"id": f"accept-{item['session_id']}", "command": "receive_decision",
                                 "session_id": item["session_id"], "accept": True})
        except Exception as exc:
            with self.condition:
                self.events.append({"harness_error": str(exc)})
                self.condition.notify_all()

    def wait(self, predicate, timeout=35):
        until = time.monotonic() + timeout
        with self.condition:
            while True:
                for index, item in enumerate(self.events):
                    if "harness_error" in item:
                        raise AssertionError(f"{self.node}: {item['harness_error']}")
                    if predicate(item):
                        return self.events.pop(index)
                if self.process.poll() is not None and not self.reader.is_alive():
                    raise AssertionError(f"{self.node}: serve exited {self.process.returncode}")
                remaining = until - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"{self.node}: timed out waiting for serve event; see {self.log.name}")
                self.condition.wait(min(remaining, 0.25))

    def call(self, name, **fields):
        request_id = uuid.uuid4().hex
        self._write({"id": request_id, "command": name, **fields})
        reply = self.wait(lambda item: item.get("id") == request_id, timeout=12)
        if not reply.get("ok"):
            raise AssertionError(f"{self.node}: {name} failed: {reply}")
        return reply["result"]

    def close(self):
        error = None
        try:
            if self.process.poll() is None:
                response = self.call("shutdown")
                if not response.get("shutting_down"):
                    raise AssertionError(f"{self.node}: shutdown was not acknowledged: {response}")
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired as exc:
                    raise AssertionError(f"{self.node}: serve did not exit after shutdown") from exc
            if self.process.returncode != 0:
                raise AssertionError(f"{self.node}: serve exited {self.process.returncode}")
        except Exception as exc:
            error = exc
        finally:
            self.lab.stop(self.process)
            self.reader.join(timeout=2)
            self.log.close()
            self.err.close()
        if error:
            raise error


class Lab:
    def __init__(self, scenario, binary, artifacts):
        self.spec = SCENARIOS[scenario]
        self.scenario = scenario
        self.binary = binary.resolve()
        self.artifacts = artifacts.resolve() / scenario
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="localsend-network-lab-")
        self.root = Path(self.temp.name)
        self.tag = uuid.uuid4().hex[:6]
        self.names = {}
        self.bridges = []
        self.processes = []
        self.captures = []
        self.runlog = open(self.artifacts / "commands.log", "w", buffering=1)
        self.counter = 0
        self.evidence = []

    def run(self, args, *, check=True, timeout=20, env=None):
        self.runlog.write("+ " + " ".join(map(str, args)) + "\n")
        result = command(args, check=False, timeout=timeout, env=env)
        self.runlog.write(f"exit={result.returncode}\n{result.stdout}{result.stderr}\n")
        if check and result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, args))}\n{result.stderr}")
        return result

    def nsrun(self, node, args, **kwargs):
        return self.run(["ip", "netns", "exec", self.names[node], *args], **kwargs)

    def create(self):
        for node in self.spec["nodes"]:
            ns = f"ls{self.tag}{len(self.names):02d}"
            self.run(["ip", "netns", "add", ns])
            self.names[node] = ns
            self.nsrun(node, ["ip", "link", "set", "lo", "up"])
            self.nsrun(node, ["sysctl", "-qw", "net.ipv6.conf.all.disable_ipv6=0"])
        bridges = {}
        for segment in self.spec["segments"]:
            bridge = f"lb{self.tag}{len(bridges):02d}"
            self.run(["ip", "link", "add", bridge, "type", "bridge"])
            self.bridges.append(bridge)
            self.run(["ip", "link", "set", "dev", bridge, "type", "bridge", "mcast_snooping", "0"])
            self.run(["ip", "link", "set", bridge, "up"])
            bridges[segment] = bridge
            pcap = self.artifacts / f"{segment}.pcap"
            capture = subprocess.Popen(["tcpdump", "-U", "-i", bridge, "-w", str(pcap)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
            self.captures.append(capture)
        for node, spec in self.spec["nodes"].items():
            for index, link in enumerate(spec["links"]):
                ident = self.counter
                self.counter += 1
                host = f"lh{self.tag}{ident:02d}"
                peer = f"lp{self.tag}{ident:02d}"
                iface = f"eth{index}"
                self.run(["ip", "link", "add", host, "type", "veth", "peer", "name", peer])
                self.run(["ip", "link", "set", peer, "netns", self.names[node]])
                self.run(["ip", "link", "set", host, "master", bridges[link["segment"]]])
                self.run(["ip", "link", "set", host, "up"])
                self.nsrun(node, ["ip", "link", "set", peer, "name", iface])
                self.nsrun(node, ["ip", "link", "set", iface, "up"])
                if "vlan" in link:
                    tagged = f"{iface}.{link['vlan']}"
                    self.nsrun(node, ["ip", "link", "add", "link", iface, "name", tagged,
                                      "type", "vlan", "id", str(link["vlan"])])
                    self.nsrun(node, ["ip", "link", "set", tagged, "up"])
                    iface = tagged
                if "ipv4" in link:
                    self.nsrun(node, ["ip", "addr", "add", link["ipv4"], "dev", iface])
                if "ipv6" in link:
                    self.nsrun(node, ["ip", "-6", "addr", "add", link["ipv6"], "dev", iface])
            if spec.get("router"):
                self.nsrun(node, ["sysctl", "-qw", "net.ipv4.ip_forward=1"])
                self.nsrun(node, ["sysctl", "-qw", "net.ipv6.conf.all.forwarding=1"])
            for route in spec.get("routes", []):
                self.nsrun(node, ["ip", "route", "add", route["to"], "via", route["via"]])
            if spec.get("block_multicast"):
                self.nsrun(node, ["iptables", "-I", "INPUT", "-d", "224.0.0.0/4", "-j", "DROP"])
                self.nsrun(node, ["iptables", "-I", "OUTPUT", "-d", "224.0.0.0/4", "-j", "DROP"])
                self.nsrun(node, ["ip6tables", "-I", "INPUT", "-d", "ff00::/8", "-j", "DROP"])
                self.nsrun(node, ["ip6tables", "-I", "OUTPUT", "-d", "ff00::/8", "-j", "DROP"])
            if "nat_out" in spec:
                outside = next(f"eth{i}" for i, link in enumerate(spec["links"]) if link["segment"] == spec["nat_out"])
                self.nsrun(node, ["iptables", "-t", "nat", "-A", "POSTROUTING", "-o", outside, "-j", "MASQUERADE"])
            for policy in spec.get("drop_forward", []):
                rule = ["iptables", "-A", "FORWARD"]
                if "source" in policy:
                    rule += ["-s", policy["source"]]
                if "destination" in policy:
                    rule += ["-d", policy["destination"]]
                self.nsrun(node, [*rule, "-j", "DROP"])

    def node_env(self, node):
        config = self.root / "config" / node
        config.mkdir(parents=True, exist_ok=True)
        home = self.root / node
        home.mkdir(parents=True, exist_ok=True)
        return {**os.environ, "XDG_CONFIG_HOME": str(config), "HOME": str(home)}

    def cli(self, node, subcommand):
        destination = self.root / "received" / node
        destination.mkdir(parents=True, exist_ok=True)
        return ["ip", "netns", "exec", self.names[node], str(self.binary),
                "--alias", node, "--port", "53317", "--destination", str(destination), *subcommand]

    def log_process(self, label, args, node):
        path = self.artifacts / f"{label}.log"
        log = open(path, "w", buffering=1)
        self.runlog.write("+ " + " ".join(args) + f" > {path}\n")
        process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                   text=True, env=self.node_env(node), start_new_session=True)
        self.processes.append((process, log))
        return process, path

    def wait_listening(self, node, process, deadline=15):
        until = time.monotonic() + deadline
        while time.monotonic() < until:
            if process.poll() is not None:
                raise RuntimeError(f"Receiver exited before listening: {process.returncode}")
            result = self.nsrun(node, ["ss", "-ltn", "sport", "=", ":53317"], check=False)
            if ":53317" in result.stdout:
                return
            time.sleep(0.2)
        raise RuntimeError(f"Receiver {node} did not listen on TCP 53317")

    def stop(self, process):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                return
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3)

    def invoke(self, label, node, subcommand, *, timeout=55):
        args = self.cli(node, subcommand)
        self.runlog.write("+ " + " ".join(args) + "\n")
        result = command(args, check=False, timeout=timeout, env=self.node_env(node))
        (self.artifacts / f"{label}.jsonl").write_text(result.stdout)
        (self.artifacts / f"{label}.stderr.log").write_text(result.stderr)
        self.runlog.write(f"exit={result.returncode}\n")
        return result

    def json_objects(self, output, *, strict=True):
        lines = [line for line in output.splitlines() if line.strip()]
        if not strict:
            lines = [line for line in lines if line.startswith("{")]
        if not lines:
            raise AssertionError("CLI produced no JSON output")
        return [json.loads(line) for line in lines]

    def peer_ip(self, node):
        link = self.spec["nodes"][node]["links"][0]
        return ipaddress.ip_interface(link.get("ipv4", link.get("ipv6"))).ip.compressed

    def link_local(self, node):
        result = self.nsrun(node, ["ip", "-6", "-o", "addr", "show", "dev", "eth0", "scope", "link"])
        for line in result.stdout.splitlines():
            fields = line.split()
            if "inet6" in fields:
                return fields[fields.index("inet6") + 1].split("/")[0]
        raise AssertionError(f"{node} has no IPv6 link-local address")

    def transfer(self, source, target, label, address=None, *, expect_success=True):
        payload = self.root / f"payload-{label}.bin"
        payload.write_bytes(hashlib.sha256(label.encode()).digest() * 8192)
        receiver, receiver_log = self.log_process(f"{label}-receive", self.cli(target, ["receive", "--auto-accept", "--once", "--json", "--timeout", "45"]), target)
        self.wait_listening(target, receiver)
        try:
            dest = address or self.peer_ip(target)
            result = self.invoke(f"{label}-send", source,
                                 ["send", "--to", dest, "--target-port", "53317", "--json", "--timeout",
                                  "30" if expect_success else "8", str(payload)], timeout=40 if expect_success else 15)
            if expect_success:
                if result.returncode:
                    raise AssertionError(f"{label}: send failed: {result.stderr}")
                objects = self.json_objects(result.stdout)
                if not any(item.get("type") == "send_completed" and item.get("success") is True for item in objects):
                    raise AssertionError(f"{label}: missing successful send JSON: {result.stdout}")
                try:
                    receiver.wait(timeout=15)
                except subprocess.TimeoutExpired as exc:
                    raise AssertionError(f"{label}: receiver did not finish") from exc
                if receiver.returncode:
                    raise AssertionError(f"{label}: receiver failed; see {receiver_log}")
                receive_events = self.json_objects(receiver_log.read_text(), strict=False)
                if not any(item.get("type") == "receive_completed" and item.get("success") is True
                           for item in receive_events):
                    raise AssertionError(f"{label}: receiver lacks successful completion event; see {receiver_log}")
                received = self.root / "received" / target / payload.name
                if not received.exists() or sha256(received) != sha256(payload):
                    raise AssertionError(f"{label}: payload hash differs or destination missing")
                self.evidence.append({"check": label, "source": source, "target": target,
                                      "address": dest, "bytes": payload.stat().st_size,
                                      "sha256": sha256(payload), "result": "transferred"})
            else:
                if result.returncode == 0:
                    raise AssertionError(f"{label}: unexpectedly sent to unreachable target")
                if "not discovered" not in result.stderr.lower():
                    raise AssertionError(f"{label}: failed for an unexpected reason: {result.stderr}")
                if receiver.poll() is not None:
                    raise AssertionError(f"{label}: receiver exited during negative probe; see {receiver_log}")
                received = self.root / "received" / target / payload.name
                if received.exists():
                    raise AssertionError(f"{label}: unreachable target received bytes")
                self.evidence.append({"check": label, "source": source, "target": target,
                                      "address": dest, "result": "unreachable"})
        finally:
            self.stop(receiver)

    def check(self, index, spec):
        source, target = spec["from"], spec["to"]
        label = f"{index}-{source}-to-{target}"
        receiver, _ = self.log_process(f"{label}-discovery-receiver",
                                       self.cli(target, ["receive", "--auto-accept", "--once", "--json", "--timeout", "45"]), target)
        try:
            self.wait_listening(target, receiver)
            found = self.invoke(f"{label}-discover", source, ["discover", "--json", "--timeout", "8"], timeout=20)
            if found.returncode:
                raise AssertionError(f"{label}: discovery command failed: {found.stderr}")
            objects = self.json_objects(found.stdout)
            devices = [device for item in objects if item.get("type") == "discovery" for device in item.get("devices", [])]
            present = any(device.get("alias") == target for device in devices)
            if present != spec["discovered"]:
                raise AssertionError(f"{label}: discovery expected {spec['discovered']}, got {present}: {devices}")
            self.evidence.append({"check": label, "source": source, "target": target,
                                  "result": "discovered" if present else "undiscovered",
                                  "devices": devices})
            if spec.get("alias_send") is False:
                payload = self.root / f"{label}-unknown-alias.bin"
                payload.write_bytes(b"unknown alias probe")
                result = self.invoke(f"{label}-unknown-alias", source,
                                     ["send", "--to", target, "--json", "--timeout", "6", str(payload)], timeout=15)
                if result.returncode == 0:
                    raise AssertionError(f"{label}: alias unexpectedly reached across discovery boundary")
                if "not discovered" not in result.stderr.lower():
                    raise AssertionError(f"{label}: alias failed for an unexpected reason: {result.stderr}")
                if receiver.poll() is not None:
                    raise AssertionError(f"{label}: receiver exited during alias negative probe")
                if (self.root / "received" / target / payload.name).exists():
                    raise AssertionError(f"{label}: alias-negative receiver got the payload")
        finally:
            self.stop(receiver)
        if spec.get("alias_send"):
            self.transfer(source, target, f"{label}-alias", address=target)
        if spec.get("reachable", True):
            self.transfer(source, target, f"{label}-ip")
            if spec.get("reverse"):
                self.transfer(target, source, f"{label}-reverse")
            if "ipv6_target" in spec:
                self.transfer(source, target, f"{label}-ipv6", address=spec["ipv6_target"])
            if spec.get("link_local"):
                self.transfer(source, target, f"{label}-linklocal", address=self.link_local(target) + "%eth0")
        else:
            self.transfer(source, target, f"{label}-isolated", expect_success=False)

    def composite_session(self):
        """Keep every endpoint online while exercising discovery, routing, and isolation."""
        names = ("alice", "local_peer", "remote_peer", "guest")
        peers = {}
        try:
            for name in names:
                peers[name] = ServePeer(self, name)
            for name in names:
                ready = peers[name].wait(lambda item: item.get("event") == "ready", timeout=18)
                if ready.get("alias") != name:
                    raise AssertionError(f"{name}: wrong serve identity: {ready}")
                self.wait_listening(name, peers[name].process)
            for name in names:
                status = peers[name].call("status")
                if any(status.get(key) is not None for key in ("sending", "queued_send", "receiving", "pending")):
                    raise AssertionError(f"{name}: unexpected initial session: {status}")
            alice = peers["alice"]
            alice.wait(lambda item: item.get("event") == "discovery_completed", timeout=15)
            with alice.condition:
                alice.events = [item for item in alice.events if item.get("event") != "discovery_completed"]
            alice.call("discover")
            discovery = alice.wait(lambda item: item.get("event") == "discovery_completed", timeout=15)
            found = {device.get("alias") for device in discovery.get("devices", [])}
            if "local_peer" not in found or "remote_peer" in found or "guest" in found:
                raise AssertionError(f"Composite live discovery mismatch: {sorted(found)}")
            self.evidence.append({"check": "composite-session-discovery", "result": "discovered",
                                  "online_nodes": list(names), "visible_aliases": sorted(found)})

            def send(source, target, address, label, success=True):
                payload = self.root / f"composite-session-{label}.bin"
                payload.write_bytes(hashlib.sha256(label.encode()).digest() * 8192)
                response = peers[source].call("send", to=address, target_port=53317, timeout=30 if success else 9,
                                              paths=[str(payload)])
                transfer_id = response.get("transfer_id")
                if not response.get("queued") or not transfer_id:
                    raise AssertionError(f"{label}: send was not queued: {response}")
                completed = peers[source].wait(lambda item: item.get("event") == "send_completed"
                                               and item.get("transfer_id") == transfer_id, timeout=36 if success else 15)
                if completed.get("success") is not success:
                    raise AssertionError(f"{label}: unexpected send completion: {completed}")
                received_path = self.root / "received" / target / payload.name
                if success:
                    session_id = completed.get("session_id")
                    request = peers[target].wait(lambda item: item.get("event") == "receive_request"
                                                 and item.get("session_id") == session_id, timeout=15)
                    decision = peers[target].wait(lambda item: item.get("id") == f"accept-{session_id}", timeout=15)
                    if request.get("alias") != source or not decision.get("ok") or not decision.get("result", {}).get("accepted"):
                        raise AssertionError(f"{label}: explicit receive decision failed: {request}, {decision}")
                    received = peers[target].wait(lambda item: item.get("event") == "receive_completed"
                                                  and item.get("session_id") == session_id, timeout=15)
                    if received.get("success") is not True or not received_path.exists() or sha256(received_path) != sha256(payload):
                        raise AssertionError(f"{label}: receiver completion or payload hash mismatch: {received}")
                    result = "transferred"
                else:
                    if "not discovered" not in completed.get("error", "").lower() or received_path.exists():
                        raise AssertionError(f"{label}: negative send failed unexpectedly: {completed}")
                    result = "unreachable"
                self.evidence.append({"check": f"composite-session-{label}", "result": result,
                                      "source": source, "target": target, "address": address,
                                      "sha256": sha256(payload) if success else None})

            send("alice", "local_peer", "local_peer", "local-alias")
            send("alice", "remote_peer", self.peer_ip("remote_peer"), "remote-ip")
            send("remote_peer", "alice", self.peer_ip("alice"), "reverse-ip")
            send("alice", "guest", self.peer_ip("guest"), "guest-denied", success=False)
            for name in names:
                status = peers[name].call("status")
                if any(status.get(key) is not None for key in ("sending", "queued_send", "receiving", "pending")):
                    raise AssertionError(f"{name}: session remained active: {status}")
            self.evidence.append({"check": "composite-session-clean-status", "result": "idle",
                                  "online_nodes": list(names)})
        finally:
            prior_error = sys.exc_info()[0] is not None
            close_errors = []
            for peer in peers.values():
                try:
                    peer.close()
                except Exception as exc:
                    close_errors.append(str(exc))
            if close_errors and not prior_error:
                raise AssertionError("Composite serve shutdown failed: " + "; ".join(close_errors))

    def diagnostics(self):
        for bridge in self.bridges:
            result = self.run(["ip", "-d", "link", "show", bridge], check=False)
            (self.artifacts / f"{bridge}-link.txt").write_text(result.stdout + result.stderr)
        for node in self.names:
            for title, args in (("links", ["ip", "-d", "addr"]),
                                ("routes", ["ip", "route", "show", "table", "all"]),
                                ("routes6", ["ip", "-6", "route", "show", "table", "all"]),
                                ("sockets", ["ss", "-lntup"]),
                                ("iptables", ["iptables", "-S"]),
                                ("nat", ["iptables", "-t", "nat", "-S"])):
                try:
                    result = self.nsrun(node, args, check=False)
                    (self.artifacts / f"{node}-{title}.txt").write_text(result.stdout + result.stderr)
                except Exception as exc:
                    (self.artifacts / f"{node}-{title}.txt").write_text(str(exc))

    def cleanup(self):
        for process, log in self.processes:
            self.stop(process)
            log.close()
        for capture in self.captures:
            self.stop(capture)
        for ns in reversed(list(self.names.values())):
            command(["ip", "netns", "del", ns], check=False)
        for bridge in reversed(self.bridges):
            command(["ip", "link", "del", bridge], check=False)
        (self.artifacts / "evidence.json").write_text(json.dumps(self.evidence, indent=2) + "\n")
        self.runlog.close()
        self.temp.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("target/debug/localsend-cli"))
    parser.add_argument("--scenario", choices=[*SCENARIOS, "smoke", "full", "all"], default="all")
    parser.add_argument("--artifacts", type=Path, default=Path("artifacts/network-lab"))
    args = parser.parse_args()
    if os.geteuid() != 0 or sys.platform != "linux":
        parser.error("the lab must run as root on Linux (use sudo)")
    for tool in ("ip", "ss", "sysctl", "iptables", "ip6tables", "tcpdump"):
        if not shutil.which(tool):
            parser.error(f"missing runner dependency: {tool}")
    if not args.binary.resolve().is_file():
        parser.error(f"CLI binary not found: {args.binary}; build with cargo build -p localsend-cli --locked")
    smoke = ["lan", "blocked_multicast"]
    if args.scenario == "smoke":
        scenarios = smoke
    elif args.scenario == "full":
        scenarios = [name for name in SCENARIOS if name not in smoke]
    elif args.scenario == "all":
        scenarios = list(SCENARIOS)
    else:
        scenarios = [args.scenario]
    for scenario in scenarios:
        lab = Lab(scenario, args.binary, args.artifacts)
        try:
            print(f"RUN {scenario}: {lab.spec['description']}", flush=True)
            lab.create()
            for index, check in enumerate(lab.spec["checks"]):
                lab.check(index, check)
            if scenario == "composite":
                lab.composite_session()
            print(f"PASS {scenario}", flush=True)
        except Exception as exc:
            lab.diagnostics()
            print(f"FAIL {scenario}: {exc}; artifacts: {lab.artifacts}", file=sys.stderr, flush=True)
            raise
        finally:
            lab.cleanup()


if __name__ == "__main__":
    main()
