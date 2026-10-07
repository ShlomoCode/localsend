#[cfg(unix)]
use std::path::Path;

#[cfg(unix)]
fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    anyhow::ensure!(
        args.len() == 7
            && args[1] == "--config"
            && args[3] == "--socket"
            && args[5] == "--token-file",
        "Usage: localsend-daemon --config PATH --socket PATH --token-file PATH"
    );
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?
        .block_on(localsend_daemon::run(
            Path::new(&args[2]),
            Path::new(&args[4]),
            Path::new(&args[6]),
        ))
}

#[cfg(not(unix))]
fn main() {
    eprintln!("The LocalSend background launcher currently requires Unix sockets");
    std::process::exit(1);
}
