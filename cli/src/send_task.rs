//! Interactive UI adapter for the shared upload task.

use crate::app::AppEvent;
use crate::storage::Identity;
use crate::ui::Category;
use localsend::discovery::StatefulDevice;
use localsend::model::transfer::FileDto;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use tokio::sync::mpsc;

use localsend_session::TaskEvent;
pub use localsend_session::{FileSource, SendCancel};

pub async fn run_send(
    identity: Arc<Identity>,
    device: StatefulDevice,
    files: HashMap<String, FileDto>,
    sources: HashMap<String, FileSource>,
    progress: Arc<AtomicU64>,
    cancel: SendCancel,
    events: mpsc::Sender<AppEvent>,
) {
    let (task_tx, mut task_rx) = mpsc::channel(64);
    let upload = tokio::spawn(localsend_session::run_send(
        identity, device, files, sources, progress, cancel, task_tx,
    ));
    while let Some(event) = task_rx.recv().await {
        let mapped = match event {
            TaskEvent::Started {
                session_id,
                accepted_bytes,
            } => AppEvent::SendSessionStarted {
                session_id,
                accepted_bytes,
            },
            TaskEvent::Ended { success } => AppEvent::SendEnded { success },
            TaskEvent::Log(text) => AppEvent::Log {
                category: Category::Send,
                text,
            },
        };
        if events.send(mapped).await.is_err() {
            break;
        }
    }
    let _ = upload.await;
}
