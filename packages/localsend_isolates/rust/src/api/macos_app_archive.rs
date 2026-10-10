use crate::api::byte_stream_source::ByteStreamSource;
use crate::api::cancel::RsCancellationToken;
use localsend::model::macos_app_archive::MacosAppArchive;

pub struct RsMacosAppArchiveInfo {
    pub source: ByteStreamSource,
    pub size: u64,
    pub sha256: String,
}

/// Measures a replayable application ZIP without storing the archive.
pub async fn prepare_macos_app_archive(
    path: String,
    cancel_token: &RsCancellationToken,
) -> anyhow::Result<RsMacosAppArchiveInfo> {
    let archive = MacosAppArchive::prepare(path.into(), cancel_token.inner.clone()).await?;
    let size = archive.size();
    let sha256 = archive.sha256();
    Ok(RsMacosAppArchiveInfo {
        source: ByteStreamSource::from_macos_app_archive(archive)?,
        size,
        sha256,
    })
}
