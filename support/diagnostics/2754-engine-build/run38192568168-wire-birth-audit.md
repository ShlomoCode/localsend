# Run 38192568168 birth-wire and cleanup audit

Both retained phases contain positive evidence that the client sent the PID-qualified public root Name request and received a complete matching reply before entering a nested GetState wait. The public GetName wrapper still did not return before the original 180-second deadline. The observer lifecycle completed within its bounds in both phases. The remaining missing discriminator is the qualified transport FD for the recovered nested/outer connection, plus a controlled intervention that tests the reentrant dispatch explanation.

This audit reads existing evidence only. No source edits, scripts, syntax checks, tests, builds, inferiors, network requests, cloud jobs, or retries were executed. The LocalSend lifecycle and NBJ writing skills were applied. The retained directory is `/tmp/2754-packaged-38192568168-compact/comparison/AB-package/guest/geometry-post-timing`; paths below are relative to that directory. The parent identifies run head as `8218af...`; this audit does not independently establish the full head SHA.

## Public and wire correlation

Both JSONL records first identify bus `:1.29`, path `/org/a11y/atspi/accessible/root`, by GetProcessId call 47 returning app PID 4736. Both then clear the cache and enter public GetName call 50. Entry occurs at 93.037 ms before and 72.973 ms after. Neither JSONL has a matching public return. Both end with process_exit status 124 and deadline_hit true.

The raw trace independently supplies the full Name identity and matching reply:

| Evidence | Before | After |
| --- | --- | --- |
| Client PID | 5772 | 8114 |
| Name send | transport.strace line 849, 1791769917.404263 | line 866, 1791770097.521876 |
| Name FD/socket | FD 26, UNIX-STREAM:[27995->27999] | FD 16, UNIX-STREAM:[31007->31011] |
| Successful send count | 177 bytes, iovecs 136 + 41 | 177 bytes, iovecs 136 + 41 |
| Reply receive | line 852, 1791769917.406196 | line 869, 1791770097.523544 |
| Successful receive count | 1312 bytes | 1312 bytes |
| Nested GetState send | line 857, 1791769917.406525 | line 874, 1791770097.523889 |
| Last traced wait | line 858, futex 0x5deb85f076f8 | line 875, futex 0x5fb3dbf36858 |

The Name packet is little-endian D-Bus protocol 1, type 1, serial 2, body length 41, fields length 120. Its header contains destination `:1.29`, the root path, interface `org.freedesktop.DBus.Properties`, member `Get`, and signature `ss`. The complete body contains `org.a11y.atspi.Accessible` and `Name`. Both successful send counts cover every printed byte.

The 1312-byte receive coalesces two complete messages. The first is a 1244-byte GetItems reply (56-byte aligned header + 1188-byte body), reply_serial 1. The final 68 bytes are a separate type-2 method return with serial 2, reply_serial 2, signature `v`, and a 36-byte body. The body contains a string variant whose 27-byte string is `org.localsend.localsend_app`. The final packet starts `6c02010124000000020000000f000000`, and its reply field starts `0501750002000000`. These facts are visible in the raw receive, independent of the decoder's overall partial status.

The request and reply use the same unchanged socket annotation and FD between successful send and receive. Therefore the narrow claim “a matching root Name reply was delivered to this client's userspace receive buffer” is supported. This does not prove that the public wrapper consumed the reply, that its pending-call callback completed, or that the stopped connection pointer has been joined to this FD. A serial-only match across different connections would be invalid; that error is avoided by the raw same-socket sequence here.

After receiving those bytes, the same client sends a 136-byte serial-3 `org.a11y.atspi.Accessible.GetState` request for `/org/a11y/atspi/accessible/3` on that socket. It then enters a futex wait with no timeout argument and the trace ends with `<detached ...>`. No subsequent successful client receive is retained. That finite observation does not establish that the peer failed to reply, that no reply reached the kernel socket, or that no traffic occurred after detach.

## Stopped evidence and limits

The exact AT-SPI and libdbus runtime modules qualify in both client snapshots. The before stack recovers the dispatch/acquire-dispatch connection as `0x5deb85f07cd0`; its dispatch_cond is `0x5deb85f076d0`, matching the pthread condition shown in the wait frame. The after equivalents are connection `0x5fb3dbf36f20` and dispatch_cond `0x5fb3dbf36830`. The retained dispatch_acquired flag is 1 and io_path_acquired is 0 for those actual connections. A different globally resolved `bus` pointer appears throughout many frame reads with acquired flags 0; it must not replace the actual frame's connection argument.

Both snapshots retain inner serial-3 pending objects completed=0/reply=null and outer serial-2 pending objects completed=0/reply=null, with both closure replies null. They also retain the complete outer Name message and inner GetState message. Before, handle_get_items holds the cache reply_serial-1 message on the same call stack. These observations support a nested dispatch wait while the outer Name reply remains unconsumed by its pending object. The wire's Name delivery and the pending object's lack of completion are compatible observations.

The helper could not qualify the socket cast: connection_socket_unavailable reports `Can't take address of "socket_vtable" which isn't an lvalue.` Consequently this audit does not claim a direct stopped-pointer-to-wire-FD join. Condition equality and acquired flags alone are insufficient to establish a deadlock or assign a product fix.

## Decoder audit

Both decoders exit 0 but report status partial, retain 23614 bytes, and emit 150 messages. Both contain one root_name record with status delivered-reply-observed, matching the raw serial-2 packets above. The root connection is decoder connection 24 before and 14 after; its number changes because discovery order changes. Both root streams are marked partial.

Seven recorded gaps appear in each phase. Six concern the initial X11 socket, not the root Name socket: line 68 reports a 1MiB message bound, and lines 83, 94, 100, 106, and 112 report partial/unavailable iovecs. Raw line 68 is an X11 setup request to `/tmp/.X11-unix/X0`, which begins with byte `l` and is being considered as a D-Bus header. Several later X11 writev records include a NULL iov_base with iov_len=0 and complete successful byte counts. These are parser/protocol-classification limitations, not evidence that the Name packet exceeded 1MiB or was truncated.

The seventh gap is the final detached futex record (before line 858, after line 875). The possible-truncation marker file likewise contains that `<detached ...>` record. It is a trace cutoff, not a truncated successful Name send/receive payload. The decoder poisons streams conservatively after this unparsed record, so overall stream completeness and absence claims remain unavailable. Positive earlier complete packets can still be checked independently as above.

## Observer ownership, timing, and detach

The birth trace begins with the exact geometry-client execve (before line 1, PID 5772). Ownership records identify the actual tracer from the client's task TracerPid. Before tracer PID/PGID is 5777, starttime 58343; after it is 8120, starttime 76356. Both are `/usr/bin/strace`, UID 1000, PPID 1, in their own process groups. Reparenting to PID 1 is expected for the daemon and was not mistaken for a waitable shell child.

Before, root entry is detected at 01:51:57.451261234Z and the unresolved gate completes at 01:52:00.504656251Z. The sole recorded tracer signal is PID-only TERM to 5777 at 01:52:00.558896297Z, exit status 0. Actual exit and repeated all-thread detach are recorded at 01:52:01.273676522Z. After, the corresponding times are entry 01:54:57.573778969Z, gate 01:55:00.618394493Z, TERM to 8120 at 01:55:00.673825376Z, and verified detach 01:55:01.399834278Z. Both retain more than three seconds unresolved before detach, terminate without KILL within the four-second grace, and finish well before the 30-second capture cutoff.

Each phase retains two before-GDB and two after-GDB inventories of the client plus 26 app threads, 27 entries per pass. Across both phases, all 216 entries have TracerPid 0 and state S or R, never stopped/zombie. The inventories retain thread starttimes. All four GDB wrapper statuses are 0, registered actual debugger processes are recorded not alive at cleanup, and both watcher exits are 0. Before snapshots span approximately 01:52:01.482–01:52:03.135Z; after snapshots span 01:55:01.606–01:55:03.217Z, within separate 12+2-second bounds. Neither phase exercised cancellation, identity reuse, pre-exec helper KILL, or unknown-owner fallback. Those branches cannot be runtime-qualified from this run.

Both result.json files correctly remain collected-only, collection_status partial, causal_success false. The original public-client deadline remains visible as status 124 in both phases. No geometry success or normal latency conclusion follows from the observer's successful cleanup.

## Next discriminator

First recover the existing connection-to-socket join through a bounded source correction to the helper's file-qualified socket_vtable address lookup. Use the already qualified libdbus ELF symbol and module bias, retain the actual transport vtable value, and require equality before interpreting the typed socket FD. Do not bypass the gate with a guessed offset or inferior getter. This would distinguish whether the nested acquired-dispatch connection is the wire socket already shown above.

The positive reply delivery means an experiment that only waits longer for a root Name response would not distinguish the remaining explanations. The next controlled behavioral comparison should target the demonstrated GetItems callback -> refresh_states -> nested GetState -> acquire_dispatch path on the same connection, while retaining the same package, public client, cache state and deadline. Exact responsible AT-SPI/libdbus source and a supported mechanism must determine the intervention before execution is proposed. A fix is not yet attributed by this audit. No further workload or retry is authorized here.

## Evidence hashes

- Before transport.strace: `b626452da954962f7cb5bd67a05e4744542e4a0c9f117d183036098da7890308`
- Before transport-decoded.json: `3395021c91e7ffbc7bb4289f1a220c49e1e0b3b44104712966d0fd54967ab554`
- After transport.strace: `4ed4af55215c7f54117cf66e42146992d7f809ec57854eab52958c88b9bbecf3`
- After transport-decoded.json: `293eb670a3aa2e8fed553ea6ed7d6411a2f1fb60d2dfea74fd8744b48ba62236`
