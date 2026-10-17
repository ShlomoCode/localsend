use crate::send_task::FileSource;
use anyhow::Context;
use bytes::Bytes;
use localsend::model::transfer::{FileDto, FileMetadata};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use uuid::Uuid;
use walkdir::WalkDir;

/// Content selected for one send. The session owns file expansion and the
/// protocol metadata; callers need only supply paths or UTF-8 message text.
pub struct SendPayload {
    pub(crate) files: HashMap<String, FileDto>,
    pub(crate) sources: HashMap<String, FileSource>,
    pub(crate) total_bytes: u64,
}

impl SendPayload {
    pub fn paths(paths: Vec<PathBuf>) -> anyhow::Result<Self> {
        let offer = Self::paths_with_log(paths, |_| {});
        anyhow::ensure!(!offer.files.is_empty(), "No readable files selected");
        Ok(offer)
    }

    /// Collect readable files and report skipped entries through `log`.
    /// This is also used by the interactive CLI's file picker.
    pub fn paths_with_log(paths: Vec<PathBuf>, mut log: impl FnMut(String)) -> Self {
        let mut files = HashMap::new();
        let mut sources = HashMap::new();
        let mut total_bytes = 0;
        for collected in paths.iter().flat_map(|path| collect_path(path)) {
            let (path, file_name) = match collected {
                Ok(collected) => collected,
                Err((path, error)) => {
                    log(format!(
                        "Skipping unreadable path: {} ({error})",
                        path.display()
                    ));
                    continue;
                }
            };
            let metadata = match path.metadata() {
                Ok(metadata) if metadata.is_file() => metadata,
                _ => {
                    log(format!("Skipping unreadable file: {}", path.display()));
                    continue;
                }
            };
            let id = Uuid::new_v4().to_string();
            total_bytes += metadata.len();
            files.insert(
                id.clone(),
                FileDto {
                    id: id.clone(),
                    file_name,
                    size: metadata.len(),
                    file_type: mime_guess::from_path(&path)
                        .first_or_octet_stream()
                        .to_string(),
                    sha256: None,
                    preview: None,
                    metadata: FileMetadata::from_fs_metadata(&metadata),
                },
            );
            sources.insert(id, FileSource::Path(path));
        }
        Self {
            files,
            sources,
            total_bytes,
        }
    }

    /// Short text travels in the request preview. Longer text is uploaded as
    /// a `.txt` file, matching the CLI's existing message behavior.
    pub fn message(text: impl Into<Bytes>) -> anyhow::Result<Self> {
        let text = text.into();
        anyhow::ensure!(!text.is_empty(), "Nothing to send: the text is empty");
        let content = std::str::from_utf8(&text).context("Message must be UTF-8")?;
        let id = Uuid::new_v4().to_string();
        let size = text.len() as u64;
        let preview = (text.len() <= 64_000).then(|| content.to_string());
        let file = FileDto {
            id: id.clone(),
            file_name: format!("{id}.txt"),
            size,
            file_type: "text/plain".to_string(),
            sha256: None,
            preview,
            metadata: None,
        };
        Ok(Self {
            files: HashMap::from([(id.clone(), file)]),
            sources: HashMap::from([(id, FileSource::Bytes(text))]),
            total_bytes: size,
        })
    }

    pub fn total_bytes(&self) -> u64 {
        self.total_bytes
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    pub fn into_parts(self) -> (HashMap<String, FileDto>, HashMap<String, FileSource>) {
        (self.files, self.sources)
    }
}

type CollectedPath = Result<(PathBuf, String), (PathBuf, String)>;

fn collect_path(path: &Path) -> Vec<CollectedPath> {
    let metadata = match path.metadata() {
        Ok(metadata) => metadata,
        Err(error) => return vec![Err((path.to_path_buf(), error.to_string()))],
    };
    if metadata.is_file() {
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "unnamed".to_string());
        return vec![Ok((path.to_path_buf(), name))];
    }
    if !metadata.is_dir() {
        return vec![Err((
            path.to_path_buf(),
            "not a regular file or directory".to_string(),
        ))];
    }
    let root_name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .or_else(|| {
            path.canonicalize()
                .ok()?
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
        });
    let Some(root_name) = root_name else {
        return vec![Err((
            path.to_path_buf(),
            "directory has no transferable name".to_string(),
        ))];
    };
    WalkDir::new(path)
        .min_depth(1)
        .sort_by_file_name()
        .into_iter()
        .filter_map(|entry| match entry {
            Ok(entry) if entry.file_type().is_file() => {
                let relative = match entry.path().strip_prefix(path) {
                    Ok(relative) => relative,
                    Err(error) => {
                        return Some(Err((entry.path().to_path_buf(), error.to_string())));
                    }
                };
                let name = std::iter::once(root_name.clone())
                    .chain(
                        relative
                            .components()
                            .filter_map(|component| match component {
                                Component::Normal(name) => {
                                    Some(name.to_string_lossy().into_owned())
                                }
                                _ => None,
                            }),
                    )
                    .collect::<Vec<_>>()
                    .join("/");
                Some(Ok((entry.path().to_path_buf(), name)))
            }
            Ok(_) => None,
            Err(error) => Some(Err((
                error.path().unwrap_or(path).to_path_buf(),
                error.to_string(),
            ))),
        })
        .collect()
}
