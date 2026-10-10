use crate::api::content_stream::RsContentStreamReceiver;
use crate::frb_generated::RustOpaque;
use flutter_rust_bridge::frb;
pub use localsend::model::content_source::ContentSource;
use localsend::model::transfer::FileContent;

/// The source supplied to a transfer. Native sources can be reopened by Rust;
/// a Dart stream passes its receiver to a single transfer.
pub enum RsContentSource {
    Native {
        source: ContentSource,
    },
    Stream {
        receiver: RustOpaque<RsContentStreamReceiver>,
    },
}

impl RsContentSource {
    #[frb(ignore)]
    pub async fn into_content(self) -> std::io::Result<FileContent> {
        match self {
            Self::Native { source } => source.into_content(),
            Self::Stream { receiver } => receiver.take_content().await,
        }
    }
}

#[frb(mirror(ContentSource))]
pub enum _ContentSource {
    Path { path: String },
    Bytes { bytes: Vec<u8> },
    FileDescriptor { fd: i32 },
    Generated { descriptor: String },
}
