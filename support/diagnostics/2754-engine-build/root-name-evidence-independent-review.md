# Independent root-name evidence source review

Final source review: the recorded blockers below were repaired, and no remaining blocking functional finding was identified in the exact final sources listed at the end. This is a read-only review of the candidate diagnostic at `/tmp/localsend-bug-2754`; no code was executed and no clone files were changed. Initial findings and hashes are retained to explain the reviewed repair delta. Dispatch remains gated by the root's review of the complete exact patch and separate authorization.

## Findings

1. **P2 — Observer cleanup does not verify or reap its process groups.** `capture-root-name-evidence.sh:20,32–44` retains group IDs alone, then sends TERM and privileged KILL to every retained group without checking starttime, executable, or current group ownership. The thirty-second monitor remains in the list even if it has already exited; background shell reaping can make that stored identity stale. Cleanup also does not wait for children or retain termination results. The geometry wrapper has stronger identity checks for its own timeout process, but cannot account for the helper's separately created `setsid` observer groups if the helper is forcibly killed. Record each observer's PID/starttime/executable/PGID while owned; verify before signals, use bounded termination/reaping, and preserve cleanup outcomes. Ensure helper shutdown has sufficient bounded grace and does not leave separate observer groups active after watcher shutdown.

2. **P2 — Collected status does not establish the required Name/request/reply/connection linkage.** `capture-root-name-evidence.sh:175–182` accepts a nonempty transport file, successful GDB exits, and any client `held_message`. A readable bootstrap/cache message alone meets that check; no matching root Properties.Get(Name), request serial/reply_serial, or connection FD is required. The GDB helper correctly retains enough candidate raw state to permit later correlation when locals are readable, but its result must explicitly be collected-only with linkage unknown/partial until the Name request and actual connection are identified. A held Name request plus a matching return/error reply in `dbind_send_and_allow_reentry`, with its frame/PC/source location established after the blocking call's assignment and in the dispatch drain, is positive evidence of reply-before-wrapper return. A `ret` value inspected while stopped below the still-in-progress assignment may be uninitialized or stale. Absence of the matched, located pair is not app-side deadlock evidence. The README's manual linkage requirement is correct but should also appear in machine-readable result fields.

3. **P2 — Transport and header/body capture truncation is not explicitly qualified.** The transport command at `capture-root-name-evidence.sh:141` uses `-s 256`, so large/coalesced socket reads can lose bytes, especially Cache.GetItems traffic. An arbitrary nonempty file is not a complete stream. `root-name-gdb.py:20` silently caps header parsing to captured bytes, and lines 70/76 cap header/body memory to 4096/256 bytes. Byte lengths are retained, which is useful, but incomplete headers/body prefixes should be explicit partial fields. Either use a bounded larger wire capture plus retained truncation detection or explicitly mark truncated stream linkage unavailable. In particular, partial data cannot justify “no reply arrived.”

Additional identity gap: the helper records and rechecks client starttime and executable, but `capture-root-name-evidence.sh:52–65` checks only app starttime, without recording/rechecking the app executable. Include app executable identity before each attach. A same-PID exec does not change starttime.

The helper says `transport_detached` after waiting for the `setsid timeout` wrapper at lines 146–149. GNU timeout bounds and signals its child group, but the source does not independently retain a verified tracer identity and confirm actual tracer exit before GDB attachment. The cleanup repair should cover this transition. This review does not assert that the tracer detached successfully at runtime.

## Sound source design and retained limits

- Workflow opt-in defaults false. `run-packaged-comparison.sh` selects only AB-package when enabled; Mint rejects another engine/bridge/delivery combination. The normal three-cohort path remains selected otherwise.
- The observed root comes from the selected app's public GetProcessId result plus exact bus/path, then its real GetName entry. A three-second wait occurs before debugger/tracer attachment. No synthetic GetName call or changed public client is introduced.
- The key discriminator is supported by exact retained 2.52 source: `/tmp/2754-packaged-38177219980-full/package/build/work/at-spi2-core-2.52.0/dbind/dbind.c:63–89` stores `ret` from `dbus_connection_send_with_reply_and_block` before the subsequent dispatch drain. The GDB helper reads `message`, `ret`, and `bus` in that named frame. A readable matched ret together with a frame/PC/source location after that assignment can establish that the reply arrived before a callback blocked public-wrapper completion. The initial helper walks 64 frames while `bt full` prints 24; recording PC/source in each target-frame record would preserve this location requirement for deeper frames too.
- GDB reads memory with types from debug information rather than guessed offsets. The D-Bus fixed-header endian fields, eight-byte struct alignment, variant signature terminator advance, and four-byte string/uint alignment are consistent with the supported header types. It preserves raw header and body prefix hex. It does not decode the Properties.Get body into an explicit Accessible/Name pair; correlation can use raw bytes and enclosing `name`/`interface` locals only when readable. Malformed/absent/optimized locals are caught and retained as unavailable. Do not treat unavailable values as null replies.
- Symbols are fetched by runtime ELF build ID before any UI sequence; downloaded debug IDs are verified, and no runtime package/library replacement occurs. GDB uses `-nx`, disables auto-loaded Python scripts, inferior calls, and debuginfod before attaching. The Python helper contains memory/type/frame inspection and `info symbol`, without inferior calls. The custom A bridge's own debug file is not prepared by the stock-library downloader; its private SpiBridge/static callback types may therefore remain unavailable. This is an explicit evidence limit, not proof of absent callbacks.
- Client/app snapshots run in parallel only after the trace wrapper ends. Global bus-monitor records do not cover a private peer connection. `/proc` FD/socket records, connection debug fields, Name serials, and readable message bodies must be correlated before assigning traffic to the stalled call. Stored memory messages are not timestamped wire observations.
- Each client retains the original 180-second timeout. The optional watcher has a 170-second timeout plus five-second kill grace; symbol fetches have individual 45-second limits. Hashing/proc snapshots are bounded only by the helper's outer deadline; a late capture can remain partial. These timings do not guarantee successful evidence collection.
- `geometry-client.c`, `validate-geometry.jq`, and `2754-ui.py` have no candidate diff. The known validator failure and rendered modal/Selection gates are preserved. No geometry or latency pass follows from observer completion.
- SSH's scenario script invokes the UI driver with stdin from `/dev/null`; descendants inherit that isolated stream. Preparation runs as a named script, while its reads have explicit files/process substitutions. No new helper intentionally reads the SSH command stream.
- README forbids latency claims under tracing/debugger and does not claim a complete fix. Those qualifications are appropriate.

## Initial reviewed SHA-256 values

| Source | SHA-256 |
| --- | --- |
| `.github/workflows/diagnose-flatpak-3553-vm.yml` | `79f15dd484670b767d9595d934e64af3505822bdbbdca030bf597e668347aede` |
| `support/diagnostics/2754-engine-build/run-packaged-comparison.sh` | `25f15f29ef6a1816ab1281aa815beb20c9a8e59dd83874b26e745fe47ed5e01d` |
| `support/diagnostics/2754-mint-vm.sh` | `1dda0b5e31cad6d183919df2981d2268bbdb3ff3c03f236871f3edbca6475519` |
| `support/diagnostics/2754-accessibility/capture-geometry.sh` | `78d9614eb34f09304643d981761609e2faaf0c98acbaf33154811c968d8e41ce` |
| `support/diagnostics/2754-accessibility/capture-root-name-evidence.sh` | `cf8a4c67e141f9552283072609f1c1e95383e0f032919377fbe29df0d20ffada` |
| `support/diagnostics/2754-accessibility/root-name-gdb.py` | `afa236dd890368f0a1d8d5ce1595540e210037069125ba504ee0d5d70a3212ad` |
| `support/diagnostics/2754-accessibility/prepare-root-name-symbols.sh` | `cf188d9cc88793dce4657b6075d6a68ba7276f55c0db6004fce92f7363c84506` |
| `support/diagnostics/2754-accessibility/README-root-name.md` | `831a6fad0ba8dff936e11943fa7c9b24322a116d3b03359257506c890466d549` |

No app, build, test, reproduction, syntax execution, VM, or dispatch occurred. Only static source reads, byte hashes, and this `/tmp` report were used. Repairs require a final source delta review before any authorized cloud run.

## First repair delta review

Reviewed helper `027d3151bee933dfb75deb307f8f89d81842b5c9c1a2e727f2fc1b578a7c7ca0`, GDB helper `e104d8a7aa4d497dd23a0c56b0445ac9feb574fe2418dc779e79dffffc921caf`, integration `3bbb6b13cdc230d875f6b52b1d75af954e078fa9ced1820cdd315f2e3c89cb2f`, and README `ed5fb4b13f78581c1d96623b6a63a736968836c9c2154af5af60e1da5ab21dd9`.

The original findings have been substantially repaired: helper cleanup stores PID/starttime/executable/PGID, records signals and bounded exit verification/waits; app executable is bound and rechecked; actual strace PID is identified through TracerPid and must terminate with all app/client task TracerPid values zero before GDB; collected-only result explicitly keeps causal linkage unknown; transport limit is 65536 with conservative truncation markers; memory/header/body truncation is explicit; target-frame PC/source fields and the after-assignment interpretation warning are present. The README now explicitly requires the stopped source location to prove the blocking call returned before treating ret as a received reply. Integration checks watcher/launcher starttime, executable and PGID twice before signalling, and offers forty 0.1-second sleeps before final watcher KILL. This is a design allowance, not a proven wall-clock bound.

One P2 completeness issue remains in this delta: global monitor launch identity failure sets `collection_status=partial`, but the final successful-commands path unconditionally resets it to `finished`. A missing bus/monitor can similarly lose its summary limitation. Keep a sticky collection limitation instead of erasing earlier partial evidence. The helper's signal ownership check also should re-read starttime/PGID after the executable lookup, as integration already does; this closes the avoidable gap caused by using a stat snapshot taken before that lookup. These two narrow repairs were sent to the author and parent. No other blocking functional finding was identified in this delta; exact final source remains pending.

## Final repair review and disposition

The final helper has sticky `collection_limited` and `collection_limit_reasons` fields. Missing global-bus address, unverified monitor launcher, later capture limitations, and unverified cleanup exit are preserved through the final result. The final `finished` assignment is immediately downgraded when an earlier limitation exists. `observer_alive` verifies stat/starttime/PGID, reads the executable, then re-reads stat/starttime/PGID/state before allowing a signal. Both narrow follow-up issues are resolved.

The initial findings are resolved for this diagnostic's stated scope: verified observer ownership and retained bounded termination checks replace bare PGID cleanup; collected-only status never asserts causal success; tracing and memory-prefix limits are explicit; app executable identity and actual all-thread tracer detach are checked; PC/source position is retained and required for interpreting ret. No automatic causal classifier was introduced. The global monitor's direct tool child is not independently recorded; it is controlled through the verified timeout session leader and its own thirty-second/one-second deadlines. A failure to establish ownership or exit remains an evidence limitation, not a claim that cleanup succeeded. The source design supplies bounded timers and recorded checks; scheduling/privileged-command overhead and successful runtime cleanup have not been measured.

Remaining runtime limits are substantive: symbol fetch or ABI/type inspection may fail; custom A bridge private debug types may be absent; relevant locals can be optimized out; the held Name request or matching reply may not be readable; traces start after the earlier exchange and can be split/coalesced/truncated; process FD snapshots precede the debugger memory snapshot and must be corroborated. All of these can leave the original causal distinction unknown. A successful collector, debugger exit, header decode, or public timeout does not establish app callback deadlock, reply-before-wrapper, geometry correctness, or product acceptance. No latency claim is supported while observers are active.

**Disposition:** no remaining blocking source finding at the final hashes below. This is readiness for the root's exact-patch gate, not dispatch authorization or runtime validation. The root must review the complete proposal including new files, verify these identities remain current, and separately authorize the single AB cloud diagnostic. No local app/build/test/reproduction/syntax execution is authorized by this review.

## Exact final SHA-256 values

| Source | SHA-256 |
| --- | --- |
| `.github/workflows/diagnose-flatpak-3553-vm.yml` | `79f15dd484670b767d9595d934e64af3505822bdbbdca030bf597e668347aede` |
| `support/diagnostics/2754-engine-build/run-packaged-comparison.sh` | `25f15f29ef6a1816ab1281aa815beb20c9a8e59dd83874b26e745fe47ed5e01d` |
| `support/diagnostics/2754-mint-vm.sh` | `1dda0b5e31cad6d183919df2981d2268bbdb3ff3c03f236871f3edbca6475519` |
| `support/diagnostics/2754-accessibility/capture-geometry.sh` | `3bbb6b13cdc230d875f6b52b1d75af954e078fa9ced1820cdd315f2e3c89cb2f` |
| `support/diagnostics/2754-accessibility/capture-root-name-evidence.sh` | `3f78e8075b5c3dc62e5aa1ea45edf8b2becec388dbd4acb533eb8f26f395d739` |
| `support/diagnostics/2754-accessibility/root-name-gdb.py` | `e104d8a7aa4d497dd23a0c56b0445ac9feb574fe2418dc779e79dffffc921caf` |
| `support/diagnostics/2754-accessibility/prepare-root-name-symbols.sh` | `cf188d9cc88793dce4657b6075d6a68ba7276f55c0db6004fce92f7363c84506` |
| `support/diagnostics/2754-accessibility/README-root-name.md` | `ed5fb4b13f78581c1d96623b6a63a736968836c9c2154af5af60e1da5ab21dd9` |

These final bytes were statically read and independently hashed. All earlier no-execution limits remain in force.

The parent prepared `/tmp/2754-root-name-proposal.patch` against stated baseline `1cb5366084b01699fa0108b7e9f1999b4b27a9fb`. Independent read-only hashing reproduced SHA-256 `37c9621b1649d9a03d4a27592faf47dcf406fc1e363628877a324a0cee1a75f2`; its eight diff headers select exactly the final source/README paths above. Ledger, audit documents, and `ISSUE-2754.txt` are excluded. Root authorization remains required for dispatch of this exact proposal.
