# Source-only birth-to-Name tracing topology proposal

No repository edits, applications, builds, tests, syntax execution, or runtime qualification were performed. This is a reviewable proposal, not permission to dispatch or proof that tracing preserves the observed failure. Debug-symbol qualification and transport/stack option review are separately owned.

## Qualified source identity

Run38184349418 guest provision-packages-before.tsv1829, provision-packages-after.tsv1861, and bridge-package/packages-after.tsv1861 all identify strace6.8-0ubuntu2. No retained strace --version/binary hash was found; package version is the observed qualification level. Before any authorized run, preserve actual binary version/hash/build ID and ensure it matches this source-qualified package.

Official6.8 source was retrieved into /tmp/strace-6.8; archive /tmp/2754-strace-6.8-source.tar.xz SHA256ba6950a96824cdf93a584fa04f0a733896d2a6bc5f0ad9ffe505d9b41e970149. Exact Ubuntu6.8-0ubuntu2 packaging archive /tmp/2754-strace-6.8-0ubuntu2.debian.tar.xz SHA2566efc6fde478f3beb37dbd246f1e9fe4f13e74eef794b5b66d7589f0933bc351b, extracted under /tmp/2754-strace-ubuntu-packaging. Its four quilt patches affect test files only; none changes strace.c, daemon startup, interrupt handling, or detach. Retrieval URLs are deliberately omitted from this report.

## Source-established topology

strace.c130-140 explains the double fork: in every -D mode the original process execs the traced program, its child exits, and the grandchild is the tracer. startup_child1740-1756 sets PR_SET_PTRACER_ANY, forks, and calls exec_or_die in the original process. exec_or_die1586-1598 waits for its child to disappear before exec. startup_attach1442-1514 makes the grandchild attach before it kills the intermediate child to release that wait; strace_child is then reset to0. This is a source-supported pre-exec attachment handshake, not a measured timing guarantee.

When GNU timeout launches strace -D/-DD/-DDD without sudo or an additional shell wrapper, the PID that timeout originally creates is ultimately geometry-client. Thus the existing direct-child identity strategy can remain: inspect timeout's direct child, wait until /proc/PID/exe equals the exact geometry-client path, retain its starttime and PPID. Its starttime should remain stable across strace-to-client exec. Do not identify the daemon tracer as the geometry client.

| Mode | Tracee parent | Daemon tracer group/session | Cleanup implication |
| --- | --- | --- | --- |
| -D | calling timeout | inherited PGID/SID | Tracer group may contain client; never group-signal this tracer. |
| -DD | calling timeout | setpgid(0,0): tracer PGID equals tracer PID, inherited SID | A verified isolated tracer group can be stopped independently. Recommended candidate. |
| -DDD | calling timeout | setsid(): tracer PGID and SID equal tracer PID | More independent of terminal/session teardown; creates additional orphan cleanup responsibility. No demonstrated need over -DD. |

Exact source branches are strace.c1461-1479; manual doc/strace.1.in378-415 makes the direct-child and separate-group/session promises. The short-lived intermediate process will disappear; do not bind ownership to it. The final daemon can be reparented by the guest's init/subreaper and is not a shell child available to wait. Record actual PPID instead of assuming it remains a literal grandchild after adoption.

## Critical signal options

Do not use bare -DD with the planned TERM cleanup. daemon mode defaults to -I4 (strace.c3061-3062); its SIGTERM/SIGINT handlers are SIG_IGN at3116-3119. The explicit candidate must use -I2. interactive is defined as opt_intr==INTR_WHILE_WAIT at112; -I2 installs the interrupt handler, then terminate4184-4194 calls cleanup and flushes/closes output. -I1 merely leaves fatal signals unblocked/default; it does not take this explicit cleanup path.

After successful daemon attachment strace_child=0 at1514. cleanup3216-3240 forwards its fatal signal only to a tracee equal to strace_child, so this daemon cleanup detaches the recorded tracees rather than forwarding TERM to the geometry client. Detach code1190 onward and cleanup's wait loop3250 onward can require temporary stops; retain their perturbation and outcome.

Never enable --kill-on-exit or --seccomp-bpf in this candidate. strace.c2990-3005 can add PTRACE_O_EXITKILL for these modes, which changes tracer-death semantics and can kill the client. Do not use syscall injection, delayed syscalls, or detach-on-exec (the initial geometry-client exec must remain traced). No sudo wrapper around the launch: the geometry client must remain the same Mint user/environment.

## Proposed launch and independent owner

Structural command only, not executed:

    timeout --kill-after=5s 180s strace -DD -I2 -f -ttt -T -yy -xx -s1048576 -o TRANSPORT_LOG -e trace=QUALIFIED_TRANSPORT_AND_WAIT_SYSCALLS GEOMETRY_CLIENT APP_PID LABEL

Keep the existing geometry-client file/hash/arguments, stdout JSONL, stderr, and timeout180s +5s grace. Use direct strace executable invocation, no shell command that remains in place between timeout and client. Consumer-owned filter qualification must include all relevant socket connect/send/receive and read/write variants; syscall output truncation/partial-message detection remains a separate acceptance gate. Birth tracing needs no replacement Name method or bypass of libatspi cache startup.

Before launching, establish the independent evidence watcher with a launcher start event and monotonic cutoff. It must not inherit the client's timeout group. An initial discovery/capture cutoff of30s from launch is a conservative proposed bound for review, not an observed requirement: failure to find a still-pending owned root Name by that cutoff stops only the tracer and marks this evidence incomplete. On reaching the PID-matched root public Name entry, retain three seconds of continued unresolved state and then stop tracing; no need to wait180s to detach. The original geometry-client wait/deadline continues independently. A tracer fallback must also execute on outer cancellation or client exit; -DD means timeout's client-group kill does not itself own the daemon tracer.

## Identity and actual-detach gates

1. Preserve timeout PID/starttime/exe/PGID. Resolve exactly one direct child with exact client executable, stable starttime, expected Mint UID and PPID==timeout. Retain its initial executable transition if observable; source supports same PID across exec, but runtime must prove the actual child identity.
2. Read TracerPid from the verified client's /proc/PID/status, and from all existing /proc/PID/task/TID/status entries. Require a nonzero single owned tracer PID, exact strace executable and retained starttime. For -DD require tracer PGID==tracer PID, tracer PGID distinct from both client and timeout groups; record SID/UID/PPID as well. Correlate the actual trace output PID/exec with the client identity. TracerPid is the authoritative live relationship, not a guessed child of the launched shell.
3. Observe the raw JSONL root identity whose GetProcessId result equals APP_PID; match its public GetName query_enter and actual call_id. Do not hardcode50, synthesize another property query, or assume a wire GetName method. After the unresolved quiet period verify the same client starttime and that no matching public return appeared. Tracing has been present from birth, so this is a traced cohort, not an initial unobserved wait.
4. Immediately before every signal recheck tracer PID/starttime/exe/PGID, isolated from client/app/timeout groups. Send TERM to that verified tracer PID or isolated owned group. Allow a bounded graceful-detach window (proposed4s plus explicit command overhead qualification); if necessary KILL only the still-verified tracer group. Do not signal the client or app as a detach workaround. No successful wrapper return is a detach verdict.
5. After termination require actual tracer absent or zombie with matching retained identity, and TracerPid0 on every currently enumerated client thread. Repeat the thread inventory/zero check to cover creation races; retain task IDs/starttimes and any missing/changed thread separately. Also require client identity unchanged and state not T/t. If the client exited, report it as such; no client stack claim. A daemon is not directly waitable by this shell: classify proven exit/zombie/reparenting rather than pretending wait reaped it.
6. Only after that gate, and only while the same client remains live, begin separately bounded GDB client/app snapshots using qualified symbols, no inferior function calls. Check GDB detach and final all-thread TracerPid/state too. On any uncertain tracer ownership or nonzero/missing detach observation, retain failure artifacts and skip GDB. Do not relax geometry acceptance.

## Perturbation and what the comparison supports

The exact untraced geometry-client source hash861eafe... and executableb8b6b451... repeatedly entered root public Name and hit180s deadline124 before any node/extents result. In run38184349418, before/after Name entered11.399/14.199ms. The existing delayed observer began only after three seconds of unresolved wait; late transport attachment cannot recover startup/bootstrap/Name traffic already exchanged. A birth trace addresses that specific missing evidence.

Daemon mode preserves parent/child waits and timeout ownership better than ordinary strace-as-parent, but adds ptrace stop/resume scheduling from startup, fork/exec handshake work and PR_SET_PTRACER_ANY. Filtering reduces printed traffic, not all ptrace scheduling overhead. The same unmodified executable under birth tracing therefore remains a perturbed diagnostic cohort. A different outcome cannot by itself prove a fix or disprove the original failure. Preserve original untraced records as the reference; only claim this cohort's message/reply sequence and contemporaneous post-detach stack, and report if Name or startup behavior changed. Every geometry gate still requires complete nodes/extents/strict validation, which this proposal does not manufacture.

## Remaining pre-dispatch gate

This topology is source-supported for installed package6.8-0ubuntu2, including its relevant packaging patch scope. The actual installed binary identity, daemon topology, owner discovery, signal cleanup wall-clock behavior and stable all-thread detach have not been runtime-qualified here. The exact implementation diff and a fresh independent review must close those source gates before any separately authorized cloud run; runtime evidence must then establish the gates above rather than infer them from source.
