# Independent static review: combined symbol preflight correction

Immutable artifact reviewed: `/tmp/2754-strict-symbol-preflight-correction.patch`, independently measured SHA-256 `82ccd614944235815e170b50c6f1e2aeb506fc228965d003e962c0bd2ee8d2b4`. This final combined artifact supersedes both the earlier URI-only patch and combined SHA `749cd9934c04021152f89358d8216538c20121587cc9d7ade5e60bdc3ee061c4`.

Verdict at maximum P2: no actionable P0–P2 defects found in the combined correction. Removing the mutable optional A archive-container hash as an acceptance criterion preserves identity because exact extracted debug bytes/Build ID and exact selected runtime bytes/Build ID remain pinned. Current retained A artifacts satisfy those immutable identities. The required stock package gates are unchanged.

## Concrete patch behavior

The patch changes the AT-SPI source URI to the exact official build-specific Launchpad route reviewed separately. It also requires the optional A archive to be a regular file, not a final-component symlink; records its size and actual archive SHA; rejects zero-length or larger-than-32-MiB archives; retains exact package-name/version/amd64 checks; and keeps extraction bounded by 30 seconds plus a 2-second termination grace.

The old optional container hash `6649246a861cb349487376e7b672fa37d15902d3abef4632792a406f0765ec49` becomes recorded provenance rather than a fixed acceptance criterion. The actual rebuilt retained archive is 215402 bytes with SHA `76b0c9a3a727630800c7003e6f0b6c1f1d300ae5ba8390349abc49800fe8316b`. Its control member identifies `libatk-bridge2.0-0t64-dbgsym`, version `2.52.0-1build1+localsend2754.1`, amd64, dependency on the same runtime version and Build-Ids `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2`.

The patch retains exact extracted debug SHA `c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b` and Build ID `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2`. It strengthens selected manifest runtime-SHA acceptance from arbitrary 64-hex text to the exact existing runtime SHA `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`, retaining exact canonical runtime path `/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0.0.0`.

## Independent raw-artifact checks

This reviewer recomputed SHA-256 of the actual archive, extracted debug ELF under `/tmp/2754-run38190313293-optional-debug/data/usr/lib/debug/.build-id/c8/`, and selected runtime ELF under `/tmp/2754-packaged-38190313293-full/package/build/target-root/usr/lib/x86_64-linux-gnu/`. Debug and runtime hashes exactly match the source pins above. Static llvm-readelf inspection gives the same `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2` Build ID for both. The static DWARF inventory preserves concrete `_SpiBridge`, `_GTypeInstance` and `_GTypeClass` layouts and `spi_global_app_data`; this is layout evidence, not runtime state.

These exact full hashes establish compatibility more strongly than version strings or matching archive metadata alone. An archive carrying altered debug bytes cannot be staged successfully by these checks; an alternate selected runtime manifest cannot pass the new runtime-SHA condition.

## Host versus guest identity boundary

The host checks the selected candidate manifest’s exact runtime SHA; it does not newly hash the runtime library or inspect its Build ID at staging time. The unchanged manifest row contains both the exact SHA and fixed `c88dc5...` Build ID. The existing guest `prepare-root-name-symbols.sh` validates canonical regular runtime pathname, installed runtime version, runtime full SHA and runtime Build ID before UI can start, as well as exact debug SHA and Build ID. Thus the complete pre-UI path still verifies actual runtime bytes and Build ID. Calling the host manifest comparison itself an actual loaded-runtime check would overstate the patch.

No source hunk touches required AT-SPI or D-Bus archive/control/debug identity checks, HTTPS-only curl policy and bounds, mandatory GDB type inventory, required row counts, guest runtime verification or the pre-VM abort. The URL change remains backed by official publication and complete retained HTTPS 303→200 chains in the prior independent strict-URI review.

## Diagnostic status and limits

The final immutable patch adds explicit statuses for archive absence/symlink rejection, incomplete archive qualification, control mismatch/extraction failure, missing debug file, debug identity/inspection failure and incomplete selected runtime identity. These stage markers distinguish rejection from complete staging without weakening identity checks; raw records identify the specific failure within grouped statuses. Successful staging still reports `staged-pending-mapped-identity`, correctly preserving the later actual-runtime qualification boundary. These refinements address the earlier remaining-path audit’s omission-status concern.

A failed size bound aborts the host preflight under set-e rather than silently omitting optional symbols. This is fail-closed and preserves mandatory gate strictness. Actual retained size satisfies the bound. Standard dpkg package processing remains relied upon; archive final-component symlink rejection is not a full adversarial tree-policy mechanism, and no such broader security redesign is claimed.

The correction is statically supported; actual Linux host execution, GDB type loading, guest identity and mapped-inode qualification remain unexecuted. This reviewer performed only reads, hashes, control-member reads and static ELF inspection. No source edits, script syntax execution, tests, builds, application/VM launch, GDB inferior, network request, cloud workload or retry was performed. This report supplies no authorization for another cloud run.
