"""Read stopped-process state only; never call a function in the inferior."""
import json
import struct

import gdb


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
    message_type = gdb.lookup_type("DBusMessage").strip_typedefs()
    real_string = gdb.lookup_type("DBusRealString").strip_typedefs()
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
        transport = value["transport"]
        socket_type = gdb.lookup_type("DBusTransportSocket").pointer()
        fd = transport.cast(socket_type)["fd"]
        try:
            number = int(fd["fd"])
        except Exception:
            number = int(fd)
        emit("connection_socket", context=context, transport_address=str(transport),
             fd=number, provenance="debug-type-based stopped-process memory; link to /proc/PID/fd")
    except Exception as error:
        emit("connection_socket_unavailable", context=context, reason=str(error))


emit("snapshot_start", inferior_pid=gdb.selected_inferior().pid,
     inferior_calls=False)
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
                                          "process_deferred_messages")):
                frame.select()
                location = frame.find_sal()
                emit("target_frame", thread=str(thread.ptid), depth=depth, function=name,
                     pc=hex(frame.pc()), source_line=location.line,
                     source_file=location.symtab.fullname() if location.symtab else None,
                     interpretation="Prove the PC is after the blocking-call assignment before treating ret as a received reply.")
                for local in ("message", "msg", "reply", "ret"):
                    context = dict(thread=str(thread.ptid), function=name, local=local, depth=depth)
                    try:
                        value = frame.read_var(local)
                        if "DBusMessage" in str(value.type):
                            message(value, context)
                            message_count += 1
                    except Exception as error:
                        emit("local_unavailable", context=context, reason=str(error))
                for local in ("app", "aobj", "unique_name", "destination", "dbind_timeout",
                              "name", "interface", "pathstr", "bus_name"):
                    try:
                        value = frame.read_var(local)
                        emit("local_value", function=name, thread=str(thread.ptid),
                             local=local, value=str(value))
                    except Exception as error:
                        emit("local_unavailable", function=name, local=local, reason=str(error))
                for local in ("bus", "app", "aobj"):
                    context = dict(thread=str(thread.ptid), function=name, local=local)
                    try:
                        value = frame.read_var(local)
                        if local == "bus":
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

try:
    bridge = gdb.parse_and_eval("spi_global_app_data")
    root = bridge["root"]
    cls = root.cast(gdb.lookup_type("GTypeInstance").pointer())["g_class"]
    atk_cls = cls.cast(gdb.lookup_type("AtkObjectClass").pointer())
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
