# Physical helper transport gates

`runTransportControls({r, snap, click, waitFor, labels, save, sleep})` binds a temporary
TCP listener on `127.0.0.1:53317`. Close the previous physical control listener before
calling it. Keep the authenticated relay and Android helper reverse listener running.
The adapter signatures match `windows-transfer-control.mjs`; `save(name, value)` must
preserve strings as strings and serialize objects as JSON. No extra device session is
created. The runner closes only its own target listener and accepted sockets in `finally`.

Android's **Run transport controls** button executes these cases in order:

| Case | Seed | Payload bytes | Physical gate |
| --- | ---: | ---: | --- |
| duplex | 11 | 98,305 | Send 32,768 bytes, await `CHALLENGE\n`, then suffix and `shutdownOutput` |
| slow | 29 | 8,388,608 | Target pauses for 5 seconds, then pauses 25 ms after each receive chunk |
| cancel | 43 | 65,536 | Target closes this peer while the concurrent peer remains live |
| concurrent | 61 | 1,048,576 | Exact response after EOF; held until the target cancels the other peer |
| sparse | 79 | 832 | 13 acknowledged 64-byte heartbeats at 25-second intervals; EOF after 310 seconds |

Each source starts with the ASCII header `TC1 <case>\n`. Payload byte at zero-based
offset `i` is `(i * 31 + seed) & 255`. Source SHA-256 and count include the header.
After source EOF the target returns one UTF-8 JSON line with `count` and `sha256`,
then ends its writable half. Duplex adds `CHALLENGE\n` before source EOF. Sparse
adds `SPARSE_OPEN\n` and `ACK <index>\n` frames while the source remains open.
Both sides hash and count every response byte, including these frames and the JSON newline.

Native result content description is `TRANSPORT_CONTROLS_RESULT\n` followed by JSON.
Progress content descriptions change at each phase and sparse heartbeat. Native socket
watchdogs enforce 180-second case deadlines (370 seconds for sparse). The duplex read
deadline is 15 seconds, reported as `duplex-challenge-before-eof`. Failure records retain
partial native counts and hashes; credentials and exception messages are excluded.

The relay exposes `uploads[id].targetLocalPort` (or trace events carrying `localPort`),
which the runner matches to target socket `remotePort`. Queue gates require target
writable buffering no greater than its measured high-water mark plus one 64 KiB chunk,
HTTP readable buffering at most 128 KiB, and reverse queue at most 512 KiB plus one
64 KiB chunk. Helper snapshots prove its configured 64 KiB read buffer and 1 MiB queue
cap, with observed queue peaks bounded by 64 KiB in streaming mode and 1 MiB in
coalesced mode. Slow-case RSS, heap, external-memory and array-buffer samples and peaks
are saved as observations; these do not establish provider-internal memory bounds.

Only a native `duplex-challenge-before-eof` `SocketTimeoutException`, with the
exact 32,779-byte prefix and its SHA-256, and zero response bytes in the failed native record, may select
the fallback. Wrong challenge bytes, early EOF and other failures stop the job. Stop the
helper, close relay peers, select relay transport `coalesced`, start **Relay from LocalSend
(coalesced)**, and rerun the entire suite. A coalesced request's EOF is a batch boundary;
its sparse result proves a logical peer lasting more than 300 seconds. Streaming mode
additionally requires one HTTP upload request to remain open more than 300 seconds.
Coalesced mode must never be reported as proving that single-request property.

The runner saves mode-specific native XML, snapshots, JSON report, physical trace and
relay trace on success and failure. All gates must pass before the original LocalSend
64 MiB transfer; these controls are helper transport evidence, not a LocalSend reproduction.
