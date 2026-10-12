"""Read stopped-process state only; never call a function in the inferior."""
import json
import csv
import hashlib
import os
import struct

import gdb


QUALIFIED = {}
CONNECTION_CONDITIONS = []
WAIT_CONDITIONS = []


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(65536), b""):
            hasher.update(block)
    return hasher.hexdigest()


def qualify():
    """Bind exact debug objfiles to the actual, non-deleted mapped runtime."""
    manifest = os.environ.get("ROOT_NAME_SYMBOL_MANIFEST", "/home/mint/evidence/root-name-symbols/manifest.tsv")
    directory = os.path.dirname(manifest)
    with open(os.path.join(directory, "manifest.sha256")) as source:
        expected = source.read().split()[0]
    if digest(manifest) != expected:
        raise ValueError("symbol manifest digest mismatch")
    with open("/proc/%d/maps" % gdb.selected_inferior().pid) as source:
        mappings = [line.rstrip().split(None, 5) for line in source]
    with open(manifest, newline="") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            runtime = row["runtime_path"]
            maps = [m for m in mappings if len(m) == 6 and m[5] == runtime]
            if not maps:
                emit("module_unavailable", module=runtime, reason="exact runtime path not mapped")
                continue
            if any(len(m) == 6 and m[5] == runtime + " (deleted)" for m in mappings):
                raise ValueError("deleted runtime mapping: " + runtime)
            # map_files names the actual mapped inode, not a potentially replaced path.
            mapped = "/proc/%d/map_files/%s" % (gdb.selected_inferior().pid, maps[0][0])
            if digest(mapped) != row["runtime_sha256"] or digest(runtime) != row["runtime_sha256"]:
                raise ValueError("mapped runtime hash mismatch: " + runtime)
            debug = os.path.realpath(os.path.join(directory, row["debug_relative_path"]))
            if digest(debug) != row["debug_sha256"]:
                raise ValueError("debug hash mismatch: " + runtime)
            candidates = [o for o in gdb.objfiles() if o.build_id == row["build_id"] and
                          os.path.realpath(o.filename) == debug]
            if len(candidates) != 1:
                raise ValueError("exact debug objfile unavailable: " + runtime)
            # These qualified stock ELFs have congruent PT_LOAD vaddr/file offsets.
            # Require the offset-zero mapping; no executable-map offset guess.
            zero = [m for m in maps if int(m[2], 16) == 0]
            if len(zero) != 1:
                raise ValueError("unique offset-zero mapping unavailable: " + runtime)
            QUALIFIED[row["package"]] = dict(objfile=candidates[0], bias=int(zero[0][0].split("-")[0], 16), runtime=runtime)
            emit("module_qualified", module=runtime, build_id=row["build_id"],
                 runtime_sha256=row["runtime_sha256"], debug_sha256=row["debug_sha256"],
                 load_bias=hex(QUALIFIED[row["package"]]["bias"]))


def module(fragment):
    matches = [v for k, v in QUALIFIED.items() if fragment in k]
    if len(matches) != 1:
        raise ValueError("qualified module unavailable: " + fragment)
    return matches[0]


def exact_type(name, fragment="libdbus"):
    obj = module(fragment)["objfile"]
    # Global lookup is permitted only when its DWARF owner is the exact objfile.
    value = gdb.lookup_type(name).strip_typedefs()
    if value.objfile != obj or value.sizeof == 0:
        raise ValueError("type owner/definition mismatch: " + name)
    return value


def emit(kind, **fields):
    print("ROOT_NAME_EVIDENCE " + json.dumps(dict(kind=kind, **fields), sort_keys=True))


def header_fields(raw):
    if len(raw) < 16 or raw[0] not in (ord("l"), ord("B")):
        raise ValueError("invalid or short D-Bus fixed header")
    endian = "<" if raw[0] == ord("l") else ">"
    u32 = lambda at: struct.unpack_from(endian + "I", raw, at)[0]
    result = dict(byte_order=chr(raw[0]), message_type=raw[1], flags=raw[2],
                  protocol=raw[3], body_length=u32(4), serial=u32(8),
                  fields_length=u32(12), header_fields_complete=len(raw) >= 16 + u32(12),
                  capture_partial=len(raw) < 16 + u32(12))
    if not result["header_fields_complete"]:
        # Preserve the fixed header/serial but do not parse a truncated array
        # into apparently complete sender/destination/reply fields.
        result["parse_status"] = "partial-fields-array-truncated"
        return result
    end = min(len(raw), 16 + u32(12))
    at = 16
    names = {1: "path", 2: "interface", 3: "member", 4: "error_name",
             5: "reply_serial", 6: "destination", 7: "sender", 8: "signature", 9: "unix_fds"}
    while at < end:
        at = (at + 7) & ~7
        if at + 3 > end:
            raise ValueError("truncated header variant")
        code, siglen = raw[at], raw[at + 1]
        if at + 3 + siglen > end:
            raise ValueError("truncated header signature")
        signature = raw[at + 2:at + 2 + siglen].decode("ascii")
        at += 3 + siglen
        if signature in ("s", "o", "u"):
            at = (at + 3) & ~3
            if at + 4 > end:
                raise ValueError("truncated header uint32 or string length")
            value = u32(at)
            at += 4
            if signature != "u":
                value_len = value
                if at + value_len + 1 > end:
                    raise ValueError("truncated header string")
                value = raw[at:at + value_len].decode("utf-8", "replace")
                at += value_len + 1
        elif signature == "g":
            if at + 1 > end:
                raise ValueError("truncated header signature length")
            value_len = raw[at]
            at += 1
            if at + value_len + 1 > end:
                raise ValueError("truncated header signature value")
            value = raw[at:at + value_len].decode("ascii", "replace")
            at += value_len + 1
        else:
            raise ValueError("unsupported header variant " + signature)
        result[names.get(code, "field_" + str(code))] = value
    result["parse_status"] = "complete-supported-fields"
    return result


def message(value, context):
    if value.is_optimized_out:
        emit("message_unavailable", context=context, reason="optimized out")
        return
    address = int(value)
    if not address:
        emit("message_null", context=context)
        return
    # Layout comes from the loaded exact-build-ID libdbus debug information.
    # Never guess offsets when debug types are absent.
    message_type = exact_type("DBusMessage")
    real_string = exact_type("DBusRealString")
    obj = value.cast(message_type.pointer()).dereference()
    data = obj["header"]["data"]
    string = data.address.cast(real_string.pointer()).dereference()
    length = int(string["len"])
    if length < 16 or length > 1048576:
        raise ValueError("invalid header buffer length")
    raw = bytes(gdb.selected_inferior().read_memory(int(string["str"]), min(length, 4096)))
    body_length, body_raw, body_error = None, b"", None
    try:
        body = obj["body"].address.cast(real_string.pointer()).dereference()
        body_length = int(body["len"])
        if body_length < 0 or body_length > 1048576:
            raise ValueError("invalid body buffer length")
        if body_length > 0:
            body_raw = bytes(gdb.selected_inferior().read_memory(int(body["str"]), min(body_length, 256)))
    except Exception as error:
        body_error = str(error)
    decoded_header, header_error = None, None
    try:
        decoded_header = header_fields(raw)
    except Exception as error:
        header_error = str(error)
    emit("held_message", context=context, address=hex(address),
         header_buffer_length=length, captured_header_bytes=len(raw),
         header_hex=raw.hex(), header=decoded_header, header_parse_error=header_error,
         header_capture_truncated=len(raw) < length,
         header_fields_complete=bool(decoded_header and decoded_header["header_fields_complete"]),
         body_buffer_length=body_length, captured_body_prefix_hex=body_raw.hex(),
         body_read_error=body_error, body_capture_truncated=body_length is not None and len(body_raw) < body_length,
         capture_partial=bool(header_error or len(raw) < length or body_error or
                              (body_length is not None and len(body_raw) < body_length)),
         provenance="stopped process memory; not a timestamped wire observation")


def connection(value, context):
    emit("connection_pointer", context=context, address=str(value))
    try:
        obj = value.cast(exact_type("DBusConnection").pointer()).dereference()
        conditions = {}
        for member in ("dispatch_cond", "io_path_cond"):
            cond = obj[member].cast(exact_type("DBusCondVar").pointer())
            conditions[member] = dict(address=hex(int(cond)),
                                      pthread_cond_address=hex(int(cond["cond"].address)) if int(cond) else None)
        emit("connection_wait_state", context=context, address=hex(int(value)), conditions=conditions,
             dispatch_acquired=int(obj["dispatch_acquired"]), io_path_acquired=int(obj["io_path_acquired"]),
             limitation="condition equality and acquired flags do not establish deadlock")
        CONNECTION_CONDITIONS.append((context, hex(int(value)), conditions))
        transport = obj["transport"].cast(exact_type("DBusTransport").pointer())
        qualified = module("libdbus")
        vtable = gdb.parse_and_eval("&'dbus-transport-socket.c'::socket_vtable")
        if vtable.type.target().strip_typedefs().unqualified() != exact_type("DBusTransportVTable").unqualified():
            raise ValueError("transport socket_vtable type mismatch")
        if int(vtable) != qualified["bias"] + 0x4d920:
            raise ValueError("file-qualified transport socket_vtable relocation mismatch")
        if int(transport["vtable"]) != int(vtable):
            raise ValueError("transport is not the qualified socket transport")
        socket_type = exact_type("DBusTransportSocket").pointer()
        fd = transport.cast(socket_type)["fd"]
        try:
            number = int(fd["fd"])
        except Exception:
            number = int(fd)
        emit("connection_socket", context=context, transport_address=str(transport),
             fd=number, socket_identity=os.readlink("/proc/%d/fd/%d" % (gdb.selected_inferior().pid, number)),
             vtable_address=hex(int(vtable)), provenance="qualified typed memory and contemporaneous /proc fd")
    except Exception as error:
        emit("connection_socket_unavailable", context=context, reason=str(error))


emit("snapshot_start", inferior_pid=gdb.selected_inferior().pid,
     inferior_calls=False)
try:
    qualify()
except Exception as error:
    QUALIFIED.clear()
    emit("qualification_unavailable", reason=str(error))
message_count = 0
for thread in gdb.selected_inferior().threads():
    try:
        thread.switch()
        frame = gdb.newest_frame()
        depth = 0
        while frame and depth < 64:
            name = frame.name() or ""
            if any(key in name for key in ("dbind_send_and_allow_reentry", "_atspi_dbus_get_property",
                                          "handle_get_bus_address", "handle_get_items",
                                          "impl_prop_GetSet", "impl_get_Name", "impl_GetItems",
                                          "process_deferred_messages", "dbus_connection_read_write_dispatch",
                                          "dbus_connection_dispatch", "_dbus_connection_acquire_dispatch",
                                          "_dbus_connection_acquire_io_path", "_dbus_condvar_wait",
                                          "_dbus_platform_condvar_wait", "pthread_cond_wait")):
                frame.select()
                location = frame.find_sal()
                emit("target_frame", thread=str(thread.ptid), depth=depth, function=name,
                     pc=hex(frame.pc()), source_line=location.line,
                     source_file=location.symtab.fullname() if location.symtab else None,
                     interpretation="Prove the PC is after the blocking-call assignment before treating ret as a received reply.")
                if not location.symtab or location.symtab.objfile not in [m["objfile"] for m in QUALIFIED.values()]:
                    emit("frame_locations_unavailable", thread=str(thread.ptid), depth=depth, function=name,
                         reason="frame DWARF is not owned by a qualified mapped module")
                    frame = frame.older()
                    depth += 1
                    continue
                for local in ("message", "msg", "reply"):
                    context = dict(thread=str(thread.ptid), function=name, local=local, depth=depth)
                    try:
                        value = frame.read_var(local)
                        if "DBusMessage" in str(value.type):
                            message(value, context)
                            message_count += 1
                    except Exception as error:
                        emit("local_unavailable", context=context, reason=str(error))
                # ret is assigned only after the closure loop; preserve it as a
                # raw local rather than treating a suspended value as a reply.
                if "dbind_send_and_allow_reentry" in name:
                    for local, type_name in (("closure", "SpiReentrantCallClosure"), ("pending", "DBusPendingCall")):
                        context = dict(thread=str(thread.ptid), function=name, depth=depth, local=local)
                        try:
                            value = frame.read_var(local)
                            kind = "libatspi" if local == "closure" else "libdbus"
                            obj = value.cast(exact_type(type_name, kind).pointer()).dereference()
                            fields = dict(address=hex(int(value)), reply_address=hex(int(obj["reply"])))
                            if local == "pending":
                                fields.update(reply_serial=int(obj["reply_serial"]), completed=int(obj["completed"]))
                            emit("reentrant_" + local, context=context, **fields)
                            message(obj["reply"], dict(context, candidate=local + "->reply"))
                        except Exception as error:
                            emit("reentrant_local_unavailable", context=context, reason=str(error))
                for local in ("cond", "condvar"):
                    context = dict(thread=str(thread.ptid), function=name, depth=depth, local=local)
                    try:
                        value = frame.read_var(local)
                        emit("wait_condition", context=context, address=hex(int(value)), type=str(value.type),
                             limitation="compare only to same-thread qualified connection condition addresses; no ownership inference")
                        WAIT_CONDITIONS.append((context, hex(int(value))))
                    except Exception as error:
                        emit("wait_condition_unavailable", context=context, reason=str(error))
                for local in ("app", "aobj", "unique_name", "destination", "dbind_timeout",
                              "name", "interface", "pathstr", "bus_name", "ret"):
                    try:
                        value = frame.read_var(local)
                        emit("local_value", function=name, thread=str(thread.ptid),
                             depth=depth, local=local, value=str(value))
                    except Exception as error:
                        emit("local_unavailable", function=name, local=local, reason=str(error))
                for local in ("connection", "bus", "app", "aobj"):
                    context = dict(thread=str(thread.ptid), function=name, local=local, depth=depth)
                    try:
                        value = frame.read_var(local)
                        if local in ("bus", "connection"):
                            connection(value, context)
                        else:
                            app = value if local == "app" else value["app"]
                            emit("application_connection", context=context, app_address=str(app),
                                 bus_name=str(app["bus_name"]), root=str(app["root"]))
                            connection(app["bus"], context)
                    except Exception as error:
                        emit("application_connection_unavailable", context=context, reason=str(error))
            frame = frame.older()
            depth += 1
    except Exception as error:
        emit("thread_partial", thread=str(thread.ptid), reason=str(error))

for wait_context, address in WAIT_CONDITIONS:
    for connection_context, connection_address, conditions in CONNECTION_CONDITIONS:
        if wait_context["thread"] == connection_context["thread"]:
            for member, candidate in conditions.items():
                emit("wait_condition_comparison", wait_context=wait_context, connection_context=connection_context,
                     connection_address=connection_address, member=member,
                     dbus_cond_equal=address == candidate["address"],
                     pthread_cond_equal=address == candidate["pthread_cond_address"],
                     limitation="address comparison only; nested calls remain distinct by depth; no ownership or deadlock inference")

try:
    module("libatk-bridge")
    bridge = gdb.parse_and_eval("spi_global_app_data")
    root = bridge["root"]
    cls = root.cast(exact_type("GTypeInstance", "libatk-bridge").pointer())["g_class"]
    atk_cls = cls.cast(exact_type("AtkObjectClass", "libatk-bridge").pointer())
    getter = atk_cls["get_name"]
    getter_address = int(getter)
    emit("root_identity", root_address=str(root), g_type=str(cls["g_type"]),
         get_name_address=hex(getter_address),
         get_name_symbol=gdb.execute("info symbol " + hex(getter_address), to_string=True).strip(),
         bridge_bus=str(bridge["bus"]))
except Exception as error:
    emit("root_identity_unavailable", reason=str(error))
emit("snapshot_end", message_candidates=message_count,
     limitation="Missing or optimized locals are partial evidence; no inference about pre-attach traffic.")
