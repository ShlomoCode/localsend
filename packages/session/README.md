# LocalSend sessions for Rust callers

`localsend-session` manages a LocalSend identity, peer discovery, transfers, incoming receive decisions, cancellation, and shutdown. It uses the real HTTP and multicast implementation in `localsend` core. The CLI's noninteractive commands and JSON-line protocol adapt this same session implementation.

The library accepts typed Rust values and emits `SessionEvent` values. It does not read stdin, write terminal output, parse CLI arguments, or define a JSON command protocol. Callers choose their identity directory, destination, and receive policy. The existing `identity.pem` and `paired-v2.json` formats are preserved, so the CLI keeps its identity and pairings after this extraction.

For another crate alongside `cli/` in this workspace:

```toml
[dependencies]
localsend-session = { path = "../packages/session" }
tokio = { version = "1", features = ["full"] }
anyhow = "1"
```

For example, send a file and wait for its completion:

```rust,no_run
use localsend_session::{
    Identity, PairedDevices, ReceivePolicy, SendPayload, Session,
    SessionConfig, SessionEvent, Target,
};
use std::{path::PathBuf, sync::Arc, time::Duration};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let profile = PathBuf::from("./sender-profile");
    std::fs::create_dir_all(&profile)?;
    let mut session = Session::start(SessionConfig {
        identity: Arc::new(Identity::load_or_generate(
            &profile, "My sender".into(), 53317,
        )?),
        paired: PairedDevices::load(&profile)?,
        destination: PathBuf::from("./incoming"),
        receive_policy: ReceivePolicy::Disabled,
    }).await?;

    let transfer_id = session.send(
        Target::parse("192.0.2.20")?,
        SendPayload::paths(vec![PathBuf::from("report.pdf")])?,
        Some(Duration::from_secs(60)),
    )?;

    let success = loop {
        match session.next_event().await? {
            SessionEvent::SendCompleted { transfer_id: id, success, .. }
                if id == transfer_id => break success,
            _ => {}
        }
    };
    session.shutdown().await;
    anyhow::ensure!(success, "Transfer failed");
    Ok(())
}
```

Use `send_to_port` for a peer listening on a non-default port, and `SendPayload::message` for UTF-8 text. Path payloads expand directories and prepare protocol metadata in the library.

`ReceivePolicy::Disabled` declines incoming transfers. `Paired` accepts paired peers, `Auto` accepts every sender, and `Decision` accepts paired peers while exposing other requests as `SessionEvent::ReceiveRequest`. Answer a request with `decide_receive` using its exact session ID. Incoming text offers follow the same policy and file-saving behavior as the CLI's existing noninteractive receiver. `status` returns typed queued, active, receiving, and pending state; `cancel` accepts a transfer or receive session ID.

Poll `next_event` continuously while the session is active: it drives discovery, receive decisions, timeouts, and transfer completion. It is cancellation-safe in `tokio::select!`, so a caller can select between session events and its own commands. Call `shutdown` to wait for network cleanup; dropping the session also signals its network tasks to stop. Long-running consumers should keep handling incoming requests and completion events while an outgoing transfer is active.

Run direct library and CLI process tests from the repository root:

```sh
cargo test -p localsend-session -p localsend-cli --locked
```

The direct library tests create real sessions and compare received bytes. The CLI process tests exercise one-shot commands and persistent stdio sessions. The [network lab](../../support/network_lab/README.md) runs the same CLI across routed, isolated, multihomed, IPv4, and IPv6 Linux topologies.
