# Independent raw root Name evidence audit — run 38184349418

## Disposition

**The strict causal Name discriminator remains unknown in both before and after.** The artifacts establish an outstanding root `atspi_accessible_get_name` call with nested D-Bus dispatch and an inner state-set query waiting in libdbus. They do not identify the actual root `Properties.Get(org.a11y.atspi.Accessible, Name)` wire message, its request serial, a matching reply_serial, or the wait frame's actual DBusConnection/FD. They therefore establish neither “GTK did not reply” nor “Name reply arrived and the client stalled only while draining dispatch.”

This agrees with both collectors' honest `result.json`: `collected-only`, partial collection, observer_exit 0, linkage unknown, causal_success false, post-attach-only incomplete stream. A successful observer exit is not causal success.

Scope: read-only artifact/source review, no edits to code, no execution/reproduction/dispatch/retry. Only this report was written.

## Artifact references

Evidence base `G`:
`/tmp/2754-packaged-38184349418-compact/comparison/AB-package/guest`

`B = G/geometry-post-timing/root-name-evidence-before`
`A = G/geometry-post-timing/root-name-evidence-after`

Full artifact is also retained at `/tmp/2754-packaged-38184349418-full`; the compact raw collector files above were used for the observations below.

## Positive stack evidence and its limits

Both root-query-enter.json records identify `query_enter`, GetName, call_id 50, bus `:1.29`, path `/org/a11y/atspi/accessible/root`; since_start_ms is 11.399 before and 14.199 after. Both use app PID 9207/starttime 18446, executable `/home/mint/source-bundle/localsend_app`. The clients differ: before PID 10207/starttime 65014; after PID 10783/starttime 83020, executable geometry-client.

Both client/gdb.txt stacks (approximately lines 240–275) positively show:

```
#4 pthread_cond_wait
#5 unknown libdbus
#6 dbus_connection_dispatch
#7 unknown libdbus
#8 dbind_send_and_allow_reentry
#9 dbind_method_call_reentrant_va
#10 _atspi_dbus_call
#11 atspi_state_set_contains
#12/#13 unknown libatspi
#14 unknown libdbus
#15 dbus_connection_dispatch
#16 unknown libdbus
#17 dbind_send_and_allow_reentry
#18 _atspi_dbus_get_property
#19 atspi_accessible_get_name
#20 walk(a=..., depth=0), geometry-client.c:122
```

The walk key matches the root identity. Thus the root Name API has not returned at the snapshot, and a nested state-set call exists inside outer dispatch. This is stronger evidence than merely “client blocked.” It does not establish the root Name reply state.

Generated target-frame records around lines 310–363 retain PCs but no source location: before dbind depths 8/17 both PC 0x7d6cd360072e, property PC 0x7d6cd35f9964; after dbind depths 8/17 both PC 0x7f8037f7172e, property PC 0x7f8037f6a964. All have source_file null/source_line 0. `message`, `msg`, `reply`, `ret`, `bus`, `app`, `aobj`, `unique_name`, and `destination` are unavailable; message_candidates is 0. The fallback `name` value of repeated NULs is not an identified Name request/property and cannot substitute for message headers. Locals belonging to later walk statements are also not proof of returned values while the call at line 122 is outstanding.

The available 2.52.0 source at `/tmp/2754-packaged-38177219980-full/package/build/work/at-spi2-core-2.52.0/dbind/dbind.c` explains two candidate paths. Lines 63–89 assign `ret = dbus_connection_send_with_reply_and_block(...)` on the different-unique-name branch and then may drain dispatch with an in_dispatch guard. The subsequent branch uses pending-call closure and `dbus_connection_read_write_dispatch` when unique_name/destination conditions do not select that branch. A private connection with null unique_name is a plausible candidate for the latter path and permits nested dispatch. **This is source-level possibility, not an established executed branch:** these records lack exact runtime source/PC mapping and connection/local values. In particular the equal dbind PCs and two dispatch frames must not be interpreted as proving both calls completed send_with_reply_and_block or that `ret` holds a Name reply.

App main-thread snapshots are idle poll: B/app/gdb.txt lines 2568–2579 and A/app/gdb.txt approximately 2566–2577 show poll(nfds=6, timeout=-1), GLib, g_main_context_iteration, g_application_run, main. They do not show a Name callback executing. This point-in-time state says nothing decisive about a prior callback or prior reply delivery. `spi_global_app_data` root identity extraction fails with unknown type; app message_candidates is 0.

## Symbols

G/root-name-symbols/runtime-packages.txt records libatspi 2.52.0-1build1, libdbus 1.14.10-4ubuntu4.1, GTK 3.24.41-4ubuntu1.3. All three required symbol downloads failed with curl 28; symbols.tsv rows 2–4 retain Build IDs:

- libatspi: d53e3f4bf82655a42a0cb86c25416fd443ee76c6; operation timed out after 45002ms, zero bytes.
- libdbus: 47829078e4267099473c6cf5f5742f16ccb2644d; connect timeout after 10002ms.
- GTK: e3bf6367082e76a6e85218c0a84a5a0e29af05b1; SSL connection timeout.

Symbol preparation process exit 0 means partial metadata was produced, not that debug symbols were available. G/root-name-symbols/result.json correctly says partial.

## Transport and actual private peer sockets

Before unix-connections.txt lines 454/462 establish reciprocal private UNIX stream sockets: geometry-client PID 10207 FD 22 socket 31255 ↔ LocalSend PID 9207 FD 33 socket 31262, named at `/run/user/1000/at-spi2-CEQRW3/socket`. Queues at that snapshot are client Recv-Q 44, app Send-Q 768. Those queue counts are not decoded Name messages.

After unix-connections.txt lines 450/489 establish geometry-client PID 10783 **FD 25** socket 32457 ↔ LocalSend PID 9207 FD 33 socket 32459, same named socket; both queues 0. A/client/fd-links.txt line 20 independently maps FD 25 to socket 32457. Before and after therefore do have retained actual private client/app peer connections. Without the wait frame's DBusConnection pointer/FD or request bytes these cannot be declared the actual Name wait connection.

Both straces attached app and client, but contain zero lines with either client PID. There are also zero syscall lines invoking `(33<` or `(34<` across both traces; these descriptors appear in app poll sets (e.g. B/transport.strace line 5). Most byte-bearing app traffic is on FD 7 socket 24250→25018 with X11-style 32-byte messages, and must not be mistaken for D-Bus.

The capture starts about 3.28s after root query entry and lasts approximately 8s. No pre-attach bytes are available. No request serial/reply_serial chain is recovered; absence of client syscalls or private socket IO during this window does not prove absence of an earlier reply or request. Each global-bus-monitor.txt is only seven lines, containing its own NameAcquired/NameLost and registry EventListenerDeregistered, before monitor :1.34 and after :1.36. These global monitor records do not cover private peer traffic.

The collector uses a 65536-byte string limit and flags possible truncation. transport-possible-truncation.txt contains many normal unfinished/resumed strace markers; their presence alone does not prove a payload hit the byte limit. The explicit incomplete-stream limitation remains valid regardless.

## Tracer detach, debugger order, and cleanup

Before timeline.tsv records attach 23:41:44.816931746Z, wrapper completion status 124 at 23:41:52.838153134Z, independent actual tracer exit/all-thread detach verification at 23:41:52.952184661Z (actual strace PID 10397), then parallel GDB 23:41:52.957232965Z–23:41:54.328308379Z.

After records attach 23:44:44.857154669Z, wrapper status 124 at 23:44:52.876733913Z, independent verification at 23:44:52.992199862Z (strace PID 10971), then GDB 23:44:52.997189588Z–23:44:54.417849609Z. Thus ordering is supported by retained evidence, rather than inferred from timeout wrapper exit alone.

Each tracer-detach-check.tsv contains 28 recorded task checks, all TracerPid 0 (zero bad/unknown records). transport.stderr names app/client attach and individual detach records. This corroborates detachment for the recorded live task snapshot; it does not prove an invariant for every task throughout capture.

Both watcher-exit.json are status 0; both GDB timeout-wrapper waits are 0, trace waits 124, global monitor waits 143. The only cleanup signals actually sent are TERM to recorded global-monitor process groups -10358 before and -10933 after, each rc 0. Other recorded identity checks skip exited/absent/changed PIDs, and actual strace/GDB grandchildren are explicitly recorded not alive. cleanup.stderr is empty in both phases, with no cleanup_exit_unverified marker. This supports successful cleanup for the retained observer identities; no blanket assertion about unrecorded processes is needed.

## Consumer gate

Accept the artifacts as a partial, bounded observation with trustworthy explicit limits and corroborated observer detach/cleanup. Reject any causal consumer assertion that Name reply was absent, that GTK blocked in its Name callback, or that Name reply was definitely assigned before dispatch. The strongest supported finding in **both** phases is the same root GetName → outer dispatch → nested state-set call → inner dispatch → libdbus condition-wait structure. The missing serial/connection/PC linkage remains material.
