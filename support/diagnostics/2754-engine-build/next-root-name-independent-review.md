# Independent source-only review of root Name evidence proposal

Reviewed October 12, 2026: `/tmp/2754-root-name-symbol-next-source-proposal.md`, `/tmp/2754-root-name-birth-trace-topology.md`, and `/tmp/2754-next-root-name-discriminator-plan.md`, against retained run 38184349418 artifacts, extracted ELF/DWARF files, strace 6.8 source, and Ubuntu packaging patches. This review used file reads, hashing, and LLVM ELF/DWARF inspection. It ran no applications, builds, tests, script syntax checks, debugger inferiors, reproductions, or cloud workloads. It changed no repository files and grants no implementation or execution authorization.

## Review result

**Resolved P2: require exact installed strace binary identity before the birth cohort.** The initially reviewed consolidated plan required the expected package while only preserving actual hash/BuildID. I reported that package identity alone leaves source-supported daemon and signal behavior unqualified for a locally changed executable. Root revised line 36, and I reread it: the plan now requires package version plus ELF SHA-256 `28f957c227012de0b18d1bd7fff2d396cb693ea60ed8013be68de071e84b5001` and Build ID `997a6f079008c26efee890fe845f79aa76018ea4` before UI, retaining raw identity output. This closes the source-plan finding. Retained guest package records establish the old package version only; no old guest strace binary hash was established by this review.

No open P2 defect remains in the revised source-only proposal. This result does not approve an implementation that has not been supplied.

## Verified binary and symbol evidence

All entries in `qualification-artifacts.sha256` passed independent recomputation. The runtime manifest also passed when checked from `/tmp/2754-qualified-symbols`, its relative-path base. I independently recomputed the extracted debug ELF hashes and inspected their ELF Build IDs:

| Artifact | Verified Build ID | Verified SHA-256 |
| --- | --- | --- |
| Stock AT-SPI debug | `d53e3f4bf82655a42a0cb86c25416fd443ee76c6` | `dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9` |
| Stock D-Bus debug | `47829078e4267099473c6cf5f5742f16ccb2644d` | `f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899` |
| Retained A bridge debug | `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2` | `c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b` |

The independently hashed official AT-SPI runtime equals retained guest SHA-256 `4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141`; its Build ID matches the debug ELF. The official D-Bus runtime equals retained guest SHA-256 `a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413`; its Build ID matches the debug ELF. Both retained before/after `client/mapped-library.sha256` and `mapped-build-ids.tsv` support these guest identities. The retained before/after app Build ID files also identify the A bridge ID above. The bridge package hash independently matches `6649246a861cb349487376e7b672fa37d15902d3abef4632792a406f0765ec49`.

## Verified retained-PC conclusion

Before: `0x7d6cd360072e - 0x7d6cd35df000 = 0x2172e`. After: `0x7f8037f7172e - 0x7f8037f50000 = 0x2172e`. Retained executable map starts are respectively `0x7d6cd35ef000` and `0x7f8037f60000`, both at file offset `0x10000`. The exact runtime executable PT_LOAD has virtual address/file offset `0x10000`, yielding the stated load biases. Zero-offset maps independently agree. Both retained stacks contain this PC at depths 8 and 17, with the latter beneath `_atspi_dbus_get_property` and `atspi_accessible_get_name`.

Independent `llvm-addr2line` on the exact debug ELF maps `0x2172e` and `0x21729` to `dbind/dbind.c:102`. Exact runtime disassembly shows the five-byte call at `0x21729` to PLT `0x11890`, making `0x2172e` its return address. The PLT jumps through GOT `0x38af0`; relocation binds it to `dbus_connection_read_write_dispatch@LIBDBUS_1_3`. Reading the retained source identifies line 102 as the closure loop's dispatch call, while the other branch begins at runtime `0x21800`.

This supports branch attribution for the suspended caller frames. It does not prove a completed child call, wire serial, reply receipt, actual connection identity, or deadlock. The `ret` reply assignment follows loop completion; interpreting `ret` at the saved PC as an already received reply would be unsupported.

## Private type and memory-read limits

Direct DWARF inspection and the retained member dumps confirm concrete `DBusConnection` (264 bytes), `DBusCondVar` (48), `DBusTransport` (144), `DBusTransportSocket` (232), `DBusMessage` (184), `DBusPendingCall` (72), `DBusRealString` (24), and `DBusTransportVTable` (56). `DBusCondVar.cond` is a `pthread_cond_t` at offset zero; connection dispatch/I/O condition members are present. These definitions permit a typed condition-address comparison only after recovering the connection and waited object. Equality alone does not prove a deadlock.

AT-SPI has concrete `_AtspiApplication`, `_AtspiObject`, and `_SpiReentrantCallClosure` (8 bytes). `dbind_send_and_allow_reentry` spans `0x21640–0x21858`. At `0x2172e`, DWARF locates `bus` in RBX, `closure` in R12, and `pending` at CFA-relative offset -120. `message` uses an entry-value expression there. Symbol presence establishes available static layouts and locations, not successful runtime argument recovery by the chosen debugger. The planned static GDB qualification and explicit unavailable states remain necessary.

The A bridge debug ELF contains `_SpiBridge` (136 bytes), `spi_global_app_data`, `_GTypeInstance`, `_GTypeClass`, and `_AtkObjectClass` with `get_name`. Availability of these types does not establish the live root or function identity. Its use remains optional and requires mapped A identity qualification.

The existing `/tmp/localsend-bug-2754/support/diagnostics/2754-accessibility/root-name-gdb.py:114–116` casts a transport directly to `DBusTransportSocket` before reading `fd`. This remains an implementation gate: the consolidated plan expressly requires replacing it with identity validation. Exact DWARF contains transport `socket_vtable` at `0x4d920`, declared in `dbus-transport-socket.c`, and server `socket_vtable` at `0x4d980`, declared in `dbus-server-socket.c`. Only file-qualified transport identity, relocated using the qualified mapped module, supports this cast. A first-name lookup can choose the wrong symbol. Inferior getters or vtable function calls are outside the proposal.

## Verified strace source support and bounded remaining gates

The source archive and Ubuntu packaging archive independently match the stated SHA-256 values. The four packaging patches affect tests only. Retained guest package records identify `strace 6.8-0ubuntu2` before and after provision.

`startup_child` in `src/strace.c` sets PR_SET_PTRACER_ANY and lets the original PID execute `exec_or_die`; `startup_attach` double-forks, attaches from the daemon, then kills the intermediate process and resets `strace_child` to zero. `exec_or_die` waits for that intermediate child before exec. This supports a direct timeout child retaining its PID through client exec when the proposed direct invocation is used. Runtime starttime, executable, UID, and PPID checks must still establish ownership.

The `DAEMONIZE_NEW_PGROUP` branch calls `setpgid(0,0)`; the new-session branch calls `setsid()`. The manual agrees. Default daemon interrupt mode is 4 and ignores TERM. Explicit `-I2` installs `interrupt`; `terminate` invokes cleanup and flushes/closes output. Once `strace_child` is zero, cleanup's fatal-signal forwarding branch cannot match a live tracee PID. Cleanup can still interrupt/stop tracees while detaching and can wait indefinitely in source, so the independent grace/fallback and observed all-thread detach gate remain essential. Avoiding EXITKILL, seccomp-bpf, injection, and detach-on-exec preserves the proposed narrower lifecycle.

The consolidated wire/wait design keeps request identity dependent on complete Properties.Get headers and Accessible/Name body, connection generation, serial, and matching reply serial. It bounds message/aggregate/count sizes and treats gaps or truncation as partial evidence. Snapshot FD linkage requires recovered connection, validated socket transport, and contemporaneous socket identity. It does not infer consumption from read delivery or absence from finite silence. These are suitable acceptance requirements for a future decoder; no decoder implementation was reviewed or run.

Source supports the candidate topology, not runtime detach latency, trace preservation of the failure, or full wire reconstruction. Root approval is still required for the exact implementation scope; a separately reviewed concrete diff and separate cloud authorization remain outstanding.
