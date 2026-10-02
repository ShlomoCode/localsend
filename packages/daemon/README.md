# LocalSend background receive module

This crate owns the HTTP server, multicast discovery, incoming decisions, and file writes while the Flutter UI is absent. The macOS native launcher embeds `liblocalsend_daemon.a` and runs `localsend_daemon_run` on a background thread. The executable runs the same module for development.

This development slice supports incoming file transfers to an existing destination directory. It keeps the most recent receive state in memory. Outgoing transfers, web sharing, favorite-device policies, persistent history, preference migration, and custom-folder bookmark access are outside this slice. The native launcher owns sandbox access; a path sent by the Flutter UI does not grant access to that path. Signed cross-app IPC and App Group packaging still need integration validation.

To build the native launcher, run `rtk proxy support/scripts/build_macos_daemon_launcher.sh`. It produces `build/daemon-launcher/LocalSend Receiver.app`. Run its `Contents/MacOS/LocalSendLauncher` executable with `--config /absolute/daemon.json --ui-app /absolute/LocalSend.app`, using a separately built Flutter app bundle. The launcher creates its private socket directory and token. The default development bundle is unsigned.

## Run a disposable development receiver

From the repository root, build the executable and fixture generator:

```sh
rtk cargo build --package localsend-daemon --examples --bins
```

1. Create a private directory with a short absolute path, such as `/tmp/lsd-dev`, with mode `0700`. Create an empty `Downloads` directory inside it. On macOS, the socket path must fit within `sockaddr_un`'s 104-byte storage, including the terminating NUL.
2. Run `target/debug/examples/fixture_config /tmp/lsd-dev/config.json /tmp/lsd-dev/Downloads`. The generator also accepts a final `[PORT]` argument. This generates a disposable identity and writes a new mode-`0600` configuration file. The fixture disables TLS and discovery and asks the OS to choose a port. Its identity represents a different device; it does not import or replace the installed app's identity.
3. Generate an unpredictable token with at least 32 characters. Save it in `/tmp/lsd-dev/token` with mode `0600`. The launcher creates this token before calling Rust; Rust reads it and does not generate or replace it.
4. Run the receiver:

   ```sh
   target/debug/localsend-daemon --config /tmp/lsd-dev/config.json --socket /tmp/lsd-dev/ipc.sock --token-file /tmp/lsd-dev/token
   ```

5. Connect the Flutter daemon UI or an IPC client to the socket. Read a snapshot to get the selected HTTP port. An authenticated `shutdown` command stops the server and removes the socket.

An existing socket makes startup fail. Rust does not remove an existing socket or change permissions on an existing directory. Config and token files must be regular files owned by the calling user with mode `0600`; file symlinks are rejected.

## Configuration and identity

The configuration uses these fields:

| Field | Meaning |
| --- | --- |
| `alias`, `port` | Name announced to peers and listening port; port `0` selects an available port. |
| `https` | Enables mutual TLS; defaults to `true`. |
| `pin` | Optional receive PIN. |
| `verify_checksums` | Verifies offered hashes; defaults to `true`. |
| `destination` | Existing absolute directory accessible to the host process. |
| `auto_accept` | Accepts all offered file IDs without opening a decision UI; defaults to `false`. This fixture setting does not implement the app's favorite/message policies. |
| `discovery` | Starts core discovery and announces once; defaults to `true`. |
| `multicast_group`, `multicast_group_v6` | Default core multicast groups; `null` disables IPv6 multicast. |
| `security_context` | Exact app identity fields: `privateKey`, `publicKey`, `certificate`, and `certificateHash`. |

Rust verifies the certificate, public key, and uppercase certificate fingerprint. It rejects a mismatched identity instead of creating a replacement. The development fixture explicitly creates its own identity; it does not read user preferences. Do not commit generated configuration or token files.

## Local IPC version 1

The socket carries UTF-8 JSON Lines. Every request includes `version`, a caller-selected string `id`, and the authentication `token`. Requests are limited to 1 MiB including the newline. Replies have no equivalent size limit because a large offer can contain thousands of files.

To observe the UI state, send this request, replacing `TOKEN` with the private token:

```json
{"version":1,"id":"ui","token":"TOKEN","command":"watch"}
```

The first reply contains the current snapshot. Later replies on the same connection contain full snapshots with increasing `revision` values; intermediate changes can be coalesced. The native launcher uses `"include_progress":false` on its watch. That control watch contains `receive.files:[]` and empty `sender_alias` and `sender_fingerprint` strings. It changes only when the receive state or daemon error changes. Full UI watches preserve peer metadata. With no UI watch attached, the daemon avoids cloning full file lists and peer metadata for progress updates. Its progress timer is polled only while state is dirty and skips missed ticks when work resumes.

A pending receive reply has this shape:

```json
{"version":1,"id":"ui","ok":true,"snapshot":{"revision":1,"port":53317,"receive":{"session_id":"SESSION_ID","sender_alias":"Sender","sender_fingerprint":"CERTIFICATE_FINGERPRINT","status":"pending","files":[{"id":"file-1","name":"example.txt","size":5,"received_bytes":0,"status":"offered","path":null,"error":null}]},"error":null}}
```

The other commands use independent connections or ordinary request/reply connections:

| Command | Additional fields | Behavior |
| --- | --- | --- |
| `snapshot` | None | Returns the full current state. |
| `accept` | `session_id`; optional `file_ids` | Omitted IDs accept all; an empty array accepts none. Unknown IDs fail. |
| `decline` | `session_id` | Rejects a pending request. |
| `cancel` | `session_id` | Rejects a pending request or prevents new uploads in an active session and notifies the sender. Core permits already-running file writes to finish. |
| `shutdown` | None | Returns a small control acknowledgment, then stops networking and the host's blocking Rust call. Its reply omits receive state. |

Receive statuses are `pending`, `receiving`, `finished`, `cancelled`, and `aborted`. File statuses are `offered`, `queued`, `receiving`, `finished`, `failed`, and `skipped`. `finished` means the session ended; check individual file errors to determine success.

Errors preserve the request ID when parsing succeeds:

```json
{"version":1,"id":"decision","ok":false,"error":{"code":"stale_session","message":"Session no longer exists"}}
```

Error codes include `invalid_request`, `unsupported_version`, `unauthorized`, `stale_session`, `invalid_state`, `invalid_files`, and `unavailable`. A stale decision cannot affect a later request. Closing an IPC connection does not decline a pending request or stop an accepted transfer.

Received filenames are sanitized to a single destination filename. Existing names get a numeric prefix, and incoming directory structure is flattened in this slice. Core retains responsibility for mutual TLS, upload tokens, checksum verification, cancellation guards, and the single active upload session.

## Validate receive behavior

Run `rtk cargo test --package localsend-daemon` and `rtk cargo clippy --package localsend-daemon --all-targets`. The tests use disposable identities and real TLS HTTP requests. They cover UI disconnects during pending and active receives, invalid decisions, local authentication, socket ownership, automatic acceptance, a 10,000-file offer, and selective file routing.

Unix hosts can run this module. Other hosts can build the crate, but its executable reports that the Unix-socket launcher is unsupported.
