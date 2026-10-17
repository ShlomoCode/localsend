use crate::identity::Identity;
use crate::offer::SendPayload;
use crate::paired::PairedDevices;
use crate::sanitize;
use crate::send_task::{self, SendCancel, TaskEvent};
use crate::target::TargetSelector;
use crate::util;
use anyhow::{anyhow, ensure};
use localsend::discovery::{
    DEFAULT_DISCOVERY_TIMEOUT, DeviceIdentity, DiscoveryConfig, DiscoveryEvent, DiscoveryHandle,
    HttpChannel,
};
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{ServerConfigV2, ServerHandle, start_with_port};
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileDto;
use localsend::multicast::{DEFAULT_MULTICAST_GROUP, DEFAULT_MULTICAST_GROUP_V6, DEFAULT_PORT};
use localsend::util::interface::{InterfaceFilter, local_interface_addresses};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReceivePolicy {
    Disabled,
    Paired,
    Auto,
    Decision,
}

pub struct SessionConfig {
    pub identity: Arc<Identity>,
    pub paired: PairedDevices,
    pub destination: PathBuf,
    pub receive_policy: ReceivePolicy,
}

#[derive(Clone, Debug)]
pub struct Device {
    pub alias: String,
    pub fingerprint: String,
    pub host: String,
    pub port: u16,
    pub paired: bool,
}

#[derive(Clone, Debug)]
pub struct FileSummary {
    pub id: String,
    pub name: String,
    pub size: u64,
}

#[derive(Clone, Debug)]
pub enum SessionEvent {
    DiscoveryCompleted {
        devices: Vec<Device>,
    },
    MulticastFailed,
    ReceiveRequest {
        session_id: String,
        alias: String,
        fingerprint: String,
        files: Vec<FileSummary>,
    },
    ReceiveStarted {
        session_id: String,
        alias: String,
        files: usize,
        bytes: u64,
    },
    ReceiveCompleted {
        session_id: String,
        alias: String,
        files: usize,
        bytes: u64,
        failed_files: usize,
        success: bool,
        error: Option<String>,
    },
    ReceiveDeclined {
        session_id: String,
        reason: String,
    },
    ReceiveAborted {
        session_id: String,
    },
    ReceiveFileFailed {
        session_id: String,
        file_id: String,
        error: String,
    },
    SendStarted {
        transfer_id: String,
        session_id: String,
        bytes: u64,
    },
    SendCompleted {
        transfer_id: String,
        session_id: Option<String>,
        bytes: u64,
        success: bool,
        error: Option<String>,
    },
    Log(String),
}

#[derive(Clone, Debug)]
pub struct TransferStatus {
    pub transfer_id: String,
    pub session_id: Option<String>,
    pub bytes: u64,
}

#[derive(Clone, Debug)]
pub struct ReceiveStatus {
    pub session_id: String,
    pub alias: String,
}

#[derive(Clone, Debug, Default)]
pub struct SessionStatus {
    pub sending: Option<TransferStatus>,
    pub queued_send: Option<String>,
    pub receiving: Option<ReceiveStatus>,
    pub pending_receive: Option<ReceiveStatus>,
}

struct PendingReceive {
    session_id: String,
    alias: String,
    files: HashMap<String, FileDto>,
    decision: oneshot::Sender<PrepareUploadDecisionV2>,
}

struct Receiving {
    session_id: String,
    alias: String,
    files: HashMap<String, FileDto>,
    outstanding: HashSet<String>,
    finished: usize,
    bytes: u64,
    failures: usize,
    ended: Option<SessionEndReasonV2>,
}

struct Sending {
    transfer_id: String,
    session_id: Option<String>,
    cancel: SendCancel,
    sent: Arc<AtomicU64>,
    host: String,
    deadline: Option<Instant>,
    completion_emitted: bool,
}

struct PendingSend {
    transfer_id: String,
    target: TargetSelector,
    port: Option<u16>,
    payload: SendPayload,
    deadline: Option<Instant>,
}

enum InternalEvent {
    DiscoveryFinished(Option<String>),
    ReceiveFileResult {
        session_id: String,
        file_id: String,
        result: Result<(), String>,
    },
}

/// One live LocalSend identity and its network/transfer state. The caller
/// drives its events through `next_event`, without depending on a terminal or
/// JSON protocol.
pub struct Session {
    config: SessionConfig,
    server: Arc<ServerHandle>,
    server_stop: Option<oneshot::Sender<()>>,
    server_rx: mpsc::Receiver<ServerEventV2>,
    discovery: Arc<DiscoveryHandle>,
    discovery_stop: Option<oneshot::Sender<()>>,
    discovery_rx: mpsc::Receiver<DiscoveryEvent>,
    internal_tx: mpsc::Sender<InternalEvent>,
    internal_rx: mpsc::Receiver<InternalEvent>,
    send_tx: mpsc::Sender<TaskEvent>,
    send_rx: mpsc::Receiver<TaskEvent>,
    events: VecDeque<SessionEvent>,
    discovery_active: bool,
    queued_discovery: Option<Option<HttpChannel>>,
    pending_send: Option<PendingSend>,
    sending: Option<Sending>,
    pending_receive: Option<PendingReceive>,
    receiving: Option<Receiving>,
}

impl Session {
    pub async fn start(config: SessionConfig) -> anyhow::Result<Self> {
        let (server_tx, server_rx) = mpsc::channel(16);
        let (server_stop, server_stop_rx) = oneshot::channel();
        let server = start_with_port(
            config.identity.port,
            Some(config.identity.tls_config()),
            config.identity.client_info(),
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: true,
                event_tx: server_tx,
            }),
            WebConfig::default(),
            server_stop_rx,
        )
        .await?;
        let (discovery_tx, discovery_rx) = mpsc::channel(16);
        let (discovery_stop, discovery_stop_rx) = oneshot::channel();
        let discovery = Arc::new(
            localsend::discovery::start(
                DiscoveryConfig {
                    group: DEFAULT_MULTICAST_GROUP,
                    group_v6: Some(DEFAULT_MULTICAST_GROUP_V6),
                    port: DEFAULT_PORT,
                    interface_filter: InterfaceFilter::default(),
                    device: config.identity.multicast_device(),
                    identity: DeviceIdentity {
                        cert_pem: config.identity.cert_pem.clone(),
                        private_key_pem: config.identity.key_pem.clone(),
                    },
                    timeout: DEFAULT_DISCOVERY_TIMEOUT,
                    event_tx: Some(discovery_tx),
                },
                discovery_stop_rx,
            )
            .await,
        );
        let (internal_tx, internal_rx) = mpsc::channel(64);
        let (send_tx, send_rx) = mpsc::channel(64);
        let mut events = VecDeque::new();
        if let Some(error) = discovery.multicast_error() {
            events.push_back(SessionEvent::Log(format!(
                "Multicast unavailable: {error:#}"
            )));
        }
        Ok(Self {
            config,
            server: Arc::new(server),
            server_stop: Some(server_stop),
            server_rx,
            discovery,
            discovery_stop: Some(discovery_stop),
            discovery_rx,
            internal_tx,
            internal_rx,
            send_tx,
            send_rx,
            events,
            discovery_active: false,
            queued_discovery: None,
            pending_send: None,
            sending: None,
            pending_receive: None,
            receiving: None,
        })
    }

    pub fn alias(&self) -> &str {
        &self.config.identity.alias
    }
    pub fn port(&self) -> u16 {
        self.config.identity.port
    }

    pub fn devices(&self) -> Vec<Device> {
        let mut devices: Vec<_> = self
            .discovery
            .devices()
            .into_iter()
            .filter_map(|stored| {
                let http = stored.get_best_channel()?.http()?;
                Some(Device {
                    alias: stored.device.alias.clone(),
                    fingerprint: stored.device.fingerprint.clone(),
                    host: http.host.clone(),
                    port: http.port,
                    paired: self.config.paired.contains(&stored.device.fingerprint),
                })
            })
            .collect();
        devices.sort_by(|a, b| a.fingerprint.cmp(&b.fingerprint));
        devices
    }

    /// Start a staged discovery. A direct channel is probed before subnet
    /// scanning. Calls made while discovery runs are serialized.
    pub fn discover(&mut self, direct: Option<HttpChannel>) {
        if self.discovery_active {
            if direct.is_some() || self.queued_discovery.is_none() {
                self.queued_discovery = Some(direct);
            }
            return;
        }
        self.discovery_active = true;
        let mut channels = self.config.paired.known_http_channels();
        if let Some(channel) = direct
            && !channels.contains(&channel)
        {
            channels.insert(0, channel);
        }
        let discovery = self.discovery.clone();
        let tx = self.internal_tx.clone();
        let port = self.config.identity.port;
        tokio::spawn(async move {
            let ips = local_interface_addresses(&InterfaceFilter::default()).unwrap_or_default();
            let result = discovery
                .discover_staged(
                    channels,
                    ips,
                    port,
                    ProtocolType::Https,
                    Duration::from_secs(1),
                )
                .await;
            let _ = tx
                .send(InternalEvent::DiscoveryFinished(
                    result.err().map(|error| error.to_string()),
                ))
                .await;
        });
    }

    /// Queue one send. Its transfer ID identifies all subsequent send events.
    /// Sending progresses while `next_event` is polled.
    pub fn send(
        &mut self,
        target: TargetSelector,
        payload: SendPayload,
        timeout: Option<Duration>,
    ) -> anyhow::Result<String> {
        ensure!(
            self.sending.is_none() && self.pending_send.is_none(),
            "A send is already in progress"
        );
        let deadline = timeout
            .map(|timeout| {
                Instant::now()
                    .checked_add(timeout)
                    .ok_or_else(|| anyhow!("timeout is too large"))
            })
            .transpose()?;
        let id = Uuid::new_v4().to_string();
        let direct = target.direct_channel();
        self.pending_send = Some(PendingSend {
            transfer_id: id.clone(),
            target,
            port: None,
            payload,
            deadline,
        });
        self.discover(direct);
        Ok(id)
    }

    /// Like `send`, but use an explicit port for a direct IP address.
    pub fn send_to_port(
        &mut self,
        target: TargetSelector,
        port: u16,
        payload: SendPayload,
        timeout: Option<Duration>,
    ) -> anyhow::Result<String> {
        ensure!(
            self.sending.is_none() && self.pending_send.is_none(),
            "A send is already in progress"
        );
        let deadline = timeout
            .map(|timeout| {
                Instant::now()
                    .checked_add(timeout)
                    .ok_or_else(|| anyhow!("timeout is too large"))
            })
            .transpose()?;
        let id = Uuid::new_v4().to_string();
        let direct = target.direct_channel_at(port);
        self.pending_send = Some(PendingSend {
            transfer_id: id.clone(),
            target,
            port: Some(port),
            payload,
            deadline,
        });
        self.discover(direct);
        Ok(id)
    }

    pub fn decide_receive(&mut self, session_id: &str, accept: bool) -> anyhow::Result<()> {
        let pending = self
            .pending_receive
            .take()
            .ok_or_else(|| anyhow!("No pending receive request"))?;
        if pending.session_id != session_id {
            self.pending_receive = Some(pending);
            return Err(anyhow!("Unknown pending session"));
        }
        if accept {
            self.accept(pending);
        } else {
            let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
        }
        Ok(())
    }

    pub async fn cancel(&mut self, id: &str) -> anyhow::Result<()> {
        if self
            .pending_send
            .as_ref()
            .is_some_and(|pending| pending.transfer_id == id)
        {
            let pending = self.pending_send.take().unwrap();
            self.events.push_back(SessionEvent::SendCompleted {
                transfer_id: pending.transfer_id,
                session_id: None,
                bytes: 0,
                success: false,
                error: Some("Cancelled".to_string()),
            });
            return Ok(());
        }
        if let Some(sending) = &self.sending
            && sending.transfer_id == id
        {
            sending.cancel.token.cancel();
            return Ok(());
        }
        if let Some(receiving) = &self.receiving
            && receiving.session_id == id
        {
            self.server.cancel_v2_session(id).await;
            let receiving = self.receiving.take().unwrap();
            self.events.push_back(SessionEvent::ReceiveCompleted {
                session_id: id.to_string(),
                alias: receiving.alias,
                files: receiving.finished,
                bytes: receiving.bytes,
                failed_files: receiving.failures,
                success: false,
                error: Some("Cancelled".to_string()),
            });
            return Ok(());
        }
        Err(anyhow!("Unknown active transfer"))
    }

    pub fn status(&self) -> SessionStatus {
        SessionStatus {
            sending: self.sending.as_ref().map(|s| TransferStatus {
                transfer_id: s.transfer_id.clone(),
                session_id: s.session_id.clone(),
                bytes: s.sent.load(Ordering::Relaxed),
            }),
            queued_send: self.pending_send.as_ref().map(|s| s.transfer_id.clone()),
            receiving: self.receiving.as_ref().map(|r| ReceiveStatus {
                session_id: r.session_id.clone(),
                alias: r.alias.clone(),
            }),
            pending_receive: self.pending_receive.as_ref().map(|r| ReceiveStatus {
                session_id: r.session_id.clone(),
                alias: r.alias.clone(),
            }),
        }
    }

    pub async fn next_event(&mut self) -> anyhow::Result<SessionEvent> {
        loop {
            self.check_timeouts();
            if let Some(event) = self.events.pop_front() {
                return Ok(event);
            }
            tokio::select! {
                Some(event) = self.server_rx.recv() => self.handle_server(event)?,
                Some(event) = self.discovery_rx.recv() => self.handle_discovery(event),
                Some(event) = self.internal_rx.recv() => self.handle_internal(event)?,
                Some(event) = self.send_rx.recv() => self.handle_send(event),
                _ = tokio::time::sleep(Duration::from_millis(250)) => self.check_timeouts(),
            }
        }
    }

    pub async fn shutdown(mut self) {
        if let Some(sending) = &self.sending {
            sending.cancel.token.cancel();
        }
        if let Some(pending) = self.pending_receive.take() {
            let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
        }
        if let Some(receiving) = &self.receiving {
            self.server.cancel_v2_session(&receiving.session_id).await;
        }
        if self.sending.is_some() {
            let _ = tokio::time::timeout(Duration::from_secs(5), async {
                while let Some(event) = self.send_rx.recv().await {
                    if matches!(event, TaskEvent::Ended { .. }) {
                        break;
                    }
                }
            })
            .await;
        }
        self.server_stop.take();
        self.discovery_stop.take();
        let _ = tokio::time::timeout(Duration::from_secs(1), self.server.wait_stopped()).await;
        let _ = tokio::time::timeout(Duration::from_secs(1), self.discovery.wait_stopped()).await;
    }

    fn handle_discovery(&mut self, event: DiscoveryEvent) {
        if matches!(event, DiscoveryEvent::MulticastFailed) {
            self.events.push_back(SessionEvent::MulticastFailed);
        }
    }

    fn handle_internal(&mut self, event: InternalEvent) -> anyhow::Result<()> {
        match event {
            InternalEvent::DiscoveryFinished(error) => {
                if let Some(error) = error {
                    self.events
                        .push_back(SessionEvent::Log(format!("Discovery failed: {error}")));
                }
                self.discovery_active = false;
                if let Some(next) = self.queued_discovery.take() {
                    self.discover(next);
                    return Ok(());
                }
                if let Some(pending) = self.pending_send.take() {
                    let transfer_id = pending.transfer_id.clone();
                    if let Err(error) = self.start_send(pending) {
                        self.events.push_back(SessionEvent::SendCompleted {
                            transfer_id,
                            session_id: None,
                            bytes: 0,
                            success: false,
                            error: Some(error.to_string()),
                        });
                    }
                }
                self.events.push_back(SessionEvent::DiscoveryCompleted {
                    devices: self.devices(),
                });
            }
            InternalEvent::ReceiveFileResult {
                session_id,
                file_id,
                result,
            } => {
                if let Some(receiving) = self
                    .receiving
                    .as_mut()
                    .filter(|r| r.session_id == session_id)
                {
                    receiving.outstanding.remove(&file_id);
                    match result {
                        Ok(()) => {
                            receiving.finished += 1;
                            receiving.bytes +=
                                receiving.files.get(&file_id).map(|f| f.size).unwrap_or(0);
                        }
                        Err(error) => {
                            receiving.failures += 1;
                            self.events.push_back(SessionEvent::ReceiveFileFailed {
                                session_id,
                                file_id,
                                error,
                            });
                        }
                    }
                    self.finish_receive();
                }
            }
        }
        Ok(())
    }

    fn start_send(&mut self, pending: PendingSend) -> anyhow::Result<()> {
        let fingerprint = pending
            .target
            .resolve_at(
                &self.discovery.devices(),
                pending.port.unwrap_or(DEFAULT_PORT),
            )
            .map_err(|e| anyhow!(e))?;
        let mut device = self
            .discovery
            .device_by_fingerprint(&fingerprint)
            .ok_or_else(|| anyhow!("Destination disappeared"))?;
        pending
            .target
            .restrict_device(&mut device, pending.port.unwrap_or(DEFAULT_PORT))
            .map_err(|e| anyhow!(e))?;
        let host = device
            .get_best_channel()
            .and_then(|channel| channel.http())
            .ok_or_else(|| anyhow!("Destination has no dialable address"))?
            .host
            .clone();
        let sent = Arc::new(AtomicU64::new(0));
        let cancel = SendCancel::new();
        self.sending = Some(Sending {
            transfer_id: pending.transfer_id.clone(),
            session_id: None,
            cancel: cancel.clone(),
            sent: sent.clone(),
            host,
            deadline: pending.deadline,
            completion_emitted: false,
        });
        let (files, sources) = pending.payload.into_parts();
        tokio::spawn(send_task::run_send(
            self.config.identity.clone(),
            device,
            files,
            sources,
            sent,
            cancel,
            self.send_tx.clone(),
        ));
        Ok(())
    }

    fn handle_send(&mut self, event: TaskEvent) {
        match event {
            TaskEvent::Started {
                session_id,
                accepted_bytes,
            } => {
                if let Some(sending) = self.sending.as_mut() {
                    sending.session_id = Some(session_id.clone());
                    self.events.push_back(SessionEvent::SendStarted {
                        transfer_id: sending.transfer_id.clone(),
                        session_id,
                        bytes: accepted_bytes,
                    });
                }
            }
            TaskEvent::Ended { success } => {
                if let Some(sending) = self.sending.take()
                    && !sending.completion_emitted
                {
                    self.events.push_back(SessionEvent::SendCompleted {
                        transfer_id: sending.transfer_id,
                        session_id: sending.session_id,
                        bytes: sending.sent.load(Ordering::Relaxed),
                        success,
                        error: None,
                    });
                }
            }
            TaskEvent::Log(text) => self.events.push_back(SessionEvent::Log(text)),
        }
    }

    fn check_timeouts(&mut self) {
        if self.pending_send.as_ref().is_some_and(|send| {
            send.deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
        }) {
            let pending = self.pending_send.take().unwrap();
            self.events.push_back(SessionEvent::SendCompleted {
                transfer_id: pending.transfer_id,
                session_id: None,
                bytes: 0,
                success: false,
                error: Some("Timed out discovering destination".to_string()),
            });
        }
        if self.sending.as_ref().is_some_and(|send| {
            send.deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
        }) {
            let sending = self.sending.as_mut().unwrap();
            sending.cancel.token.cancel();
            sending.deadline = None;
            sending.completion_emitted = true;
            self.events.push_back(SessionEvent::SendCompleted {
                transfer_id: sending.transfer_id.clone(),
                session_id: sending.session_id.clone(),
                bytes: sending.sent.load(Ordering::Relaxed),
                success: false,
                error: Some("Timed out sending".to_string()),
            });
        }
    }

    fn accept(&mut self, pending: PendingReceive) {
        let ids = pending.files.keys().cloned().collect();
        if pending
            .decision
            .send(PrepareUploadDecisionV2::Accept(ids))
            .is_ok()
        {
            let files = pending.files.len();
            let bytes = pending.files.values().map(|f| f.size).sum();
            self.events.push_back(SessionEvent::ReceiveStarted {
                session_id: pending.session_id.clone(),
                alias: pending.alias.clone(),
                files,
                bytes,
            });
            self.receiving = Some(Receiving {
                session_id: pending.session_id,
                alias: pending.alias,
                files: pending.files,
                outstanding: HashSet::new(),
                finished: 0,
                bytes: 0,
                failures: 0,
                ended: None,
            });
        }
    }

    fn finish_receive(&mut self) {
        if !self
            .receiving
            .as_ref()
            .is_some_and(|r| r.ended.is_some() && r.outstanding.is_empty())
        {
            return;
        }
        let received = self.receiving.take().unwrap();
        let success =
            matches!(received.ended, Some(SessionEndReasonV2::Finished)) && received.failures == 0;
        self.events.push_back(SessionEvent::ReceiveCompleted {
            session_id: received.session_id,
            alias: received.alias,
            files: received.finished,
            bytes: received.bytes,
            failed_files: received.failures,
            success,
            error: None,
        });
    }

    fn handle_server(&mut self, event: ServerEventV2) -> anyhow::Result<()> {
        match event {
            ServerEventV2::Register { ip, info } => self.device_confirmed(ip.to_string(), info),
            ServerEventV2::PrepareUpload {
                session_id,
                ip,
                info,
                cert_fingerprint,
                files,
                decision_tx,
            } => {
                self.device_confirmed(ip.to_string(), info.clone());
                let fingerprint = cert_fingerprint.unwrap_or(info.fingerprint);
                let alias = sanitize::single_line(&info.alias);
                let pending = PendingReceive {
                    session_id: session_id.clone(),
                    alias: alias.clone(),
                    files,
                    decision: decision_tx,
                };
                if self.config.receive_policy == ReceivePolicy::Disabled
                    || self.receiving.is_some()
                    || self.pending_receive.is_some()
                {
                    let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
                } else if self.config.receive_policy == ReceivePolicy::Auto
                    || self.config.paired.contains(&fingerprint)
                {
                    self.accept(pending);
                } else if self.config.receive_policy == ReceivePolicy::Decision {
                    let files = pending
                        .files
                        .iter()
                        .map(|(id, file)| FileSummary {
                            id: id.clone(),
                            name: file.file_name.clone(),
                            size: file.size,
                        })
                        .collect();
                    self.events.push_back(SessionEvent::ReceiveRequest {
                        session_id,
                        alias,
                        fingerprint,
                        files,
                    });
                    self.pending_receive = Some(pending);
                } else {
                    let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
                    self.events.push_back(SessionEvent::ReceiveDeclined {
                        session_id,
                        reason: "unpaired".to_string(),
                    });
                }
            }
            ServerEventV2::FileUpload {
                session_id,
                file_id,
                file,
                target_tx,
            } => {
                let Some(receiving) = self
                    .receiving
                    .as_mut()
                    .filter(|r| r.session_id == session_id)
                else {
                    return Ok(());
                };
                receiving.outstanding.insert(file_id.clone());
                let path = util::unique_path(&self.config.destination, &file.file_name);
                let (result_tx, result_rx) = oneshot::channel();
                let tx = self.internal_tx.clone();
                tokio::spawn(async move {
                    let result = result_rx
                        .await
                        .unwrap_or_else(|_| Err("Upload aborted".to_string()));
                    let _ = tx
                        .send(InternalEvent::ReceiveFileResult {
                            session_id,
                            file_id,
                            result,
                        })
                        .await;
                });
                let _ = target_tx.send(FileUploadTarget::Path {
                    path,
                    result_tx,
                    progress_tx: None,
                });
            }
            ServerEventV2::SessionEnd { session_id, reason } => {
                if let Some(receiving) = self
                    .receiving
                    .as_mut()
                    .filter(|r| r.session_id == session_id)
                {
                    receiving.ended = Some(reason);
                    self.finish_receive();
                }
            }
            ServerEventV2::PrepareUploadAborted { session_id } => {
                if self
                    .pending_receive
                    .as_ref()
                    .is_some_and(|p| p.session_id == session_id)
                {
                    self.pending_receive = None;
                    self.events
                        .push_back(SessionEvent::ReceiveAborted { session_id });
                }
            }
            ServerEventV2::CancelReceived { ip, session_id } => {
                if let Some(sending) = &self.sending
                    && sending.session_id.as_deref() == Some(session_id.as_str())
                    && sending.host == ip.to_string()
                {
                    sending.cancel.by_peer.store(true, Ordering::Relaxed);
                    sending.cancel.token.cancel();
                }
            }
            ServerEventV2::ListenerFailed { error } => {
                return Err(anyhow!("Server stopped: {error}"));
            }
        }
        Ok(())
    }

    fn device_confirmed(&self, host: String, info: RegisterDtoV2) {
        if info.fingerprint == self.config.identity.fingerprint {
            return;
        }
        let device = localsend::discovery::DiscoveredDevice {
            alias: info.alias,
            version: info.version,
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.fingerprint,
            channel: localsend::discovery::DeviceChannel::Http(HttpChannel {
                host,
                port: info.port,
                protocol: info.protocol,
            }),
            download: info.download,
        };
        let discovery = self.discovery.clone();
        tokio::spawn(async move {
            discovery.add_device(device).await;
        });
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(sending) = &self.sending {
            sending.cancel.token.cancel();
        }
        if let Some(pending) = self.pending_receive.take() {
            let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
        }
        self.server_stop.take();
        self.discovery_stop.take();
    }
}
