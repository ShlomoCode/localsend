#![cfg(unix)]

use bytes::Bytes;
use localsend_daemon::{
    config::{Config, SecurityContext},
    ipc::Endpoint,
    protocol::Reply,
    runtime::Runtime,
};
use serde_json::{Value, json};
use std::{os::unix::fs::PermissionsExt, path::PathBuf, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
};

const TOKEN: &str = "test-token-00000000000000000000000000000000";

struct Fixture {
    directory: PathBuf,
    socket: PathBuf,
    client: reqwest::Client,
    sender_fingerprint: String,
    port: u16,
    task: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl Fixture {
    async fn start(auto_accept: bool) -> Self {
        // macOS's per-user TMPDIR is too long for a sockaddr_un plus a UUID.
        let directory = PathBuf::from("/tmp").join(format!("lsd-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let downloads = directory.join("Downloads");
        std::fs::create_dir(&downloads).unwrap();
        let token = directory.join("token");
        std::fs::write(&token, TOKEN).unwrap();
        std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
        let identity = localsend::crypto::cert::generate_self_signed().unwrap();
        let config = Config {
            alias: "Background receiver".into(),
            port: 0,
            https: true,
            pin: None,
            verify_checksums: true,
            destination: downloads,
            auto_accept,
            discovery: false,
            multicast_group: localsend::multicast::DEFAULT_MULTICAST_GROUP,
            multicast_group_v6: None,
            security_context: SecurityContext {
                private_key: identity.private_key_pem,
                public_key: identity.public_key_pem,
                certificate: identity.certificate_pem,
                certificate_hash: identity.fingerprint,
            },
        };
        let socket = directory.join("daemon.sock");
        let endpoint = Endpoint::bind(&socket, &token).unwrap();
        let runtime = Runtime::start(config).await.unwrap();
        let port = runtime.snapshots.borrow().port;
        let task = tokio::spawn(endpoint.serve(runtime));
        let sender = localsend::crypto::cert::generate_self_signed().unwrap();
        let identity = reqwest::Identity::from_pem(
            format!("{}\n{}", sender.certificate_pem, sender.private_key_pem).as_bytes(),
        )
        .unwrap();
        let client = reqwest::Client::builder()
            .identity(identity)
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap();
        Self {
            directory,
            socket,
            client,
            sender_fingerprint: sender.fingerprint,
            port,
            task,
        }
    }

    async fn request(&self, mut request: Value) -> Reply {
        request["version"] = json!(1);
        request["id"] = json!("test");
        request["token"] = json!(TOKEN);
        let mut connection = UnixStream::connect(&self.socket).await.unwrap();
        connection
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();
        let mut line = String::new();
        BufReader::new(connection)
            .read_line(&mut line)
            .await
            .unwrap();
        serde_json::from_str(&line).unwrap()
    }

    async fn watch(&self) -> UnixStream {
        let mut stream = UnixStream::connect(&self.socket).await.unwrap();
        stream
            .write_all(
                format!(
                    "{}\n",
                    json!({"version":1,"id":"ui","token":TOKEN,"command":"watch"})
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        assert!(serde_json::from_str::<Reply>(&line).unwrap().ok);
        reader.into_inner()
    }

    fn prepare(&self, name: &str, size: u64) -> reqwest::RequestBuilder {
        self.client.post(format!("https://127.0.0.1:{}/api/localsend/v2/prepare-upload", self.port)).json(&json!({
            "info":{"alias":"Sender","version":"2.2","deviceType":"desktop","fingerprint":self.sender_fingerprint,
                "port":self.port,"protocol":"https","download":false},
            "files":{"file-1":{"id":"file-1","fileName":name,"size":size,"fileType":"application/octet-stream"}}
        }))
    }

    fn upload_url(&self, prepared: &Value) -> reqwest::Url {
        let mut url = reqwest::Url::parse(&format!(
            "https://127.0.0.1:{}/api/localsend/v2/upload",
            self.port
        ))
        .unwrap();
        url.query_pairs_mut()
            .append_pair("sessionId", prepared["sessionId"].as_str().unwrap())
            .append_pair("fileId", "file-1")
            .append_pair("token", prepared["files"]["file-1"].as_str().unwrap());
        url
    }

    async fn status(&self, expected: &str) -> localsend_daemon::protocol::Receive {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(receive) = self
                    .request(json!({"command":"snapshot"}))
                    .await
                    .snapshot
                    .unwrap()
                    .receive
                    && receive.status == expected
                {
                    return receive;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap()
    }

    async fn stop(self) {
        let reply = self.request(json!({"command":"shutdown"})).await;
        assert!(reply.ok);
        assert!(
            serde_json::to_vec(&reply).unwrap().len() < 1024,
            "Shutdown acknowledgment must fit native's bounded reader, even after a large offer"
        );
        tokio::time::timeout(Duration::from_secs(5), self.task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(!self.socket.exists());
        std::fs::remove_dir_all(self.directory).unwrap();
    }
}

#[tokio::test]
async fn pending_decision_and_active_upload_survive_ui_disconnect() {
    let fixture = Fixture::start(false).await;
    let ui = fixture.watch().await;
    let request = fixture.prepare("../../safe.txt", 6);
    let pending_http = tokio::spawn(async move { request.send().await.unwrap() });
    let pending = fixture.status("pending").await;
    drop(ui);
    assert!(
        !pending_http.is_finished(),
        "UI disconnect must not drop the HTTP responder"
    );
    let bad = fixture
        .request(json!({"command":"accept","session_id":"old-session"}))
        .await;
    assert_eq!(bad.error.unwrap().code, "stale_session");
    let bad = fixture
        .request(json!({"command":"accept","session_id":pending.session_id,"file_ids":["unknown"]}))
        .await;
    assert_eq!(bad.error.unwrap().code, "invalid_files");
    assert!(
        fixture
            .request(json!({"command":"accept","session_id":pending.session_id}))
            .await
            .ok
    );
    let response = pending_http.await.unwrap();
    assert_eq!(response.status(), 200);
    let response: Value = response.json().await.unwrap();
    let stale = fixture
        .request(json!({"command":"decline","session_id":pending.session_id}))
        .await;
    assert_eq!(stale.error.unwrap().code, "invalid_state");
    let ui = fixture.watch().await;
    let (chunks, receiver) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(2);
    let body = reqwest::Body::wrap_stream(futures_util::stream::unfold(
        receiver,
        |mut receiver| async { receiver.recv().await.map(|bytes| (bytes, receiver)) },
    ));
    let upload = fixture
        .client
        .post(fixture.upload_url(&response))
        .body(body);
    let upload = tokio::spawn(async move { upload.send().await.unwrap() });
    chunks.send(Ok(Bytes::from_static(b"abc"))).await.unwrap();
    fixture.status("receiving").await;
    drop(ui);
    chunks.send(Ok(Bytes::from_static(b"def"))).await.unwrap();
    drop(chunks);
    assert_eq!(upload.await.unwrap().status(), 200);
    let finished = fixture.status("finished").await;
    assert_eq!(finished.files[0].received_bytes, 6);
    assert_eq!(finished.files[0].status, "finished");
    let path = PathBuf::from(finished.files[0].path.as_ref().unwrap());
    assert_eq!(path.parent().unwrap(), fixture.directory.join("Downloads"));
    assert_eq!(std::fs::read(path).unwrap(), b"abcdef");

    // A peer holding its upload body open must not prevent native Quit.
    let request = fixture.prepare("still-uploading.txt", 6);
    let pending_http = tokio::spawn(async move { request.send().await.unwrap() });
    let next = fixture.status("pending").await;
    let stale = fixture
        .request(json!({"command":"decline","session_id":pending.session_id}))
        .await;
    assert_eq!(stale.error.unwrap().code, "stale_session");
    assert!(
        fixture
            .request(json!({"command":"accept","session_id":next.session_id}))
            .await
            .ok
    );
    let prepared: Value = pending_http.await.unwrap().json().await.unwrap();
    let (chunks, receiver) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(2);
    let body = reqwest::Body::wrap_stream(futures_util::stream::unfold(
        receiver,
        |mut receiver| async { receiver.recv().await.map(|bytes| (bytes, receiver)) },
    ));
    let request = fixture
        .client
        .post(fixture.upload_url(&prepared))
        .body(body);
    let stalled = tokio::spawn(async move { request.send().await });
    chunks.send(Ok(Bytes::from_static(b"abc"))).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if fixture.status("receiving").await.files[0].received_bytes == 3 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    fixture.stop().await;
    drop(chunks);
    let result = tokio::time::timeout(Duration::from_secs(5), stalled)
        .await
        .unwrap()
        .unwrap();
    assert!(
        result.is_err(),
        "Shutdown must terminate the stalled HTTP upload"
    );
}

#[tokio::test]
async fn authenticated_ipc_cannot_be_replaced_and_autoaccept_needs_no_ui() {
    let fixture = Fixture::start(true).await;
    let token = fixture.directory.join("token");
    assert!(
        Endpoint::bind(&fixture.socket, &token).is_err(),
        "Second owner must not unlink first owner's socket"
    );
    let mut stream = UnixStream::connect(&fixture.socket).await.unwrap();
    stream
        .write_all(b"{\"version\":1,\"id\":\"bad\",\"token\":\"wrong\",\"command\":\"shutdown\"}\n")
        .await
        .unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).await.unwrap();
    assert_eq!(
        serde_json::from_str::<Reply>(&line)
            .unwrap()
            .error
            .unwrap()
            .code,
        "unauthorized"
    );
    let response = fixture.prepare("empty.txt", 0).send().await.unwrap();
    assert_eq!(response.status(), 200);
    let prepared: Value = response.json().await.unwrap();
    let response = fixture
        .client
        .post(fixture.upload_url(&prepared))
        .body(Vec::new())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    fixture.status("finished").await;
    fixture.stop().await;
}

#[tokio::test]
async fn large_offer_has_full_ui_snapshot_and_small_native_wake_with_selective_receive() {
    let fixture = Fixture::start(false).await;
    let peer_alias = "Sender".repeat(180_000);
    let files: serde_json::Map<String, Value> = (0..10_000).map(|index| {
        let id = format!("file-{index}");
        (id.clone(), json!({"id":id,"fileName":format!("{index}-{}.txt", "x".repeat(100)),"size":1,"fileType":"text/plain"}))
    }).collect();
    let request = fixture.client.post(format!("https://127.0.0.1:{}/api/localsend/v2/prepare-upload", fixture.port)).json(&json!({
        "info":{"alias":peer_alias,"version":"2.2","fingerprint":fixture.sender_fingerprint,"port":fixture.port,"protocol":"https","download":false},
        "files":files,
    }));
    let pending_http = tokio::spawn(async move { request.send().await.unwrap() });
    let pending = fixture.status("pending").await;
    for full in [false, true] {
        let mut stream = UnixStream::connect(&fixture.socket).await.unwrap();
        stream.write_all(format!("{}\n", json!({"version":1,"id":"watch","token":TOKEN,"command":"watch","include_progress":full})).as_bytes()).await.unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).await.unwrap();
        let receive = serde_json::from_str::<Reply>(&line)
            .unwrap()
            .snapshot
            .unwrap()
            .receive
            .unwrap();
        if full {
            assert_eq!(receive.files.len(), 10_000);
            assert_eq!(receive.sender_alias, peer_alias);
            assert!(line.len() > 1024 * 1024);
        } else {
            assert!(receive.files.is_empty());
            assert!(receive.sender_alias.is_empty());
            assert!(receive.sender_fingerprint.is_empty());
            assert!(line.len() < 1024);
        }
    }
    assert!(
        fixture
            .request(
                json!({"command":"accept","session_id":pending.session_id,"file_ids":["file-9000"]})
            )
            .await
            .ok
    );
    let response = pending_http.await.unwrap();
    assert_eq!(response.status(), 200);
    let prepared: Value = response.json().await.unwrap();
    assert_eq!(prepared["files"].as_object().unwrap().len(), 1);
    let mut url = reqwest::Url::parse(&format!(
        "https://127.0.0.1:{}/api/localsend/v2/upload",
        fixture.port
    ))
    .unwrap();
    url.query_pairs_mut()
        .append_pair("sessionId", prepared["sessionId"].as_str().unwrap())
        .append_pair("fileId", "file-9000")
        .append_pair("token", prepared["files"]["file-9000"].as_str().unwrap());
    assert_eq!(
        fixture
            .client
            .post(url)
            .body("X")
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let finished = fixture.status("finished").await;
    let received = finished
        .files
        .iter()
        .find(|file| file.id == "file-9000")
        .unwrap();
    assert_eq!(received.status, "finished");
    assert_eq!(received.received_bytes, 1);
    assert_eq!(
        std::fs::read(received.path.as_ref().unwrap()).unwrap(),
        b"X"
    );
    assert!(
        finished
            .files
            .iter()
            .filter(|file| file.id != "file-9000")
            .all(|file| file.status == "skipped" && file.path.is_none())
    );
    fixture.stop().await;
}
