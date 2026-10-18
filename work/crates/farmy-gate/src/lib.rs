//! Host policies shared by the filtering proxy and its control plane.
#![forbid(unsafe_code)]
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::net::IpAddr;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostRule {
    pub host: String,
    pub port: Option<u16>,
    pub wildcard: bool,
}

fn dns_host(host: &str) -> Result<String, String> {
    let host = host.strip_suffix('.').unwrap_or(host).to_ascii_lowercase();
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(ip.to_string());
    }
    if host.is_empty()
        || host.len() > 253
        || !host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label.as_bytes()[0].is_ascii_alphanumeric()
                && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
                && label
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
    {
        return Err("expected a DNS hostname or IP literal".into());
    }
    Ok(host)
}

/// Splits `host[:port]` (IPv6 in brackets) into a normalised host and its port.
///
/// # Errors
///
/// The text of the problem when the authority is malformed: whitespace or URL syntax in it, an
/// IPv6 literal without its brackets, a port that is not a number, a host that is neither a DNS
/// name nor an IP literal, or no port when `require_port` asks for one.
pub fn authority(value: &str, require_port: bool) -> Result<(String, Option<u16>), String> {
    if value.is_empty()
        || value
            .chars()
            .any(|c| c.is_whitespace() || matches!(c, '/' | '@' | '?' | '#' | '\\'))
    {
        return Err("invalid host authority".into());
    }
    let (host, port) = if let Some(rest) = value.strip_prefix('[') {
        let (ip, rest) = rest.split_once(']').ok_or("IPv6 needs brackets")?;
        if !matches!(ip.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
            return Err("invalid IPv6 literal".into());
        }
        let port = if rest.is_empty() {
            None
        } else {
            Some(rest.strip_prefix(':').ok_or("invalid IPv6 port")?)
        };
        (ip, port)
    } else if let Some((host, port)) = value.split_once(':') {
        (host, Some(port))
    } else {
        (value, None)
    };
    let port = port
        .map(|p| {
            if p.is_empty() || !p.bytes().all(|c| c.is_ascii_digit()) {
                return Err("invalid port".to_string());
            }
            p.parse::<u16>()
                .ok()
                .filter(|p| *p != 0)
                .ok_or_else(|| "port must be 1..65535".into())
        })
        .transpose()?;
    if require_port && port.is_none() {
        return Err("an explicit port is required".into());
    }
    Ok((dns_host(host)?, port))
}

impl HostRule {
    /// An allow entry: `host`, `host:port` or `*.suffix[:port]`.
    ///
    /// # Errors
    ///
    /// What [`authority`] refuses, and a wildcard on an IP literal.
    pub fn parse(value: &str) -> Result<Self, String> {
        let value = value.trim();
        let (wildcard, value) = value
            .strip_prefix("*.")
            .map(|v| (true, v))
            .unwrap_or((false, value));
        let (host, port) = authority(value, false)?;
        if wildcard && host.parse::<IpAddr>().is_ok() {
            return Err("wildcards require a DNS suffix".into());
        }
        Ok(Self {
            host,
            port,
            wildcard,
        })
    }
    pub fn normalized(&self) -> String {
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        format!(
            "{}{}{}",
            if self.wildcard { "*." } else { "" },
            host,
            self.port.map(|p| format!(":{p}")).unwrap_or_default()
        )
    }
    pub fn permits(&self, host: &str, port: u16) -> bool {
        let Ok(host) = dns_host(host) else {
            return false;
        };
        let name = if self.wildcard {
            host != self.host && host.ends_with(&format!(".{}", self.host))
        } else {
            host == self.host
        };
        name && self.port.map(|p| port == p).unwrap_or(true)
    }
}

/// An upstream proxy URL, `http://host[:port]`, as host and port (80 when none is given).
///
/// # Errors
///
/// A URL that does not start with `http://`, and what [`authority`] refuses.
pub fn http_proxy(value: &str) -> Result<(String, u16), String> {
    let target = value
        .strip_prefix("http://")
        .ok_or("upstream must be an http:// proxy URL")?
        .trim_end_matches('/');
    let (host, port) = authority(target, false)?;
    Ok((host, port.unwrap_or(80)))
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Client {
    pub service: String,
    #[serde(default)]
    pub addresses: Option<Vec<String>>,
    pub allow: Vec<String>,
    #[serde(default)]
    pub mode: Mode,
}
#[derive(Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    #[default]
    Strict,
    Audit,
}

pub fn utc_timestamp(secs: u64) -> String {
    let days = (secs / 86400).cast_signed() + 719468; // below 2^48: no wrap
    let era = days.div_euclid(146097);
    let doe = days - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    let year = year + if month <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        secs / 3600 % 24,
        secs / 60 % 60,
        secs % 60
    )
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub version: u32,
    pub upstream: Option<String>,
    pub clients: BTreeMap<String, Client>,
}
impl Policy {
    /// Checks a policy before the gate uses it.
    ///
    /// # Errors
    ///
    /// The first problem found: a version other than 1, an upstream that [`http_proxy`] refuses,
    /// an empty client or service name, an invalid client IP, or an allow entry that
    /// [`HostRule::parse`] refuses.
    pub fn validate(&self) -> Result<(), String> {
        if self.version != 1 {
            return Err("policy version must be 1".into());
        }
        if let Some(proxy) = &self.upstream {
            http_proxy(proxy)?;
        }
        for (name, client) in &self.clients {
            if name.is_empty() || client.service.is_empty() {
                return Err("client and service names cannot be empty".into());
            }
            if let Some(addresses) = &client.addresses {
                for ip in addresses {
                    ip.parse::<IpAddr>()
                        .map_err(|_| format!("invalid client IP {ip}"))?;
                }
            }
            for entry in &client.allow {
                HostRule::parse(entry).map_err(|e| format!("invalid allow entry {entry}: {e}"))?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_timestamps_are_utc_across_days_leap_years_and_centuries() {
        for (seconds, expected) in [
            (0, "1970-01-01T00:00:00Z"),
            (86399, "1970-01-01T23:59:59Z"),
            (951782400, "2000-02-29T00:00:00Z"),
            (4107542400, "2100-03-01T00:00:00Z"),
        ] {
            assert_eq!(utc_timestamp(seconds), expected);
        }
    }

    #[test]
    fn suffixes_and_ports_cannot_widen_a_host_rule() {
        let rule = HostRule::parse("*.API.Example.COM.:0443").unwrap();
        assert_eq!(rule.normalized(), "*.api.example.com:443");
        assert!(rule.permits("one.two.API.example.com.", 443));
        for (host, port) in [
            ("api.example.com", 443),
            ("badapi.example.com", 443),
            ("a.api.example.com.attacker.example", 443),
            ("a.api.example.com", 80),
        ] {
            assert!(!rule.permits(host, port), "{host}:{port}");
        }
        let ip = HostRule::parse("[2001:0db8::1]:443").unwrap();
        assert_eq!(ip.normalized(), "[2001:db8::1]:443");
        assert!(ip.permits("2001:db8::1", 443));
        assert!(!ip.permits("2001:db8::2", 443));
    }

    #[test]
    fn invalid_authorities_never_become_rules() {
        for text in [
            "",
            "*",
            "*example.com",
            "a.*.example.com",
            "*.127.0.0.1",
            "https://example.com",
            "user@example.com",
            "example.com/path",
            "example.com?secret",
            "example.com#secret",
            "example.com:0",
            "example.com:65536",
            "example.com:+443",
            "example.com..",
            "a..example.com",
            "[127.0.0.1]",
            "2001:db8::1",
            "example.com\\attacker.example",
            "example.com\r\nHost: attacker.example",
        ] {
            assert!(HostRule::parse(text).is_err(), "{text:?}");
        }
    }
}
