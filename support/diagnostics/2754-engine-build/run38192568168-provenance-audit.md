# Run 38192568168: input and pre-UI qualification

The actual run reached the Mint guest and passed the required symbol gates. It is separate from run 38190313293, which stopped before creating a VM. This audit reads retained artifacts only; no local workload, script/syntax execution, test, build, debugger inferior, cloud run or retry was performed.

## Run and retained inputs

The terminal GitHub response reports completed/failure on diagnostic head `8218af015ceff59e9e9587d79bde6d688b16bd11`, updated `2026-10-12T01:58:25Z`. The packaged job ran from 01:36:58 to 01:58:24 UTC. The package build passed; the comparison step ran from 01:39:54 to 01:58:07 UTC and failed. The actual scope record selects only `AB-package` with root-name evidence enabled. Workflow step wording does not establish a new control/B/AB matrix.

Compact artifact 11721959325 has API archive digest `44713e9190bb3f4b7a2d137ee4e4f2fa1f0d4b42559777c559894e83186d6bcf`. Full artifact 11723045734 has API archive digest `8927384826ab830e6291241d9d173d152fecc8ae06d35f4cfc410e048aa04228`. Both downloaded successfully to `/tmp/2754-packaged-38192568168-{compact,full}`. These are API digests, not a newly measured hash of an extracted directory. Raw artifact inventory, failed-step log, terminal observation and full directory copies are durable under `.a5c/localsend-sprint/2754-run38192568168/` in the main sprint worktree.

Recursive byte comparison of the guest source artifact provenance directory against the accepted B artifact from run 38164164206 exits zero with no differences. Loaded-engine records report exact engine SHA `1cb9ec7c0516575ef5cdcd452a5de53761680539e5f5d78db7c88a7bad254ab3` and AOT SHA `e34ebc05ed2bd6bea8ce59b4e088bb7f2904f86a8f04e0ad21269d5dc6f156d5`. The source-artifact stage record reports exit zero. The retained package transaction changes only the target bridge version from `2.52.0-1build1` to `2.52.0-1build1+localsend2754.1`.

The actual A DEB hashes to `94266e5fc0d49a6a2a386beaa35301b2a3a98f03badb6823da12e7af27ac47f2`, matching its candidate manifest. Its extracted runtime independently hashes to the unchanged `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`. The guest bridge process hash check reports `OK`. Container hash changes do not establish a runtime-code change.

## Actual symbol preparation

Host `result.json` reports required symbols verified, and optional bridge status is `staged-pending-mapped-identity`. Guest `result.json` also reports required symbols verified. Its retained runtime hashes match the fixed AT-SPI, D-Bus and A pins, respectively `4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141`, `a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413`, and `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`.

Actual strict-policy host downloads report HTTP 200 and curl exit zero: AT-SPI 229124 bytes from HTTPS librarian 723726435, and D-Bus 417028 bytes from HTTPS librarian 742976071. Both guest preparation status records exit zero. The previous downgrade blocker did not recur.

Guest debug hashes match `dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9`, `f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899`, and `c8f341752ed668ed6f022b728bbbb41f745b785f8acaed0c24f198c06dd9b91b`. `symbols.tsv` marks all three verified with their fixed Build IDs. AT-SPI closure and all eight required D-Bus aggregate type checks print `TYPE_GATE_PASSED`; the strace identity record says verified. The manifest specifies both mandatory stock rows and the optional A row.

Pre-UI identity/type success does not establish live mapped-inode/debug-object ownership, request/reply correlation, geometry or interaction success. The separate GDB/Name, birth-wire and controls audits review those actual later records. No application-fix or complete-validation claim follows from these input gates alone.
