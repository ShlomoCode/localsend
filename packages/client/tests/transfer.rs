//! A consumer can transfer files through the Rust API without a CLI process.

use localsend_client::{
    Identity, PairedDevices, ReceivePolicy, SendPayload, Session, SessionConfig, SessionEvent,
    Target,
};
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "localsend-client-test-{}-{stamp}",
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

fn assert_port_released(port: u16) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match TcpListener::bind(("127.0.0.1", port)) {
            Ok(listener) => {
                drop(listener);
                return;
            }
            Err(_) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(error) => panic!("Session shutdown did not release port {port}: {error}"),
        }
    }
}

async fn send_and_accept(
    sender: &mut Session,
    receiver: &mut Session,
    receiver_port: u16,
    path: &Path,
    bytes: &[u8],
) {
    let transfer_id = sender
        .send_to_port(
            Target::parse("127.0.0.1").unwrap(),
            receiver_port,
            SendPayload::paths(vec![path.to_path_buf()]).unwrap(),
            Some(Duration::from_secs(25)),
        )
        .unwrap();
    let file_name = path.file_name().unwrap().to_string_lossy();
    let mut requested_session = None;
    let mut sent = false;
    let mut received = false;
    tokio::time::timeout(Duration::from_secs(30), async {
        while !sent || !received {
            tokio::select! {
                result = sender.next_event() => match result.unwrap() {
                    SessionEvent::SendCompleted { transfer_id: id, bytes: sent_bytes, success, error, .. } if id == transfer_id => {
                        assert!(success, "send failed: {error:?}");
                        assert_eq!(sent_bytes, bytes.len() as u64);
                        sent = true;
                    }
                    _ => {}
                },
                result = receiver.next_event() => match result.unwrap() {
                    SessionEvent::ReceiveRequest { session_id, files, .. } => {
                        assert!(requested_session.is_none(), "unexpected second receive request");
                        assert_eq!(files.len(), 1);
                        assert_eq!(files[0].name, file_name);
                        assert_eq!(files[0].size, bytes.len() as u64);
                        receiver.decide_receive(&session_id, true).unwrap();
                        requested_session = Some(session_id);
                    }
                    SessionEvent::ReceiveCompleted { session_id, files, bytes: received_bytes, success, error, .. } => {
                        assert_eq!(requested_session.as_deref(), Some(session_id.as_str()));
                        assert!(success, "receive failed: {error:?}");
                        assert_eq!(files, 1);
                        assert_eq!(received_bytes, bytes.len() as u64);
                        received = true;
                    }
                    _ => {}
                },
            }
        }
    }).await.expect("two Sessions did not finish the transfer");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_sessions_accept_and_save_repeated_file_transfers() {
    let fixture = Fixture::new();
    let sender_dir = fixture.directory("sender-identity");
    let receiver_dir = fixture.directory("receiver-identity");
    let downloads = fixture.directory("downloads");
    let sender_port = free_port();
    let mut receiver_port = free_port();
    while receiver_port == sender_port {
        receiver_port = free_port();
    }
    let sender = Session::start(SessionConfig {
        identity: Arc::new(
            Identity::load_or_generate(&sender_dir, "library sender".into(), sender_port).unwrap(),
        ),
        paired: PairedDevices::load(&sender_dir).unwrap(),
        destination: fixture.directory("sender-downloads"),
        receive_policy: ReceivePolicy::Disabled,
    })
    .await
    .unwrap();
    let receiver = Session::start(SessionConfig {
        identity: Arc::new(
            Identity::load_or_generate(&receiver_dir, "library receiver".into(), receiver_port)
                .unwrap(),
        ),
        paired: PairedDevices::load(&receiver_dir).unwrap(),
        destination: downloads.clone(),
        receive_policy: ReceivePolicy::Decision,
    })
    .await
    .unwrap();
    let (mut sender, mut receiver) = (sender, receiver);

    for (name, contents) in [
        ("first.bin", vec![0x5a; 70_000]),
        ("second.bin", (0..90_000).map(|n| (n % 251) as u8).collect()),
    ] {
        let path = fixture.0.join(name);
        fs::write(&path, &contents).unwrap();
        send_and_accept(&mut sender, &mut receiver, receiver_port, &path, &contents).await;
        assert_eq!(fs::read(downloads.join(name)).unwrap(), contents);
        assert!(sender.status().sending.is_none());
        assert!(receiver.status().receiving.is_none());
    }

    sender.shutdown().await;
    receiver.shutdown().await;
    assert_port_released(sender_port);
    assert_port_released(receiver_port);
}
