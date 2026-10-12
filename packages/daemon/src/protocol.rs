use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;

#[derive(Deserialize)]
pub struct Request {
    pub version: u32,
    pub id: String,
    pub token: String,
    #[serde(flatten)]
    pub operation: Operation,
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum Operation {
    Snapshot,
    Watch {
        #[serde(default = "include_progress")]
        include_progress: bool,
    },
    Accept {
        session_id: String,
        file_ids: Option<Vec<String>>,
    },
    Decline {
        session_id: String,
    },
    Cancel {
        session_id: String,
    },
    Shutdown,
}

fn include_progress() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    pub revision: u64,
    pub port: u16,
    pub receive: Option<Receive>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Receive {
    pub session_id: String,
    pub sender_alias: String,
    pub sender_fingerprint: String,
    pub status: String,
    pub files: Vec<File>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct File {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub received_bytes: u64,
    pub status: String,
    pub path: Option<String>,
    pub error: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct Reply {
    pub version: u32,
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<Snapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<Failure>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

impl Reply {
    pub fn success(id: String, snapshot: Snapshot) -> Self {
        Self {
            version: VERSION,
            id,
            ok: true,
            snapshot: Some(snapshot),
            error: None,
        }
    }
    pub fn failure(id: String, code: &str, message: impl ToString) -> Self {
        Self {
            version: VERSION,
            id,
            ok: false,
            snapshot: None,
            error: Some(Failure {
                code: code.into(),
                message: message.to_string(),
            }),
        }
    }
}
