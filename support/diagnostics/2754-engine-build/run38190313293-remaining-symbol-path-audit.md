# Remaining symbol path audit after run 38190313293

Static audit on 2026-10-12. No source edits, application/build/test/syntax execution, GDB inferior, network request, VM, retry or cloud dispatch was performed by this auditor. Authorized archive extraction, hashing, LLVM ELF/DWARF inspection and source reads only. Raw additional inspection files are under `/tmp/2754-run38190313293-optional-debug/`.

## Actual stop and limits

The retained `comparison/AB-package/root-name-symbols-host/records/atspi-download.txt` reports HTTP 301, effective URL `http://ddebs.ubuntu.com/...`, `size_download=194`, and `curl_exit_status=1`. Its stderr says `Protocol "http" not supported or disabled in libcurl`. The host script exits at `[[ $status == 0 ]]`, before the package digest/control/extraction/type gates. `root-name-symbols-host/result.json` stays incomplete and the transfer manifest has its header only. Driver propagation is before ISO/QEMU creation. No VM/UI/query result exists from this attempt. The separate package builder is qualifying HTTPS-only alternatives for both stock packages; this audit did not duplicate its network work.

## [P2] Optional A symbols are predictably omitted by the old archive pin

`prepare-root-name-symbols-host.sh:90–98` locates the correct current artifact at selected `build/candidate/../work/`, but requires the old ddeb SHA `6649246a861cb349487376e7b672fa37d15902d3abef4632792a406f0765ec49` before extracting it. The actual run's file has SHA `76b0c9a3a727630800c7003e6f0b6c1f1d300ae5ba8390349abc49800fe8316b`. This is a predictable omission after the URL repair: host required stock gates may pass, but no A debug row/file will be staged, and GDB app-side root identity remains unavailable. It does not invalidate the required client-side gate and is not evidence of changed runtime code.

Authorized static extraction of the actual new ddeb proves:

| Item | Actual identity |
| --- | --- |
| Package / version / architecture | `libatk-bridge2.0-0t64-dbgsym` / `2.52.0-1build1+localsend2754.1` / `amd64` |
| Debug Build ID | `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2` |
| Debug full SHA-256 | `c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b` — exactly the current debug pin |
| Selected runtime canonical path | `/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0.0.0` |
| Selected runtime full SHA-256 | `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297` — recomputed, matches candidate manifest |
| Runtime Build ID | `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2` from retained target ELF notes |

The exact extracted debug ELF has concrete `_SpiBridge` (136 bytes; root at 0x18, bus at 0x20), `_GTypeInstance` (8 bytes; g_class), `_GTypeClass` (8 bytes; g_type), `_AtkObjectClass` (352 bytes; get_name at 0x88), and `spi_global_app_data` at ELF 0x3e128. These agree with the earlier qualified debug file, whose full byte hash is identical. This is static layout evidence, not recovered live root state. Raw control, type, symbol and member inventory are retained under the directory above.

Minimal bounded adaptation for independent review: keep the selected candidate's sibling ddeb route; record its actual archive SHA/bytes/control and finite extraction exit; require exact package/version/amd64 plus the immutable debug full SHA and Build ID, and require the selected candidate's exact runtime path/SHA/Build ID before staging. Archive SHA is retained provenance, while exact extracted debug and runtime identity decide compatibility. Do not replace the old archive pin with only the current 76b0 hash: the next source-package build can change archive metadata again. An alternative is explicitly supplying the already-qualified retained ddeb artifact, retaining its provenance and verifying the selected runtime identically. The current workflow does not download that retained artifact. Neither option installs debug packages or changes runtime libraries. Optional mismatch must retain an explicit reason, rather than collapse into an indistinguishable `absent` status. This proposal is unimplemented and needs root review.

## Other prerequisites inspected

The required stock archives' recomputed hashes, controls, Build IDs, `.build-id` paths and readable 0644 debug-file modes agree with both scripts' pins. AT-SPI control is `libatspi2.0-0t64-dbgsym`, `2.52.0-1build1`, amd64; D-Bus control is `libdbus-1-3-dbgsym`, `1.14.10-4ubuntu4.1`, amd64. Both archives are standard ar packages containing `control.tar.zst` and `data.tar.zst`; the authorized Ubuntu host's dpkg-deb supports these. Debug sizes are 310288 and 501504 bytes, comfortably below the 32 MiB download cap. Required debug full hashes are respectively `dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9` and `f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899`.

Source prerequisites are connected: workflow is ubuntu-24.04 with Actions/Linux guard variables; driver installs host gdb/binutils/jq before preparation; bootstrap stages the accessibility scripts; separate bounded SCP creates the mint-owned evidence directory and copies `.build-id` plus manifest/checksum; guest provisioning already installs gdb/strace/binutils/jq and the development packages before its gate. The guest gate requires mint/Linux Mint/bootstrap marker, canonical exact runtime paths, package versions, runtime/debug SHA and Build ID, required concrete types, and exact `/usr/bin/strace` version/hash/ID. A nonzero gate aborts provisioning and the driver collects guest evidence instead of running the scenario. Successful marker path and line match the birth watcher interface.

The chosen guest GDB snapshots use `sudo -n env ... gdb`, so the actual mapped-inode `/proc/PID/map_files/...` hash check has guest-root privileges; a normal unprivileged-reader assumption is not being made. Attach uses the transferred debug directory, disables auto-load/debuginfod/inferior function calls, and is independently bounded. Snapshot qualification hashes both mapped inode and pathname and verifies loaded exact debug objfile identity; missing/replaced/deleted modules and unavailable type owners remain explicit limitations. The transport cast is guarded by file-qualified socket-vtable type and relocated 0x4d920 identity. No newly demonstrated hard missing prerequisite was found in these static connections.

## Still untested and bounded

This run never reached static GDB qualification on the host. GDB's actual typedef selection, separate-debug objfile ownership, and availability of optimized DWARF locations are untested. Guest APT may select a changed stock runtime or strace; the exact pre-UI identity gate must stop in that case rather than loosen the pin or replace libraries. No current guest exists to establish sudo/capability, bus, tracer-lifecycle, type-loading, detach or snapshot success. Even qualified bytes/types do not prove recoverable bus/pending/closure locals, a complete Name wire stream, latency or valid geometry. These are finite runtime outcomes with retained blockers/partial evidence, not reasons to automatically retry or expand scope.

Assessment is capped at P2. The URL failure is actual; the A-symbol omission is statically predictable and independently byte-qualified. All later runtime outcomes remain untested.
