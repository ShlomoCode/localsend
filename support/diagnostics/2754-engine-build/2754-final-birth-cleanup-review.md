# Independent final birth-trace and cleanup review

Verdict: no remaining reportable P2-or-higher finding in the reviewed lifecycle and preparation scope. This is a source-only review, not runtime qualification or authorization to run a workload.

Reviewed immutable eight-file patch: `/tmp/2754-root-name-birth-discriminator.patch`, SHA-256 `4a82069f2342ef12c0c5bc252dc9f0cc96f7b22c049d38c85864904b6189a1f2`.

Reviewed final source identities:

- capture-geometry.sh: `963c583a34900647396e7a23971cbf48680d4607fab39c181cc6a0e3d7284559`
- capture-root-name-evidence.sh: `8232ae90f84a698489990a0eecaf63bfedc9612b7431aa4d873aee838863ada7`
- prepare-root-name-symbols-host.sh: `6175e03b0e6855a63ab5b9c51e83d8a6fcf1cb84a12def5034b29bb9ae324576`
- prepare-root-name-symbols.sh: `df3773eb142f2681428335fc54fe6557992a159e7962b0e681d8cadfa3fba43d`
- 2754-mint-vm.sh: `407dcb7b045fad3b355bf5a4ca1f1846a17003335e36fddb21f1cca38630239b`

## Adversarial paths found and closed before this final snapshot

1. Pre-exec tracer TERM could kill the tracee. Exact strace 6.8 source sets strace_child to the original tracee during startup_child. startup_attach checks interrupted before killing the intermediate process and clearing strace_child. A TERM interrupt in that interval can therefore return to cleanup with strace_child still equal to the tracee; cleanup forwards its fatal signal to that PID. Final code forbids tracer TERM without natural client exec proof and permanently forbids it after observer-induced intermediate release. Generic cleanup excludes every strace role.

2. Killing only the pre-exec daemon could orphan the intermediate strace process in pause(). Source startup_attach double-forks; the intermediate waits for the grandchild to kill it. SIGCHLD is SIG_DFL, so daemon death does not release pause(). Final code retains the unique intermediate through exact original-birth-child lineage, UID, executable, inherited group and stable starttime, rechecks identity, signals only its PID, and requires absent/same-identity-zombie before daemon KILL. An unowned intermediate prevents that exceptional KILL and produces partial evidence.

3. Cancellation between background launch and assignment could lose the client/watcher launcher. Final parent code publishes a pending launch role before both asynchronous launches, retains the previous background PID, and recovers only a changed actual direct child with matching role command-line arguments, UID, timeout executable, stable starttime and PGID. The watcher likewise recovers its pending GDB timeout child. Missing launcher handoff preserves an already observed starttime rather than refreshing it from a reused PID.

4. Before-phase launcher identity could incorrectly reject after-phase cancellation recovery. Final code clears the geometry ownership tuple together before each launch and after normal wait, and rejects a new phase while either launcher remains owned. The watcher tuple is likewise reset before its new launch.

## Source-supported checks

The direct `timeout ... strace -DD -I2 ... geometry-client` preserves the original direct-child PID across exec. strace startup_attach gives the actual daemon an isolated PGID equal to its PID. Ownership is obtained from actual task TracerPid values, not a guessed daemon PID. Signal paths recheck retained PID/starttime/executable/group and tracer isolation before signalling; daemon and intermediate signals are PID-only. A disappeared or changed identity is never promoted to signalable ownership.

The natural-exec interval between daemon kill(intermediate) and strace_child=0 is safe for TERM at source level: interrupt() only assigns interrupted; after the last interrupted check, startup_attach unconditionally clears strace_child before returning. An artificially killed intermediate differs because it can release exec before that check; final code preserves a permanent exceptional-path guard.

The normal capture deadline is monotonic 30 seconds from launch, with a PID-qualified public root Name entry and a complete three-second unresolved gate. No call_id is hardcoded. Completion/client exit causes a changed/partial outcome. Normal verified tracer TERM has a monotonic four-second grace, followed by verified KILL and bounded exit verification. GDB starts only after actual tracer exit and two all-thread TracerPid-zero/non-stopped inventories for both targets. Separate snapshots retain 12-second plus two-second kill bounds; actual observer exit and final repeated all-thread detach are checked. Query timeout remains 180 seconds plus its existing five-second kill grace, and both geometry phases and strict geometry validation remain present.

Host exact symbol downloads/type qualification precede VM creation. Guest verification of transferred debug files, runtime hashes/BuildIDs/package versions, concrete types and actual strace identity precedes UI. Required gate failures stop the scenario and retain preparation status. No attach-time debugger network fetching or inferior calls are enabled.

## Explicit limitation

The source does not guarantee cleanup of a never-observed or ownership-unproven daemon under arbitrary pre-exec scheduling. If intermediate ownership or exit cannot be qualified, exceptional daemon KILL is skipped, evidence remains partial and GDB is skipped. Tracing can then persist until the client's original 180-second deadline. This is an explicit failure outcome, not a successful 30-second detach verdict. Likewise the static 70-second observer bound and 16-second shutdown grace do not establish actual scheduling or command overhead on the guest.

No scripts, syntax checks, apps, builds, tests, inferiors, reproductions or cloud workloads were executed. Reads and hashes only. Exact strace source consulted: `/tmp/strace-6.8/src/strace.c`, especially startup_child/exec_or_die/startup_attach, SIGCHLD setup, interrupt and cleanup; topology context: `/tmp/2754-root-name-birth-trace-topology.md`.
