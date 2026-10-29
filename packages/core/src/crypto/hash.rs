use crate::model::transfer::FileContent;
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;

#[derive(Debug, thiserror::Error)]
pub enum HashError {
    #[error("Failed to read the file: {0}")]
    Io(#[from] std::io::Error),

    #[error("Hashing has been cancelled")]
    Cancelled,
}

pub fn sha256(data: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().to_vec()
}

/// Computes the SHA-256 checksum of `data`, encoded as lowercase hex.
pub fn sha256_hex(data: &[u8]) -> String {
    to_hex(&sha256(data))
}

/// Computes the SHA-256 checksum of a file's content, encoded as lowercase hex.
///
/// `progress` is invoked with the cumulative number of bytes hashed as each
/// chunk is consumed, mirroring the upload progress callback.
pub async fn sha256_file_content(
    content: FileContent,
    cancel_token: &CancellationToken,
    progress: impl Fn(u64),
) -> Result<String, HashError> {
    let mut hasher = Sha256::new();
    let mut stream = content.into_stream();
    let mut hashed = 0_u64;
    loop {
        let chunk = tokio::select! {
            biased;
            _ = cancel_token.cancelled() => return Err(HashError::Cancelled),
            chunk = stream.next() => chunk,
        };
        let Some(chunk) = chunk else { break };
        let chunk = chunk?;
        hasher.update(&chunk);
        hashed += chunk.len() as u64;
        progress(hashed);
    }

    Ok(to_hex(&hasher.finalize()))
}

pub(crate) fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
