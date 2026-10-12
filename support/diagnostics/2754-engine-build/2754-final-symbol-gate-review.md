# Final static review of root Name symbol gates

Reviewed October 12, 2026, in `/tmp/localsend-bug-2754`. Scope: `prepare-root-name-symbols-host.sh`, `prepare-root-name-symbols.sh`, their `2754-mint-vm.sh` integration, and manifest/mapped-module/type consumption in `root-name-gdb.py`. This review read source and diffs and compared pinned identities with the independently qualified ELF/DWARF artifacts. It executed no scripts, syntax checks, applications, tests, builds, debugger inferiors, or cloud workloads. It edited no repository files.

No open P2 findings remain in this scope. Runtime operation and the separate decoder/daemon cleanup reviews remain outside this verdict.

Reviewed source SHA-256 values:

- `prepare-root-name-symbols-host.sh`: `6175e03b0e6855a63ab5b9c51e83d8a6fcf1cb84a12def5034b29bb9ae324576`
- `prepare-root-name-symbols.sh`: `df3773eb142f2681428335fc54fe6557992a159e7962b0e681d8cadfa3fba43d`
- `2754-mint-vm.sh`: `407dcb7b045fad3b355bf5a4ca1f1846a17003335e36fddb21f1cca38630239b`
- `root-name-gdb.py`: `6c352771f2f6091d6fe7774772542d87e83fa9b43c80c0f4e12edbe4e3961a16`

I reread the complete frozen GDB source at the hash above after its final raw-local/depth changes. Manifest, mapped-inode, exact debug/type-owner, and qualified socket-vtable checks remain intact. Concrete aggregate sizes and members are qualified by the host and guest preparation inventories; the snapshot helper checks exact type owner and nonzero size. No additional P2 finding arose in this symbol-gate scope.

## Resolved finding

**[P2, resolved] Normalize const on the socket transport vtable type comparison.** Exact D-Bus DWARF declares `dbus-transport-socket.c::socket_vtable` as `const DBusTransportVTable`. The initial consumer compared its target after `strip_typedefs()` with the unqualified aggregate, which could reject valid socket transports and lose the intended FD linkage. I reported this to the parent and worker. The revised `root-name-gdb.py:202` calls `.unqualified()` on both comparison operands. I reread the correction. The file-qualified lookup, expected relocated address, and instance-vtable equality checks remain before the socket cast.

## Verified preparation and integration

The host script requires the Actions Linux diagnostic context. It pins the successful official AT-SPI ddeb URL and build-specific Launchpad D-Bus ddeb URL, HTTPS-only redirect policy, download time/size bounds, package hashes, package/version/amd64 controls, exact debug hashes, and exact Build IDs. Required preparation errors propagate through `set -e`; the driver checks both exit status and the success result before ISO retrieval or VM creation.

The host performs finite batch GDB symbol-file qualification with no inferior, auto-load and debuginfod disabled, and inferior calls prohibited. It requires aggregate types, exact sizes, and relevant members for closure, connection, conditions, transport/socket/vtable, messages, pending calls, and private strings. Its expected sizes and identities match the qualified artifacts.

Only the separate `.build-id` debug directory, manifest, and manifest digest cross the new transfer boundary. The guest requires the expected Mint context, exact output directory, manifest header/count/digest, two unique pinned required rows, debug regular-file/canonical-path identities, debug hashes/IDs, and installed runtime versions/canonical paths/hashes/IDs. It repeats the concrete type gate. It also requires the exact official `/usr/bin/strace` SHA-256 and Build ID as well as package version `6.8-0ubuntu2`.

The driver checks the guest preparation exit status and success JSON before it reports UI readiness; the scenario SSH block is conditional on successful provisioning. Thus symbol/type/tool failures prevent the proposed app/UI/query scenario. Host and guest retain an incomplete result and exit status on failure.

The optional bridge path has separate pinned package/control/debug verification. It cannot replace either required row: guest independently counts and checks the AT-SPI and D-Bus rows. Its runtime SHA comes from the selected A package manifest, and its snapshot use still requires mapped identity. Optional bridge absence permits the required gate to pass. If a staged bridge fails validation, preparation stops conservatively; it does not weaken required qualification.

## Verified snapshot consumption

`root-name-gdb.py` checks the transferred manifest digest, reads the stopped inferior's maps, hashes the actual mapped inode through `/proc/PID/map_files`, hashes the canonical runtime file, and checks the debug hash. It requires one exact loaded debug objfile with the manifest Build ID and canonical debug filename. The hash of the mapped file binds the runtime bytes to the already qualified runtime Build ID. Offset-zero maps provide the bias for these exact, previously inspected ELFs.

The consumer rejects deleted/replaced or otherwise mismatched mapped modules before interpreting their memory. Qualification exceptions clear the qualified module set; frame-local reads require DWARF from a qualified objfile. Missing modules emit unavailable states. Exact-type reads require the type owner to match the qualified debug objfile and a nonzero concrete size.

The socket transport check uses `&'dbus-transport-socket.c'::socket_vtable`, its normalized concrete vtable type, qualified bias plus `0x4d920`, and the instance vtable pointer. It cannot silently choose the distinct server vtable at `0x4d980`. Only after these checks does it cast to the qualified socket type and read the FD. It reads `/proc/PID/fd` identity and makes no inferior function calls.

This establishes source-level rejection paths and intended linkage. It does not prove GDB will recover optimized locations, permit map_files reads in the guest, finish within its deadline, or produce a useful connection/socket result. Those outcomes must remain explicit unavailable or partial evidence in any separately authorized run.

## Immutable artifact binding

Final patch: `/tmp/2754-root-name-birth-discriminator.patch`, independently recomputed SHA-256 `4a82069f2342ef12c0c5bc252dc9f0cc96f7b22c049d38c85864904b6189a1f2`. I recomputed all four reviewed source hashes at this binding gate; they match the values listed above. This binds the symbol-gate review to the frozen source accompanying that patch. It does not extend my scope to the independently reviewed wire decoder and daemon cancellation logic or authorize execution.
