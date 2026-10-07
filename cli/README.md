# LocalSend CLI

`localsend-cli` sends and receives files on the local network. Run it without a subcommand for the interactive terminal interface, or use the commands below from a script or another process.

Build the CLI from the repository root with `cargo build -p localsend-cli`. The examples below assume `localsend-cli` is on your `PATH`; you can also use `cargo run -p localsend-cli --` before the arguments.

## Interactive use

Run `localsend-cli` to discover peers, send files, and answer incoming requests with the terminal hotkeys. Press `1`–`9` to choose a displayed device, `D` for the device list, and `Y`, `N`, or `P` to accept, decline, or accept and pair a request. `Ctrl+C` cancels the current activity or quits while idle. `W+S` and `W+R` toggle browser link sharing and receiving.

To choose files before selecting a device, run `localsend-cli send report.pdf photos/`. To send without a terminal, supply an exact device alias or an IP address with `--to`:

```sh
localsend-cli send --to 192.0.2.10 report.pdf
```

An alias must match exactly. If multiple discovered devices share it, use an IP address. Direct IP sends probe the target and still require it to respond as a LocalSend peer. Without `--json`, a direct send writes progress and diagnostics as text to stderr.

## One-shot commands

Use the global `--alias`, `--port`, and `--destination` options before the subcommand. `--port` sets this CLI's listening port, which defaults to `53317` unless configured otherwise. `send --target-port` sets the peer's port when `--to` is an IP address; it defaults to `53317`.

| Command | Behavior |
| --- | --- |
| `discover --timeout 5 --json` | Discover peers, then print one JSON object with `type: "discovery"` and a `devices` array. The timeout is in seconds. Each device has `alias`, `fingerprint`, `host`, `port`, and `paired`. Omit `--json` for text output. |
| `receive --once --timeout 60 --json` | Listen for transfers and exit after one completed transfer. The timeout is in seconds; a timeout or failed transfer with `--once` exits with an error. Without `--once`, it keeps listening until interrupted or timed out. |
| `send --to TARGET --timeout 60 --json PATH...` | Discover the selected peer, send one or more files or directories, and exit when the transfer ends. Directories are collected recursively. `TARGET` is an exact alias or IP address. The timeout covers discovery and transfer. |

For a same-host smoke test, run these commands in one shell with the CLI on `PATH`:

```sh
test_dir=$(mktemp -d)
mkdir -p "$test_dir/receiver" "$test_dir/sender" "$test_dir/incoming"
printf 'Hello from LocalSend\n' > "$test_dir/report.txt"
XDG_CONFIG_HOME="$test_dir/receiver" localsend-cli --port 53417 --destination "$test_dir/incoming" receive --auto-accept --once --timeout 60 --json &
receiver_pid=$!
sleep 2
XDG_CONFIG_HOME="$test_dir/sender" localsend-cli --port 53418 send --to 127.0.0.1 --target-port 53417 --timeout 60 --json "$test_dir/report.txt"
wait "$receiver_pid"
cat "$test_dir/incoming/report.txt"
```

Use `--auto-accept` only where accepting files from any sender is intended. By default, noninteractive `receive` accepts paired senders and declines unpaired requests. The interactive `P` action pairs a sender for later runs. `serve --stdio` instead exposes unpaired requests for an explicit decision. One-shot `send --to` and `discover` decline incoming transfers, including requests from paired senders.

With `--json`, one-shot commands write one JSON object per stdout line. Without it, `discover` prints text to stdout, while `send --to` and `receive` write text to stderr. JSON `discover` prints a snapshot. A successful send emits `send_started` and `send_completed` events; a completed receive emits `receive_completed`. Completion records include `success`, and send records include `transfer_id` and, when assigned, `session_id`. Diagnostics go to stderr. A command failure in JSON mode also emits an error object with `type: "error"` and `code: "command_failed"`. Check the process exit status as well as the completion event: success is zero, while invalid arguments, setup failures, transfer failures, and an unmet `receive --once` timeout exit nonzero. Error message text is not a stable machine protocol.

## Persistent JSON-line session

`serve --stdio` keeps one CLI identity, listener, and discovery session running across commands and transfers. Write one JSON object per line to stdin and read one JSON object per line from stdout. Each request has a caller-chosen `id` and a `command`; each response repeats the `id` and has either `{"ok":true,"result":...}` or `{"ok":false,"error":"..."}`. A malformed request produces an error without an `id`. Asynchronous messages have an `event` field and no request `id`. Events can arrive between a command and its response, so match responses by `id`. The process emits `ready` with `protocol_version: 1`, its alias, and its port after startup. Diagnostics go to stderr.

The supported commands are:

| `command` | Additional request fields | Result or effect |
| --- | --- | --- |
| `status` | None | Current `queued_send`, `sending`, `receiving`, and `pending` sessions, each `null` when absent. |
| `devices` | None | A `devices` snapshot in the same shape as `discover --json`. |
| `discover` | None | `started: true`; a later `discovery_completed` event contains the devices snapshot. |
| `send` | `to`, `paths`, optional `target_port` and `timeout` | Queues a discovery and send, and returns a `transfer_id` with `queued: true`. Follow `send_started` and `send_completed` events for its outcome. Only one send can be queued or active at a time. |
| `receive_decision` | `session_id`, `accept` (`true` or `false`) | Answers the matching pending `receive_request`; result contains `accepted`. |
| `cancel` | `transfer_id` or `session_id` | Cancels a queued or active send by transfer ID, or an active receive by session ID. Result contains `cancelled: true`; a completion event reports the cancellation. |
| `shutdown` | None | Replies with `shutting_down: true`, then stops the listener and exits. |

`send` starts a discovery pass before resolving the target. For a fresh IP target, its direct probe uses `target_port`, which defaults to `53317`. The optional `timeout` covers discovery and transfer in seconds and defaults to 60. The command response acknowledges the queued work; it does not report transfer success. A `send_completed` event with the same `transfer_id` reports the outcome, including discovery failure. Use the ID in `queued_send` or `sending` from `status` to cancel it.

For example, this session checks status and shuts down cleanly:

```sh
printf '%s\n' '{"id":"check-1","command":"status"}' '{"id":"stop-1","command":"shutdown"}' | localsend-cli serve --stdio
```

When an unpaired sender requests a transfer, `serve` emits `receive_request` with a `session_id`, sender alias and fingerprint, and a `files` array of IDs, names, and sizes. Send a decision using that exact session ID:

```json
{"id":"accept-1","command":"receive_decision","session_id":"SESSION_ID","accept":true}
```

Paired senders are accepted automatically. Only one incoming request or receive transfer can be active at a time. The session emits `receive_started`, then `receive_completed` with the same `session_id`; `send_completed` uses the `transfer_id` returned by `send`. Closing stdin ends `serve` and stops its network listener, as does `shutdown`.

## Configuration and limits

The CLI stores `config.toml`, `identity.pem`, and `paired-v2.json` under `$XDG_CONFIG_HOME/localsend-cli` when `XDG_CONFIG_HOME` is an absolute path, or `~/.config/localsend-cli` otherwise. Set a different `XDG_CONFIG_HOME` for each concurrently running CLI identity, and a different `--port` for each listener on the same host. Command-line options override `LOCALSEND_ALIAS`, `LOCALSEND_PORT`, and `LOCALSEND_DESTINATION`; those environment variables override `config.toml`.

These commands use the CLI's HTTP transfer and discovery implementation. They do not provide the Flutter app's interface or browser link controls. Local process tests cover JSON framing, same-host sends, multiple transfers in one session, pairing policy, and timeouts. For broader network scenarios, see the [network lab](../support/network_lab/README.md); real Wi-Fi and cross-device behavior still needs device testing.
