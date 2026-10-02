//! Creates an explicit disposable development identity, never imports user preferences.
#[cfg(unix)]
use std::{io::Write, os::unix::fs::OpenOptionsExt, path::Path};

#[cfg(unix)]
fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    anyhow::ensure!(
        args.len() == 3 || args.len() == 4,
        "Usage: fixture_config CONFIG_PATH DOWNLOADS_PATH [PORT]"
    );
    let destination = Path::new(&args[2]);
    anyhow::ensure!(
        destination.is_absolute() && destination.is_dir(),
        "Downloads must exist and be absolute"
    );
    let identity = localsend::crypto::cert::generate_self_signed()?;
    let config = serde_json::json!({
        "alias":"Disposable background fixture", "port":args.get(3).map(|p| p.parse::<u16>()).transpose()?.unwrap_or(0),
        "https":false,"pin":null,"verify_checksums":true,"destination":destination,"auto_accept":false,
        "discovery":false,"security_context": {
            "privateKey":identity.private_key_pem,"publicKey":identity.public_key_pem,
            "certificate":identity.certificate_pem,"certificateHash":identity.fingerprint,
        }
    });
    let mut output = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&args[1])?;
    output.write_all(&serde_json::to_vec_pretty(&config)?)?;
    Ok(())
}

#[cfg(not(unix))]
fn main() {
    eprintln!("This development fixture currently requires Unix");
}
