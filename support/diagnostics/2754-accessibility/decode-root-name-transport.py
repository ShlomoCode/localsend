#!/usr/bin/env python3
"""Bounded offline strace decoder. Read delivery is not wrapper consumption.

Only continuous, completely printed, successful byte IO is reconstructed.
Unrecognized IO poisons a connection; there is no heuristic resynchronization.
"""
import argparse
import json
import re
import struct

MAX_MESSAGE = 1048576
MAX_BYTES = 16777216
MAX_MESSAGES = 4096
MAX_LINE = MAX_MESSAGE * 8 + 65536
MAX_RAW = 134217728
MAX_LINES = 262144
PREFIX = re.compile(r"^(?:\[pid\s+(\d+)\]|(\d+))\s+(\d+\.\d+)\s+(.*)$")
CALL = re.compile(r"^(\w+)\((.*)\)\s+=\s+(-?\d+)(.*)$")
FD = re.compile(r"^\s*(\d+)(?:<((?:->|[^>])*)>)?")
HEX = re.compile(r'"((?:\\x[0-9a-fA-F]{2})*)"')
IO = {"read": "in", "readv": "in", "recvfrom": "in", "recvmsg": "in",
      "write": "out", "writev": "out", "sendto": "out", "sendmsg": "out"}
UNSUPPORTED = {"sendmmsg", "recvmmsg", "splice", "tee", "vmsplice", "sendfile",
               "sendfile64", "io_uring_enter", "io_uring_setup", "pidfd_getfd"}


def split_args(text):
    result, start, depth, quoted, escape = [], 0, 0, False, False
    for i, char in enumerate(text):
        if quoted:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            result.append(text[start:i].strip())
            start = i + 1
    result.append(text[start:].strip())
    return result


def quoted_bytes(text):
    match = HEX.fullmatch(text.strip())
    if not match:
        raise ValueError("non-hex, abbreviated, or unavailable byte buffer")
    return bytes.fromhex(match[1].replace("\\x", ""))


def syscall_bytes(name, args, count):
    if name in ("readv", "writev", "recvmsg", "sendmsg"):
        # Decode only iov_base buffers. Path names, control data, and addresses
        # are never treated as payload. Lengths must be fully printed.
        parts = re.findall(r'iov_base=("(?:\\x[0-9a-fA-F]{2})*"), iov_len=(\d+)', args[1])
        declared = args[1].count("iov_base=")
        if not parts or len(parts) != declared or "..." in args[1]:
            raise ValueError("partial/unavailable iovec")
        data = bytearray()
        remaining = count
        for raw, size in parts:
            size = int(size)
            take = min(size, remaining)
            value = quoted_bytes(raw)
            if len(value) < take:
                raise ValueError("iovec shorter than successful returned bytes")
            data.extend(value[:take])
            remaining -= take
        if remaining:
            raise ValueError("return count exceeds printed iovecs")
        return bytes(data)
    value = quoted_bytes(args[1])
    if len(value) < count:
        raise ValueError("return count exceeds printed buffer (including MSG_TRUNC)")
    return value[:count]


def dbus_message(raw):
    endian = "<" if raw[0] == ord("l") else ">"
    u32 = lambda at: struct.unpack_from(endian + "I", raw, at)[0]
    if raw[3] != 1 or raw[1] not in (1, 2, 3, 4) or u32(8) == 0:
        raise ValueError("invalid protocol/type/serial")
    fields_end = 16 + u32(12)
    body_start = (fields_end + 7) & ~7
    result = dict(message_type=raw[1], serial=u32(8), body_length=u32(4))
    names = {1: "path", 2: "interface", 3: "member", 4: "error_name", 5: "reply_serial",
             6: "destination", 7: "sender", 8: "signature", 9: "unix_fds"}
    signatures = {1: "o", 2: "s", 3: "s", 4: "s", 5: "u", 6: "s", 7: "s", 8: "g", 9: "u"}

    def string(at, signature, limit):
        if signature == "g":
            if at >= limit:
                raise ValueError("short signature")
            size, at = raw[at], at + 1
        else:
            at = (at + 3) & ~3
            if at + 4 > limit:
                raise ValueError("short string length")
            size, at = u32(at), at + 4
        if at + size + 1 > limit or raw[at + size] != 0:
            raise ValueError("short/non-terminated string")
        return raw[at:at + size].decode("ascii" if signature == "g" else "utf-8"), at + size + 1

    at, seen = 16, set()
    while at < fields_end:
        at = (at + 7) & ~7
        if at + 4 > fields_end:
            raise ValueError("short header variant")
        code, length = raw[at], raw[at + 1]
        if length != 1 or raw[at + 3] != 0 or code in seen:
            raise ValueError("unsupported/duplicate header variant")
        signature = chr(raw[at + 2])
        if code not in signatures or signatures[code] != signature:
            raise ValueError("unqualified header field type")
        seen.add(code)
        at += 4
        if signature == "u":
            at = (at + 3) & ~3
            if at + 4 > fields_end:
                raise ValueError("short header uint32")
            value, at = u32(at), at + 4
        else:
            value, at = string(at, signature, fields_end)
        result[names[code]] = value
    result["root_name_request"] = False
    if (result["message_type"] == 1 and result.get("path") == "/org/a11y/atspi/accessible/root"
            and result.get("interface") == "org.freedesktop.DBus.Properties"
            and result.get("member") == "Get" and result.get("signature") == "ss"):
        interface, at = string(body_start, "s", len(raw))
        property_name, at = string(at, "s", len(raw))
        if at != len(raw):
            raise ValueError("trailing Properties.Get body")
        result.update(body_interface=interface, body_property=property_name,
                      root_name_request=interface == "org.a11y.atspi.Accessible" and property_name == "Name")
    return result


class Decoder:
    def __init__(self):
        self.tables, self.connections, self.pending = {}, {}, {}
        self.messages, self.gaps, self.total = [], [], 0
        self.next_id, self.partial = 1, False

    def gap(self, reason, event, connection=None):
        self.partial = True
        if len(self.gaps) < MAX_MESSAGES:
            self.gaps.append(dict(reason=reason, event=event, connection=connection))
        # An unidentified loss can concern any existing socket. Never continue
        # framing a stream after a gap, even if later bytes look like a header.
        affected = [connection] if connection in self.connections else list(self.connections)
        for cid in affected:
            self.connections[cid]["poisoned"] = True
            self.connections[cid]["buffers"] = {"in": bytearray(), "out": bytearray()}

    def new(self, pid, fd, event, identity=None):
        table = self.tables.setdefault(pid, {})
        if fd in table:
            self.gap("FD reused without observed close", event, table[fd])
        cid = self.next_id
        self.next_id += 1
        table[fd] = cid
        self.connections[cid] = dict(id=cid, birth=event, socket_identity=identity, connected=False,
                                     proc_socket_identity=None,
                                     poisoned=False, buffers={"in": bytearray(), "out": bytearray()},
                                     provenance={"in": [], "out": []}, offsets={"in": 0, "out": 0})
        return cid

    def feed(self, cid, direction, data, event):
        con = self.connections[cid]
        if con["poisoned"]:
            return
        if self.total + len(data) > MAX_BYTES:
            self.gap("16MiB aggregate byte bound", event, cid)
            return
        self.total += len(data)
        buf, ranges = con["buffers"][direction], con["provenance"][direction]
        start = con["offsets"][direction] + len(buf)
        ranges.append(dict(start=start, end=start + len(data), **event))
        buf.extend(data)
        while buf:
            # Authentication is accepted only as complete recognized CRLF lines,
            # never by searching arbitrary payload for a D-Bus marker.
            if buf[0] not in (ord("l"), ord("B")) or b"BEGIN".startswith(bytes(buf)) or buf.startswith(b"BEGIN\r\n"):
                prefixes = (b"\0AUTH", b"AUTH", b"OK ", b"REJECTED", b"DATA", b"ERROR", b"CANCEL", b"NEGOTIATE_UNIX_FD", b"AGREE_UNIX_FD", b"BEGIN")
                if any(p.startswith(bytes(buf)) or bytes(buf).startswith(p) for p in prefixes):
                    end = buf.find(b"\r\n")
                    if end < 0:
                        if len(buf) > 65536:
                            self.gap("oversized authentication line", event, cid)
                        return
                    used = end + 2
                    del buf[:used]
                    con["offsets"][direction] += used
                    ranges[:] = [r for r in ranges if r["end"] > con["offsets"][direction]]
                    continue
                self.gap("unrecognized stream bytes; no resynchronization", event, cid)
                return
            if len(buf) < 16:
                return
            endian = "<" if buf[0] == ord("l") else ">"
            body, fields = struct.unpack_from(endian + "I", buf, 4)[0], struct.unpack_from(endian + "I", buf, 12)[0]
            length = ((16 + fields + 7) & ~7) + body
            if length > MAX_MESSAGE:
                self.gap("1MiB message bound", event, cid)
                return
            if len(buf) < length:
                return
            if len(self.messages) >= MAX_MESSAGES:
                self.gap("4096 message bound", event, cid)
                return
            try:
                decoded = dbus_message(bytes(buf[:length]))
            except (ValueError, UnicodeError, struct.error) as error:
                self.gap(str(error), event, cid)
                return
            start = con["offsets"][direction]
            self.messages.append(dict(connection=cid, direction=direction, byte_start=start,
                                      byte_end=start + length, provenance=[r for r in ranges if r["end"] > start and r["start"] < start + length], **decoded))
            del buf[:length]
            con["offsets"][direction] += length
            ranges[:] = [r for r in ranges if r["end"] > con["offsets"][direction]]

    def syscall(self, pid, timestamp, text, line):
        event = dict(pid=pid, timestamp=timestamp, line=line)
        entry_generation = None
        resumed_call = False
        if "<unfinished ...>" in text:
            if pid in self.pending:
                self.gap("overlapping unfinished calls", event)
            prefix = text.split("<unfinished ...>")[0]
            first = FD.match(prefix.split("(", 1)[1]) if "(" in prefix else None
            generation = self.tables.get(pid, {}).get(int(first[1])) if first else None
            name = prefix.split("(", 1)[0]
            if generation is not None and name in IO:
                for pending_prefix, pending_event, pending_generation in self.pending.values():
                    pending_name = pending_prefix.split("(", 1)[0]
                    if pending_generation == generation and IO.get(pending_name) == IO[name]:
                        self.gap("overlapping same-direction socket IO has unknown byte order", event, generation)
            self.pending[pid] = (prefix, event, generation)
            return
        if text.startswith("<... "):
            resumed = re.match(r"<\.\.\. (\w+) resumed>(.*)", text)
            saved = self.pending.pop(pid, None)
            if not resumed or not saved or not saved[0].startswith(resumed[1] + "("):
                self.gap("unmatched resumed syscall", event)
                return
            text = saved[0] + resumed[2]
            entry_generation, resumed_call = saved[2], True
            event["start_line"] = saved[1]["line"]
            event["start_timestamp"] = saved[1]["timestamp"]
        match = CALL.match(text)
        if not match:
            if not text.startswith(("--- ", "+++ ")):
                self.gap("unparsed syscall record", event)
            return
        name, argument_text, result, suffix = match.groups()
        args, result = split_args(argument_text), int(result)
        table = self.tables.setdefault(pid, {})
        fd_match = FD.match(args[0]) if args else None
        fd = int(fd_match[1]) if fd_match else None
        cid = table.get(fd)
        if resumed_call and name in IO:
            # A successful blocked read holds its open-file description even if
            # another thread closed/reused the numeric descriptor meanwhile.
            cid = entry_generation
        elif resumed_call and name in ("connect", "dup", "dup2", "dup3", "fcntl", "close") and cid != entry_generation:
            self.gap("FD generation changed during unfinished mutation", event)
            return
        event.update(syscall=name, fd=fd, fd_annotation=fd_match[2] if fd_match else None)
        if name in ("clone", "clone3", "fork", "vfork") and result > 0:
            self.tables[result] = table if "CLONE_FILES" in argument_text else dict(table)
        elif name == "socket" and result >= 0:
            self.new(pid, result, event)
        elif name == "socketpair" and result == 0:
            self.gap("socketpair topology unsupported", event)
        elif name == "connect" and result in (0, -1):
            if cid is None:
                self.gap("connect without socket birth", event)
            elif result == 0:
                self.connections[cid]["connected"] = True
                self.connections[cid]["connect"] = event
                self.connections[cid]["address"] = args[1]
            elif "EINPROGRESS" not in suffix:
                self.gap("unsuccessful connect", event, cid)
        elif name in ("dup", "dup2", "dup3") or (name == "fcntl" and len(args) > 1 and args[1] in ("F_DUPFD", "F_DUPFD_CLOEXEC")):
            if result >= 0:
                if cid is None:
                    table.pop(result, None)
                    self.gap("dup source generation unavailable", event)
                else:
                    table[result] = cid
        elif name == "close" and result == 0:
            table.pop(fd, None)
        elif name == "close" and result < 0 and cid is not None:
            self.gap("failed close has uncertain FD lifetime", event, cid)
            table.pop(fd, None)
        elif name in ("close_range", "unshare", "execve", "execveat") and result == 0:
            # CLOEXEC and unsharing cannot be inferred safely from this limited
            # descriptor model. Preserve positive observations, invalidate joins.
            for known in set(table.values()):
                self.gap("descriptor table transition: " + name, event, known)
            if name in ("unshare", "execve", "execveat") or "CLOSE_RANGE_UNSHARE" in argument_text:
                # The caller ceases sharing its descriptor table. Clearing the
                # old shared dict would let newly-created child sockets appear
                # in surviving parent/sibling tables under the same FD.
                self.tables[pid] = {}
            else:
                table.clear()
        elif name in UNSUPPORTED or (name == "recvmsg" and "SCM_RIGHTS" in argument_text):
            self.gap("unsupported IO/FD transfer: " + name, event, cid)
        elif name in IO and result > 0:
            if cid is None:
                # Non-socket bootstrap IO is retained in raw trace. An annotated
                # socket without its observed birth cannot support reconstruction.
                if fd_match and fd_match[2] and ("UNIX" in fd_match[2] or "socket" in fd_match[2]):
                    self.gap("socket IO without observed FD generation", event)
                return
            try:
                for pending_prefix, pending_event, pending_generation in self.pending.values():
                    if pending_generation == cid and IO.get(pending_prefix.split("(", 1)[0]) == IO[name]:
                        self.gap("overlapping same-direction socket IO has unknown byte order", event, cid)
                        return
                annotation = event["fd_annotation"]
                if annotation:
                    previous = self.connections[cid]["socket_identity"]
                    if previous is not None and previous != annotation:
                        self.gap("socket annotation changed within generation", event, cid)
                        return
                    self.connections[cid]["socket_identity"] = annotation
                    inode = re.search(r"(?:UNIX(?:-STREAM)?|socket):\[(\d+)", annotation)
                    if inode:
                        self.connections[cid]["proc_socket_identity"] = "socket:[%s]" % inode[1]
                data = syscall_bytes(name, args, result)
                if "MSG_PEEK" in argument_text:
                    self.gap("peek does not consume stream bytes", event, cid)
                    return
                self.feed(cid, IO[name], data, event)
            except (ValueError, IndexError) as error:
                self.gap(str(error), event, cid)

    def finish(self):
        for pid, (_, event, _) in self.pending.items():
            name = self.pending[pid][0].split("(", 1)[0]
            if name in IO or name in UNSUPPORTED or name in ("socket", "connect", "dup", "dup2", "dup3", "fcntl", "close", "close_range", "clone", "clone3", "unshare"):
                self.gap("unfinished transport/FD syscall at capture end", event)
        for cid, con in self.connections.items():
            for direction, buf in con["buffers"].items():
                if buf:
                    self.gap("partial stream at capture end: " + direction, con["birth"], cid)
        requests = [m for m in self.messages if m["direction"] == "out" and m["root_name_request"]]
        matches = []
        for request in requests:
            replies = [m for m in self.messages if m["connection"] == request["connection"] and m["direction"] == "in"
                       and m["message_type"] in (2, 3) and m.get("reply_serial") == request["serial"]
                       and float(m["provenance"][-1]["timestamp"]) >= float(request["provenance"][-1]["timestamp"])]
            same_serial = [m for m in self.messages if m["connection"] == request["connection"] and m["direction"] == "out"
                           and m["serial"] == request["serial"]]
            matches.append(dict(request=request, replies=replies,
                                status="delivered-reply-observed" if len(replies) == 1 and len(same_serial) == 1 else "unknown",
                                stream_completeness="partial" if self.connections[request["connection"]]["poisoned"] else "finite-continuous-capture",
                                sender_associations=["target" if m.get("sender") == request.get("destination") else
                                                     "bus-generated-error" if m["message_type"] == 3 and m.get("sender") == "org.freedesktop.DBus" else
                                                     "unknown" for m in replies],
                                causal_linkage="unknown; requires qualified stopped connection and contemporaneous socket identity"))
        connections = [{k: v for k, v in c.items() if k not in ("buffers", "provenance")} for c in self.connections.values()]
        return dict(status="partial" if self.partial else "finite-capture", retained_bytes=self.total,
                    messages=self.messages, root_name=matches, connections=connections, gaps=self.gaps,
                    limitation="Read bytes prove kernel delivery only, not wrapper consumption. No reply in a finite capture is unknown. Collection does not establish geometry success.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    decoder = Decoder()
    with open(args.trace, "r", encoding="ascii", errors="replace") as source:
        line, raw_bytes = 0, 0
        while True:
            raw = source.readline(MAX_LINE + 1)
            if not raw:
                break
            line += 1
            raw_bytes += len(raw)
            if raw_bytes > MAX_RAW or line > MAX_LINES:
                decoder.gap("raw capture scan bound exceeded", dict(line=line))
                break
            if len(raw) > MAX_LINE:
                decoder.gap("raw line bound exceeded", dict(line=line))
                break
            match = PREFIX.match(raw.rstrip("\n"))
            if not match:
                decoder.gap("missing PID/timestamp or truncated record", dict(line=line))
                continue
            pid, alternate, timestamp, text = match.groups()
            decoder.syscall(int(pid or alternate), timestamp, text, line)
    with open(args.output, "w", encoding="utf-8") as target:
        json.dump(decoder.finish(), target, indent=2, sort_keys=True)
        target.write("\n")


if __name__ == "__main__":
    main()
