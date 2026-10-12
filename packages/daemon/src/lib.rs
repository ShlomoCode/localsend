pub mod config;
#[cfg(unix)]
pub mod ipc;
pub mod protocol;
pub mod runtime;

#[cfg(unix)]
use std::{
    ffi::{CStr, c_char},
    path::Path,
};

#[cfg(unix)]
pub async fn run(config_path: &Path, socket_path: &Path, token_file: &Path) -> anyhow::Result<()> {
    let config = serde_json::from_str(&ipc::read_private_file(config_path)?)?;
    // Reserve local ownership before starting network listeners.
    let endpoint = ipc::Endpoint::bind(socket_path, token_file)?;
    let runtime = runtime::Runtime::start(config).await?;
    endpoint.serve(runtime).await
}

/// Runs the background module on the calling thread until authenticated
/// shutdown. The caller keeps all strings alive for this blocking call.
///
/// # Safety
/// Arguments must be non-null pointers to valid NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
#[cfg(unix)]
pub unsafe extern "C" fn localsend_daemon_run(
    config_path: *const c_char,
    socket_path: *const c_char,
    token_file: *const c_char,
) -> i32 {
    let result = std::panic::catch_unwind(|| -> anyhow::Result<()> {
        anyhow::ensure!(
            !config_path.is_null() && !socket_path.is_null() && !token_file.is_null(),
            "Null daemon path"
        );
        let config_path = unsafe { CStr::from_ptr(config_path) }.to_str()?;
        let socket_path = unsafe { CStr::from_ptr(socket_path) }.to_str()?;
        let token_file = unsafe { CStr::from_ptr(token_file) }.to_str()?;
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()?
            .block_on(run(
                Path::new(config_path),
                Path::new(socket_path),
                Path::new(token_file),
            ))
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            eprintln!("LocalSend background startup/runtime failed: {error:#}");
            1
        }
        Err(_) => 2,
    }
}
