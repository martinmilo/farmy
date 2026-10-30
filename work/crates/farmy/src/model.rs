//! What the containers folder defines: .env (the settings), `services/<name>.yml` (the definitions, their
//! ports included) and farmy.yml (secrets, routes, agents, knowledge). Formats in FORMATS.md.
use crate::{R, refuse};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// farmy's own state, "nothing in it is promised": `.work` in a project folder, `<state>/.work` for the
/// default home (FORMATS.md, "Where farmy keeps things"). A value of its own so that every `.work/…`
/// path reads `PathBuf::from(WORK).join(…)` or `format!("{WORK}/…")` wherever the state folder is.
#[derive(Clone, Copy)]
pub(crate) struct Work;
pub(crate) const WORK: Work = Work;

impl Work {
    pub(crate) fn path(self) -> &'static Path {
        crate::folder::work()
    }
}

impl AsRef<Path> for Work {
    fn as_ref(&self) -> &Path {
        self.path()
    }
}

impl AsRef<std::ffi::OsStr> for Work {
    fn as_ref(&self) -> &std::ffi::OsStr {
        self.path().as_os_str()
    }
}

impl From<Work> for PathBuf {
    fn from(w: Work) -> PathBuf {
        w.path().to_path_buf()
    }
}

impl std::fmt::Display for Work {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.path().display())
    }
}

/// Where farmy's own files are: the toolbox, the Dockerfiles of the helpers, the docs. The control
/// image sets FARMY_HOME; a binary run from a checkout finds them two folders up (bin/farmy).
pub(crate) fn farmy_home() -> PathBuf {
    if let Ok(h) = std::env::var("FARMY_HOME") {
        return PathBuf::from(h);
    }
    let exe = std::env::current_exe().unwrap_or_default();
    exe.parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

// ── .env ──────────────────────────────────────────────────────────────────────────────────────

pub(crate) struct Settings {
    map: BTreeMap<String, String>,
}

impl Settings {
    pub(crate) fn empty() -> Settings {
        Settings {
            map: BTreeMap::new(),
        }
    }

    /// None when there is no .env.
    pub(crate) fn load() -> Option<Settings> {
        let text = std::fs::read_to_string(".env").ok()?;
        Some(Settings::from_text(&text))
    }

    pub(crate) fn from_text(text: &str) -> Settings {
        Settings {
            map: parse_env(text),
        }
    }

    pub(crate) fn get(&self, key: &str) -> Option<&str> {
        self.map
            .get(key)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    pub(crate) fn lan_host(&self) -> String {
        self.get("LAN_HOST").unwrap_or("localhost").to_string()
    }

    /// LAN_HOST is a host and nothing more: a scheme, a port or a path in it would break every URL.
    pub(crate) fn check_lan_host(&self) -> R {
        if let Some(h) = self.get("LAN_HOST") {
            let bad = h.starts_with('.')
                || h.starts_with('-')
                || !h
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
            if bad {
                return refuse(format!(
                    "LAN_HOST={h} in .env — expected an IP address or a host name (10.0.40.101, my-host.local): no http://, no port, no path"
                ));
            }
        }
        Ok(())
    }

    /// The Git identity every container needs; the keys are named when they are missing.
    pub(crate) fn require_identity(&self) -> R {
        for k in ["GIT_USER_NAME", "GIT_USER_EMAIL"] {
            match self.get(k) {
                Some("Your Name") | Some("you@example.com") | None => {
                    return refuse(format!(
                        "{k} is not set in .env — run: farmy init  (or set it by hand)"
                    ));
                }
                _ => {}
            }
        }
        Ok(())
    }
}

/// KEY=value lines; surrounding quotes and a trailing " # comment" are dropped, as env-file readers do.
pub(crate) fn parse_env(text: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        let line = line.strip_prefix("export ").unwrap_or(line).trim_start();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let v = v.trim();
        let v = if (v.starts_with('"') && v.len() >= 2 && v[1..].contains('"'))
            || (v.starts_with('\'') && v.len() >= 2 && v[1..].contains('\''))
        {
            let q = &v[..1];
            v[1..].split(q).next().unwrap_or("").to_string()
        } else {
            v.split(" #").next().unwrap_or("").trim().to_string()
        };
        map.insert(k.trim().to_string(), v);
    }
    map
}

// ── farmy.yml ─────────────────────────────────────────────────────────────────────────────────

#[derive(Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct SecretsCfg {
    #[serde(default)]
    pub provider: Vec<String>,
    #[serde(default)]
    pub unlock: Vec<String>,
}

#[derive(Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct RouteCfg {
    pub secret: String,
    #[serde(default)]
    pub upstream: Option<String>,
    #[serde(default = "basic")]
    pub auth: String,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub git: bool,
    #[serde(default)]
    pub expose: Option<String>,
    #[serde(default)]
    pub placeholder: Option<String>,
    #[serde(default)]
    pub services: Option<Vec<String>>,
    #[serde(default)]
    pub encoding: Option<String>, // base64: the provider's value is decoded before the broker is loaded
}

fn basic() -> String {
    "basic".into()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    #[serde(default)]
    tools: Vec<String>,
    #[serde(default)]
    packages: Vec<String>,
    #[serde(default)]
    toolbox: crate::toolbox::Managed,
    #[serde(default)]
    shell: Option<String>,
    #[serde(default)]
    shared_data: Option<Vec<String>>,
    #[serde(default)]
    dotfiles: Option<crate::home::Dotfiles>,
    #[serde(default)]
    tool_catalogue: BTreeMap<String, serde_yaml::Value>,
    #[serde(default)]
    notify: Option<serde_json::Value>,

    #[serde(default, rename = "farmy")]
    _version: Option<String>,
    #[serde(default, rename = "format")]
    _format: Option<serde_yaml::Value>,
    #[serde(default)]
    secrets: SecretsCfg,
    #[serde(default)]
    keys: Option<serde_yaml::Mapping>,
    #[serde(default)]
    agents: Option<serde_yaml::Value>,
    #[serde(default)]
    knowledge: Option<bool>,
    #[serde(default)]
    egress: Option<EgressCfg>,
    #[serde(default)]
    setup_timeout: Option<String>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct EgressCfg {
    pub restrict: Option<Restriction>,
    pub allow: Option<Vec<String>>,
    pub services: Option<BTreeMap<String, AppEgressCfg>>,
    #[serde(default)]
    pub authkey: Option<String>,
    #[serde(default)]
    pub join_timeout: Option<String>,
    #[serde(default)]
    pub tailscale: Option<TailscaleCfg>,
    #[serde(default)]
    pub proxy: Option<String>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct TailscaleCfg {
    #[serde(default)]
    pub login_server: Option<String>,
}

/// The mesh egress node as configured (FORMATS.md, "Mesh egress").
#[derive(Clone)]
pub(crate) struct Egress {
    pub restrict: Restriction,
    pub allow: Vec<String>,
    pub services: BTreeMap<String, AppEgressCfg>,
    pub mesh: bool,
    pub authkey: Option<String>, // the unlocking value's name
    pub join_timeout: String,
    pub join_timeout_secs: u64,
    pub login_server: Option<String>,
    pub proxy: Option<String>, // an existing HTTP proxy, host:port: no node at all
}

#[derive(Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct AppEgressCfg {
    #[serde(default)]
    pub allow: Vec<String>,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(crate) enum Restriction {
    #[default]
    Unrestricted,
    Audit,
    Strict,
}
impl Restriction {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Unrestricted => "off",
            Self::Audit => "audit",
            Self::Strict => "enforce",
        }
    }
}
impl<'de> Deserialize<'de> for Restriction {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        match serde_yaml::Value::deserialize(d)? {
            serde_yaml::Value::Bool(true) => Ok(Self::Strict),
            serde_yaml::Value::Bool(false) => Ok(Self::Unrestricted),
            serde_yaml::Value::String(s) if s == "audit" => Ok(Self::Audit),
            serde_yaml::Value::String(s) if s == "off" || s == "unrestricted" => {
                Ok(Self::Unrestricted)
            }
            serde_yaml::Value::String(s) if s == "enforce" || s == "strict" => Ok(Self::Strict),
            _ => Err(serde::de::Error::custom(
                "restrict must be off, audit or enforce (false or true)",
            )),
        }
    }
}
#[derive(Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DefinitionEgressCfg {
    #[serde(default)]
    pub allow: Vec<String>,
    #[serde(default)]
    pub restrict: Restriction,
}

pub(crate) struct Config {
    pub tools: Vec<String>,
    pub packages: Vec<String>,
    pub toolbox: crate::toolbox::Managed,
    pub shell: String,
    pub shared_data: Vec<String>,
    pub dotfiles: Option<crate::home::Dotfiles>,
    pub tool_catalogue: BTreeMap<String, serde_yaml::Value>,
    pub notify: Option<serde_json::Value>,
    pub secrets: SecretsCfg,
    pub keys: Vec<(String, RouteCfg)>, // in the order of farmy.yml
    pub agents: Vec<crate::agents::Agent>, // the agents of farmy.yml, resolved over the catalogue
    pub catalogue: Vec<(String, crate::agents::Entry)>, // the shipped catalogue, in its order
    pub knowledge: bool,
    pub egress: Option<Egress>,
    pub setup_timeout: String, // how long a setup command may run, as written (30m)
    pub setup_timeout_secs: u64,
}

impl Config {
    pub(crate) fn load() -> R<Config> {
        let text = match std::fs::read_to_string("farmy.yml") {
            Ok(t) => t,
            Err(_) => {
                let catalogue = crate::agents::catalogue()?;
                let agents = crate::agents::resolve(None, &catalogue)?;
                return Ok(Config {
                    tools: vec![],
                    packages: vec![],
                    toolbox: Default::default(),
                    shell: "zsh".into(),
                    shared_data: vec!["nvim".into()],
                    dotfiles: None,
                    tool_catalogue: BTreeMap::new(),
                    notify: None,
                    secrets: SecretsCfg::default(),
                    keys: vec![],
                    agents,
                    catalogue,
                    knowledge: true,
                    egress: None,
                    setup_timeout: "30m".into(),
                    setup_timeout_secs: 1800,
                });
            }
        };
        let mut value: serde_yaml::Value =
            serde_yaml::from_str(&text).map_err(|e| format!("farmy.yml does not read: {e}"))?;
        if value.is_null() {
            // nothing but comments: every default
            value = serde_yaml::Value::Mapping(serde_yaml::Mapping::new());
        }
        if let Some(map) = value.as_mapping() {
            for k in map.keys() {
                let k = k.as_str().unwrap_or("?");
                if k == "claude" {
                    return refuse(
                        "farmy.yml: the key 'claude' is gone — an agent's mode is a field of its entry under agents: (agents.claude.mode: subscription | api-key | off; FORMATS.md, Agents)",
                    );
                }
                if ![
                    "secrets",
                    "keys",
                    "agents",
                    "egress",
                    "knowledge",
                    "setup_timeout",
                    "farmy",
                    "format",
                    "tools",
                    "packages",
                    "toolbox",
                    "shell",
                    "shared_data",
                    "dotfiles",
                    "tool_catalogue",
                    "notify",
                ]
                .contains(&k)
                {
                    return refuse(format!(
                        "farmy.yml: unknown key '{k}' — the keys farmy reads are listed in FORMATS.md (farmy.yml)"
                    ));
                }
            }
        }
        let file: ConfigFile = serde_yaml::from_value(value)
            .map_err(|e| format!("farmy.yml: {}", tidy(e.to_string())))?;
        let mut keys = vec![];
        for (k, v) in file.keys.unwrap_or_default() {
            let name = k.as_str().unwrap_or("?").to_string();
            let route: RouteCfg = serde_yaml::from_value(v)
                .map_err(|e| format!("farmy.yml: keys.{name}: {}", tidy(e.to_string())))?;
            keys.push((name, route));
        }
        let catalogue = crate::agents::catalogue()?;
        let agents = crate::agents::resolve(file.agents.as_ref(), &catalogue)?;
        let egress = match file.egress {
            None => None,
            Some(e) => {
                let mesh = e.proxy.is_none()
                    && (e.authkey.is_some()
                        || e.tailscale.is_some()
                        || e.join_timeout.is_some()
                        || (e.restrict.is_none() && e.allow.is_none() && e.services.is_none()));
                let allow = e.allow.clone().unwrap_or_default();
                crate::filter::expand(&allow)?;
                let services = e.services.clone().unwrap_or_default();
                for addition in services.values() {
                    crate::filter::expand(&addition.allow)?;
                }
                if e.proxy.is_some() && (e.authkey.is_some() || e.tailscale.is_some()) {
                    let other = if e.authkey.is_some() {
                        "authkey"
                    } else {
                        "tailscale"
                    };
                    return refuse(format!(
                        "farmy.yml: egress.proxy and egress.{other} do not go together — proxy is an existing HTTP proxy and runs no Tailscale node; keep one of them"
                    ));
                }
                if let Some(p) = &e.proxy {
                    let plain = farmy_gate::http_proxy(&if p.starts_with("http://") {
                        p.clone()
                    } else {
                        format!("http://{p}")
                    })
                    .is_ok();
                    if !plain {
                        return refuse(format!(
                            "farmy.yml: egress.proxy must be the proxy's host:port (proxy.example.com:3128), not '{p}'"
                        ));
                    }
                }
                if let Some(k) = &e.authkey
                    && !file.secrets.unlock.contains(k)
                {
                    return refuse(format!(
                        "farmy.yml: egress.authkey names {k}, which is not under secrets.unlock — list it there: the shim obtains it like the other unlocking values"
                    ));
                }
                let join_timeout = e.join_timeout.unwrap_or_else(|| "10m".into());
                let Some(join_timeout_secs) = duration_secs(&join_timeout) else {
                    return refuse(format!(
                        "farmy.yml: egress.join_timeout must be a number with s, m or h (10m), not '{join_timeout}'"
                    ));
                };
                let login_server = e.tailscale.and_then(|t| t.login_server);
                if let Some(u) = &login_server {
                    // written into the node's command: a URL and nothing a shell or compose would read
                    let plain = u
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || "-._~:/?#[]@+,=%".contains(c));
                    if !(u.starts_with("https://") || u.starts_with("http://")) || !plain {
                        return refuse(format!(
                            "farmy.yml: egress.tailscale.login_server must be the control server's URL (https://mesh.example.com), not '{u}'"
                        ));
                    }
                }
                Some(Egress {
                    authkey: e.authkey,
                    join_timeout,
                    join_timeout_secs,
                    login_server,
                    proxy: e.proxy,
                    restrict: e.restrict.unwrap_or_default(),
                    allow,
                    services,
                    mesh,
                })
            }
        };
        let setup_timeout = file.setup_timeout.unwrap_or_else(|| "30m".into());
        let Some(setup_timeout_secs) = duration_secs(&setup_timeout) else {
            return refuse(format!(
                "farmy.yml: setup_timeout must be a number with s, m or h (30m), not '{setup_timeout}'"
            ));
        };
        let cfg = Config {
            tools: file.tools,
            packages: file.packages,
            toolbox: file.toolbox,
            shell: file.shell.unwrap_or_else(|| "zsh".into()),
            shared_data: file.shared_data.unwrap_or_else(|| vec!["nvim".into()]),
            dotfiles: file.dotfiles,
            tool_catalogue: file.tool_catalogue,
            notify: file.notify,
            secrets: file.secrets,
            keys,
            agents,
            catalogue,
            knowledge: file.knowledge.unwrap_or(true),
            egress,
            setup_timeout,
            setup_timeout_secs,
        };
        if let Some(notify) = &cfg.notify {
            let Some(m) = notify.as_object() else {
                return refuse("farmy.yml: notify must be a mapping");
            };
            if let Some(k) = m
                .keys()
                .find(|k| !["format", "url", "url_secret", "token_secret"].contains(&k.as_str()))
            {
                return refuse(format!("farmy.yml: notify unknown field {k}"));
            }
            if notify["url"].is_string() == notify["url_secret"].is_string() {
                return refuse("farmy.yml: notify needs exactly one of url or url_secret");
            }
            if !matches!(
                notify["format"].as_str().unwrap_or("json"),
                "json" | "ntfy" | "slack"
            ) {
                return refuse("farmy.yml: notify format must be json, ntfy or slack");
            }
        }
        crate::toolbox::validate_config(&cfg)?;

        Ok(cfg)
    }

    pub(crate) fn agent(&self, name: &str) -> Option<&crate::agents::Agent> {
        self.agents.iter().find(|a| a.name == name)
    }
}

/// `2s`, `30m`, `1h` (or a bare number of seconds) as seconds; None when it is none of those.
pub(crate) fn duration_secs(text: &str) -> Option<u64> {
    let t = text.trim();
    let (num, unit) = match t.chars().last() {
        Some(c) if c.is_ascii_alphabetic() => (&t[..t.len() - 1], c),
        _ => (t, 's'),
    };
    let n: u64 = num.parse().ok()?;
    match unit {
        's' => Some(n),
        'm' => Some(n * 60),
        'h' => Some(n * 3600),
        _ => None,
    }
}

/// serde's "unknown field `x`, expected one of ..." in farmy's words.
fn tidy(msg: String) -> String {
    if let Some(rest) = msg.strip_prefix("unknown field `")
        && let Some((field, _)) = rest.split_once('`')
    {
        return format!("unknown key '{field}' — the keys farmy reads are listed in FORMATS.md");
    }
    msg
}

// ── ports: in the definition ──────────────────────────────────────────────────────────────────

/// One `host:container` pair of a definition's `ports:`.
#[derive(Clone, Debug)]
pub(crate) struct PortPair {
    pub host: u32,
    pub container: String,
}

/// A service owns the hundred its host ports lie in: 3100 → 3100-3199.
pub(crate) fn block_of(host_port: u32) -> (u32, u32) {
    let lo = host_port / 100 * 100;
    (lo, lo + 99)
}

pub(crate) fn block_text(block: (u32, u32)) -> String {
    format!("{}-{}", block.0, block.1)
}

/// A clone URL as git takes it: a scheme (https://, ssh://, file://, git://) or the scp form user@host:path.
pub(crate) fn is_clone_url(s: &str) -> bool {
    if s.contains("://") {
        return true;
    }
    match s.split_once('@') {
        Some((_, rest)) => rest.split('/').next().unwrap_or("").contains(':'),
        None => false,
    }
}

// ── services/<name>.yml ───────────────────────────────────────────────────────────────────────

#[derive(Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct Definition {
    #[serde(default)]
    pub pipelines: BTreeMap<String, PipelineCfg>,
    #[serde(default)]
    pub forge: Option<String>,
    #[serde(default)]
    pub repo_web_url: Option<String>,
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub packages: Vec<String>,
    #[serde(default, rename = "format")]
    pub _format: Option<serde_yaml::Value>,
    #[serde(default)]
    pub restrict: Restriction,
    #[serde(default)]
    pub egress: DefinitionEgressCfg,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub dockerfile: Option<String>,
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default)]
    pub build_files: Vec<String>,
    #[serde(default)]
    pub ports: Vec<serde_yaml::Value>,
    #[serde(default)]
    pub workdir: Option<String>,
    #[serde(default)]
    pub factory: Option<FactoryCfg>,
    #[serde(default)]
    pub shared_logins: Option<bool>, // false: the agents' logins on the service's own volume, no farmy-shared
    #[serde(default)]
    pub mounts: BTreeMap<String, String>,
    #[serde(default)]
    pub start_after: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, serde_yaml::Value>,
    #[serde(default)]
    pub agents: Option<BTreeMap<String, String>>, // a mode per agent for this service
    #[serde(default)]
    pub commands: BTreeMap<String, String>,
    #[serde(default)]
    pub keys: Option<Vec<String>>,
    #[serde(default)]
    pub compose: Option<serde_yaml::Mapping>,
    #[serde(default)]
    pub volumes: Option<serde_yaml::Value>,
    #[serde(default)]
    pub networks: Option<serde_yaml::Value>,
}

/// `factory:` in a definition (FORMATS.md, "The factory"); checked by `farmy factory start`.
#[derive(Default, Clone)]
pub(crate) struct FactoryCfg {
    pub concurrency: usize,
    pub profiles: BTreeMap<String, FactoryProfile>,
}

impl<'de> Deserialize<'de> for FactoryCfg {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let mut value = serde_yaml::Value::deserialize(deserializer)?;
        let concurrency = value
            .as_mapping_mut()
            .and_then(|m| m.remove(serde_yaml::Value::String("concurrency".into())))
            .map(|v| {
                v.as_u64()
                    .filter(|n| *n > 0)
                    .and_then(|n| usize::try_from(n).ok())
                    .ok_or_else(|| {
                        serde::de::Error::custom("factory.concurrency must be a positive integer")
                    })
            })
            .transpose()?
            .unwrap_or(2);
        let legacy = value
            .as_mapping()
            .map(|m| {
                m.is_empty()
                    || m.values().any(|v| !v.is_mapping())
                    || m.get(serde_yaml::Value::String("gate".into()))
                        .and_then(|v| v.as_mapping())
                        .map(|g| {
                            g.keys()
                                .any(|k| matches!(k.as_str(), Some("network" | "kind")))
                        })
                        .unwrap_or(false)
            })
            .unwrap_or(true);
        let profiles = if legacy {
            let profile = serde_yaml::from_value(value).map_err(serde::de::Error::custom)?;
            BTreeMap::from([("default".into(), profile)])
        } else {
            serde_yaml::from_value(value).map_err(serde::de::Error::custom)?
        };
        Ok(Self {
            profiles,
            concurrency,
        })
    }
}

#[derive(Deserialize, serde::Serialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct FactoryProfile {
    #[serde(default)]
    pub gate_setup: Option<String>,
    #[serde(default)]
    pub base: Option<String>,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub writes: Option<Vec<String>>,
    #[serde(default)]
    pub protects: Vec<String>,
    #[serde(default)]
    pub hidden: Vec<String>,
    #[serde(default)]
    pub test: Option<String>,
    #[serde(default)]
    pub check: Option<String>,
    #[serde(default)]
    pub review: Option<bool>,
    #[serde(default)]
    pub max_iterations: Option<u32>,
    #[serde(default)]
    pub iteration_timeout: Option<String>,
    #[serde(default)]
    pub gate: Option<GateCfg>,
    /// A name under `commands:` the agent may run on demand with `farmy-verify` (FORMATS.md, "On-demand
    /// verify"); left out of a saved profile without it, so older runs' records stay as they were.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verify: Option<String>,
}

/// `factory.gate`: `network: none` runs the gate without the service's sidecars, without any network.
#[derive(Deserialize, serde::Serialize, Clone)]
#[serde(untagged)]
pub(crate) enum GateCfg {
    Kind(String),
    Options(GateOptions),
}

#[derive(Deserialize, serde::Serialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct GateOptions {
    pub red_pattern: Option<String>,
    pub red_exit_codes: Option<Vec<i32>>,
    pub health_timeout: Option<String>,
    pub kind: Option<String>,
    pub network: Option<String>,
}

#[derive(Deserialize, serde::Serialize, Clone, Default)]
#[serde(deny_unknown_fields)]
pub(crate) struct PipelineCfg {
    pub steps: Vec<String>,
    pub on_question: Option<String>,
    pub handoff_limit: Option<u32>,
    #[serde(default)]
    pub review_answers: bool,
}

impl GateCfg {
    pub(crate) fn options(&self) -> GateOptions {
        match self {
            Self::Kind(kind) => GateOptions {
                kind: Some(kind.clone()),
                ..Default::default()
            },
            Self::Options(o) => o.clone(),
        }
    }
    pub(crate) fn kind(&self) -> &str {
        match self {
            Self::Kind(kind) => kind,
            Self::Options(opts) => opts.kind.as_deref().unwrap_or("green"),
        }
    }
    pub(crate) fn network(&self) -> Option<&str> {
        match self {
            Self::Kind(_) => None,
            Self::Options(opts) => opts.network.as_deref(),
        }
    }
}

pub(crate) fn definition_path(name: &str) -> String {
    format!("services/{name}.yml")
}

impl Definition {
    pub(crate) fn load(name: &str) -> R<Definition> {
        Self::load_from(Path::new(&definition_path(name)), name)
    }

    pub(crate) fn load_from(path: &Path, name: &str) -> R<Definition> {
        let text = std::fs::read_to_string(path).map_err(|_| {
            format!(
                "no definition for '{name}' (expected {} — README → Adding a service)",
                definition_path(name)
            )
        })?;
        crate::version::check_document(&text, &path.display().to_string(), false)?;
        serde_yaml::from_str(&text)
            .map_err(|e| format!("{}: {}", path.display(), tidy(e.to_string())).into())
    }

    /// `repo: none`: a workbench — an empty /workspace, nothing cloned.
    pub(crate) fn is_workbench(&self) -> bool {
        self.repo.as_deref().map(str::trim) == Some("none")
    }

    /// The `ports:` pairs as written; a malformed entry names the file.
    pub(crate) fn port_pairs(&self, name: &str) -> R<Vec<PortPair>> {
        let path = definition_path(name);
        let mut out = vec![];
        for v in &self.ports {
            let text = scalar(v);
            let pair = text.rsplit_once(':').and_then(|(h, c)| {
                h.parse::<u32>().ok().map(|h| PortPair {
                    host: h,
                    container: c.to_string(),
                })
            });
            match pair {
                Some(p)
                    if !p.container.is_empty()
                        && p.container.chars().all(|c| c.is_ascii_digit()) =>
                {
                    out.push(p)
                }
                _ => {
                    return refuse(format!(
                        "{path}: ports: takes host:container pairs, such as [\"3100:3000\"] — not '{text}'"
                    ));
                }
            }
        }
        Ok(out)
    }

    /// The block the service owns: the hundred of its first host port; None without ports:.
    pub(crate) fn block(&self) -> Option<(u32, u32)> {
        self.first_host_port().map(block_of)
    }

    pub(crate) fn first_host_port(&self) -> Option<u32> {
        self.ports
            .first()
            .map(scalar)
            .and_then(|t| t.rsplit_once(':').and_then(|(h, _)| h.parse().ok()))
    }

    /// What a definition must have before its containers are made; every message names the file.
    pub(crate) fn check(&self, name: &str) -> R {
        let path = definition_path(name);
        match self.repo.as_deref().map(str::trim) {
            None | Some("") => {
                return refuse(format!(
                    "{path}: no repo: — the clone URL of the repository (https://github.com/<owner>/<name>.git), or none for a workbench"
                ));
            }
            Some("none") => {}
            Some(r) if !is_clone_url(r) => {
                return refuse(format!(
                    "{path}: repo: {r} is not a clone URL — write the full one, such as https://github.com/{r}.git, ssh://git@github.com/{r}.git or git@github.com:{r}.git"
                ));
            }
            _ => {}
        }
        let pairs = self.port_pairs(name)?;
        if let Some(first) = pairs.first() {
            let block = block_of(first.host);
            for p in &pairs {
                if p.host < block.0 || p.host > block.1 {
                    return refuse(format!(
                        "{path}: ports: the host port {} is outside the service's block {} (the hundred its first host port lies in) — keep a service's host ports in one block",
                        p.host,
                        block_text(block)
                    ));
                }
            }
        }
        if self.image.is_none() && self.dockerfile.is_none() {
            return refuse(format!(
                "{path}: neither image: nor dockerfile: — name the image the app container is built on (an official Debian image such as ruby:3.4-slim), or a Dockerfile of the repository with a stage written for development (a generated production Dockerfile is the wrong base)"
            ));
        }
        if self.is_workbench() && self.dockerfile.is_some() {
            return refuse(format!(
                "{path}: repo: none with dockerfile: — a workbench has no repository to build from; name an image:"
            ));
        }
        for (mount, target) in &self.mounts {
            if mount == "src" {
                return refuse(format!(
                    "{path}: the mount 'src' — /workspace is the checkout's volume {name}-src already; rename the mount"
                ));
            }
            if ["agents", "farmy-shared", "keys-agent"].contains(&mount.as_str()) {
                return refuse(format!(
                    "{path}: the mount '{mount}' takes a name farmy uses itself — rename it"
                ));
            }
            if !target.starts_with('/') {
                return refuse(format!(
                    "{path}: the mount '{mount}' must be an absolute path in the app container, not '{target}'"
                ));
            }
        }
        Ok(())
    }

    pub(crate) fn env_strings(&self) -> Vec<(String, String)> {
        self.env
            .iter()
            .map(|(k, v)| (k.clone(), scalar(v)))
            .collect()
    }

    pub(crate) fn workdir_clean(&self) -> Option<String> {
        self.workdir
            .as_ref()
            .map(|w| w.trim_end_matches('/').to_string())
            .filter(|w| !w.is_empty())
    }

    /// `/workspace`, or `/workspace/<workdir>`
    pub(crate) fn app_dir(&self) -> String {
        match self.workdir_clean() {
            Some(w) => format!("/workspace/{w}"),
            None => "/workspace".into(),
        }
    }
}

pub(crate) fn scalar(v: &serde_yaml::Value) -> String {
    match v {
        serde_yaml::Value::String(s) => s.clone(),
        serde_yaml::Value::Null => String::new(),
        serde_yaml::Value::Bool(b) => b.to_string(),
        serde_yaml::Value::Number(n) => n.to_string(),
        other => serde_yaml::to_string(other)
            .unwrap_or_default()
            .trim()
            .to_string(),
    }
}

/// Services with a definition file, in name order.
pub(crate) fn definition_services() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir("services")
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter_map(|e| e.file_name().to_str().map(String::from))
                .filter_map(|f| f.strip_suffix(".yml").map(String::from))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// A service is known by its definition file.
pub(crate) fn known_services() -> Vec<String> {
    definition_services()
}

/// The definition a running service was made from (the copy in .work), else the current one.
pub(crate) fn booted_definition(name: &str) -> R<Definition> {
    let copy = PathBuf::from(WORK).join(name).join("definition.yml");
    if copy.is_file() {
        Definition::load_from(&copy, name)
    } else {
        Definition::load(name)
    }
}

/// Standard base64 (padding optional, whitespace ignored) to bytes; None for anything else.
pub(crate) fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut acc: u32 = 0;
    let mut bits = 0;
    for c in text.bytes() {
        let v = u32::from(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => break,
            b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => return None,
        });
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            #[expect(
                clippy::cast_possible_truncation,
                reason = "acc holds fewer than 16 bits here; its top eight are the decoded byte"
            )]
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// A value that is not an OpenSSH/PEM key itself but decodes from base64 to one.
pub(crate) fn looks_like_base64_key(value: &str) -> bool {
    !value.contains("-----BEGIN")
        && base64_decode(value.trim())
            .map(|b| b.starts_with(b"-----BEGIN"))
            .unwrap_or(false)
}

/// `uid:gid` of the user farmy runs as. On Linux the shim runs farmy in the control container as the user
/// who runs the shim, so that what farmy writes is that user's from the moment it is written (nothing is
/// chowned afterwards); containers farmy runs that write into the folder or the state folder run as it too.
pub(crate) fn running_as() -> String {
    format!(
        "{}:{}",
        rustix::process::getuid().as_raw(),
        rustix::process::getgid().as_raw()
    )
}

#[cfg(test)]
mod factory_profile_tests {
    use super::*;

    #[test]
    fn named_profiles_can_use_legacy_field_names_and_retain_their_own_gate() {
        let definition: Definition = serde_yaml::from_str("factory:\n  base:\n    base: trunk\n    agent: example\n    gate: {kind: red_first, network: none}\n  gate:\n    base: trunk\n    agent: example\n    gate: release\n").unwrap();
        let profiles = definition.factory.unwrap().profiles;
        assert_eq!(profiles.len(), 2);
        assert_eq!(profiles["base"].gate.as_ref().unwrap().kind(), "red_first");
        assert_eq!(
            profiles["base"].gate.as_ref().unwrap().network(),
            Some("none")
        );
        assert_eq!(profiles["gate"].gate.as_ref().unwrap().kind(), "release");
    }

    #[test]
    fn legacy_network_mapping_is_a_default_green_profile_and_profile_typos_are_rejected() {
        let legacy: Definition =
            serde_yaml::from_str("factory:\n  base: trunk\n  gate: {network: none}\n").unwrap();
        let profiles = legacy.factory.unwrap().profiles;
        assert_eq!(profiles["default"].gate.as_ref().unwrap().kind(), "green");
        assert_eq!(
            profiles["default"].gate.as_ref().unwrap().network(),
            Some("none")
        );
        assert!(
            serde_yaml::from_str::<Definition>("factory:\n  example:\n    bas: trunk\n").is_err()
        );
    }
}
