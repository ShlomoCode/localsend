#![cfg(feature = "http")]

use bytes::Bytes;
use localsend::http::client::{HttpEndpoint, LsHttpClient, LsHttpClientV2, LsHttpClientVersion};
use localsend::http::dto::{PrepareUploadRequestDto, RegisterDto};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2, ServerHandle, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::{FileContent, FileDto};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_util::sync::CancellationToken;

struct Identity {
    cert: String,
    private_key: String,
    fingerprint: String,
}

fn identity() -> Identity {
    let cert = localsend::crypto::cert::generate_self_signed().unwrap();
    Identity {
        cert: cert.certificate_pem,
        private_key: cert.private_key_pem,
        fingerprint: cert.fingerprint,
    }
}

struct TestServer {
    port: u16,
    prepare_count: Arc<AtomicUsize>,
    received: Arc<Mutex<Vec<u8>>>,
    _handle: ServerHandle,
    _stop: oneshot::Sender<()>,
}

async fn server(
    identity: &Identity,
    claimed_fingerprint: &str,
    v2_enabled: bool,
    tls: bool,
) -> TestServer {
    let (stop, stop_rx) = oneshot::channel();
    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(8);
    let prepare_count = Arc::new(AtomicUsize::new(0));
    let received = Arc::new(Mutex::new(Vec::new()));
    tokio::spawn({
        let prepare_count = prepare_count.clone();
        let received = received.clone();
        async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        prepare_count.fetch_add(1, Ordering::SeqCst);
                        let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(
                            files.keys().cloned().collect(),
                        ));
                    }
                    ServerEventV2::FileUpload { target_tx, .. } => {
                        let (binary_tx, mut binary_rx) = mpsc::channel(8);
                        let (result_tx, result_rx) = oneshot::channel();
                        let _ = target_tx.send(FileUploadTarget::Stream {
                            binary_tx,
                            result_rx,
                        });
                        let received = received.clone();
                        tokio::spawn(async move {
                            let mut bytes = Vec::new();
                            while let Some(chunk) = binary_rx.recv().await {
                                bytes.extend_from_slice(&chunk);
                            }
                            *received.lock().await = bytes;
                            let _ = result_tx.send(Ok(()));
                        });
                    }
                    _ => {}
                }
            }
        }
    });
    let handle = start_with_port(
        0,
        tls.then(|| TlsConfig {
            cert: identity.cert.clone(),
            private_key: identity.private_key.clone(),
        }),
        ClientInfo {
            alias: "Endpoint test".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: claimed_fingerprint.into(),
        },
        None,
        v2_enabled.then_some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx,
        }),
        WebConfig::default(),
        stop_rx,
    )
    .await
    .expect("server bind must succeed");
    TestServer {
        port: handle.port(),
        prepare_count,
        received,
        _handle: handle,
        _stop: stop,
    }
}

fn client(sender: &Identity, expected: Option<&str>) -> LsHttpClient {
    LsHttpClient::new(
        &sender.private_key,
        &sender.cert,
        LsHttpClientVersion::V2,
        expected.map(str::to_string),
        None,
    )
    .unwrap()
}

fn endpoint(port: u16, protocol: ProtocolType) -> HttpEndpoint {
    HttpEndpoint {
        host: "127.0.0.1".into(),
        port,
        protocol,
    }
}

#[tokio::test]
async fn stalled_first_address_does_not_block_authenticated_second_address() {
    let sender = identity();
    let peer = identity();
    let healthy = server(&peer, &peer.fingerprint, true, true).await;
    let stalled = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("stalled socket bind");
    let stalled_port = stalled.local_addr().unwrap().port();
    let accept_task = tokio::spawn(async move {
        let (_socket, _) = stalled.accept().await.unwrap();
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    });
    let client = client(&sender, Some(&peer.fingerprint));
    let direct = LsHttpClientV2::try_new(
        &sender.private_key,
        &sender.cert,
        Some(peer.fingerprint.clone()),
        None,
    )
    .unwrap();

    // The original first-address path hangs while the same pinned client can
    // authenticate the second server. This is the controlled failing baseline.
    assert!(tokio::time::timeout(
        std::time::Duration::from_millis(250),
        direct.info(ProtocolType::Https, "127.0.0.1", stalled_port)
    )
    .await
    .is_err());
    assert_eq!(
        direct
            .info(ProtocolType::Https, "127.0.0.1", healthy.port)
            .await
            .unwrap()
            .fingerprint,
        peer.fingerprint
    );

    let selected = client
        .select_endpoint(
            vec![
                endpoint(stalled_port, ProtocolType::Https),
                endpoint(healthy.port, ProtocolType::Https),
            ],
            ProtocolType::Https,
            peer.fingerprint.clone(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(selected, endpoint(healthy.port, ProtocolType::Https));

    let content = b"chosen route completes a real transfer".repeat(64);
    let file = FileDto {
        id: "route-file".into(),
        file_name: "route.bin".into(),
        size: content.len() as u64,
        file_type: "application/octet-stream".into(),
        sha256: None,
        preview: None,
        metadata: None,
    };
    let prepared = client
        .prepare_upload(
            selected.protocol,
            &selected.host,
            selected.port,
            None,
            PrepareUploadRequestDto {
                info: RegisterDto {
                    alias: "Route sender".into(),
                    version: "2.2".into(),
                    device_model: None,
                    device_type: None,
                    token: sender.fingerprint.clone(),
                    port: 53317,
                    protocol: ProtocolType::Https,
                    has_web_interface: false,
                },
                files: HashMap::from([(file.id.clone(), file)]),
            },
            None,
            CancellationToken::new(),
        )
        .await
        .expect("one prepare request should succeed");
    let session = prepared.response.expect("receiver accepted file");
    let token = session.files.get("route-file").expect("file token");
    let (tx, rx) = mpsc::channel(2);
    tx.send(Bytes::from(content.clone())).await.unwrap();
    drop(tx);
    client
        .upload(
            selected.protocol,
            &selected.host,
            selected.port,
            None,
            &session.session_id,
            "route-file",
            token,
            FileContent::Stream(rx),
            |_| {},
            CancellationToken::new(),
        )
        .await
        .expect("content upload should complete");
    assert_eq!(healthy.prepare_count.load(Ordering::SeqCst), 1);
    assert_eq!(*healthy.received.lock().await, content);
    accept_task.abort();
}

#[tokio::test]
async fn wrong_certificate_is_rejected_before_a_healthy_endpoint_wins() {
    let sender = identity();
    let peer = identity();
    let impostor = identity();
    let wrong = server(&impostor, &peer.fingerprint, true, true).await;
    let healthy = server(&peer, "wrong-body-claim", true, true).await;
    let client = client(&sender, Some(&peer.fingerprint));

    let selected = client
        .select_endpoint(
            vec![
                endpoint(wrong.port, ProtocolType::Https),
                endpoint(healthy.port, ProtocolType::Https),
            ],
            ProtocolType::Https,
            peer.fingerprint.clone(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    // A TLS certificate is authoritative even when /info claims a different
    // fingerprint, matching the existing discovery identity policy.
    assert_eq!(selected, endpoint(healthy.port, ProtocolType::Https));
}

#[tokio::test]
async fn https_404_remains_usable_when_certificate_is_pinned() {
    let sender = identity();
    let peer = identity();
    let legacy = server(&peer, &peer.fingerprint, false, true).await;
    let client = client(&sender, Some(&peer.fingerprint));

    let selected = client
        .select_endpoint(
            vec![endpoint(legacy.port, ProtocolType::Https)],
            ProtocolType::Https,
            peer.fingerprint.clone(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(selected, endpoint(legacy.port, ProtocolType::Https));
}

#[tokio::test]
async fn unpinned_https_client_and_http_404_cannot_pass_selection() {
    let sender = identity();
    let peer = identity();
    let legacy_http = server(&peer, &peer.fingerprint, false, false).await;
    let unpinned = client(&sender, None);
    assert!(unpinned
        .select_endpoint(
            vec![endpoint(legacy_http.port, ProtocolType::Https)],
            ProtocolType::Https,
            peer.fingerprint.clone(),
            CancellationToken::new(),
        )
        .await
        .is_err());

    assert!(unpinned
        .select_endpoint(
            vec![endpoint(legacy_http.port, ProtocolType::Http)],
            ProtocolType::Http,
            peer.fingerprint.clone(),
            CancellationToken::new(),
        )
        .await
        .is_err());
}

#[tokio::test]
async fn http_selection_rejects_wrong_identity_and_other_protocols() {
    let sender = identity();
    let peer = identity();
    let wrong_claim = server(&peer, "different-device", true, false).await;
    let healthy_http = server(&peer, &peer.fingerprint, true, false).await;
    let healthy_https = server(&peer, &peer.fingerprint, true, true).await;
    let client = client(&sender, Some(&peer.fingerprint));

    let selected = client
        .select_endpoint(
            vec![
                endpoint(healthy_https.port, ProtocolType::Https),
                endpoint(wrong_claim.port, ProtocolType::Http),
                endpoint(healthy_http.port, ProtocolType::Http),
            ],
            ProtocolType::Http,
            peer.fingerprint.clone(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(selected, endpoint(healthy_http.port, ProtocolType::Http));
}

#[tokio::test]
async fn cancellation_stops_a_stalled_probe() {
    let sender = identity();
    let peer = identity();
    let stalled = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("stalled socket bind");
    let port = stalled.local_addr().unwrap().port();
    let client = client(&sender, Some(&peer.fingerprint));
    let cancel = CancellationToken::new();
    let cancel_for_task = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancel_for_task.cancel();
    });

    let result = tokio::time::timeout(
        std::time::Duration::from_millis(500),
        client.select_endpoint(
            vec![endpoint(port, ProtocolType::Https)],
            ProtocolType::Https,
            peer.fingerprint,
            cancel,
        ),
    )
    .await
    .expect("cancellation should not wait for probe timeout");
    assert!(matches!(
        result,
        Err(localsend::http::client::ClientError::Cancelled)
    ));
}
