# Independent review of omitted shader inputs

Fresh reviewer: `shader_input_review`, gpt-6.1-sol, medium, no inherited history. Review scope: necessity and supported alternatives, not only the diff. No local build or test ran.

The reviewer verified the exact GN declarations and all 17 original successful COPY log entries. B's source patch changes only the Linux engine build/test and socket files, so the shader input identity is shared by both variants. The retained full stage artifact has no shader directory, reusable Ninja graph, GN executable or build workspace.

The reviewer accepted the narrow byte-equivalent restoration under the parent's stated allowance. Recreating the measured approximately 10 GiB bootstrap is disproportionate for 17 source copies. The reviewer could not exclude every possible selectively bootstrapped GN route, but a custom minimal GN root would itself be a substitute harness and would add no stronger input fidelity.

Material conditions and responses:

- Link the original run, variant, archive hash and manifest in additive provenance. The app consumer retains both originals and adds their identities/hashes to the restoration manifest.
- Link exact target definitions, source blob IDs and staged hashes. The script verifies the three exact target definition SHA256 values, requires all 17 staged Git blobs to match the pinned engine revision, and hashes each provenance list in the additive manifest.
- Rehash original transported files after addition. The app consumer repeats the original per-file SHA256 verification and retains its output.
- Acknowledge that the original selected artifact omitted inputs. The README records the omission and separates restoration from app build, loaded identity and UI evidence.

This review establishes equivalent source-copy inputs only. The parent must assess this evidence and remaining uncertainty before the next cloud retry. It does not approve a product fix, runtime injection, built-binary replacement or PR.

Parent decision: accepted the bounded additive recovery for original engine run `38153341418` only after reading the restoration script, independent rationale and consumer diff. Acceptance rests on exact pure-COPY equivalence, retained original COPY logs, pinned source identities, and unchanged original archive bytes with repeated per-file verification. Cost alone would not justify an unknown replacement. The next authorized action is one app-only cloud retry. Product-fix and VM acceptance remain pending complete-bundle proof.
