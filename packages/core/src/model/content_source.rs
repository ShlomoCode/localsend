//! Resolves application-provided byte sources for uploads and downloads.

use super::{
    macos_app_archive::MacosAppArchive,
    transfer::{FileContent, FileStream},
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use std::{io, path::PathBuf};
use tokio::sync::mpsc;

/// A source of transfer bytes. Generated sources carry an opaque descriptor;
/// callers do not need to know how a particular source produces its stream.
#[derive(Debug)]
pub enum ContentSource {
    Path { path: String },
    Bytes { bytes: Vec<u8> },
    FileDescriptor { fd: i32 },
    Generated { descriptor: String },
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", content = "source", rename_all = "camelCase")]
enum Generator {
    MacosAppArchive(MacosAppArchive),
}

impl ContentSource {
    /// Wrap a measured archive in the private generated-source format.
    pub fn from_macos_app_archive(archive: MacosAppArchive) -> io::Result<Self> {
        let source = Generator::MacosAppArchive(archive);
        let descriptor = serde_json::to_string(&source).map_err(invalid_descriptor)?;
        Ok(Self::Generated { descriptor })
    }

    /// Resolve the source to content supported by the transfer layer.
    pub fn into_content(self) -> io::Result<FileContent> {
        match self {
            Self::Path { path } => Ok(FileContent::Path(PathBuf::from(path))),
            Self::Bytes { bytes } => {
                let (tx, rx) = mpsc::channel(1);
                tx.try_send(Bytes::from(bytes)).map_err(io::Error::other)?;
                Ok(FileContent::Stream(rx))
            }
            Self::FileDescriptor { fd } => {
                #[cfg(target_os = "android")]
                {
                    if fd < 0 {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "Invalid file descriptor",
                        ));
                    }
                    Ok(FileContent::Fd(fd))
                }
                #[cfg(not(target_os = "android"))]
                {
                    let _ = fd;
                    Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "File descriptors are only supported on Android",
                    ))
                }
            }
            Self::Generated { descriptor } => {
                let generator: Generator =
                    serde_json::from_str(&descriptor).map_err(invalid_descriptor)?;
                match generator {
                    Generator::MacosAppArchive(archive) => {
                        Ok(FileContent::MacosAppArchive(archive))
                    }
                }
            }
        }
    }

    /// Open this source using the same stream path as a transfer.
    pub fn open_read(self) -> io::Result<FileStream> {
        Ok(self.into_content()?.into_stream())
    }
}

fn invalid_descriptor(error: serde_json::Error) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("Invalid generated source: {error}"),
    )
}
