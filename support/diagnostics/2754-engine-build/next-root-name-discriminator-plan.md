# Next root Name discriminator: source-only implementation plan

This plan follows run 38184349418. No implementation or workload is authorized by this document. Root reviews this plan and the fresh independent static review before authorizing an exact implementation diff; cloud execution needs a separate authorization. No local apps, builds, tests, syntax execution, or reproductions were performed.

## Evidence and objective

Official exact stock debug packages are available. The qualified AT-SPI runtime ELF is byte-identical to the retained guest runtime. Both old dbind return PCs normalize to ELF 0x2172e, the return address following the closure-loop dbus_connection_read_write_dispatch call at 0x21729. This closes branch attribution only. Name message serial, reply history, nested connection identity, and wait ownership remain unknown. Exact symbols may still expose optimized-out locals.

The next discriminator will link positive wire facts from client birth to one pending public root Name call, then recover the stopped nested wait connection if qualified locations permit. It cannot establish normal latency or product acceptance. Existing untraced accepted-bundle records remain the behavior reference; tracing changes scheduling.

## Proposed source scope

| File | Responsibility |
| --- | --- |
| New accessibility/prepare-root-name-symbols-host.sh | Bounded official stock debug downloads, pinned hashes/IDs/package controls, extraction and static type qualification before VM scenario. |
| accessibility/prepare-root-name-symbols.sh | Replace guest debuginfod fetch with verification of transferred files and exact installed runtime identities; required failures stop before UI. |
| 2754-mint-vm.sh | Prepare on host, SCP separate debug directory/manifest, require guest gate, preserve preparation failure evidence. |
| accessibility/capture-geometry.sh | For the existing diagnostic flag only, launch unchanged client under timeout with direct strace -DD -I2; retain original 180s deadline and two geometry phases. |
| accessibility/capture-root-name-evidence.sh | Own birth tracer discovered through actual TracerPid, bounded collection and verified detach, then existing bounded parallel snapshots; remove late attach. |
| accessibility/root-name-gdb.py | Add exact per-depth closure/pending and libdbus wait/dispatch reads; validate transport vtable before socket cast; preserve unavailable states. |
| New accessibility/decode-root-name-transport.py | Offline bounded reconstruction of syscall bytes, FD generations, D-Bus Name request/reply identities, gaps and unknown states. No execution locally. |
| accessibility/README-root-name.md | Explain symbol/lifecycle/wire/wait gates, perturbation and collection-only outcomes. |

Workflow input and accepted cohort selection remain capture_root_name_evidence=true, AB-package only. No geometry fixture, validator, UI controls, app, bridge binary, engine, modal-close behavior or deadline changes are included. Existing validator and modal-close failures stay visible.

## Symbol gates

Pin official libatspi2.0-0t64-dbgsym 2.52.0-1build1 and libdbus-1-3-dbgsym 1.14.10-4ubuntu4.1 URLs, package SHA, debug SHA and BuildID from the qualification report. Require both exact runtime hashes/IDs in guest before UI. Download/extract only; never install or replace runtime libraries. Retained A bridge ddeb may provide optional app-side types only after its package/debug SHA and mapped bridge ID match.

Host retains URL, HTTP/exit status, bytes, package control, hashes, BuildIDs and finite debugger type inventory. Transfer only .build-id debug files and manifest. Required static GDB types are concrete DBusConnection, DBusCondVar, DBusTransport, DBusTransportSocket, DBusTransportVTable, DBusMessage, DBusPendingCall, DBusRealString and SpiReentrantCallClosure. GDB qualification loads files without an inferior. Debug download/type failure stops before UI. No debugger network fetch is allowed at attach.

Guest preserves canonical runtime path, package version, SHA and BuildID; each snapshot preserves maps and requalifies actually mapped files against manifest before memory interpretation. A replacement/deleted mapping, absent symbol or mismatch makes causal interpretation unavailable. No blind offsets or ABI-register reconstruction.

## Birth trace and lifecycle

Use source-qualified strace 6.8-0ubuntu2, require package version plus actual ELF SHA-256 28f957c227012de0b18d1bd7fff2d396cb693ea60ed8013be68de071e84b5001 and BuildID 997a6f079008c26efee890fe845f79aa76018ea4 before UI, and retain the raw identity output. Candidate direct invocation is timeout --kill-after=5s 180s strace -DD -I2 -f -ttt -T -yy -xx -s1048576 -o TRACE -e trace=FILTER CLIENT APP_PID LABEL. No sudo or intervening shell wrapper. The final trace filter must include socket/socketpair/connect, sendto/sendmsg/sendmmsg, recvfrom/recvmsg/recvmmsg, read/readv/write/writev, dup/dup2/dup3/fcntl/close/close_range/shutdown, poll/ppoll/select/pselect6/futex, process exec/exit events and relevant FD lifecycle events. Unsupported/missed IO remains a recorded gap. Capture raw authentication/bootstrap as well as binary traffic. Do not enable injection, seccomp-bpf, kill-on-exit or detach-on-exec.

An independent watcher starts before launch with a monotonic launch event. Resolve exactly one timeout direct child after exact client exec, with stable PID/starttime/PPID/UID. Resolve tracer from all live client task TracerPid values, require one owned exact strace PID/starttime and isolated PGID equal tracer PID, distinct from app/client/timeout groups. -DD keeps tracee timeout ownership; -I2 permits TERM cleanup. Daemon is not a waitable shell child.

Capture cutoff is 30s from launch. If verified root identity (GetProcessId equals app PID) reaches public GetName query_enter, keep 3s unresolved then detach; otherwise detach at cutoff and mark incomplete. Never hardcode call_id 50. If Name returns or client exits first, retain changed outcome and detach promptly. Client deadline remains 180s independently.

Before each signal recheck tracer PID/starttime/exe/PGID, including a post-exe stat recheck. TERM only verified tracer; allow up to 4s grace, then KILL only still-verified tracer. Retain signal outcomes. Do not signal client/app to detach. Prove actual tracer absent or same-identity zombie; inventory every client task twice and require TracerPid 0, stable client identity and non-stopped state. Ownership/detach uncertainty skips GDB. Outer cancellation and client exit invoke the same bounded tracer cleanup.

After detach, capture client and app under separate 12s +2s GDB bounds, with inferior calls/auto-load/debuginfod disabled. Verify GDB exit and all-thread final detach. Existing outer observer bound must cover discovery, 30s capture, 4s detach and snapshots without extending the query deadline.

## Stopped-memory linkage

Emit thread/depth/function/PC/source and availability for each dbind, property, dispatch/acquire-dispatch/condition-wait frame. Keep outer Name and inner state queries distinct. Record actual connection argument only where exact DWARF location succeeds. Compare wait condition object to that recovered connection dispatch_cond/io_path_cond using exact typed members. Condition/address equality alone is not proof of deadlock.

For closure branch read pending, closure, closure->reply and pending reply_serial/completed/reply where readable. Treat message candidates separately; do not interpret ret before loop completion as a reply. Read message headers/body with existing explicit byte caps. Transport FD requires file-qualified dbus-transport-socket.c socket_vtable identity at qualified ELF offset 0x4d920 and actual module bias; do not confuse server socket_vtable 0x4d980. Validate exact symbol and typed vtable before DBusTransportSocket cast. Do not call getters or vtable functions. No hash-table/queue traversal is proposed; pending objects reachable from proven frame locals suffice for this finite discriminator.

## Offline wire gate

Retain full raw strace. Decoder accepts only completed successful syscall bytes, accounts for short return counts, iovecs, unfinished/resumed records and per-direction streams. Track FD generations from socket/connect/dup/fcntl/close; reuse, gaps, unsupported syscalls and truncation invalidate completeness. Retain timestamp/PID/FD/socket and byte-range provenance for each reconstructed message. Bound per-message 1MiB, aggregate retained bytes 16MiB and message count 4096; exceeding bounds yields explicit partial status.

Parse D-Bus byte order, fixed header lengths, alignment, field variants and body signature. Require complete Properties.Get header/root path plus complete body org.a11y.atspi.Accessible and Name, nonzero serial and matching connection generation. Match return/error reply_serial on that same connection. Kernel-to-client read bytes prove delivery, not wrapper consumption. No reply in a finite/gapped capture stays unknown. Header-only or printable text matches do not establish Name identity.

Join wire socket/FD generation to snapshot connection->validated transport FD and contemporaneous /proc socket identity. If the connection or FD changed, or location/stream is partial, output positive observations separately and causal linkage unknown. Every result remains collected-only; geometry success requires original strict independent gate.

## Review and execution gates

Before root authorization, supply exact diff, hashes, static manual source inspection and independent review with max-priority P2. No local script execution is used to qualify it. Any later authorized Actions job must qualify runtime/tool/symbol gates and archive their raw outputs before the UI scenario. One cloud job maximum, no automatic retries. A trace-changed behavior or unrecoverable connection leads to a bounded partial report, not expansion of workload.
