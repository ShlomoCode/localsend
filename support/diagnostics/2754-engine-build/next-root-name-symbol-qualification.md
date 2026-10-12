# Qualify exact debug files before the next root-name scenario

Source-only qualification completed on October 12, 2026. No repository code changed. No application, build, test, GDB inferior, reproduction, VM, or cloud job ran. Downloads came from official Ubuntu/Launchpad endpoints; inspection used archive extraction and LLVM ELF/DWARF tools.

## Available matching artifacts

Both required stock debug packages are available. Fetch packages on the Actions host, extract debug files, and transfer those files to Mint before the UI scenario. The Mint-side debuginfod requests in run `38184349418` timed out; a host-side debuginfod request also timed out during this qualification. An exact package route works and avoids depending on Mint internet access.

| Package | Exact version | Debug ELF Build ID | Downloaded package SHA-256 | Extracted debug ELF SHA-256 |
| --- | --- | --- | --- | --- |
| `libatspi2.0-0t64-dbgsym` | `2.52.0-1build1` | `d53e3f4bf82655a42a0cb86c25416fd443ee76c6` | `6be64cf137f649471785d44e373e4fba5f6e79598ebca9289f8c13f9e7d4c16b` | `dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9` |
| `libdbus-1-3-dbgsym` | `1.14.10-4ubuntu4.1` | `47829078e4267099473c6cf5f5742f16ccb2644d` | `3ba3c5094950d8913a56267f4f8ff13fd3d1000af44b2bdd8678119abc0928fe` | `f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899` |

Successful official download URLs:

- AT-SPI: `https://ddebs.ubuntu.com/pool/main/a/at-spi2-core/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb`.
- D-Bus: `https://launchpad.net/ubuntu/+source/dbus/1.14.10-4ubuntu4.1/+build/28726865/+files/libdbus-1-3-dbgsym_1.14.10-4ubuntu4.1_amd64.ddeb`.

The guessed D-Bus pool URL returned 404; do not use it as the next preflight source. Official Launchpad publication metadata identifies noble amd64 build `28726865`. The supported `devel` API publication operation returned `https://launchpad.net/ubuntu/+archive/primary/+files/libdbus-1-3-dbgsym_1.14.10-4ubuntu4.1_amd64.ddeb`; the successful build-specific URL above identifies the same package/version. The `1.0` API operation returned 400 and is not needed.

The official AT-SPI runtime package was also downloaded and extracted. Its `libatspi.so.0.0.1` SHA-256 is exactly the retained guest value `4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141`, and its Build ID matches the qualified debug ELF.

The exact official D-Bus runtime package was fetched from `https://archive.ubuntu.com/ubuntu/pool/main/d/dbus/libdbus-1-3_1.14.10-4ubuntu4.1_amd64.deb`. Package SHA-256 is `5d630480f04b4b442300ce847a3fa705ea4d14d80ba6de91f99b51a4e4953b08`. Its extracted `usr/lib/x86_64-linux-gnu/libdbus-1.so.3.32.4` has SHA-256 `a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413` and Build ID `47829078e4267099473c6cf5f5742f16ccb2644d`, matching both retained guest values and the qualified debug file. The next guest preflight must recompute both runtime hashes/IDs.

The official strace package is also available at `https://archive.ubuntu.com/ubuntu/pool/main/s/strace/strace_6.8-0ubuntu2_amd64.deb`. Package SHA-256 is `d588810ae26b06fee6678dc81e5b54f6efcde8e718e4589adb4d11d254b9820b`; extracted `usr/bin/strace` SHA-256 is `28f957c227012de0b18d1bd7fff2d396cb693ea60ed8013be68de071e84b5001`, Build ID `997a6f079008c26efee890fe845f79aa76018ea4`. This records official binary identity; its equality to the retained guest tracer was not established in this qualification. No extracted binary was executed.

## Exact retained PC result

Both captured `dbind_send_and_allow_reentry` PCs resolve to the closure-driven `dbus_connection_read_write_dispatch` call, not the other branch's blocking-call return assignment and subsequent dispatch drain.

| Snapshot | Retained PC | ELF load bias | Relative PC |
| --- | --- | --- | --- |
| Before | `0x7d6cd360072e` | `0x7d6cd35df000` | `0x2172e` |
| After | `0x7f8037f7172e` | `0x7f8037f50000` | `0x2172e` |

The retained executable mappings have file offset `0x10000`; the exact runtime ELF executable PT_LOAD has matching virtual address/file offset `0x10000`. Subtracting that virtual address from each mapped executable start gives the load bias shown above. The zero-offset mapping independently has the same bias. Subtracting that bias from each retained PC yields `0x2172e`.

Exact debug `llvm-addr2line` identifies `dbind/dbind.c:102` (discriminator 1) at `0x2172e`, and line 102 at the preceding call instruction `0x21729`. The runtime disassembly shows `0x21729: callq 0x11890`, with return address `0x2172e`. PLT entry `0x11890` jumps through GOT address `0x38af0`; the ELF relocation identifies this as `dbus_connection_read_write_dispatch@LIBDBUS_1_3`. AT-SPI source line 102 is the closure loop's call to that function. The distinct remote-return branch starts at `0x21800` in this runtime.

These are suspended caller return PCs. They establish the compiled branch containing the active child call; they do not imply that `read_write_dispatch` has returned. They do not establish a Name request serial, a reply serial, the actual connection, or whether a reply was received before a recursive callback. Those facts remain unknown. In this branch, `pending` and `closure->reply` are the relevant state; `ret` is assigned only after the closure loop exits.

## Usable static type and source inventory

The qualified stock debug files contain concrete DWARF layouts, not only opaque declarations:

- AT-SPI has `dbind_send_and_allow_reentry` at ELF `0x21640–0x21858`, parameter/local location lists, `AtspiApplication`, `AtspiObject`, and `SpiReentrantCallClosure`. At the retained PC, `bus` has a concrete RBX location and `pending` has a CFA-relative location. `message` uses an entry-value expression in this region, so a readable message argument is not guaranteed even with exact symbols. No runtime recovery was attempted.
- D-Bus has `DBusConnection` (264 bytes), with dispatch mutex/condition/acquired fields, I/O mutex/condition/acquired fields, transport, and pending replies. `DBusCondVar` (48 bytes) contains its `pthread_cond_t cond` member at offset zero. The pthread type definitions are included in the debug information. These permit a type-based comparison of a waited condition to a particular connection's synchronization member, if actual frame arguments can be recovered.
- D-Bus also has `DBusTransport` (144 bytes), `DBusTransportSocket` (232 bytes), `DBusMessage` (184 bytes; header/body), `DBusPendingCall` (72 bytes; reply/reply_serial/completed), and `DBusRealString` (24 bytes; str/len). Actual source and debug layouts are retained.
- Before casting a transport to `DBusTransportSocket`, validate its vtable identity against the socket transport implementation. The debug file contains two static variables named `socket_vtable`: the transport vtable at ELF `0x4d920` and a separate server vtable at `0x4d980`. Use the `dbus-transport-socket.c` static symbol or matching typed function members; an unqualified first-name lookup or a blind cast is insufficient. Read memory/symbol identities only; do not invoke the vtable's function to get an FD.

Official D-Bus source archives were fetched and their hashes matched the official `.dsc` checksum entries: upstream `ba1f21d2bd9d339da2d4aa8780c09df32fea87998b73da24f49ab9df1e36a50f`; Ubuntu Debian archive `c28e0e4840bf3c3f3cbdacae9b7228bb4694dd234f325535942dde76af3c322e`. The retained distribution series lists RISC-V test-timeout, AppArmor security-context, and service-stop patches. Sources were extracted for reading, not built or installed. The qualified DWARF is authoritative for the exact compiled member layouts.

## Optional retained A bridge symbols

The existing run artifact contains `libatk-bridge2.0-0t64-dbgsym_2.52.0-1build1+localsend2754.1_amd64.ddeb` under `package/build/work/`; no rebuild is needed. It extracts a debug ELF with exact A Build ID `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2`. Package SHA-256 is `6649246a861cb349487376e7b672fa37d15902d3abef4632792a406f0765ec49`; debug SHA-256 is `c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b`.

Its DWARF includes concrete `_SpiBridge` with root/bus/private-bus address, `spi_global_app_data`, `_GTypeInstance`, `_GTypeClass`, and `_AtkObjectClass` with `get_name`. Stage this retained file as optional app-side evidence, and require its Build ID/hash to match the mapped A bridge before using it. GTK symbol fetching is unnecessary for the required client-side gate. Missing optional app-side types remain an explicit limit.

## Finite next source proposal

Root must review and authorize the next implementation/execution gate. Implement only the following preparation change before considering the separately reviewed next discriminator:

1. Fetch the two pinned official `.ddeb` files on the Actions host with bounded HTTPS requests. Retain URL, HTTP/download status, package control, byte count, package hash, extracted debug hash, and debug Build ID. Fail this preparation if either required hash, package identity, Build ID, or necessary concrete type inventory differs. Include the qualified retained A debug file if the same package artifact is selected. Do not install debug packages or modify runtime libraries.
2. Transfer a small `.build-id` directory and manifest to `/home/mint/evidence/root-name-symbols`. Verify the manifest and debug files again in Mint. Before any UI/query workload, read the guest's installed runtime canonical paths, versions, Build IDs, and SHA-256 hashes; require the exact stock AT-SPI/D-Bus values above. This is a hard gate, replacing the earlier continue-on-symbol-download-failure behavior. A mismatch stops the scenario with a retained preparation blocker.
3. Before UI, perform a static symbol/type loading qualification against these exact runtime/debug pairs on the cloud host or guest, without attaching to or running an inferior. Require concrete `DBusConnection`, `DBusCondVar`, `DBusTransport`/socket, `DBusMessage`, `DBusPendingCall`, `DBusRealString`, and AT-SPI closure layouts to be available to the chosen debugger. Retain this finite output. Do not attempt speculative queue walking or a runtime rebuild.
4. On any later snapshot, compare each process's actually mapped runtime IDs/hashes to the preflight manifest before interpreting memory. Keep debuginfod disabled during attach. Required missing/mismatched symbols stop causal interpretation. A successful symbol gate does not guarantee optimized arguments can be recovered; use the separate consumer-approved birth-wire/stack design if needed. No deadline or geometry-check change follows from this preparation.

## Retained artifacts for independent review

The complete qualification directory is `/tmp/2754-qualified-symbols/`. `qualification-artifacts.sha256` lists package/static-inspection/raw retained-stack artifacts. Key files are:

- Qualified `.ddeb` archives and AT-SPI runtime `.deb` at the directory root; extracted exact debug ELFs under `atspi/usr/lib/debug/.build-id/`, `dbus/usr/lib/debug/.build-id/`, and `bridge/usr/lib/debug/.build-id/`.
- Exact D-Bus and strace runtime `.deb` files at the root; extracted ELFs under `dbus-runtime/` and `strace-runtime/`. `runtime-download-identities.json`, `runtime-elf-identities.sha256`, `dbus-runtime-{control,notes}.txt`, and `strace-runtime-{control,notes}.txt` retain official URLs, package hashes, ELF hashes, and raw Build IDs.
- `retained-client-maps-before.txt`, `retained-client-maps-after.txt`, and corresponding `retained-client-gdb-*.txt` copied from run `38184349418`.
- `atspi-runtime-segments.txt`, `atspi-dbind-instructions.txt`, `dispatch-plt.txt`, `atspi-relocations.txt`, and `retained-pc-addr2line.txt` support the mapping/branch result.
- `atspi-dbind-dwarf.txt`, `dbus-types.txt`, `dbus-realstring-layout.txt`, `dbus-vtable-layout.txt`, `dbus-transport-vtable.txt`, `dbus-dispatch-functions.txt`, `dispatch-extra-types.txt`, `bridge-types.txt`, and `bridge-class-layouts.txt` preserve the type/PC qualification outputs.
- Exact D-Bus `.dsc` and source archives at the root, extracted upstream plus Debian source under `dbus-source/dbus-1.14.10/`. This is a read-only source inventory, not a claim that an unpatched tree reproduces the distribution build.

No next cloud run, retry, code change, or workload is authorized by this report itself.
