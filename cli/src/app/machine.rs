//! CLI rendering and stdio commands for the typed session library.

use super::sending::Payload;
use crate::storage::Repository;
use anyhow::{Context, anyhow};
use localsend_session::{ReceivePolicy, SendPayload, Session, SessionConfig, SessionEvent, Target};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::mpsc;

fn config(storage: Repository, receive_policy: ReceivePolicy) -> SessionConfig {
    SessionConfig {
        identity: storage.identity,
        paired: storage.paired,
        destination: storage.destination,
        receive_policy,
    }
}

fn emit(value: Value) -> anyhow::Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}

fn devices(session: &Session) -> Vec<Value> {
    session
        .devices()
        .into_iter()
        .map(|device| {
            json!({
                "alias": device.alias, "fingerprint": device.fingerprint,
                "host": device.host, "port": device.port, "paired": device.paired,
            })
        })
        .collect()
}

fn event_json(event: &SessionEvent) -> Option<Value> {
    Some(match event {
        SessionEvent::DiscoveryCompleted { devices } => {
            json!({"event":"discovery_completed","devices":devices.iter().map(|d| json!({
            "alias":d.alias,"fingerprint":d.fingerprint,"host":d.host,"port":d.port,"paired":d.paired
        })).collect::<Vec<_>>()})
        }
        SessionEvent::ReceiveRequest {
            session_id,
            alias,
            fingerprint,
            files,
        } => {
            json!({"event":"receive_request","session_id":session_id,"alias":alias,"fingerprint":fingerprint,"files":files.iter().map(|f| json!({"id":f.id,"name":f.name,"size":f.size})).collect::<Vec<_>>()})
        }
        SessionEvent::ReceiveStarted {
            session_id,
            alias,
            files,
            bytes,
        } => {
            json!({"event":"receive_started","session_id":session_id,"alias":alias,"files":files,"bytes":bytes})
        }
        SessionEvent::ReceiveCompleted {
            session_id,
            alias,
            files,
            bytes,
            failed_files,
            success,
            error,
        } => {
            let mut value = json!({"type":"receive_completed","event":"receive_completed","session_id":session_id,"alias":alias,"files":files,"bytes":bytes,"failed_files":failed_files,"success":success});
            if let Some(error) = error {
                value["error"] = json!(error);
            }
            value
        }
        SessionEvent::ReceiveDeclined { session_id, reason } => {
            json!({"event":"receive_declined","session_id":session_id,"reason":reason})
        }
        SessionEvent::ReceiveAborted { session_id } => {
            json!({"event":"receive_aborted","session_id":session_id})
        }
        SessionEvent::ReceiveFileFailed {
            session_id,
            file_id,
            error,
        } => {
            json!({"event":"receive_file_failed","session_id":session_id,"file_id":file_id,"error":error})
        }
        SessionEvent::SendStarted {
            transfer_id,
            session_id,
            bytes,
        } => {
            json!({"event":"send_started","transfer_id":transfer_id,"session_id":session_id,"bytes":bytes})
        }
        SessionEvent::SendCompleted {
            transfer_id,
            session_id,
            bytes,
            success,
            error,
        } => {
            let mut value = json!({"type":"send_completed","event":"send_completed","transfer_id":transfer_id,"session_id":session_id,"bytes":bytes,"success":success});
            if let Some(error) = error {
                value["error"] = json!(error);
            }
            value
        }
        SessionEvent::Log(_) | SessionEvent::MulticastFailed => return None,
    })
}

fn report(event: &SessionEvent, json_output: bool, stdio: bool) -> anyhow::Result<()> {
    match event {
        SessionEvent::Log(text) => {
            eprintln!("{text}");
            return Ok(());
        }
        SessionEvent::MulticastFailed => {
            eprintln!("Multicast stopped");
            return Ok(());
        }
        SessionEvent::DiscoveryCompleted { .. } if !stdio => return Ok(()),
        _ => {}
    }
    if json_output {
        return event_json(event).map(emit).transpose().map(|_| ());
    }
    match event {
        SessionEvent::SendStarted { bytes, .. } => {
            eprintln!("Transfer accepted; sending {bytes} bytes")
        }
        SessionEvent::SendCompleted { success: true, .. } => eprintln!("Transfer complete"),
        SessionEvent::SendCompleted { error, .. } => eprintln!(
            "Transfer failed: {}",
            error.as_deref().unwrap_or("unknown error")
        ),
        SessionEvent::ReceiveStarted { alias, .. } => eprintln!("Receiving from {alias}"),
        SessionEvent::ReceiveCompleted { files, .. } => eprintln!("Received {files} file(s)"),
        SessionEvent::ReceiveDeclined { .. } => eprintln!("Declined an unpaired sender"),
        _ => {}
    }
    Ok(())
}

fn offer(payload: Payload) -> anyhow::Result<SendPayload> {
    match payload {
        Payload::Files(paths) => {
            let payload = SendPayload::paths_with_log(paths, |message| eprintln!("{message}"));
            anyhow::ensure!(!payload.is_empty(), "No readable files selected");
            Ok(payload)
        }
        Payload::Text(text) => SendPayload::message(text),
    }
}

pub(super) async fn discover(
    storage: Repository,
    timeout: u64,
    json_output: bool,
) -> anyhow::Result<()> {
    let mut session = Session::start(config(storage, ReceivePolicy::Disabled)).await?;
    session.discover(None);
    let outcome = async {
        let deadline = tokio::time::sleep(Duration::from_secs(timeout));
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                event = session.next_event() => {
                    let event = event?;
                    if matches!(event, SessionEvent::DiscoveryCompleted { .. }) { break; }
                    report(&event, json_output, false)?;
                }
                _ = &mut deadline => break,
            }
        }
        if json_output {
            emit(json!({"type":"discovery","devices":devices(&session)}))?;
        } else {
            for row in devices(&session) {
                println!(
                    "{} ({}:{})",
                    row["alias"].as_str().unwrap_or("?"),
                    row["host"].as_str().unwrap_or("?"),
                    row["port"]
                );
            }
        }
        Ok(())
    }
    .await;
    session.shutdown().await;
    outcome
}

pub(super) async fn receive(
    storage: Repository,
    auto_accept: bool,
    once: bool,
    timeout: Option<u64>,
    json_output: bool,
) -> anyhow::Result<()> {
    let policy = if auto_accept {
        ReceivePolicy::Auto
    } else {
        ReceivePolicy::Paired
    };
    let mut session = Session::start(config(storage, policy)).await?;
    if json_output {
        emit(
            json!({"event":"ready","protocol_version":1,"alias":session.alias(),"port":session.port()}),
        )?;
    }
    session.discover(None);
    let deadline = async {
        match timeout {
            Some(seconds) => tokio::time::sleep(Duration::from_secs(seconds)).await,
            None => std::future::pending::<()>().await,
        }
    };
    tokio::pin!(deadline);
    let outcome: anyhow::Result<()> = async {
        let mut completed = false;
        loop {
            tokio::select! {
                event = session.next_event() => {
                    let event = event?;
                    if let SessionEvent::ReceiveCompleted { success, .. } = &event {
                        completed = true;
                        report(&event, json_output, false)?;
                        if once && !success { return Err(anyhow!("Received transfer failed")); }
                        if once { return Ok(()); }
                    } else { report(&event, json_output, false)?; }
                }
                _ = &mut deadline => {
                    if once && !completed { return Err(anyhow!("Timed out waiting for a transfer")); }
                    return Ok(());
                }
                _ = tokio::signal::ctrl_c() => return Ok(()),
            }
        }
    }.await;
    session.shutdown().await;
    outcome
}

pub(super) async fn send(
    storage: Repository,
    target: Target,
    target_port: Option<u16>,
    timeout: Option<u64>,
    json_output: bool,
    payload: Payload,
) -> anyhow::Result<()> {
    let mut session = Session::start(config(storage, ReceivePolicy::Disabled)).await?;
    let outcome: anyhow::Result<()> = async {
        let payload = offer(payload)?;
        let deadline = Duration::from_secs(timeout.unwrap_or(60));
        let transfer_id = match target_port {
            Some(port) => session.send_to_port(target.clone(), port, payload, Some(deadline))?,
            None => session.send(target.clone(), payload, Some(deadline))?,
        };
        loop {
            let event = session.next_event().await?;
            if let SessionEvent::SendCompleted {
                transfer_id: id,
                success,
                error,
                ..
            } = &event
            {
                report(&event, json_output, false)?;
                if id == &transfer_id {
                    return if *success {
                        Ok(())
                    } else {
                        Err(anyhow!(
                            error
                                .clone()
                                .unwrap_or_else(|| "Transfer failed".to_string())
                        ))
                    };
                }
            } else {
                report(&event, json_output, false)?;
            }
        }
    }
    .await;
    session.shutdown().await;
    outcome
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
        Ok(result) => emit(json!({"id":id,"ok":true,"result":result})),
        Err(error) => emit(json!({"id":id,"ok":false,"error":error.to_string()})),
    }
}

pub(super) async fn serve(storage: Repository) -> anyhow::Result<()> {
    let mut session = Session::start(config(storage, ReceivePolicy::Decision)).await?;
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
    session.discover(None);
    emit(
        json!({"event":"ready","protocol_version":1,"alias":session.alias(),"port":session.port()}),
    )?;
    let outcome: anyhow::Result<()> = async { loop {
        tokio::select! {
            event = session.next_event() => report(&event?, true, true)?,
            line = input_rx.recv() => {
                let Some(line) = line else { break; };
                let request: Request = match serde_json::from_str(&line) {
                    Ok(request) => request,
                    Err(error) => { emit(json!({"ok":false,"error":format!("Invalid request: {error}")}))?; continue; }
                };
                let id = request.id.clone();
                if request.command == "shutdown" {
                    reply(id, Ok(json!({"shutting_down":true})))?;
                    break;
                }
                let result: anyhow::Result<Value> = async { match request.command.as_str() {
                    "devices" => Ok(json!({"devices":devices(&session)})),
                    "discover" => { session.discover(None); Ok(json!({"started":true})) },
                    "send" => {
                        let target = request.to.as_deref().context("Missing to").and_then(Target::parse);
                        target.and_then(|target| {
                            let paths = request.paths.context("Missing paths")?;
                            let timeout = request.timeout.unwrap_or(60);
                            anyhow::ensure!((1..=86400).contains(&timeout), "timeout must be 1 to 86400 seconds");
                            let payload = offer(Payload::Files(paths))?;
                            let transfer_id = match request.target_port {
                                Some(port) => session.send_to_port(target, port, payload, Some(Duration::from_secs(timeout)))?,
                                None => session.send(target, payload, Some(Duration::from_secs(timeout)))?,
                            };
                            Ok(json!({"transfer_id":transfer_id,"queued":true}))
                        })
                    }
                    "receive_decision" => {
                        let session_id = request.session_id.context("Missing session_id")?;
                        let accept = request.accept.context("Missing accept decision")?;
                        session.decide_receive(&session_id, accept).map(|()| json!({"accepted":accept}))
                    }
                    "cancel" => {
                        let transfer_id = request.transfer_id.or(request.session_id).context("Missing transfer_id or session_id")?;
                        session.cancel(&transfer_id).await.map(|()| json!({"cancelled":true}))
                    }
                    "status" => {
                        let status = session.status();
                        Ok(json!({"sending":status.sending.map(|s| json!({"transfer_id":s.transfer_id,"session_id":s.session_id,"bytes":s.bytes})),
                            "queued_send":status.queued_send.map(|id| json!({"transfer_id":id})),
                            "receiving":status.receiving.map(|r| json!({"session_id":r.session_id,"alias":r.alias})),
                            "pending":status.pending_receive.map(|r| json!({"session_id":r.session_id,"alias":r.alias}))}))
                    }
                    other => Err(anyhow!("Unknown command: {other}")),
                }}.await;
                reply(id, result)?;
            }
        }
    } Ok(()) }.await;
    session.shutdown().await;
    outcome
}
