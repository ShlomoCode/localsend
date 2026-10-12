# Retained GDB audit: run 38192568168

The two client snapshots recover a complete root Accessible/Name request (serial 2) and an incomplete nested GetState request (serial 3) on the same actual DBusConnection. The client is stopped inside recursive dispatch acquisition while a same-thread outer dispatcher is executing the GetItems completion callback on that connection. This identifies a client-side dispatch stall in this traced cohort. It does not establish the cause of the reporter's application failure, normal untraced behavior, or whether the Name reply reached the socket.

The planned connection-to-FD link failed because GDB could not take the address of the file-qualified transport `socket_vtable`. This is an evidence-collector failure, not evidence that the runtime transport has the wrong vtable.

## Scope and artifact identity

Audited completed run `38192568168`, requested head `8218af015ceff59e9e9587d79bde6d688b16bd11`. All inspection used retained files, source reads, and hashes. No app, script, syntax check, test, build, debugger inferior, network request, cloud workload, or retry was run. The only write is this report.

Evidence base `E` is `/tmp/2754-packaged-38192568168-compact/comparison/AB-package/guest/geometry-post-timing`. Paths below are relative to `E` unless stated otherwise. The full download has byte-identical GDB text files:

| Snapshot | SHA-256 of gdb.txt |
| --- | --- |
| before/client | `d05e013952b6418323c4c0b4e0ddf9881da0d7c73404428659b570cf1d8fd026` |
| before/app | `71667e6980ca13d322f7e4b50a4dd4ab4e29019582fe30ca435dcd45686bc203` |
| after/client | `be484109afdc71f74dabb2efdbd9dbaab891a01cb3bd3d2edbfcde9000bae939` |
| after/app | `cca702000d1b2ba6dbc37184c32f79c22ceb70e7743b0c9437a6177445478c98` |

Each snapshot's `gdb.exit-status` is 0, and each GDB text ends with its inferior detached. The stderr files contain missing libc source-file warnings, not a top-level Python failure. A successful GDB process does not mean every read succeeded: unavailable states appear in the JSON records.

## Runtime and mapped-inode compatibility

Guest `root-name-symbols/manifest.tsv`, `runtime-elf.sha256`, the snapshot `mapped-library.sha256` and `mapped-build-ids.tsv` agree on these identities:

| Runtime | Build ID | SHA-256 |
| --- | --- | --- |
| libatspi.so.0.0.1 | `d53e3f4bf82655a42a0cb86c25416fd443ee76c6` | `4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141` |
| libdbus-1.so.3.32.4 | `47829078e4267099473c6cf5f5742f16ccb2644d` | `a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413` |
| app libatk-bridge-2.0.so.0.0.0 | `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2` | `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297` |

Both clients map AT-SPI inode 37686 and D-Bus inode 37920 on device `00:1d`. The app maps those same inode identities and bridge inode 9682. None of those library mappings is marked deleted. Other deleted app mappings are shared memory and dconf files, not the qualified libraries.

GDB `module_qualified` records agree with the maps: client-before AT-SPI bias `0x7ba6ec413000`, D-Bus `0x7ba6ec006000`; client-after AT-SPI `0x715dd0b04000`, D-Bus `0x715dd06f7000`; both app snapshots AT-SPI `0x7b9e2b017000`, D-Bus `0x7b9e2afc8000`, bridge `0x7b9e2b51a000`. These records are backed by the collector's checks at the requested head: it hashes `/proc/PID/map_files/<range>` and the runtime path, hashes the debug file, verifies its loaded objfile Build ID and path, and requires the offset-zero mapping. Thus qualification success supports mapped-inode compatibility; it is not based only on a library-name label. This audit did not rerun those guest checks or independently read the now-gone guest inode.

The client does not map the bridge, so its `root_identity_unavailable` is expected. The app does qualify the retained A bridge.

## Concrete client state

Before client PID 5772/starttime 58342 and after client PID 8114/starttime 76356 are separate invocations. App PID 4736/starttime 11784 persists. The one client thread listed in each snapshot is its main thread. `root-query-enter.json` records public GetName on `:1.29` and `/org/a11y/atspi/accessible/root` at about 93 ms before and 73 ms after. The identity and serial findings below come from complete stopped-memory bytes, not that label alone.

| Recovered state | Before | After |
| --- | --- | --- |
| actual app-specific DBusConnection | `0x5deb85f07cd0` | `0x5fb3dbf36f20` |
| connection dispatch_cond | `0x5deb85f076d0` | `0x5fb3dbf36830` |
| connection io_path_cond | `0x5deb85f06c10` | `0x5fb3dbf24030` |
| dispatch_acquired / io_path_acquired | 1 / 0 | 1 / 0 |
| outer Name message | `0x5deb85ee3fe0` | `0x5fb3dbf3f990` |
| outer pending, depth 27 | `0x5deb85f08ee0` | `0x5fb3dbf46140` |
| outer closure, depth 27 | `0x5deb85f08f70` | `0x5fb3dbf461d0` |
| nested GetState message, depth 12 | `0x5deb85ede930` | `0x5fb3dbf3fab0` |
| nested pending, depth 12 | `0x5deb85f0a840` | `0x5fb3dbf47970` |
| nested closure, depth 12 | `0x5deb85f0a820` | `0x5fb3dbf3fa90` |

The outer message at depth 28 has complete 136-byte header and complete 41-byte body (`gdb.txt:724` in each client). It is Properties.Get, root path, destination `:1.29`, serial 2, signature `ss`. Its body contains the terminated strings `org.a11y.atspi.Accessible` and `Name`. The outer pending has `reply_serial=2`, `completed=0`, `reply=NULL`; the outer closure has `reply=NULL` (`gdb.txt:701–704`). This establishes that the suspended wrapper has not completed its Name reply handling at the snapshot. It does not establish that no Name reply was sent or read.

The inner message at depth 12 is complete GetState for `/org/a11y/atspi/accessible/3`, destination `:1.29`, serial 3, no body. Its pending has `reply_serial=3`, `completed=0`, `reply=NULL`, and its closure reply is NULL (`gdb.txt:554–560`). It is a different request from the root Name query.

`handle_get_items` at depth 19 holds a method return with `reply_serial=1`. Its 1188-byte body capture is truncated to 256 bytes. This is the cache/GetItems completion being processed; it is not the Name reply or GetState reply (`gdb.txt:582`). No recovered held message has reply_serial 2 or 3.

The collector also prints `bus` values in frames where no such argument exists. Retained AT-SPI source declares a file-static `bus` at atspi-misc.c:186, and `frame.read_var` can resolve static/global symbols. These values are not proof of a per-frame connection argument. In particular, `0x5deb85ed9a30` before and `0x5fb3dbf16a30` after have dispatch_acquired=0 and are distinct from the app-specific connection. The audit uses the actual `connection` parameter in dispatch frames, the actual `bus` parameter in each dbind frame, and `aobj->app->bus` for the Name object.

## Exact stopped path and supported stall mechanism

Both dbind caller depths 12 and 27 normalize to AT-SPI ELF PC `0x2172e`: before `0x7ba6ec43472e - 0x7ba6ec413000`, after `0x715dd0b2572e - 0x715dd0b04000`. Retained exact symbols/instructions locate this at dbind.c:102, immediately after the dispatch call in the closure loop. `ret` remains optimized out; the assignment from closure->reply is after the loop at line 120.

The recovered same-thread stack has these nested steps:

1. Outer Name dbind closure loop, depth 27, calls read_write_dispatch on the app-specific connection.
2. Outer dbus_connection_dispatch, depth 23, is suspended at dbus-connection.c:4663 inside `complete_pending_call_and_unlock` for the GetItems pending call.
3. `_dbus_pending_call_finish_completion` invokes `handle_get_items`, which calls `add_accessible_from_iter`, `atspi_state_set_contains`, `refresh_states`, and the synchronous GetState dbind operation.
4. Inner read_write_dispatch enters dbus_connection_dispatch and `_dbus_connection_acquire_dispatch` at depths 8/7 on the same recovered connection.
5. `_dbus_connection_acquire_dispatch` waits while `dispatch_acquired` remains true. Exact qualified source at lines 4149–4155 passes this connection's dispatch_cond to `_dbus_condvar_wait`.

Exact libdbus source at 4601–4614 acquires the dispatcher before selecting/dispatching a message; the pending-call branch at 4663 invokes its callback before going to `out`; `_dbus_connection_release_dispatch` occurs only later at line 4873. `complete_pending_call_and_unlock` at 2333–2345 drops the main connection lock before invoking the callback; it does not release the separate dispatcher. Thus the callback is trying to acquire the same dispatcher before its outer invocation can return and release it. The source and actual same-connection stack establish the client recursive dispatch-acquisition stall; acquired-flag equality alone would not.

Raw libc frames report pthread_cond_wait condition `0x5deb85f076d0` before and `0x5fb3dbf36830` after, numerically equal to the qualified connection's dispatch_cond; the futex word is respectively `...76f8` and `...6858`. The collector refuses libc frame locations because libc is outside its exact module gate, and the libdbus cond locals are optimized out. Therefore there is no emitted qualified wait_condition_comparison. The strongest wait identification comes from the recovered connection parameter plus exact libdbus source branch, with the raw libc equality as supplementary evidence.

The inner dbind timeout is checked after read_write_dispatch returns. The wait reached here is the unconditional `_dbus_condvar_wait`, not a timed condition wait. The retained state therefore explains how the client can remain inside a public query beyond that intended timeout. This does not measure untraced latency or authorize a production fix.

## App-side limits

Both app snapshots are in the GLib poll/main-loop path, with no recovered held-message candidates. The bridge root is `0x5e8c71750e90`, bridge bus `0x5e8c717570f0`, and root get_name function pointer `0x7b9e2ca55b60` in both snapshots (`before/app/gdb.txt:2562`, `after/app/gdb.txt:2560`). GDB reports no symbol for that getter. Maps place it in the executable GTK mapping, not Flutter's mapping, at GTK ELF offset `0x40db60` from bias `0x7b9e2c648000`. This establishes module containment, not an exact getter function identity or evidence that it ran for this request. No app-side Name handler or Name reply is recovered from these snapshots.

## Transport failure and minimal supported discriminator

Every client connection FD attempt fails at the requested head's expression `gdb.parse_and_eval("&'dbus-transport-socket.c'::socket_vtable")`, with `Can't take address of "socket_vtable" which isn't an lvalue.` The subsequent exact type comparison, relocated-address comparison, transport->vtable equality, DBusTransportSocket cast, and FD read never execute. Therefore neither socket transport identity nor connection-to-FD linkage was recovered. The many fd-links socket entries do not select the right connection by themselves.

This error establishes that the expression result was not addressable in this GDB session. It does not establish why GDB exposed it that way, that GDB selected the server vtable, or that the actual transport value mismatched. Replacing the expression with an unqualified symbol lookup or simply accessing `.address` on the same non-lvalue would not close that gap.

The independent retained exact DWARF dump `/tmp/2754-qualified-symbols/dbus-transport-vtable.txt` already proves transport `socket_vtable` has concrete `const DBusTransportVTable` type, is declared in dbus-transport-socket.c:1269, and has `DW_OP_addr 0x4d920`. The separate dbus-server-socket.c symbol has `DBusServerVTable` type at `0x4d980`. Mapped runtime/debug SHA and Build ID establish that these exact locations apply to the guest's stock D-Bus module. Derived transport-vtable addresses would be `0x7ba6ec053920` before and `0x715dd0744920` after; no value was read from either address in this audit.

A minimal future collector correction can keep the exact runtime/debug checks and the independently qualified file/type/DWARF location, construct the expected address from qualified module bias + the proven `0x4d920` location, and compare the live typed transport->vtable pointer to that exact address before allowing the socket cast. The expected address must be represented as an integer-to-qualified-vtable-pointer `gdb.Value` so it does not depend on the failed symbolic unary-address operation. File/type/location qualification must remain an explicit gate; this is an exact pinned DWARF location, not a guessed structure offset. Preserve symbolic `.address` recovery as a separately available/unavailable observation. If those checks succeed, read only the qualified socket FD and contemporaneous `/proc/PID/fd` identity, then join to the retained trace's matching generation. This proposal has not been edited, executed, or validated here.

If a future change instead enumerates GDB static symbols, it must require exactly the transport file and exact objfile/type, keep the server symbol separate, and treat `symbol.value().address` as unavailable when GDB still provides a non-lvalue. The existing error gives no basis to promise that this alternative alone will succeed.

Remaining blocker: the stopped-memory snapshot cannot currently select a trace FD generation, so its actual connection address cannot be conclusively joined to a trace FD. During this audit, the parent reported that the independent wire helper manually validated complete Name request and method return reply_serial 2 on before FD 26 and after FD 16, with variant value `org.localsend.localsend_app`, followed by nested GetState serial 3 and a futex wait. That separate positive result establishes Name delivery within each trace despite decoder partial status; it is not evidence that the Name closure consumed the reply. This report does not claim to have independently parsed those trace bytes. The source-supported same-thread recursive dispatch stall is already established from the retained client state and exact source, so another environment is not required to identify that mechanism. The FD join remains a narrower collection gap. The geometry gate and the reported bug's supported-use-case reproduction remain separate requirements.
