use anyhow::{Context, ensure};
use localsend::crypto::cert::{fingerprint_from_cert_der, verify_cert_from_pem};
use serde::Deserialize;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    path::PathBuf,
};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecurityContext {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

#[derive(Clone, Deserialize)]
pub struct Config {
    pub alias: String,
    pub port: u16,
    #[serde(default = "yes")]
    pub https: bool,
    pub pin: Option<String>,
    #[serde(default = "yes")]
    pub verify_checksums: bool,
    pub destination: PathBuf,
    #[serde(default)]
    pub auto_accept: bool,
    #[serde(default = "yes")]
    pub discovery: bool,
    #[serde(default = "group")]
    pub multicast_group: Ipv4Addr,
    #[serde(default = "group_v6")]
    pub multicast_group_v6: Option<Ipv6Addr>,
    pub security_context: SecurityContext,
}

fn yes() -> bool {
    true
}
fn group() -> Ipv4Addr {
    localsend::multicast::DEFAULT_MULTICAST_GROUP
}
fn group_v6() -> Option<Ipv6Addr> {
    Some(localsend::multicast::DEFAULT_MULTICAST_GROUP_V6)
}

impl Config {
    pub fn validate(&self) -> anyhow::Result<()> {
        ensure!(
            self.destination.is_absolute(),
            "destination must be absolute"
        );
        ensure!(
            self.destination.is_dir(),
            "destination must be an existing directory"
        );
        let context = &self.security_context;
        verify_cert_from_pem(context.certificate.clone(), Some(&context.public_key))
            .context("invalid persisted certificate")?;
        let certificate = pem::parse(&context.certificate)?;
        ensure!(
            certificate.tag() == "CERTIFICATE",
            "identity is not a certificate"
        );
        ensure!(
            fingerprint_from_cert_der(certificate.contents()) == context.certificate_hash,
            "persisted certificateHash does not match certificate; refusing to replace identity"
        );
        Ok(())
    }
}
