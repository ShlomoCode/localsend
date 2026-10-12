use super::{ClientError, LsHttpClient};
use crate::model::discovery::ProtocolType;
use futures_util::stream::{FuturesUnordered, StreamExt};
use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;
use tokio::time::{sleep_until, Instant};
use tokio_util::sync::CancellationToken;

const PROBE_TIMEOUT: Duration = Duration::from_secs(1);
const SEARCH_TIMEOUT: Duration = Duration::from_secs(4);
const STAGGER: Duration = Duration::from_millis(180);

/// A dialable address for one LocalSend peer. IPv6 scope IDs remain in `host`.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct HttpEndpoint {
    pub host: String,
    pub port: u16,
    pub protocol: ProtocolType,
}

impl LsHttpClient {
    /// Selects a reachable v2 address matching the selected peer.
    ///
    /// HTTPS requires this client to have been created with `expected_fingerprint` as
    /// its certificate pin. In HTTP mode the claimed `/info` fingerprint is checked;
    /// this is a consistency check, not cryptographic authentication.
    /// Only candidates using `protocol` are probed; the selector never downgrades
    /// an HTTPS transfer to HTTP. Callers can keep the existing direct path for a
    /// single address to support older peers that do not implement `/info`.
    pub async fn select_endpoint(
        &self,
        candidates: Vec<HttpEndpoint>,
        protocol: ProtocolType,
        expected_fingerprint: String,
        cancel: CancellationToken,
    ) -> Result<HttpEndpoint, ClientError> {
        let client = match self {
            Self::V2(client) => client,
            Self::V3(_) => {
                return Err(ClientError::Other(anyhow::anyhow!(
                    "Endpoint selection is not supported for protocol v3"
                )));
            }
        };

        let expected = expected_fingerprint.to_ascii_uppercase();
        if expected.is_empty() {
            return Err(ClientError::Other(anyhow::anyhow!(
                "An expected peer fingerprint is required for endpoint selection"
            )));
        }
        if protocol == ProtocolType::Https
            && client.expected_fingerprint.as_deref() != Some(expected.as_str())
        {
            return Err(ClientError::Other(anyhow::anyhow!(
                "HTTPS endpoint selection requires a client pinned to the expected peer fingerprint"
            )));
        }

        let mut seen = HashSet::new();
        let mut candidates: VecDeque<_> = candidates
            .into_iter()
            .filter(|candidate| candidate.protocol == protocol && seen.insert(candidate.clone()))
            .collect();
        if candidates.is_empty() {
            return Err(ClientError::Other(anyhow::anyhow!(
                "No endpoint matches the required security protocol"
            )));
        }

        type Probe<'a> =
            Pin<Box<dyn Future<Output = Result<HttpEndpoint, ClientError>> + Send + 'a>>;
        let mut pending: FuturesUnordered<Probe<'_>> = FuturesUnordered::new();
        let deadline = Instant::now() + SEARCH_TIMEOUT;
        let mut next_launch = Instant::now();
        let mut last_error = None;

        loop {
            if cancel.is_cancelled() {
                return Err(ClientError::Cancelled);
            }

            if pending.len() < 2
                && !candidates.is_empty()
                && (pending.is_empty() || Instant::now() >= next_launch)
            {
                let candidate = candidates.pop_front().expect("checked above");
                let expected = expected.clone();
                pending.push(Box::pin(async move {
                    let (info, cert_fingerprint) = tokio::time::timeout(
                        PROBE_TIMEOUT,
                        client.probe_info(
                            candidate.protocol,
                            &candidate.host,
                            candidate.port,
                            true,
                        ),
                    )
                    .await
                    .map_err(|_| {
                        ClientError::Other(anyhow::anyhow!("Endpoint probe timed out"))
                    })??;

                    let actual = match candidate.protocol {
                        ProtocolType::Https => cert_fingerprint.ok_or_else(|| {
                            ClientError::Other(anyhow::anyhow!(
                                "HTTPS endpoint has no peer certificate"
                            ))
                        })?,
                        ProtocolType::Http => info
                            .ok_or_else(|| {
                                ClientError::Other(anyhow::anyhow!(
                                    "HTTP endpoint did not provide an identity in /info"
                                ))
                            })?
                            .fingerprint
                            .to_ascii_uppercase(),
                    };
                    if actual != expected {
                        return Err(ClientError::Other(anyhow::anyhow!(
                            "Endpoint identity did not match the expected peer"
                        )));
                    }
                    Ok(candidate)
                }));
                next_launch = Instant::now() + STAGGER;
            }

            if pending.is_empty() && candidates.is_empty() {
                return Err(ClientError::Other(anyhow::anyhow!(
                    "No verified endpoint was reachable: {}",
                    last_error.map_or_else(
                        || "no probe completed".to_string(),
                        |error: ClientError| error.to_string()
                    )
                )));
            }

            tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(ClientError::Cancelled),
                _ = sleep_until(deadline) => return Err(ClientError::Other(anyhow::anyhow!("Endpoint selection timed out"))),
                result = pending.next(), if !pending.is_empty() => {
                    match result.expect("pending probe exists") {
                        Ok(endpoint) => return Ok(endpoint),
                        Err(error) => last_error = Some(error),
                    }
                },
                _ = sleep_until(next_launch), if pending.len() < 2 && !candidates.is_empty() => {},
            }
        }
    }
}
