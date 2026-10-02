use localsend::discovery::{HttpChannel, StatefulDevice};
use localsend::model::discovery::ProtocolType;
use localsend::multicast::DEFAULT_PORT;
use std::net::IpAddr;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum TargetSelector {
    Alias(String),
    Ip(IpAddr),
    ScopedIp { ip: IpAddr, host: String },
}

impl TargetSelector {
    pub(super) fn parse(value: &str) -> anyhow::Result<Self> {
        let value = value.trim();
        anyhow::ensure!(!value.is_empty(), "Destination cannot be empty");
        Ok(match value.parse::<IpAddr>() {
            Ok(ip) => Self::Ip(ip),
            Err(_) => match value.split_once('%') {
                Some((address, scope)) if !scope.is_empty() && !scope.contains('%') => {
                    match address.parse::<std::net::Ipv6Addr>() {
                        Ok(ip) => {
                            let index = match scope.parse::<u32>() {
                                Ok(index) if index > 0 => index,
                                Ok(_) => {
                                    anyhow::bail!("IPv6 interface scope must be greater than zero")
                                }
                                Err(_) => if_addrs::get_if_addrs()?
                                    .into_iter()
                                    .find(|interface| {
                                        interface.name == scope && interface.index.is_some()
                                    })
                                    .and_then(|interface| interface.index)
                                    .ok_or_else(|| {
                                        anyhow::anyhow!("Unknown IPv6 interface scope {scope:?}")
                                    })?,
                            };
                            Self::ScopedIp {
                                ip: IpAddr::V6(ip),
                                host: format!("{ip}%{index}"),
                            }
                        }
                        Err(_) => Self::Alias(value.to_string()),
                    }
                }
                _ => Self::Alias(value.to_string()),
            },
        })
    }

    pub(super) fn direct_channel(&self) -> Option<HttpChannel> {
        self.direct_channel_at(DEFAULT_PORT)
    }

    pub(super) fn direct_channel_at(&self, port: u16) -> Option<HttpChannel> {
        let host = match self {
            Self::Ip(ip) => ip.to_string(),
            Self::ScopedIp { host, .. } => host.clone(),
            Self::Alias(_) => return None,
        };
        Some(HttpChannel {
            host,
            port,
            protocol: ProtocolType::Https,
        })
    }

    pub(super) fn resolve(&self, devices: &[StatefulDevice]) -> Result<String, String> {
        self.resolve_matching(devices, |device| self.matches(device))
    }

    /// Resolve an explicit address only among identities confirmed on the
    /// exact channel the caller selected. Different peers can share an IP
    /// when their listening ports or IPv6 interface scopes differ.
    pub(super) fn resolve_at(
        &self,
        devices: &[StatefulDevice],
        port: u16,
    ) -> Result<String, String> {
        if matches!(self, Self::Alias(_)) {
            return self.resolve(devices);
        }
        self.resolve_matching(devices, |device| {
            device.get_ranked_channels().into_iter().any(|channel| {
                channel
                    .http()
                    .is_some_and(|http| self.matches_channel(http, port))
            })
        })
    }

    fn resolve_matching(
        &self,
        devices: &[StatefulDevice],
        matches: impl Fn(&StatefulDevice) -> bool,
    ) -> Result<String, String> {
        let matching: Vec<&StatefulDevice> =
            devices.iter().filter(|device| matches(device)).collect();
        match matching.as_slice() {
            [] => Err(format!("Destination {self} was not discovered")),
            [device] => Ok(device.device.fingerprint.clone()),
            devices => Err(format!(
                "Destination {self} is ambiguous ({} devices matched); use an IP address",
                devices.len()
            )),
        }
    }

    /// For an explicit address, keep only the confirmed channel at the
    /// requested address and port. A multi-homed peer may otherwise rank a
    /// different interface above the one the caller selected.
    pub(super) fn restrict_device(
        &self,
        device: &mut StatefulDevice,
        port: u16,
    ) -> Result<(), String> {
        if matches!(self, Self::Alias(_)) {
            return Ok(());
        }
        device.channels.retain(|channel, _| {
            channel
                .http()
                .is_some_and(|http| self.matches_channel(http, port))
        });
        if device.channels.is_empty() {
            Err(format!(
                "Destination {self} was not confirmed at port {port}"
            ))
        } else {
            Ok(())
        }
    }

    fn matches_channel(&self, http: &HttpChannel, port: u16) -> bool {
        http.port == port
            && match self {
                Self::Ip(ip) => http.host == ip.to_string(),
                Self::ScopedIp { host, .. } => http.host == *host,
                Self::Alias(_) => true,
            }
    }

    fn matches(&self, device: &StatefulDevice) -> bool {
        match self {
            Self::Alias(alias) => device.device.alias == *alias,
            Self::Ip(ip) | Self::ScopedIp { ip, .. } => {
                device.get_ranked_channels().into_iter().any(|channel| {
                    channel.http().is_some_and(|http| {
                        http.host
                            .split('%')
                            .next()
                            .and_then(|host| host.parse::<IpAddr>().ok())
                            == Some(*ip)
                    })
                })
            }
        }
    }
}

impl std::fmt::Display for TargetSelector {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Alias(alias) => write!(formatter, "alias {alias:?}"),
            Self::Ip(ip) => write!(formatter, "IP address {ip}"),
            Self::ScopedIp { host, .. } => write!(formatter, "IP address {host}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::TargetSelector;
    use localsend::discovery::{
        ChannelStatus, DeviceChannel, DiscoveredDevice, HttpChannel, StatefulDevice,
    };
    use localsend::model::discovery::ProtocolType;
    use std::collections::HashMap;
    use std::net::{IpAddr, Ipv4Addr};

    fn device(alias: &str, fingerprint: &str, host: &str) -> StatefulDevice {
        let channel = DeviceChannel::Http(HttpChannel {
            host: host.to_string(),
            port: 53317,
            protocol: ProtocolType::Https,
        });
        StatefulDevice {
            device: DiscoveredDevice {
                alias: alias.to_string(),
                version: "2.2".to_string(),
                device_model: None,
                device_type: None,
                fingerprint: fingerprint.to_string(),
                channel: channel.clone(),
                download: false,
            },
            channels: HashMap::from([(channel, ChannelStatus::Available)]),
            logs: Vec::new(),
        }
    }

    #[test]
    fn parses_aliases_and_ip_addresses() {
        assert_eq!(
            TargetSelector::parse("Cute Tomato").unwrap(),
            TargetSelector::Alias("Cute Tomato".to_string())
        );
        assert_eq!(
            TargetSelector::parse("192.168.27.26").unwrap(),
            TargetSelector::Ip(IpAddr::V4(Ipv4Addr::new(192, 168, 27, 26)))
        );
    }

    #[test]
    fn rejects_an_empty_destination() {
        assert!(TargetSelector::parse("  ").is_err());
    }

    #[test]
    fn creates_a_direct_https_channel_for_an_ip() {
        let selector = TargetSelector::parse("192.168.27.26").unwrap();

        assert_eq!(
            selector.direct_channel(),
            Some(HttpChannel {
                host: "192.168.27.26".to_string(),
                port: 53317,
                protocol: ProtocolType::Https,
            })
        );
    }

    #[test]
    fn retains_scope_for_link_local_ipv6_probe_and_matching() {
        let selector = TargetSelector::parse("fe80::20%3").unwrap();
        assert_eq!(
            selector.direct_channel_at(54444).unwrap().host,
            "fe80::20%3"
        );
        assert_eq!(selector.direct_channel_at(54444).unwrap().port, 54444);
        assert_eq!(
            selector.resolve(&[device("Peer", "fp", "fe80::20%3")]),
            Ok("fp".to_string())
        );
    }

    #[test]
    fn named_scope_uses_the_interface_index() {
        let interface = if_addrs::get_if_addrs()
            .unwrap()
            .into_iter()
            .find(|interface| interface.index.is_some())
            .expect("network interface with index");
        let index = interface.index.unwrap();
        let selector = TargetSelector::parse(&format!("fe80::20%{}", interface.name)).unwrap();
        assert_eq!(
            selector.direct_channel().unwrap().host,
            format!("fe80::20%{index}")
        );
        assert!(TargetSelector::parse("fe80::20%there-is-no-such-interface").is_err());
    }

    #[test]
    fn explicit_address_and_port_restrict_a_multihomed_device() {
        let mut peer = device("Peer", "fp", "192.168.1.20");
        let other = DeviceChannel::Http(HttpChannel {
            host: "10.0.0.20".to_string(),
            port: 53318,
            protocol: ProtocolType::Https,
        });
        peer.channels.insert(other, ChannelStatus::Available);
        let target = TargetSelector::parse("192.168.1.20").unwrap();
        target.restrict_device(&mut peer, 53317).unwrap();
        assert_eq!(peer.channels.len(), 1);
        assert_eq!(
            peer.get_best_channel().unwrap().http().unwrap().host,
            "192.168.1.20"
        );
        assert!(target.restrict_device(&mut peer, 53318).is_err());
    }

    #[test]
    fn resolves_identity_by_explicit_port_before_fingerprint() {
        let first = device("First", "first", "192.168.1.20");
        let mut second = device("Second", "second", "192.168.1.20");
        second.channels.clear();
        second.channels.insert(
            DeviceChannel::Http(HttpChannel {
                host: "192.168.1.20".to_string(),
                port: 54444,
                protocol: ProtocolType::Https,
            }),
            ChannelStatus::Available,
        );
        let target = TargetSelector::parse("192.168.1.20").unwrap();
        assert_eq!(
            target.resolve_at(&[first.clone(), second.clone()], 53317),
            Ok("first".to_string())
        );
        assert_eq!(
            target.resolve_at(&[first, second], 54444),
            Ok("second".to_string())
        );
    }

    #[test]
    fn resolves_link_local_identity_by_scope_before_fingerprint() {
        let target = TargetSelector::parse("fe80::20%3").unwrap();
        let devices = [
            device("Wrong interface", "wrong", "fe80::20%4"),
            device("Right interface", "right", "fe80::20%3"),
        ];
        assert_eq!(target.resolve_at(&devices, 53317), Ok("right".to_string()));
    }

    #[test]
    fn resolves_an_exact_alias() {
        let devices = vec![
            device("Cute Tomato", "windows", "192.168.27.26"),
            device("Wise Cherry", "linux", "192.168.27.33"),
        ];

        assert_eq!(
            TargetSelector::parse("Cute Tomato")
                .unwrap()
                .resolve(&devices),
            Ok("windows".to_string())
        );
    }

    #[test]
    fn resolves_an_ip_address() {
        let devices = vec![device("Cute Tomato", "windows", "192.168.27.26")];

        assert_eq!(
            TargetSelector::parse("192.168.27.26")
                .unwrap()
                .resolve(&devices),
            Ok("windows".to_string())
        );
    }

    #[test]
    fn rejects_an_ambiguous_alias() {
        let devices = vec![
            device("Cute Tomato", "first", "192.168.27.26"),
            device("Cute Tomato", "second", "192.168.27.27"),
        ];

        assert!(
            TargetSelector::parse("Cute Tomato")
                .unwrap()
                .resolve(&devices)
                .unwrap_err()
                .contains("ambiguous")
        );
    }

    #[test]
    fn rejects_a_destination_that_was_not_discovered() {
        let devices = vec![device("Wise Cherry", "linux", "192.168.27.33")];

        assert!(
            TargetSelector::parse("Cute Tomato")
                .unwrap()
                .resolve(&devices)
                .unwrap_err()
                .contains("was not discovered")
        );
    }
}
