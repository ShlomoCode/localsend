# Independent native build-pair review

Reviewer: `/root/bug_513_recover/sol_native_pair_audit`, `gpt-6.1-sol`, medium reasoning, fresh history. Read-only review; no local application, build or test workloads. Previous Luna reviewer was interrupted and no output from it was accepted.

Result: **PASS for source, compilation and packaging identity of run 38167715876.** This is not a runtime or issue-resolution verdict.

Raw evidence root: `/tmp/bug513-build38167715876/issue513-causal-source-packages-38167715876`. Cloud artifact: `issue513-causal-source-packages-38167715876`, [build run](https://github.com/ShlomoCode/localsend/actions/runs/38167715876).

The reviewer independently checked the following retained evidence:

- `isolated-portal.patch` is byte-identical to the lib/Linux diff of correcting commit `af1fb55a82eab1912e6bb8a11d5bf284f7ed687d`, SHA256 `dc34e608a43a43f6c9b80cd78de2e5ce22b7b104354f21f225db9c60fcc9022d`. The builder copies positive from `2ef30a7e96c185c926a7a2d210fc5f6b7d803248`, reverses only that patch, and copies negative. It removes `resolution: workspace` from both copies. `plugin-pubspec-equality.txt` is empty and its producing diff is under `set -euo pipefail`.
- The positive lib/Linux trees match published desktop_drop 0.8.4. Its `.cc` and `channel.dart` hashes match Git and published sources: `4873bd632649d2e03e23cd45ec9daa1402eae3f9efd21fb8016e039b5e5f0f44` and `a5ed9ab3e05c215697519a587353f70eab05b7ba49c667bae0bf7bdd90f17f14`. Negative hashes match direct `git show` of the pre-correction source and hosted normal 0.7.1: `1722b4047c1cdc7bb33ace249badadfa9a414075b5e685b4f54fe2bc0a60a52c` and `5e8155f4f22f7e0ffe037ea291107568f06491916898404bec01edd5cfbe0173`.
- Pair locks differ only in the overridden source path. Both use version 0.8.4 and identical dependencies. All three manifests are byte-identical, SHA256 `5c2dcced25790ce06e4a7122503755ee92ce1e73c57c95342376b739043c111f`. Source diffs contain only the dependency override and matching lock entry; normal is empty.
- Source worktrees and build directories are separate. Each `ninja-*.log` records actual compilation of `desktop_drop_plugin.cc.o` and linking of `libdesktop_drop_plugin.so`, with condition-specific absolute paths. `native-provenance-*.txt` records source and ELF hashes.
- The reviewer directly inspected all six retained compiled/packaged ELFs. Only positive contains `application/vnd.portal.filetransfer` and `performOperation_portal`. Native and Dart code use the same `desktop_drop` channel and portal method; Dart calls `RetrieveFiles`. Computed ELF hashes match the recorded provenance.
- The reviewer independently decoded the ELFs and reconstructed allocated memory content. Every SHF_ALLOC section, including `.bss` geometry, and all nine program headers match compiled to packaged for each condition. This includes LOAD, DYNAMIC, NOTE, GNU_EH_FRAME, GNU_STACK and GNU_RELRO. Standard Flatpak stripping removes compiler/debug metadata and adds `.gnu_debuglink`; it preserves allocated content and load layout.

| Condition | Allocated-content SHA256, compiled = packaged | GNU Build ID, compiled = packaged |
| --- | --- | --- |
| normal | `dc93ace1470261f8ff8e90482da16edee1069e6ca2552913359526da876c74d2` | `952a7660a4eada1843d29ddcf9878d51409d1cd4` |
| negative | `59a85407dfb493d0a411482ab6f0428ac601128e608091c30778c0bd0200c262` | `dde2c2c2d6155a9500fb7e3e6d155f25544e09e5` |
| positive | `71d22a8f29e08c4c563a9e6362257db5224d0e711e37c6c05443dd7f1eef29cf` | `b887cb2f19b10537e7d18415a8a299af7cd24290` |

Material limitations: these are retained artifacts/logs, not signed runner attestations. Full runner copies of the plugin sources are absent; pubspec equality relies on the builder and retained diff result. Full Git/pub.dev archives differ in Android, CHANGELOG and Git-only files; lib/Linux match. Dart source identity does not independently validate every packaged AOT byte. The reviewer did not inspect runtime 38169212296. Original build 38163717100 remains invalid for causal inference because its three packaged native plugins were identical.
