//! A consumer can transfer files through the Rust API without a CLI process.

use bytes::Bytes;
use localsend::crypto::hash::sha256_hex;
use localsend::http::client::{LsHttpClient, LsHttpClientVersion};
use localsend::http::dto::{PrepareUploadRequestDto, PrepareUploadResponseDto, RegisterDto};
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::{FileContent, FileDto};
use localsend_client::{
    Identity, PairedDevices, ReceivePolicy, SendPayload, Session, SessionConfig, SessionEvent,
    Target,
};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

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

async fn manual_receiver(fixture: &Fixture) -> (Session, Identity, Identity, PathBuf) {
    let sender_port = free_port();
    let mut receiver_port = free_port();
    while receiver_port == sender_port {
        receiver_port = free_port();
    }
    let sender_dir = fixture.directory("manual-sender");
    let receiver_dir = fixture.directory("manual-receiver");
    let downloads = fixture.directory("manual-downloads");
    let sender = Identity::load_or_generate(&sender_dir, "sender".into(), sender_port).unwrap();
    let receiver_identity =
        Identity::load_or_generate(&receiver_dir, "receiver".into(), receiver_port).unwrap();
    let session = Session::start(SessionConfig {
        identity: Arc::new(
            Identity::load_or_generate(&receiver_dir, "receiver".into(), receiver_port).unwrap(),
        ),
        paired: PairedDevices::load(&receiver_dir).unwrap(),
        destination: downloads.clone(),
        receive_policy: ReceivePolicy::Auto,
    })
    .await
    .unwrap();
    (session, sender, receiver_identity, downloads)
}

fn manual_client(sender: &Identity, receiver: &Identity) -> LsHttpClient {
    LsHttpClient::new(
        &sender.key_pem,
        &sender.cert_pem,
        LsHttpClientVersion::V2,
        Some(receiver.fingerprint.clone()),
        None,
    )
    .unwrap()
}

fn manual_info(sender: &Identity) -> RegisterDto {
    let info = sender.register_dto();
    RegisterDto {
        alias: info.alias,
        version: info.version,
        device_model: info.device_model,
        device_type: info.device_type,
        token: info.fingerprint,
        port: info.port,
        protocol: info.protocol,
        has_web_interface: info.download,
    }
}

fn offered_file(id: &str, name: &str, bytes: &[u8], sha256: Option<String>) -> FileDto {
    FileDto {
        id: id.into(),
        file_name: name.into(),
        size: bytes.len() as u64,
        file_type: "application/octet-stream".into(),
        sha256,
        preview: None,
        metadata: None,
    }
}

async fn prepare_manual(
    receiver: &mut Session,
    client: &LsHttpClient,
    sender: &Identity,
    receiver_port: u16,
    files: HashMap<String, FileDto>,
) -> PrepareUploadResponseDto {
    let prepare = client.prepare_upload(
        ProtocolType::Https,
        "127.0.0.1",
        receiver_port,
        None,
        PrepareUploadRequestDto {
            info: manual_info(sender),
            files,
        },
        None,
        CancellationToken::new(),
    );
    tokio::pin!(prepare);
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            tokio::select! {
                result = &mut prepare => return result.unwrap().response.unwrap(),
                event = receiver.next_event() => {
                    if let SessionEvent::ReceiveRequest { session_id, .. } = event.unwrap() {
                        receiver.decide_receive(&session_id, true).unwrap();
                    }
                }
            }
        }
    })
    .await
    .expect("prepare upload did not finish")
}

fn stream(bytes: Vec<u8>) -> FileContent {
    let (tx, rx) = mpsc::channel(1);
    tx.try_send(Bytes::from(bytes)).unwrap();
    drop(tx);
    FileContent::Stream(rx)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn simultaneous_files_with_the_same_name_keep_distinct_contents() {
    let fixture = Fixture::new();
    let (mut receiver, sender, receiver_identity, downloads) = manual_receiver(&fixture).await;
    let client = Arc::new(manual_client(&sender, &receiver_identity));
    let contents: Vec<Vec<u8>> = (0..12).map(|i| vec![i as u8; 70_000]).collect();
    let files = contents
        .iter()
        .enumerate()
        .map(|(i, bytes)| {
            let id = format!("file-{i}");
            (id.clone(), offered_file(&id, "same.bin", bytes, None))
        })
        .collect();
    let prepared = prepare_manual(
        &mut receiver,
        &client,
        &sender,
        receiver_identity.port,
        files,
    )
    .await;
    assert_eq!(prepared.files.len(), contents.len());
    let mut uploads = tokio::task::JoinSet::new();
    for (i, bytes) in contents.iter().enumerate() {
        let client = client.clone();
        let session_id = prepared.session_id.clone();
        let file_id = format!("file-{i}");
        let token = prepared.files[&file_id].clone();
        let port = receiver_identity.port;
        let content = stream(bytes.clone());
        uploads.spawn(async move {
            client
                .upload(
                    ProtocolType::Https,
                    "127.0.0.1",
                    port,
                    None,
                    &session_id,
                    &file_id,
                    &token,
                    content,
                    |_| {},
                    CancellationToken::new(),
                )
                .await
        });
    }
    let mut uploaded = 0;
    let mut completed = None;
    tokio::time::timeout(Duration::from_secs(30), async {
        while uploaded < contents.len() || completed.is_none() {
            tokio::select! {
                result = uploads.join_next(), if uploaded < contents.len() => {
                    result.unwrap().unwrap().unwrap();
                    uploaded += 1;
                }
                event = receiver.next_event(), if completed.is_none() => {
                    if let SessionEvent::ReceiveCompleted { files, bytes, failed_files, success, .. } = event.unwrap() {
                        completed = Some((files, bytes, failed_files, success));
                    }
                }
            }
        }
    }).await.expect("parallel uploads did not finish");
    assert_eq!(
        completed.unwrap(),
        (contents.len(), (contents.len() * 70_000) as u64, 0, true)
    );
    let saved: HashSet<Vec<u8>> = fs::read_dir(&downloads)
        .unwrap()
        .map(|entry| fs::read(entry.unwrap().path()).unwrap())
        .collect();
    assert_eq!(
        saved.len(),
        contents.len(),
        "files with the same name overwrote each other"
    );
    assert_eq!(saved, contents.into_iter().collect());
    receiver.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn checksum_retry_reuses_file_and_counts_only_the_final_success() {
    let fixture = Fixture::new();
    let (mut receiver, sender, receiver_identity, downloads) = manual_receiver(&fixture).await;
    let client = manual_client(&sender, &receiver_identity);
    let good = b"right bytes".to_vec();
    let bad = b"wrong bytes".to_vec();
    assert_eq!(bad.len(), good.len());
    let files = HashMap::from([(
        "file".to_string(),
        offered_file("file", "retry.bin", &good, Some(sha256_hex(&good))),
    )]);
    let prepared = prepare_manual(
        &mut receiver,
        &client,
        &sender,
        receiver_identity.port,
        files,
    )
    .await;
    let token = &prepared.files["file"];
    let bad_upload = client.upload(
        ProtocolType::Https,
        "127.0.0.1",
        receiver_identity.port,
        None,
        &prepared.session_id,
        "file",
        token,
        stream(bad),
        |_| {},
        CancellationToken::new(),
    );
    tokio::pin!(bad_upload);
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            tokio::select! {
                result = &mut bad_upload => { assert!(result.is_err(), "bad checksum must be rejected"); break; }
                event = receiver.next_event() => { let _ = event.unwrap(); }
            }
        }
    }).await.expect("bad upload did not finish");
    let good_upload = client.upload(
        ProtocolType::Https,
        "127.0.0.1",
        receiver_identity.port,
        None,
        &prepared.session_id,
        "file",
        token,
        stream(good.clone()),
        |_| {},
        CancellationToken::new(),
    );
    tokio::pin!(good_upload);
    let mut upload_done = false;
    let mut completed = None;
    tokio::time::timeout(Duration::from_secs(15), async {
        while !upload_done || completed.is_none() {
            tokio::select! {
                result = &mut good_upload, if !upload_done => { result.unwrap(); upload_done = true; }
                event = receiver.next_event(), if completed.is_none() => {
                    if let SessionEvent::ReceiveCompleted { files, bytes, failed_files, success, .. } = event.unwrap() {
                        completed = Some((files, bytes, failed_files, success));
                    }
                }
            }
        }
    }).await.expect("checksum retry did not finish");
    assert_eq!(completed.unwrap(), (1, good.len() as u64, 0, true));
    assert_eq!(fs::read(downloads.join("retry.bin")).unwrap(), good);
    assert_eq!(
        fs::read_dir(downloads).unwrap().count(),
        1,
        "retry must reuse its path"
    );
    receiver.shutdown().await;
}
