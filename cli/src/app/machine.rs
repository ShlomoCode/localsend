//! Terminal-free CLI modes. The same core server, discovery and upload task
//! drive one-shot commands and the persistent JSON-line protocol.

use super::discovery;
use super::sending;
use super::sending::Payload;
use super::target::TargetSelector;
use super::{AppEvent, Network, spawn_staged_discovery, start_network, stop_network};
use crate::sanitize;
use crate::send_task::{self, FileSource, SendCancel};
use crate::storage::Repository;
use crate::util;
use anyhow::{Context, anyhow};
use localsend::discovery::{DiscoveryEvent, DiscoveryHandle, StatefulDevice};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::model::transfer::FileDto;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

fn emit(value: Value) -> anyhow::Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}

fn devices(discovery: &DiscoveryHandle, storage: &Repository) -> Vec<Value> {
    let mut devices: Vec<Value> = discovery
        .devices()
        .into_iter()
        .filter_map(|stored| {
            let http = stored.get_best_channel()?.http()?.clone();
            Some(json!({
                "alias": stored.device.alias,
                "fingerprint": stored.device.fingerprint,
                "host": http.host,
                "port": http.port,
                "paired": storage.paired.contains(&stored.device.fingerprint),
            }))
        })
        .collect();
    devices.sort_by(|a, b| a["fingerprint"].as_str().cmp(&b["fingerprint"].as_str()));
    devices
}

struct Pending {
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
    peer_cancelled: Arc<AtomicBool>,
    host: String,
    deadline: Option<Instant>,
    completion_emitted: bool,
}

struct PendingSend {
    transfer_id: String,
    target: TargetSelector,
    target_port: Option<u16>,
    paths: Vec<PathBuf>,
    deadline: Instant,
}

#[derive(Clone, Copy)]
enum ReceivePolicy {
    Disabled,
    Paired,
    Auto,
    Decision,
}

struct Machine {
    storage: Repository,
    network: Network,
    events_tx: mpsc::Sender<AppEvent>,
    events_rx: mpsc::Receiver<AppEvent>,
    receive_policy: ReceivePolicy,
    stdio: bool,
    json_output: bool,
    receiving: Option<Receiving>,
    pending: Option<Pending>,
    sending: Option<Sending>,
    pending_send: Option<PendingSend>,
    discovery_active: bool,
    queued_discovery: Option<Option<localsend::discovery::HttpChannel>>,
    completed_receives: usize,
    last_receive_success: Option<bool>,
    completed_send: Option<bool>,
}

impl Machine {
    async fn start(
        storage: Repository,
        receive_policy: ReceivePolicy,
        stdio: bool,
        json_output: bool,
    ) -> anyhow::Result<Self> {
        let network = start_network(&storage.identity).await?;
        let (events_tx, events_rx) = mpsc::channel(64);
        Ok(Self {
            storage,
            network,
            events_tx,
            events_rx,
            receive_policy,
            stdio,
            json_output,
            receiving: None,
            pending: None,
            sending: None,
            pending_send: None,
            discovery_active: false,
            queued_discovery: None,
            completed_receives: 0,
            last_receive_success: None,
            completed_send: None,
        })
    }

    fn emit_event(&self, value: Value) -> anyhow::Result<()> {
        if self.json_output {
            return emit(value);
        }
        match value["event"].as_str() {
            Some("send_started") => {
                eprintln!("Transfer accepted; sending {} bytes", value["bytes"])
            }
            Some("send_completed") if value["success"] == true => eprintln!("Transfer complete"),
            Some("send_completed") => eprintln!(
                "Transfer failed: {}",
                value["error"].as_str().unwrap_or("unknown error")
            ),
            Some("receive_started") => eprintln!(
                "Receiving from {}",
                value["alias"].as_str().unwrap_or("peer")
            ),
            Some("receive_completed") => eprintln!("Received {} file(s)", value["files"]),
            Some("receive_declined") => eprintln!("Declined an unpaired sender"),
            _ => {}
        }
        Ok(())
    }

    fn start_discovery(&mut self, direct: Option<localsend::discovery::HttpChannel>) {
        if self.discovery_active {
            if direct.is_some() || self.queued_discovery.is_none() {
                self.queued_discovery = Some(direct);
            }
            return;
        }
        self.discovery_active = true;
        let mut channels = self.storage.paired.known_http_channels();
        if let Some(channel) = direct
            && !channels.contains(&channel)
        {
            channels.insert(0, channel);
        }
        spawn_staged_discovery(
            self.network.discovery.clone(),
            self.events_tx.clone(),
            channels,
            self.storage.identity.port,
        );
    }

    fn start_send(
        &mut self,
        target: &TargetSelector,
        target_port: Option<u16>,
        payload: Payload,
        transfer_id: String,
        deadline: Option<Instant>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(self.sending.is_none(), "A send is already in progress");
        let fingerprint = target
            .resolve_at(
                &self.network.discovery.devices(),
                target_port.unwrap_or(53317),
            )
            .map_err(|e| anyhow!(e))?;
        let mut device = self
            .network
            .discovery
            .device_by_fingerprint(&fingerprint)
            .ok_or_else(|| anyhow!("Destination disappeared"))?;
        target
            .restrict_device(&mut device, target_port.unwrap_or(53317))
            .map_err(|e| anyhow!(e))?;
        self.send_to_device(device, payload, transfer_id, deadline)
    }

    fn send_to_device(
        &mut self,
        device: StatefulDevice,
        payload: Payload,
        transfer_id: String,
        deadline: Option<Instant>,
    ) -> anyhow::Result<()> {
        let host = device
            .get_best_channel()
            .and_then(|channel| channel.http())
            .ok_or_else(|| anyhow!("Destination has no dialable address"))?
            .host
            .clone();
        let (files, sources) = match payload {
            Payload::Files(paths) => {
                let (files, paths, _) =
                    sending::collect_files_with_log(paths, |message| eprintln!("{message}"));
                (
                    files,
                    paths
                        .into_iter()
                        .map(|(id, path)| (id, FileSource::Path(path)))
                        .collect(),
                )
            }
            Payload::Text(text) => {
                let (files, sources, _) =
                    sending::text_transfer_with_log(text, |message| eprintln!("{message}"));
                (files, sources)
            }
        };
        anyhow::ensure!(!files.is_empty(), "No readable files selected");
        let sent = Arc::new(AtomicU64::new(0));
        let cancel = SendCancel::new();
        self.sending = Some(Sending {
            transfer_id: transfer_id.clone(),
            session_id: None,
            peer_cancelled: cancel.by_peer.clone(),
            cancel: cancel.clone(),
            sent: sent.clone(),
            host,
            deadline,
            completion_emitted: false,
        });
        tokio::spawn(send_task::run_send(
            self.storage.identity.clone(),
            device,
            files,
            sources,
            sent,
            cancel,
            self.events_tx.clone(),
        ));
        Ok(())
    }

    fn accept(&mut self, pending: Pending) {
        let ids: HashSet<String> = pending.files.keys().cloned().collect();
        if pending
            .decision
            .send(PrepareUploadDecisionV2::Accept(ids))
            .is_ok()
        {
            let session_id = pending.session_id;
            let count = pending.files.len();
            let bytes: u64 = pending.files.values().map(|file| file.size).sum();
            let _ = self.emit_event(json!({"event":"receive_started","session_id":session_id,"alias":pending.alias,"files":count,"bytes":bytes}));
            self.receiving = Some(Receiving {
                session_id,
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

    fn handle_server(&mut self, event: ServerEventV2) -> anyhow::Result<()> {
        match event {
            ServerEventV2::Register { ip, info } => {
                discovery::device_confirmed(
                    &self.network.discovery,
                    &self.storage.identity.fingerprint,
                    ip.to_string(),
                    info,
                );
            }
            ServerEventV2::PrepareUpload {
                session_id,
                ip,
                info,
                cert_fingerprint,
                files,
                decision_tx,
            } => {
                discovery::device_confirmed(
                    &self.network.discovery,
                    &self.storage.identity.fingerprint,
                    ip.to_string(),
                    info.clone(),
                );
                let alias = sanitize::single_line(&info.alias);
                let fingerprint = cert_fingerprint.unwrap_or(info.fingerprint);
                let paired = self.storage.paired.contains(&fingerprint);
                let pending = Pending {
                    session_id: session_id.clone(),
                    alias: alias.clone(),
                    files,
                    decision: decision_tx,
                };
                if matches!(self.receive_policy, ReceivePolicy::Disabled)
                    || self.receiving.is_some()
                    || self.pending.is_some()
                {
                    let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
                } else if matches!(self.receive_policy, ReceivePolicy::Auto) || paired {
                    self.accept(pending);
                } else if matches!(self.receive_policy, ReceivePolicy::Decision) {
                    let files: Vec<Value> = pending
                        .files
                        .iter()
                        .map(|(id, f)| json!({"id":id,"name":f.file_name,"size":f.size}))
                        .collect();
                    self.emit_event(json!({"event":"receive_request","session_id":session_id,"alias":alias,"fingerprint":fingerprint,"files":files}))?;
                    self.pending = Some(pending);
                } else {
                    let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
                    self.emit_event(json!({"event":"receive_declined","session_id":session_id,"reason":"unpaired"}))?;
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
                let path = util::unique_path(&self.storage.destination, &file.file_name);
                let (result_tx, result_rx) = oneshot::channel();
                let events = self.events_tx.clone();
                tokio::spawn(async move {
                    let result = result_rx
                        .await
                        .unwrap_or_else(|_| Err("Upload aborted".to_string()));
                    let _ = events
                        .send(AppEvent::ReceiveFileResult {
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
                    self.finish_receive()?;
                }
            }
            ServerEventV2::PrepareUploadAborted { session_id } => {
                if self
                    .pending
                    .as_ref()
                    .is_some_and(|p| p.session_id == session_id)
                {
                    self.pending = None;
                    self.emit_event(json!({"event":"receive_aborted","session_id":session_id}))?;
                }
            }
            ServerEventV2::CancelReceived { ip, session_id } => {
                if let Some(sending) = &self.sending
                    && sending.session_id.as_deref() == Some(session_id.as_str())
                    && sending.host == ip.to_string()
                {
                    sending.peer_cancelled.store(true, Ordering::Relaxed);
                    sending.cancel.token.cancel();
                }
            }
            ServerEventV2::ListenerFailed { error } => {
                return Err(anyhow!("Server stopped: {error}"));
            }
        }
        Ok(())
    }

    fn finish_receive(&mut self) -> anyhow::Result<()> {
        if !self
            .receiving
            .as_ref()
            .is_some_and(|r| r.ended.is_some() && r.outstanding.is_empty())
        {
            return Ok(());
        }
        let received = self.receiving.take().unwrap();
        let success =
            matches!(received.ended, Some(SessionEndReasonV2::Finished)) && received.failures == 0;
        self.emit_event(json!({"type":"receive_completed","event":"receive_completed","session_id":received.session_id,
            "alias":received.alias,"files":received.finished,"bytes":received.bytes,"failed_files":received.failures,"success":success}))?;
        self.completed_receives += 1;
        self.last_receive_success = Some(success);
        Ok(())
    }

    fn handle_app(&mut self, event: AppEvent) -> anyhow::Result<()> {
        match event {
            AppEvent::ReceiveFileResult {
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
                            self.emit_event(json!({"event":"receive_file_failed","session_id":session_id,"file_id":file_id,"error":error}))?;
                        }
                    }
                    self.finish_receive()?;
                }
            }
            AppEvent::SendSessionStarted {
                session_id,
                accepted_bytes,
            } => {
                if let Some(sending) = self.sending.as_mut() {
                    sending.session_id = Some(session_id.clone());
                    let transfer_id = sending.transfer_id.clone();
                    self.emit_event(json!({"event":"send_started","transfer_id":transfer_id,"session_id":session_id,"bytes":accepted_bytes}))?;
                }
            }
            AppEvent::SendEnded { success } => {
                if let Some(sending) = self.sending.take()
                    && !sending.completion_emitted
                {
                    self.emit_event(json!({"type":"send_completed","event":"send_completed","transfer_id":sending.transfer_id,
                        "session_id":sending.session_id,"bytes":sending.sent.load(Ordering::Relaxed),"success":success}))?;
                }
                self.completed_send = Some(success);
            }
            AppEvent::Log { text, .. } => eprintln!("{text}"),
            AppEvent::DiscoveryFinished => {
                self.discovery_active = false;
                if let Some(next) = self.queued_discovery.take() {
                    self.start_discovery(next);
                    return Ok(());
                }
                if let Some(pending) = self.pending_send.take()
                    && let Err(error) = self.start_send(
                        &pending.target,
                        pending.target_port,
                        Payload::Files(pending.paths),
                        pending.transfer_id.clone(),
                        Some(pending.deadline),
                    )
                {
                    self.emit_event(json!({"type":"send_completed","event":"send_completed","transfer_id":pending.transfer_id,"success":false,"error":error.to_string()}))?;
                    self.completed_send = Some(false);
                }
                if self.stdio {
                    self.emit_event(json!({"event":"discovery_completed","devices":devices(&self.network.discovery, &self.storage)}))?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    async fn shutdown(mut self) {
        if let Some(sending) = &self.sending {
            sending.cancel.token.cancel();
        }
        if let Some(pending) = self.pending {
            let _ = pending.decision.send(PrepareUploadDecisionV2::Decline);
        }
        if let Some(receiving) = &self.receiving {
            self.network
                .server
                .cancel_v2_session(&receiving.session_id)
                .await;
        }
        if self.sending.is_some() {
            let _ = tokio::time::timeout(Duration::from_secs(5), async {
                while let Some(event) = self.events_rx.recv().await {
                    if matches!(event, AppEvent::SendEnded { .. }) {
                        break;
                    }
                }
            })
            .await;
        }
        stop_network(
            &self.network.server,
            Some(self.network.server_stop_tx),
            &self.network.discovery,
            self.network.discovery_stop_tx,
        )
        .await;
    }
}

pub(super) async fn discover(
    storage: Repository,
    timeout: u64,
    json_output: bool,
) -> anyhow::Result<()> {
    let mut machine = Machine::start(storage, ReceivePolicy::Disabled, false, json_output).await?;
    machine.start_discovery(None);
    let deadline = tokio::time::sleep(Duration::from_secs(timeout));
    tokio::pin!(deadline);
    let run_result: anyhow::Result<()> = async { loop {
        tokio::select! {
            Some(event) = machine.network.server_rx.recv() => machine.handle_server(event)?,
            Some(event) = machine.network.discovery_rx.recv() => {
                if let DiscoveryEvent::MulticastFailed = event { eprintln!("Multicast unavailable"); }
            }
            Some(event) = machine.events_rx.recv() => {
                if matches!(event, AppEvent::DiscoveryFinished) { break; }
                machine.handle_app(event)?;
            }
            _ = &mut deadline => break,
        }
    } Ok(()) }.await;
    if let Err(error) = run_result {
        machine.shutdown().await;
        return Err(error);
    }
    let rows = devices(&machine.network.discovery, &machine.storage);
    let output_result = if json_output {
        emit(json!({"type":"discovery","devices":rows}))
    } else {
        for row in rows {
            println!(
                "{} ({}:{})",
                row["alias"].as_str().unwrap_or("?"),
                row["host"].as_str().unwrap_or("?"),
                row["port"]
            );
        }
        Ok(())
    };
    machine.shutdown().await;
    output_result
}

pub(super) async fn receive(
    storage: Repository,
    auto_accept: bool,
    once: bool,
    timeout: Option<u64>,
    json: bool,
) -> anyhow::Result<()> {
    let receive_policy = if auto_accept {
        ReceivePolicy::Auto
    } else {
        ReceivePolicy::Paired
    };
    let mut machine = Machine::start(storage, receive_policy, false, json).await?;
    machine.emit_event(json!({"event":"ready","protocol_version":1,"alias":machine.storage.identity.alias,"port":machine.storage.identity.port}))?;
    machine.start_discovery(None);
    let deadline = async {
        match timeout {
            Some(seconds) => tokio::time::sleep(Duration::from_secs(seconds)).await,
            None => std::future::pending::<()>().await,
        }
    };
    tokio::pin!(deadline);
    let mut timed_out = false;
    let run_result: anyhow::Result<()> = async {
        loop {
            tokio::select! {
                Some(event) = machine.network.server_rx.recv() => machine.handle_server(event)?,
                Some(_) = machine.network.discovery_rx.recv() => {},
                Some(event) = machine.events_rx.recv() => machine.handle_app(event)?,
                _ = &mut deadline => { timed_out = true; break; },
                _ = tokio::signal::ctrl_c() => break,
            }
            if once && machine.completed_receives > 0 {
                break;
            }
        }
        Ok(())
    }
    .await;
    let completed = machine.completed_receives;
    let success = machine.last_receive_success;
    machine.shutdown().await;
    run_result?;
    if timed_out && once && completed == 0 {
        anyhow::bail!("Timed out waiting for a transfer");
    }
    if once && success == Some(false) {
        anyhow::bail!("Received transfer failed");
    }
    Ok(())
}

pub(super) async fn send(
    storage: Repository,
    target: TargetSelector,
    target_port: Option<u16>,
    timeout: Option<u64>,
    json: bool,
    payload: Payload,
) -> anyhow::Result<()> {
    let mut machine = Machine::start(storage, ReceivePolicy::Disabled, false, json).await?;
    machine.start_discovery(match target_port {
        Some(port) => target.direct_channel_at(port),
        None => target.direct_channel(),
    });
    let deadline = tokio::time::sleep(Duration::from_secs(timeout.unwrap_or(60)));
    tokio::pin!(deadline);
    let mut started = false;
    let result: anyhow::Result<()> = async { loop {
        tokio::select! {
            Some(event) = machine.network.server_rx.recv() => machine.handle_server(event)?,
            Some(_) = machine.network.discovery_rx.recv() => {},
            Some(event) = machine.events_rx.recv() => {
                if matches!(event, AppEvent::DiscoveryFinished) && !started {
                    machine.start_send(&target, target_port, payload.clone(), Uuid::new_v4().to_string(), None)?;
                    started = true;
                } else { machine.handle_app(event)?; }
            }
            _ = &mut deadline => break Err(anyhow!("Timed out sending to {target}")),
        }
        if let Some(success) = machine.completed_send {
            break if success {
                Ok(())
            } else {
                Err(anyhow!("Transfer failed"))
            };
        }
    } }.await;
    if result.is_err()
        && let Some(sending) = &machine.sending
    {
        sending.cancel.token.cancel();
    }
    machine.shutdown().await;
    result
}

#[derive(Deserialize)]
struct Request {
    id: Value,
    command: String,
    #[serde(default)]
    to: Option<String>,
    #[serde(default)]
    target_port: Option<u16>,
    #[serde(default)]
    paths: Option<Vec<PathBuf>>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    transfer_id: Option<String>,
    #[serde(default)]
    accept: Option<bool>,
    #[serde(default)]
    timeout: Option<u64>,
}

fn reply(id: Value, result: anyhow::Result<Value>) -> anyhow::Result<()> {
    match result {
        Ok(value) => emit(json!({"id":id,"ok":true,"result":value})),
        Err(error) => emit(json!({"id":id,"ok":false,"error":error.to_string()})),
    }
}

pub(super) async fn serve(storage: Repository) -> anyhow::Result<()> {
    let mut machine = Machine::start(storage, ReceivePolicy::Decision, true, true).await?;
    let (input_tx, mut input_rx) = mpsc::channel::<String>(32);
    std::thread::spawn(move || {
        let stdin = io::stdin();
        for line in io::BufRead::lines(io::BufReader::new(stdin)) {
            let Ok(line) = line else {
                break;
            };
            if input_tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    machine.start_discovery(None);
    emit(
        json!({"event":"ready","protocol_version":1,"alias":machine.storage.identity.alias,"port":machine.storage.identity.port}),
    )?;
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let run_result: anyhow::Result<()> = async { loop {
        tokio::select! {
            Some(event) = machine.network.server_rx.recv() => machine.handle_server(event)?,
            Some(_) = machine.network.discovery_rx.recv() => {},
            Some(event) = machine.events_rx.recv() => machine.handle_app(event)?,
            _ = tick.tick() => {
                if machine.pending_send.as_ref().is_some_and(|send| Instant::now() >= send.deadline) {
                    let pending = machine.pending_send.take().unwrap();
                    machine.emit_event(json!({"type":"send_completed","event":"send_completed","transfer_id":pending.transfer_id,"success":false,"error":"Timed out discovering destination"}))?;
                }
                if machine.sending.as_ref().is_some_and(|send| send.deadline.is_some_and(|deadline| Instant::now() >= deadline)) {
                    let sending = machine.sending.as_mut().unwrap();
                    sending.cancel.token.cancel();
                    sending.deadline = None;
                    sending.completion_emitted = true;
                    let transfer_id = sending.transfer_id.clone();
                    let session_id = sending.session_id.clone();
                    machine.emit_event(json!({"type":"send_completed","event":"send_completed","transfer_id":transfer_id,"session_id":session_id,"success":false,"error":"Timed out sending"}))?;
                }
            }
            line = input_rx.recv() => {
                let Some(line) = line else { break; };
                let request: Request = match serde_json::from_str(&line) {
                    Ok(request) => request,
                    Err(error) => { emit(json!({"ok":false,"error":format!("Invalid request: {error}")}))?; continue; }
                };
                let id = request.id.clone();
                let result = match request.command.as_str() {
                    "devices" => Ok(json!({"devices":devices(&machine.network.discovery, &machine.storage)})),
                    "discover" => { machine.start_discovery(None); Ok(json!({"started":true})) },
                    "send" => {
                        let target = request.to.as_deref().context("Missing to").and_then(TargetSelector::parse);
                        target.and_then(|target| {
                            anyhow::ensure!(machine.sending.is_none() && machine.pending_send.is_none(), "A send is already in progress");
                            let paths = request.paths.context("Missing paths")?;
                            anyhow::ensure!(!paths.is_empty(), "No paths selected");
                            for path in &paths {
                                anyhow::ensure!(path.is_file() || path.is_dir(), "Not a file or directory: {}", path.display());
                            }
                            let transfer_id = Uuid::new_v4().to_string();
                            let timeout = request.timeout.unwrap_or(60);
                            anyhow::ensure!((1..=86400).contains(&timeout), "timeout must be 1 to 86400 seconds");
                            let deadline = Instant::now() + Duration::from_secs(timeout);
                            machine.pending_send = Some(PendingSend { transfer_id: transfer_id.clone(), target: target.clone(), target_port: request.target_port, paths, deadline });
                            machine.start_discovery(match request.target_port { Some(port) => target.direct_channel_at(port), None => target.direct_channel() });
                            Ok(json!({"transfer_id":transfer_id,"queued":true}))
                        })
                    }
                    "receive_decision" => {
                        match machine.pending.take() {
                            Some(pending) if Some(pending.session_id.as_str()) == request.session_id.as_deref() => {
                                match request.accept {
                                    Some(true) => { machine.accept(pending); Ok(json!({"accepted":true})) }
                                    Some(false) => { let _ = pending.decision.send(PrepareUploadDecisionV2::Decline); Ok(json!({"accepted":false})) }
                                    None => { machine.pending = Some(pending); Err(anyhow!("Missing accept decision")) }
                                }
                            }
                            Some(pending) => { machine.pending = Some(pending); Err(anyhow!("Unknown pending session")) }
                            None => Err(anyhow!("No pending receive request")),
                        }
                    }
                    "cancel" => {
                        if machine.pending_send.as_ref().is_some_and(|send| Some(send.transfer_id.as_str()) == request.transfer_id.as_deref()) {
                            let pending = machine.pending_send.take().unwrap();
                            machine.emit_event(json!({"type":"send_completed","event":"send_completed","transfer_id":pending.transfer_id,"success":false,"error":"Cancelled"}))?;
                            Ok(json!({"cancelled":true}))
                        } else if machine.sending.as_ref().is_some_and(|send| Some(send.transfer_id.as_str()) == request.transfer_id.as_deref()) {
                            machine.sending.as_ref().unwrap().cancel.token.cancel();
                            Ok(json!({"cancelled":true}))
                        } else if machine.receiving.as_ref().is_some_and(|receive| Some(receive.session_id.as_str()) == request.session_id.as_deref()) {
                            let receiving = machine.receiving.take().unwrap();
                            machine.network.server.cancel_v2_session(&receiving.session_id).await;
                            machine.emit_event(json!({"type":"receive_completed","event":"receive_completed","session_id":receiving.session_id,"success":false,"error":"Cancelled","files":receiving.finished,"bytes":receiving.bytes}))?;
                            Ok(json!({"cancelled":true}))
                        } else {
                            Err(anyhow!("Unknown active transfer"))
                        }
                    }
                    "status" => Ok(json!({"sending":machine.sending.as_ref().map(|s| json!({"transfer_id":s.transfer_id,"session_id":s.session_id,"bytes":s.sent.load(Ordering::Relaxed)})),
                        "queued_send":machine.pending_send.as_ref().map(|s| json!({"transfer_id":s.transfer_id})),
                        "receiving":machine.receiving.as_ref().map(|r| json!({"session_id":r.session_id,"alias":r.alias})),
                        "pending":machine.pending.as_ref().map(|r| json!({"session_id":r.session_id,"alias":r.alias}))})),
                    "shutdown" => { reply(id, Ok(json!({"shutting_down":true})))?; break; }
                    other => Err(anyhow!("Unknown command: {other}")),
                };
                reply(id, result)?;
            }
        }
    } Ok(()) }.await;
    machine.shutdown().await;
    run_result
}
