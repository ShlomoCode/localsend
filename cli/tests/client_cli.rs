//! Exercise the existing headless CLI against the public client library.

use anyhow::{Context, ensure};
use localsend_client::{
    Identity, PairedDevices, ReceivePolicy, Session, SessionConfig, SessionEvent,
};
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::process::Command;

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "localsend-cli-client-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn directory(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::create_dir(&path).unwrap();
        path
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

async fn send_and_receive(
    receiver: &mut Session,
    sender_config: &Path,
    sender_port: u16,
    args: &[&str],
    expected_files: usize,
) -> anyhow::Result<()> {
    let mut command = Command::new(env!("CARGO_BIN_EXE_localsend-cli"));
    command
        .env("XDG_CONFIG_HOME", sender_config)
        .arg("--port")
        .arg(sender_port.to_string())
        .arg("send")
        .arg("--to")
        .arg("127.0.0.1")
        .args(args)
        .stdin(Stdio::null())
        .kill_on_drop(true);

    let outcome = tokio::time::timeout(Duration::from_secs(45), async {
        let mut child_output = Box::pin(command.output());
        let mut output = None;
        let mut received = false;
        while output.is_none() || !received {
            tokio::select! {
                result = &mut child_output, if output.is_none() => {
                    let result = result.context("failed to run CLI")?;
                    ensure!(result.status.success(), "CLI failed: {}", String::from_utf8_lossy(&result.stderr));
                    output = Some(result);
                }
                event = receiver.next_event(), if !received => {
                    if let SessionEvent::ReceiveCompleted { files, success, error, .. } = event? {
                        ensure!(success, "receive failed: {error:?}");
                        ensure!(files == expected_files, "received {files} files, expected {expected_files}");
                        received = true;
                    }
                }
            }
        }
        Ok::<(), anyhow::Error>(())
    })
    .await
    .context("CLI transfer timed out")?;
    outcome
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn headless_cli_sends_files_and_text_to_client_session() {
    let fixture = Fixture::new();
    let receiver_config = fixture.directory("receiver-config");
    let sender_config = fixture.directory("sender-config");
    let downloads = fixture.directory("downloads");
    let source = fixture.directory("source");
    let report = source.join("report.bin");
    let folder = source.join("photos");
    fs::create_dir(&folder).unwrap();
    let nested = folder.join("notes.txt");
    let report_bytes: Vec<u8> = (0..90_000).map(|n| (n % 251) as u8).collect();
    let nested_bytes = b"nested file from a directory\n";
    fs::write(&report, &report_bytes).unwrap();
    fs::write(&nested, nested_bytes).unwrap();

    // The original `send --to IP` probes LocalSend's fixed default peer port.
    // A bind failure here reports that the test environment already owns it.
    let receiver_port = 53317;
    let mut sender_port = free_port();
    while sender_port == receiver_port {
        sender_port = free_port();
    }
    let mut receiver = Session::start(SessionConfig {
        identity: Arc::new(
            Identity::load_or_generate(&receiver_config, "library receiver".into(), receiver_port)
                .unwrap(),
        ),
        paired: PairedDevices::load(&receiver_config).unwrap(),
        destination: downloads.clone(),
        receive_policy: ReceivePolicy::Auto,
    })
    .await
    .expect("could not start receiver on LocalSend's default port 53317");

    let result = async {
        send_and_receive(
            &mut receiver,
            &sender_config,
            sender_port,
            &[report.to_str().unwrap(), folder.to_str().unwrap()],
            2,
        )
        .await?;
        ensure!(
            fs::read(downloads.join("report.bin"))? == report_bytes,
            "report bytes changed in transit"
        );
        ensure!(
            fs::read(downloads.join("notes.txt"))? == nested_bytes,
            "nested file bytes changed in transit"
        );

        // Long text exercises the CLI's `--text` path and is uploaded as a file.
        let text = "message ".repeat(8_001);
        send_and_receive(
            &mut receiver,
            &sender_config,
            sender_port,
            &["--text", &text],
            1,
        )
        .await?;
        let message_files: Vec<_> = fs::read_dir(&downloads)?
            .map(|entry| entry.map(|entry| entry.path()))
            .collect::<Result<_, _>>()?;
        let message_file = message_files
            .into_iter()
            .find(|path| {
                path.extension().is_some_and(|extension| extension == "txt")
                    && path.file_name().unwrap() != "notes.txt"
            })
            .context("text upload did not create a file")?;
        ensure!(
            fs::read(message_file)? == text.as_bytes(),
            "text bytes changed in transit"
        );
        Ok::<(), anyhow::Error>(())
    }
    .await;
    receiver.shutdown().await;
    result.unwrap();
}
