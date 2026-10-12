use crate::{
    config::Config,
    protocol::{File, Operation, Receive, Snapshot},
};
use localsend::{
    discovery::{DEFAULT_DISCOVERY_TIMEOUT, DeviceIdentity, DiscoveryConfig, DiscoveryHandle},
    http::{
        server::{
            ServerConfigV2, ServerHandle, TlsConfig,
            common::save::FileUploadTarget,
            start_with_port,
            v2::{PrepareUploadDecisionV2, ServerEventV2},
            web::WebConfig,
        },
        state::ClientInfo,
    },
    model::discovery::{DeviceType, PROTOCOL_VERSION_V2, ProtocolType},
    multicast::{DEFAULT_PORT, MulticastDevice},
    util::{
        filename::{Rules, sanitize_path},
        interface::InterfaceFilter,
    },
};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::sync::{mpsc, oneshot, watch};

pub struct Command {
    pub operation: Operation,
    pub result: oneshot::Sender<Result<Snapshot, (&'static str, String)>>,
}

pub struct Runtime {
    pub commands: mpsc::Sender<Command>,
    pub snapshots: watch::Receiver<Snapshot>,
    pub wake_snapshots: watch::Receiver<Snapshot>,
    pub stopped: watch::Receiver<bool>,
}

enum Update {
    Progress(String, String, u64),
    Result(String, String, Result<(), String>),
}

struct Actor {
    config: Config,
    server: Arc<ServerHandle>,
    snapshot: Snapshot,
    pending: Option<(String, oneshot::Sender<PrepareUploadDecisionV2>)>,
    paths: HashMap<String, PathBuf>,
    file_indices: HashMap<String, usize>,
    sender: Option<(String, u16, ProtocolType, String)>,
    ended: bool,
    dirty: bool,
    updates: mpsc::Sender<Update>,
}

impl Runtime {
    pub async fn start(config: Config) -> anyhow::Result<Self> {
        config.validate()?;
        let security = &config.security_context;
        let (server_tx, mut server_rx) = mpsc::channel(32);
        let (stop_tx, stop_rx) = oneshot::channel();
        let server = Arc::new(
            start_with_port(
                config.port,
                config.https.then(|| TlsConfig {
                    cert: security.certificate.clone(),
                    private_key: security.private_key.clone(),
                }),
                ClientInfo {
                    alias: config.alias.clone(),
                    version: PROTOCOL_VERSION_V2.into(),
                    device_model: Some("macOS background".into()),
                    device_type: Some(DeviceType::Desktop),
                    token: security.certificate_hash.clone(),
                },
                None,
                Some(ServerConfigV2 {
                    pin: config.pin.clone(),
                    verify_checksums: config.verify_checksums,
                    event_tx: server_tx,
                }),
                WebConfig::default(),
                stop_rx,
            )
            .await?,
        );
        let protocol = if config.https {
            ProtocolType::Https
        } else {
            ProtocolType::Http
        };
        let (discovery_stop, discovery_rx) = oneshot::channel();
        let discovery = if config.discovery {
            Some(Arc::new(
                localsend::discovery::start(
                    DiscoveryConfig {
                        group: config.multicast_group,
                        group_v6: config.multicast_group_v6,
                        port: DEFAULT_PORT,
                        interface_filter: InterfaceFilter::default(),
                        device: MulticastDevice {
                            alias: config.alias.clone(),
                            version: PROTOCOL_VERSION_V2.into(),
                            device_model: Some("macOS background".into()),
                            device_type: Some(DeviceType::Desktop),
                            fingerprint: security.certificate_hash.clone(),
                            port: server.port(),
                            protocol,
                            download: false,
                        },
                        identity: DeviceIdentity {
                            cert_pem: security.certificate.clone(),
                            private_key_pem: security.private_key.clone(),
                        },
                        timeout: DEFAULT_DISCOVERY_TIMEOUT,
                        event_tx: None,
                    },
                    discovery_rx,
                )
                .await,
            ))
        } else {
            None
        };
        if let Some(discovery) = &discovery {
            let discovery = discovery.clone();
            tokio::spawn(async move {
                discovery.announce().await;
            });
        }
        let snapshot = Snapshot {
            revision: 0,
            port: server.port(),
            receive: None,
            error: discovery
                .as_ref()
                .and_then(|d| d.multicast_error())
                .map(|e| format!("Multicast unavailable: {e}")),
        };
        let (snapshot_tx, snapshots) = watch::channel(snapshot.clone());
        let (wake_tx, wake_snapshots) = watch::channel(snapshot.clone());
        let (stopped_tx, stopped) = watch::channel(false);
        let (commands, mut command_rx) = mpsc::channel::<Command>(32);
        let (updates, mut update_rx) = mpsc::channel(128);
        let mut actor = Actor {
            config,
            server: server.clone(),
            snapshot,
            pending: None,
            paths: HashMap::new(),
            file_indices: HashMap::new(),
            sender: None,
            ended: false,
            dirty: false,
            updates,
        };
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(100));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    Some(event) = server_rx.recv() => actor.event(event, discovery.as_deref()).await,
                    Some(update) = update_rx.recv() => actor.update(update),
                    Some(command) = command_rx.recv() => {
                        let shutdown = matches!(command.operation, Operation::Shutdown);
                        let result = actor.command(command.operation).await;
                        actor.publish(&snapshot_tx, &wake_tx);
                        let _ = command.result.send(result.map(|_| if shutdown {
                            // Quit is a control acknowledgment. It must fit
                            // the native launcher's bounded reply reader even
                            // when the last offer contains thousands of files.
                            Snapshot { revision: actor.snapshot.revision, port: actor.snapshot.port, receive: None, error: None }
                        } else { actor.snapshot.clone() }));
                        if shutdown { break; }
                    }
                    _ = tick.tick(), if actor.dirty => actor.publish(&snapshot_tx, &wake_tx),
                    else => break,
                }
            }
            if let Some((_, pending)) = actor.pending.take() {
                let _ = pending.send(PrepareUploadDecisionV2::Decline);
            }
            let _ = stop_tx.send(());
            let _ = discovery_stop.send(());
            server.wait_stopped().await;
            if let Some(discovery) = discovery {
                discovery.wait_stopped().await;
            }
            let _ = stopped_tx.send(true);
        });
        Ok(Self {
            commands,
            snapshots,
            wake_snapshots,
            stopped,
        })
    }

    pub async fn command(&self, operation: Operation) -> Result<Snapshot, (&'static str, String)> {
        let (result, rx) = oneshot::channel();
        self.commands
            .send(Command { operation, result })
            .await
            .map_err(|_| ("unavailable", "Daemon stopped".into()))?;
        rx.await
            .map_err(|_| ("unavailable", "Daemon stopped".into()))?
    }
}

impl Actor {
    fn publish(&mut self, tx: &watch::Sender<Snapshot>, wake_tx: &watch::Sender<Snapshot>) {
        if self.dirty {
            self.snapshot.revision += 1;
            // No full-file-list cloning/encoding while only the native
            // launcher is attached. Full watches refresh on their first
            // snapshot command before emitting an initial reply.
            if tx.receiver_count() > 1 {
                tx.send_replace(self.snapshot.clone());
            }
            let wake = Snapshot {
                revision: self.snapshot.revision,
                port: self.snapshot.port,
                error: self.snapshot.error.clone(),
                receive: self.snapshot.receive.as_ref().map(|receive| Receive {
                    session_id: receive.session_id.clone(),
                    // The launcher only needs decision state and its UUID.
                    // Peer metadata can be arbitrarily large; keep it on
                    // the full UI watch instead of the control watch.
                    sender_alias: String::new(),
                    sender_fingerprint: String::new(),
                    status: receive.status.clone(),
                    files: vec![],
                }),
            };
            let changed = {
                let previous = wake_tx.borrow();
                previous.receive != wake.receive || previous.error != wake.error
            };
            if changed {
                wake_tx.send_replace(wake);
            }
            self.dirty = false;
        } else if tx.receiver_count() > 1 && tx.borrow().revision != self.snapshot.revision {
            tx.send_replace(self.snapshot.clone());
        }
    }

    async fn command(&mut self, operation: Operation) -> Result<(), (&'static str, String)> {
        match operation {
            Operation::Snapshot | Operation::Watch { .. } | Operation::Shutdown => Ok(()),
            Operation::Accept {
                session_id,
                file_ids,
            } => self.decide(&session_id, file_ids, true),
            Operation::Decline { session_id } => self.decide(&session_id, None, false),
            Operation::Cancel { session_id } => {
                self.check_session(&session_id)?;
                let status = &self.snapshot.receive.as_ref().unwrap().status;
                if status == "pending" {
                    self.decide(&session_id, None, false)?;
                } else if status == "receiving" {
                    self.server.cancel_v2_session(&session_id).await;
                } else {
                    return Err(("invalid_state", "Session is not active".into()));
                }
                self.snapshot.receive.as_mut().unwrap().status = "cancelled".into();
                self.dirty = true;
                if let Some((host, port, protocol, fingerprint)) = self.sender.clone() {
                    let security = self.config.security_context.clone();
                    tokio::spawn(async move {
                        let expected =
                            matches!(protocol, ProtocolType::Https).then_some(fingerprint);
                        if let Ok(client) = localsend::http::client::v2::LsHttpClientV2::try_new(
                            &security.private_key,
                            &security.certificate,
                            expected,
                            Some(Duration::from_secs(5)),
                        ) {
                            let _ = client.cancel(protocol, &host, port, &session_id).await;
                        }
                    });
                }
                Ok(())
            }
        }
    }

    fn check_session(&self, session_id: &str) -> Result<(), (&'static str, String)> {
        if self
            .snapshot
            .receive
            .as_ref()
            .is_some_and(|r| r.session_id == session_id)
        {
            Ok(())
        } else {
            Err(("stale_session", "Session no longer exists".into()))
        }
    }

    fn decide(
        &mut self,
        session_id: &str,
        ids: Option<Vec<String>>,
        accept: bool,
    ) -> Result<(), (&'static str, String)> {
        self.check_session(session_id)?;
        let receive = self.snapshot.receive.as_ref().unwrap();
        if receive.status != "pending"
            || !self
                .pending
                .as_ref()
                .is_some_and(|(id, _)| id == session_id)
        {
            return Err((
                "invalid_state",
                "Session is not waiting for a decision".into(),
            ));
        }
        let offered: HashSet<String> = receive.files.iter().map(|f| f.id.clone()).collect();
        let ids: HashSet<String> = ids
            .map(|ids| ids.into_iter().collect())
            .unwrap_or_else(|| offered.clone());
        if accept && !ids.is_subset(&offered) {
            return Err(("invalid_files", "Unknown offered file ID".into()));
        }
        let (_, sender) = self.pending.take().unwrap();
        sender
            .send(if accept {
                PrepareUploadDecisionV2::Accept(ids.clone())
            } else {
                PrepareUploadDecisionV2::Decline
            })
            .map_err(|_| ("stale_session", "Sender already ended request".into()))?;
        let receive = self.snapshot.receive.as_mut().unwrap();
        receive.status = if !accept {
            "cancelled"
        } else if ids.is_empty() {
            "finished"
        } else {
            "receiving"
        }
        .into();
        for file in &mut receive.files {
            file.status = if accept && ids.contains(&file.id) {
                "queued"
            } else {
                "skipped"
            }
            .into();
        }
        self.dirty = true;
        Ok(())
    }

    async fn event(&mut self, event: ServerEventV2, discovery: Option<&DiscoveryHandle>) {
        match event {
            ServerEventV2::Register { ip, info } => {
                if let Some(discovery) = discovery {
                    discovery
                        .add_device(localsend::discovery::DiscoveredDevice {
                            alias: info.alias,
                            version: info.version,
                            device_model: info.device_model,
                            device_type: info.device_type,
                            fingerprint: info.fingerprint,
                            channel: localsend::discovery::DeviceChannel::Http(
                                localsend::discovery::HttpChannel {
                                    host: ip.to_string(),
                                    port: info.port,
                                    protocol: info.protocol,
                                },
                            ),
                            download: info.download,
                        })
                        .await;
                }
            }
            ServerEventV2::PrepareUpload {
                session_id,
                ip,
                info,
                cert_fingerprint,
                files,
                decision_tx,
            } => {
                let fingerprint = cert_fingerprint.unwrap_or(info.fingerprint);
                self.sender = Some((
                    ip.to_string(),
                    info.port,
                    info.protocol,
                    fingerprint.clone(),
                ));
                let mut files: Vec<File> = files
                    .into_iter()
                    .map(|(id, file)| File {
                        id,
                        name: file.file_name,
                        size: file.size,
                        received_bytes: 0,
                        status: "offered".into(),
                        path: None,
                        error: None,
                    })
                    .collect();
                files.sort_by(|a, b| a.id.cmp(&b.id));
                self.file_indices = files
                    .iter()
                    .enumerate()
                    .map(|(index, file)| (file.id.clone(), index))
                    .collect();
                self.snapshot.receive = Some(Receive {
                    session_id: session_id.clone(),
                    sender_alias: info.alias,
                    sender_fingerprint: fingerprint,
                    status: "pending".into(),
                    files,
                });
                self.pending = Some((session_id.clone(), decision_tx));
                self.paths.clear();
                self.ended = false;
                self.dirty = true;
                if self.config.auto_accept {
                    let _ = self.decide(&session_id, None, true);
                }
            }
            ServerEventV2::PrepareUploadAborted { session_id } => {
                if self.check_session(&session_id).is_ok() {
                    self.pending = None;
                    self.snapshot.receive.as_mut().unwrap().status = "aborted".into();
                    self.dirty = true;
                }
            }
            ServerEventV2::FileUpload {
                session_id,
                file_id,
                file,
                target_tx,
            } => {
                if self.check_session(&session_id).is_err() {
                    return;
                }
                let path = match self.paths.get(&file_id) {
                    Some(path) => Ok(path.clone()),
                    None => reserve_path(&self.config.destination, &file.file_name).await,
                };
                let path = match path {
                    Ok(path) => path,
                    Err(error) => {
                        self.update(Update::Result(session_id, file_id, Err(error.to_string())));
                        return;
                    }
                };
                self.paths.insert(file_id.clone(), path.clone());
                if let Some(receive) = &mut self.snapshot.receive
                    && let Some(file) = self
                        .file_indices
                        .get(&file_id)
                        .and_then(|index| receive.files.get_mut(*index))
                {
                    file.status = "receiving".into();
                    file.error = None;
                    file.received_bytes = 0;
                    file.path = Some(path.to_string_lossy().into_owned());
                    self.dirty = true;
                }
                let (progress_tx, mut progress_rx) = mpsc::channel(16);
                let (result_tx, result_rx) = oneshot::channel();
                let updates = self.updates.clone();
                let sid = session_id.clone();
                let fid = file_id.clone();
                tokio::spawn(async move {
                    while let Some(bytes) = progress_rx.recv().await {
                        if updates
                            .send(Update::Progress(sid.clone(), fid.clone(), bytes))
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                });
                let updates = self.updates.clone();
                tokio::spawn(async move {
                    let result = result_rx
                        .await
                        .unwrap_or_else(|_| Err("Upload aborted".into()));
                    let _ = updates
                        .send(Update::Result(session_id, file_id, result))
                        .await;
                });
                let _ = target_tx.send(FileUploadTarget::Path {
                    path,
                    result_tx,
                    progress_tx: Some(progress_tx),
                });
            }
            ServerEventV2::SessionEnd { session_id, reason } => {
                if self.check_session(&session_id).is_ok() {
                    if reason == localsend::http::server::v2::SessionEndReasonV2::Cancelled {
                        self.snapshot.receive.as_mut().unwrap().status = "cancelled".into();
                    } else {
                        self.ended = true;
                        self.finish_if_done();
                    }
                    self.dirty = true;
                }
            }
            ServerEventV2::ListenerFailed { error } => {
                self.snapshot.error = Some(error);
                self.dirty = true;
            }
            ServerEventV2::CancelReceived { .. } => {}
        }
    }

    fn update(&mut self, update: Update) {
        let (session_id, file_id) = match &update {
            Update::Progress(s, f, _) | Update::Result(s, f, _) => (s, f),
        };
        if self.check_session(session_id).is_err() {
            return;
        }
        if let Some(file) = self.file_indices.get(file_id).and_then(|index| {
            self.snapshot
                .receive
                .as_mut()
                .unwrap()
                .files
                .get_mut(*index)
        }) {
            match update {
                Update::Progress(_, _, bytes) => {
                    file.received_bytes = file.received_bytes.max(bytes).min(file.size)
                }
                Update::Result(_, _, result) => {
                    file.status = if result.is_ok() { "finished" } else { "failed" }.into();
                    if result.is_ok() {
                        file.received_bytes = file.size;
                    }
                    file.error = result.err();
                }
            }
            self.dirty = true;
        }
        self.finish_if_done();
    }

    fn finish_if_done(&mut self) {
        if let Some(receive) = &mut self.snapshot.receive
            && self.ended
            && receive.status == "receiving"
            && receive
                .files
                .iter()
                .all(|f| matches!(f.status.as_str(), "finished" | "failed" | "skipped"))
        {
            receive.status = "finished".into();
            self.dirty = true;
        }
    }
}

async fn reserve_path(destination: &std::path::Path, name: &str) -> anyhow::Result<PathBuf> {
    let name = sanitize_path(name, Rules::current());
    for index in 0..10_000 {
        let candidate = destination.join(if index == 0 {
            name.clone()
        } else {
            format!("{index}-{name}")
        });
        match tokio::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&candidate)
            .await
        {
            Ok(_) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    anyhow::bail!("Could not reserve a unique receive filename")
}
