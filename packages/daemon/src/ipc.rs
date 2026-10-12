use crate::{
    protocol::{Operation, Reply, Request, VERSION},
    runtime::Runtime,
};
use anyhow::{Context, ensure};
use std::{
    io::Read,
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        net::UnixListener as StdListener,
    },
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    task::JoinSet,
};

const MAX_REQUEST_BYTES: usize = 1024 * 1024;

pub struct Endpoint {
    listener: UnixListener,
    path: PathBuf,
    inode: u64,
    token: String,
}

fn private_directory(path: &Path) -> anyhow::Result<()> {
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new().mode(0o700).create(path)?;
        }
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let metadata = std::fs::symlink_metadata(path)?;
    // A private, current-user directory is the local permission seam. Never
    // follow a symlink or relax permissions on an existing directory.
    ensure!(
        metadata.is_dir()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.permissions().mode() & 0o777 == 0o700,
        "IPC directory must be owned by this user and mode 0700"
    );
    Ok(())
}

pub fn read_private_file(path: &Path) -> anyhow::Result<String> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.permissions().mode() & 0o777 == 0o600,
        "Secret file must be owned by this user and mode 0600"
    );
    ensure!(
        metadata.len() <= MAX_REQUEST_BYTES as u64,
        "Secret file too large"
    );
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    Ok(text)
}

impl Endpoint {
    pub fn bind(path: &Path, token_file: &Path) -> anyhow::Result<Self> {
        private_directory(path.parent().context("Socket needs a parent directory")?)?;
        let token = read_private_file(token_file)?.trim().to_string();
        ensure!(
            token.len() >= 32,
            "IPC token must have at least 32 characters"
        );
        // bind refuses existing files/sockets, including stale ones. A second
        // daemon never unlinks a socket belonging to another live instance.
        let listener = StdListener::bind(path)
            .context("Cannot bind daemon socket (another owner or stale socket)")?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        let inode = std::fs::symlink_metadata(path)?.ino();
        listener.set_nonblocking(true)?;
        Ok(Self {
            listener: UnixListener::from_std(listener)?,
            path: path.into(),
            inode,
            token,
        })
    }

    pub async fn serve(self, runtime: Runtime) -> anyhow::Result<()> {
        let runtime = Arc::new(runtime);
        let mut stopped = runtime.stopped.clone();
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                changed = stopped.changed() => {
                    if changed.is_err() || *stopped.borrow() { break; }
                }
                accepted = self.listener.accept() => {
                    let (stream, _) = accepted?;
                    let runtime = runtime.clone(); let token = self.token.clone();
                    connections.spawn(async move { let _ = connection(stream, runtime, token).await; });
                }
                Some(_) = connections.join_next(), if !connections.is_empty() => {}
            }
        }
        // Command replies already queued are allowed to flush; watches exit
        // through the stopped signal. No UI connection extends daemon life.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while connections.join_next().await.is_some() {}
        })
        .await;
        Ok(())
    }
}

impl Drop for Endpoint {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.path).is_ok_and(|metadata| metadata.ino() == self.inode)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

async fn reply(stream: &mut UnixStream, value: &Reply) -> anyhow::Result<()> {
    let mut json = serde_json::to_vec(value)?;
    json.push(b'\n');
    stream.write_all(&json).await?;
    Ok(())
}

async fn connection(
    stream: UnixStream,
    runtime: Arc<Runtime>,
    token: String,
) -> anyhow::Result<()> {
    let mut reader = BufReader::new(stream);
    let mut stopped = runtime.stopped.clone();
    loop {
        let mut line = Vec::new();
        let count = {
            let mut limited = (&mut reader).take((MAX_REQUEST_BYTES + 1) as u64);
            tokio::select! {
                read = limited.read_until(b'\n', &mut line) => read?,
                _ = stopped.changed() => return Ok(()),
            }
        };
        if count == 0 {
            return Ok(());
        }
        if count > MAX_REQUEST_BYTES || line.last() != Some(&b'\n') {
            reply(
                reader.get_mut(),
                &Reply::failure(
                    "".into(),
                    "invalid_request",
                    "Request exceeds limit or lacks newline",
                ),
            )
            .await?;
            return Ok(());
        }
        let request: Request = match serde_json::from_slice(&line) {
            Ok(request) => request,
            Err(_) => {
                reply(
                    reader.get_mut(),
                    &Reply::failure("".into(), "invalid_request", "Invalid JSON request"),
                )
                .await?;
                continue;
            }
        };
        if request.version != VERSION {
            reply(
                reader.get_mut(),
                &Reply::failure(
                    request.id,
                    "unsupported_version",
                    "Expected protocol version 1",
                ),
            )
            .await?;
            continue;
        }
        if request.token != token {
            reply(
                reader.get_mut(),
                &Reply::failure(
                    request.id,
                    "unauthorized",
                    "Invalid local authentication token",
                ),
            )
            .await?;
            return Ok(());
        }
        if let Operation::Watch { include_progress } = request.operation {
            let mut snapshots = if include_progress {
                runtime.snapshots.clone()
            } else {
                runtime.wake_snapshots.clone()
            };
            // Subscribe first, then refresh atomically through the actor so
            // changes cannot fall between the initial snapshot and the watch.
            if include_progress {
                let _ = runtime.command(Operation::Snapshot).await;
            }
            loop {
                let snapshot = snapshots.borrow_and_update().clone();
                reply(
                    reader.get_mut(),
                    &Reply::success(request.id.clone(), snapshot),
                )
                .await?;
                tokio::select! {
                    changed = snapshots.changed() => { if changed.is_err() { return Ok(()); } }
                    _ = stopped.changed() => return Ok(()),
                    // EOF closes a watch promptly even when the daemon is idle.
                    read = reader.read_u8() => { let _ = read; return Ok(()); }
                }
            }
        }
        let result = runtime.command(request.operation).await;
        let value = match result {
            Ok(snapshot) => Reply::success(request.id, snapshot),
            Err((code, message)) => Reply::failure(request.id, code, message),
        };
        reply(reader.get_mut(), &value).await?;
    }
}
