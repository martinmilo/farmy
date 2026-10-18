//! Routes (farmy.yml `keys:`), the provider that yields their secrets, and loading the brokers. The
//! secrets are held in memory for one command and handed to a broker on the stdin of `docker exec -i`;
//! they are never on a command line, in a file, in a container's configuration or in the output.
use crate::model::{Config, Settings, WORK, farmy_home};
use crate::{R, refuse, warn};
use std::collections::BTreeMap;
use std::io::{IsTerminal, Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub(crate) struct Route {
    pub name: String,
    pub secret: String,
    pub upstream: String,         // for the broker: "-" for an SSH route
    pub host: String,             // the host the route applies to (git routes), from upstream
    pub ssh_user: String,         // an SSH route: the user before @ in upstream, git by default
    pub ssh_port: Option<String>, // an SSH route: the port after the host in upstream, when it names one
    pub auth: String,
    pub who: String, // the user (basic), the header name (header), or "-"
    pub git: bool,
    pub expose: Option<String>,
    pub placeholder: Option<String>,
    pub services: Option<Vec<String>>,
    pub encoding: Option<String>,
}

impl Route {
    /// An SSH route's `ssh://<user>@<host>[:<port>]`, with the user and the port its upstream names.
    pub(crate) fn ssh_base(&self) -> String {
        format!(
            "ssh://{}@{}{}",
            self.ssh_user,
            self.host,
            self.ssh_port
                .as_ref()
                .map(|p| format!(":{p}"))
                .unwrap_or_default()
        )
    }

    /// The broker's contract: `<upstream> <auth> <user|header|-> <secret name>`, then `public` for a git
    /// route over http(s): without its secret the broker forwards without credentials (public repositories).
    pub(crate) fn spec(&self) -> String {
        let public = if self.git && !self.is_ssh() {
            " public"
        } else {
            ""
        };
        format!(
            "{} {} {} {}{public}",
            self.upstream, self.auth, self.who, self.secret
        )
    }

    pub(crate) fn is_ssh(&self) -> bool {
        self.auth == "ssh"
    }

    pub(crate) fn granted_to(&self, svc: &str) -> bool {
        self.services
            .as_ref()
            .map(|l| l.iter().any(|x| x == svc))
            .unwrap_or(true)
    }
}

/// The routes of farmy.yml, checked and with their placeholders filled from .env.
pub(crate) fn routes(cfg: &Config, settings: &Settings) -> R<Vec<Route>> {
    let mut out = vec![];
    for (name, r) in &cfg.keys {
        let who = match r.auth.as_str() {
            "basic" => r.user.clone().unwrap_or_else(|| "x-access-token".into()),
            "bearer" | "ssh" => "-".into(),
            "header" => r.header.clone().ok_or_else(|| {
                format!("farmy.yml: route '{name}' has auth: header and no header:")
            })?,
            other => {
                return refuse(format!(
                    "farmy.yml: route '{name}': auth must be basic, bearer, header or ssh, not '{other}'"
                ));
            }
        };
        let Some(given) = &r.upstream else {
            return refuse(format!(
                "farmy.yml: route '{name}' has no upstream: — the host it applies to (https://github.com, or ssh://git@github.com for an SSH route)"
            ));
        };
        let given = expand(given, settings).trim_end_matches('/').to_string();
        if given.is_empty() {
            return refuse(format!(
                "farmy.yml: route '{name}': upstream is empty — write the host, such as https://github.com"
            ));
        }
        let host = host_of(&given);
        let (upstream, ssh_user, ssh_port) = if r.auth == "ssh" {
            let authority = given
                .split("://")
                .nth(1)
                .unwrap_or(&given)
                .split('/')
                .next()
                .unwrap_or("");
            let user = authority
                .split_once('@')
                .map(|(u, _)| u.to_string())
                .unwrap_or_else(|| "git".into());
            let port = authority
                .rsplit('@')
                .next()
                .unwrap_or("")
                .split_once(':')
                .map(|(_, p)| p.to_string())
                .filter(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()));
            ("-".to_string(), user, port)
        } else {
            (given, "git".to_string(), None)
        };
        out.push(Route {
            name: name.clone(),
            secret: r.secret.clone(),
            upstream,
            host,
            ssh_user,
            ssh_port,
            auth: r.auth.clone(),
            who,
            git: r.git,
            expose: r.expose.clone(),
            placeholder: r.placeholder.clone(),
            services: r.services.clone(),
            encoding: r.encoding.clone(),
        });
    }
    Ok(out)
}

/// `{KEY}`: a .env key's value.
pub(crate) fn expand(v: &str, settings: &Settings) -> String {
    let mut out = v.to_string();
    while let Some(start) = out.find('{') {
        let Some(len) = out[start..].find('}') else {
            break;
        };
        let key = out[start + 1..start + len].to_string();
        if key.is_empty()
            || !key
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
        {
            break;
        }
        let val = settings.get(&key).unwrap_or("").to_string();
        out.replace_range(start..start + len + 1, &val);
    }
    out
}

pub(crate) fn granted<'a>(routes: &'a [Route], svc: &str) -> Vec<&'a Route> {
    routes.iter().filter(|r| r.granted_to(svc)).collect()
}

/// The git route for a host: the one whose upstream has that host.
pub(crate) fn git_route_for<'a>(routes: &'a [Route], host: &str) -> Option<&'a Route> {
    routes.iter().find(|r| r.git && r.host == host)
}

/// The host of a URL (`scheme://[user@]host[:port]/…` or `user@host:path`), lower-cased.
pub(crate) fn host_of(url: &str) -> String {
    let rest = match url.split_once("://") {
        Some((_, r)) => r,
        None => match url.split_once('@') {
            Some((_, r)) => return r.split(':').next().unwrap_or("").to_lowercase(),
            None => url,
        },
    };
    let authority = rest.split('/').next().unwrap_or("");
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    authority.split(':').next().unwrap_or("").to_lowercase()
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum State {
    Loaded,
    Missing,
    Locked,
    ProviderFailed,
    Undecodable,
    LooksBase64,
}

impl State {
    pub(crate) fn word(self) -> &'static str {
        match self {
            State::Loaded => "loaded",
            State::Missing => "missing",
            State::Locked => "locked",
            State::ProviderFailed => "provider failed",
            State::Undecodable => {
                "rejected (encoding: base64 on the route, and the secret does not decode)"
            }
            State::LooksBase64 => {
                "rejected (it looks base64-encoded: encoding: base64 on the route)"
            }
        }
    }
}

pub(crate) struct Resolved {
    pub values: BTreeMap<String, String>,
    pub states: BTreeMap<String, State>,
}

impl Resolved {
    pub(crate) fn has(&self, secret: &str) -> bool {
        self.values.contains_key(secret)
    }
}

/// The names the host is asked for (`farmy unlock-names`): those under `secrets.unlock`, then, without a
/// provider, the secret of every route, since the host is then where the routes' secrets come from.
pub(crate) fn host_names(cfg: &Config) -> Vec<String> {
    let mut names: Vec<String> = cfg.secrets.unlock.clone();
    if cfg.secrets.provider.is_empty() {
        names.extend(
            cfg.keys
                .iter()
                .map(|(_, r)| r.secret.clone())
                .filter(|s| !s.is_empty()),
        );
        if let Some(notify) = &cfg.notify {
            for field in ["url_secret", "token_secret"] {
                if let Some(name) = notify[field].as_str() {
                    names.push(name.into());
                }
            }
        }
    }
    let mut seen = std::collections::BTreeSet::new();
    names.retain(|n| seen.insert(n.clone()));
    names
}

/// The values the host gives (`host_names`): NAME:base64=… or NAME=value lines on farmy's stdin, else a
/// hidden prompt on a terminal. With a provider, None when an unlocking value is missing (the routes are
/// then locked and the provider is not run); without one, whatever was given (a route whose secret is
/// not among it is locked).
pub(crate) fn unlock(cfg: &Config) -> Option<BTreeMap<String, String>> {
    let names = host_names(cfg);
    let mut values = BTreeMap::new();
    if names.is_empty() {
        return Some(values);
    }
    let stdin = std::io::stdin();
    if !stdin.is_terminal() {
        let mut text = String::new();
        #[expect(
            clippy::let_underscore_must_use,
            reason = "an unreadable stdin leaves no values, and the routes then show as missing"
        )]
        let _ = stdin.lock().read_to_string(&mut text);
        // NAME:base64=<value> (what the shim writes: multi-line values arrive byte for byte), or NAME=value
        let mut plain = String::new();
        for line in text.lines() {
            match line.split_once(":base64=") {
                Some((k, b)) if !k.contains('=') && names.iter().any(|u| u == k) => {
                    if let Some(v) =
                        crate::model::base64_decode(b).and_then(|b| String::from_utf8(b).ok())
                    {
                        values.insert(k.to_string(), v);
                    }
                }
                _ => {
                    plain.push_str(line);
                    plain.push('\n');
                }
            }
        }
        for (k, v) in crate::model::parse_env(&plain) {
            if names.contains(&k) && !values.contains_key(&k) {
                values.insert(k, v);
            }
        }
    }
    // what the control container holds fills in what stdin did not bring
    let held = crate::hold::get();
    let mut given: BTreeMap<String, String> = values.clone();
    for name in &names {
        if let (false, Some(v)) = (values.contains_key(name), held.get(name)) {
            values.insert(name.clone(), v.clone());
        }
    }
    if stdin.is_terminal() {
        for name in &names {
            if values.contains_key(name) {
                continue;
            }
            if let Ok(v) =
                rpassword::prompt_password(format!("{name} (not shown; empty: leave it out): "))
                && !v.is_empty()
            {
                values.insert(name.clone(), v.clone());
                given.insert(name.clone(), v);
            }
        }
    }
    // what the host gave now is held from now on (stdin wins over what was held)
    given.retain(|k, v| held.get(k) != Some(v));
    crate::hold::put(&given);
    if !cfg.secrets.provider.is_empty()
        && cfg.secrets.unlock.iter().any(|n| !values.contains_key(n))
    {
        return None;
    }
    Some(values)
}

/// A route's `encoding: base64` decodes its value before the broker sees it; an SSH route's value that
/// is not a key but decodes to one is held back (the agent would refuse it) and named.
fn decode_values(
    routes: &[&Route],
    values: &mut BTreeMap<String, String>,
    states: &mut BTreeMap<String, State>,
) {
    for r in routes {
        let Some(v) = values.get(&r.secret).cloned() else {
            continue;
        };
        if r.encoding.as_deref() == Some("base64") {
            match crate::model::base64_decode(&v).and_then(|b| String::from_utf8(b).ok()) {
                Some(decoded) => {
                    values.insert(r.secret.clone(), decoded);
                }
                None => {
                    values.remove(&r.secret);
                    states.insert(r.name.clone(), State::Undecodable);
                    warn(format!(
                        "the route {}: encoding: base64, and the secret {} does not decode — it is not loaded",
                        r.name, r.secret
                    ));
                }
            }
        } else if r.is_ssh() && crate::model::looks_like_base64_key(&v) {
            values.remove(&r.secret);
            states.insert(r.name.clone(), State::LooksBase64);
            warn(format!(
                "the route {}: the secret {} looks base64-encoded (it decodes to a key) — encoding: base64 on the route; it is not loaded",
                r.name, r.secret
            ));
        }
    }
}

/// Asks the provider for the secrets the routes need. The provider's stdout is read as data and never
/// shown; a failure names the provider, not its output.
/// `extra`: secrets that are no route's (Claude's token in subscription mode), asked for alongside.
pub(crate) fn resolve(
    cfg: &Config,
    routes: &[&Route],
    unlock: Option<&BTreeMap<String, String>>,
    extra: &[String],
) -> Resolved {
    let mut states = BTreeMap::new();
    let mut values = BTreeMap::new();
    let names: Vec<String> = {
        let mut v: Vec<String> = routes.iter().map(|r| r.secret.clone()).collect();
        v.extend(extra.iter().cloned());
        v.dedup();
        v
    };
    if cfg.secrets.provider.is_empty() {
        // no provider: the host gave the routes' secrets with the unlocking values
        let given = unlock.cloned().unwrap_or_default();
        for r in routes {
            match given.get(&r.secret) {
                Some(v) => {
                    values.insert(r.secret.clone(), v.clone());
                    states.insert(r.name.clone(), State::Loaded);
                }
                None => {
                    states.insert(r.name.clone(), State::Locked);
                }
            }
        }
        decode_values(routes, &mut values, &mut states);
        return Resolved { values, states };
    }
    let Some(unlock) = unlock else {
        for r in routes {
            states.insert(r.name.clone(), State::Locked);
        }
        return Resolved { values, states };
    };
    if names.is_empty() {
        return Resolved { values, states };
    }
    let request = serde_json::json!({ "version": 1, "secrets": names }).to_string();
    match run_provider(
        &cfg.secrets.provider,
        unlock,
        &request,
        &crate::egress::proxy_env(cfg, &[]),
    ) {
        Ok(answer) => {
            let parsed: Result<serde_json::Value, _> = serde_json::from_str(&answer);
            match parsed {
                Ok(v) if v.get("error").map(|e| !e.is_null()).unwrap_or(false) => {
                    warn(format!(
                        "the secrets provider {} reported an error — run it yourself to see why",
                        cfg.secrets.provider[0]
                    ));
                    for r in routes {
                        states.insert(r.name.clone(), State::ProviderFailed);
                    }
                }
                Ok(v) => {
                    if let Some(map) = v.get("secrets").and_then(|m| m.as_object()) {
                        for (k, val) in map {
                            let wanted = names
                                .iter()
                                .any(|n| k == n || k.starts_with(&format!("{n}_")));
                            if let (true, Some(sv)) = (wanted, val.as_str()) {
                                values.insert(k.clone(), sv.to_string());
                            }
                        }
                    }
                    for r in routes {
                        states.insert(
                            r.name.clone(),
                            if values.contains_key(&r.secret) {
                                State::Loaded
                            } else {
                                State::Missing
                            },
                        );
                    }
                    decode_values(routes, &mut values, &mut states);
                }
                Err(_) => {
                    warn(format!(
                        "the secrets provider {} did not answer in the protocol (FORMATS.md) — run it yourself to see what it prints",
                        cfg.secrets.provider[0]
                    ));
                    for r in routes {
                        states.insert(r.name.clone(), State::ProviderFailed);
                    }
                }
            }
        }
        Err(why) => {
            warn(format!(
                "the secrets provider {} {why} — run it yourself to see why; its routes are off",
                cfg.secrets.provider[0]
            ));
            for r in routes {
                states.insert(r.name.clone(), State::ProviderFailed);
            }
        }
    }
    Resolved { values, states }
}

const PROVIDER_TIMEOUT: Duration = Duration::from_secs(30);
const PROVIDER_LIMIT: usize = 1_000_000;

/// A provider with a path in it is looked for in the containers folder first, then in farmy's own
/// folder (where `providers/env` and `providers/infisical` ship); a bare name is found on the PATH.
fn resolve_provider(program: &str) -> String {
    if !program.contains('/') {
        return program.to_string();
    }
    if let Ok(p) = std::fs::canonicalize(program) {
        return p.display().to_string();
    }
    let shipped = farmy_home().join(program);
    if shipped.is_file() {
        return shipped.display().to_string();
    }
    program.to_string()
}

fn run_provider(
    provider: &[String],
    unlock: &BTreeMap<String, String>,
    request: &str,
    extra_env: &[(String, String)],
) -> Result<String, String> {
    let program = resolve_provider(&provider[0]);
    let mut child = Command::new(&program)
        .args(&provider[1..])
        .envs(unlock)
        .envs(extra_env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("could not be run ({e})"))?;
    if let Some(mut stdin) = child.stdin.take() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the provider's exit status and output, checked below, say whether it got the request"
        )]
        let _ = stdin.write_all(request.as_bytes());
    }
    let mut stdout = child.stdout.take().ok_or("has no stdout")?;
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        #[expect(
            clippy::let_underscore_must_use,
            reason = "a failed read leaves what arrived, which is checked below like any answer"
        )]
        let _ = stdout
            .by_ref()
            .take(PROVIDER_LIMIT as u64 + 1)
            .read_to_end(&mut buf);
        buf
    });
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let buf = reader.join().unwrap_or_default();
                if buf.len() > PROVIDER_LIMIT {
                    return Err("printed more than 1 MB".into());
                }
                if !status.success() {
                    return Err(format!(
                        "failed (exit {})",
                        status
                            .code()
                            .map(|c| c.to_string())
                            .unwrap_or_else(|| "by signal".into())
                    ));
                }
                return Ok(String::from_utf8_lossy(&buf).to_string());
            }
            Ok(None) if started.elapsed() > PROVIDER_TIMEOUT => {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the provider is ended for taking too long; the timeout is the error reported"
                )]
                let _ = child.kill();
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the provider is ended for taking too long; the timeout is the error reported"
                )]
                let _ = child.wait();
                return Err("took longer than 30 s".into());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(30)),
            Err(e) => return Err(format!("could not be waited for ({e})")),
        }
    }
}

/// Loads a service's broker: the secrets of its granted routes, as JSON on the stdin of
/// `docker exec -i <svc>-keys farmy-keys load`.
pub(crate) fn load_broker(svc: &str, routes: &[&Route], resolved: &Resolved) -> bool {
    let mut payload = serde_json::Map::new();
    for r in routes {
        for (k, v) in &resolved.values {
            if k == &r.secret || k.starts_with(&format!("{}_", r.secret)) {
                payload.insert(k.clone(), serde_json::Value::String(v.clone()));
            }
        }
    }
    let text = serde_json::json!({ "version": 1, "secrets": payload }).to_string();
    crate::docker::exec_stdin(&format!("{svc}-keys"), &["farmy-keys", "load"], &text)
}

/// The names of the secrets a running broker holds (`farmy-keys loaded`); None when it cannot say.
pub(crate) fn broker_holds(svc: &str) -> Option<Vec<String>> {
    crate::docker::out(&["exec", &format!("{svc}-keys"), "farmy-keys", "loaded"])
        .ok()
        .map(|o| {
            o.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
}

/// The states of the routes after the last resolution (never a value), for `farmy keys`.
pub(crate) fn save_states(states: &BTreeMap<String, State>) {
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the states file is informational for `farmy keys`; it is written again at the next resolution"
    )]
    let _ = std::fs::create_dir_all(WORK);
    let map: serde_json::Map<String, serde_json::Value> = states
        .iter()
        .map(|(k, v)| (k.clone(), serde_json::Value::String(v.word().into())))
        .collect();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the states file is informational for `farmy keys`; it is written again at the next resolution"
    )]
    let _ = std::fs::write(
        format!("{WORK}/keys.json"),
        serde_json::Value::Object(map).to_string(),
    );
}

pub(crate) fn saved_states() -> BTreeMap<String, String> {
    std::fs::read_to_string(format!("{WORK}/keys.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&t).ok())
        .map(|m| {
            m.into_iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// `farmy keys --why`: the provider once, as a load would ask it, with its stderr kept. Every unlocking
/// value and every secret value it answered is replaced by `[redacted]` before anything is printed.
pub(crate) fn why(
    cfg: &Config,
    routes: &[&Route],
    unlock: Option<&BTreeMap<String, String>>,
) -> Vec<String> {
    let mut out = vec![];
    if cfg.secrets.provider.is_empty() {
        let given = unlock.cloned().unwrap_or_default();
        let (have, lack): (Vec<&&Route>, Vec<&&Route>) =
            routes.iter().partition(|r| given.contains_key(&r.secret));
        out.push("no provider: the routes' secrets come from the host (FARMY_UNLOCK_COMMAND, the Keychain, the secret service or a prompt)".into());
        out.push(format!(
            "given: {}",
            if have.is_empty() {
                "none".to_string()
            } else {
                have.iter()
                    .map(|r| r.secret.clone())
                    .collect::<Vec<_>>()
                    .join(" ")
            }
        ));
        out.push(format!(
            "not given: {}",
            if lack.is_empty() {
                "none".to_string()
            } else {
                lack.iter()
                    .map(|r| r.secret.clone())
                    .collect::<Vec<_>>()
                    .join(" ")
            }
        ));
        return out;
    }
    let Some(unlock) = unlock else {
        out.push(format!(
            "locked: the unlocking values ({}) were not given, so the provider is not run",
            cfg.secrets.unlock.join(", ")
        ));
        return out;
    };
    let mut names: Vec<String> = routes.iter().map(|r| r.secret.clone()).collect();
    names.dedup();
    let request = serde_json::json!({ "version": 1, "secrets": names }).to_string();
    let program = resolve_provider(&cfg.secrets.provider[0]);
    out.push(format!(
        "provider: {} {}",
        program,
        cfg.secrets.provider[1..].join(" ")
    ));
    out.push(format!(
        "asked for: {}",
        if names.is_empty() {
            "nothing (no route is granted)".to_string()
        } else {
            names.join(" ")
        }
    ));
    let child = Command::new(&program)
        .args(&cfg.secrets.provider[1..])
        .envs(unlock)
        .envs(crate::egress::proxy_env(cfg, &[]))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            out.push(format!("could not be run: {e}"));
            return out;
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "this only collects the provider's diagnostics; a failed write shows in them"
        )]
        let _ = stdin.write_all(request.as_bytes());
    }
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if started.elapsed() > PROVIDER_TIMEOUT => {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the provider is ended for taking too long; the diagnostics say so"
                )]
                let _ = child.kill();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(30)),
            Err(_) => break None,
        }
    };
    let mut stdout = String::new();
    let mut stderr = String::new();
    if let Some(mut s) = child.stdout.take() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "diagnostics only: whatever arrived is shown"
        )]
        let _ = s
            .by_ref()
            .take(PROVIDER_LIMIT as u64)
            .read_to_string(&mut stdout);
    }
    if let Some(mut s) = child.stderr.take() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "diagnostics only: whatever arrived is shown"
        )]
        let _ = s
            .by_ref()
            .take(PROVIDER_LIMIT as u64)
            .read_to_string(&mut stderr);
    }
    let answer: serde_json::Value =
        serde_json::from_str(&stdout).unwrap_or(serde_json::Value::Null);
    let mut values: Vec<String> = unlock.values().cloned().collect();
    if let Some(m) = answer.get("secrets").and_then(|m| m.as_object()) {
        values.extend(m.values().filter_map(|v| v.as_str().map(String::from)));
    }
    values.retain(|v| v.len() >= 4);
    values.sort_by_key(|v| std::cmp::Reverse(v.len()));
    let redact = |text: &str| {
        values.iter().fold(text.to_string(), |acc, v| {
            acc.replace(v.as_str(), "[redacted]")
        })
    };
    out.push(match status {
        None => "ended: took longer than 30 s and was stopped".into(),
        Some(s) => format!(
            "ended: exit {}",
            s.code()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "by signal".into())
        ),
    });
    if let Some(e) = answer.get("error").and_then(|e| e.as_str()) {
        out.push(format!("answered with the error form: {}", redact(e)));
    } else if let Some(m) = answer.get("secrets").and_then(|m| m.as_object()) {
        let missing: Vec<String> = answer
            .get("missing")
            .and_then(|m| m.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        out.push(format!(
            "answered: {}{}",
            if m.is_empty() {
                "no secret".to_string()
            } else {
                m.keys().cloned().collect::<Vec<_>>().join(" ")
            },
            if missing.is_empty() {
                String::new()
            } else {
                format!("; missing: {}", missing.join(" "))
            }
        ));
    } else if !stdout.trim().is_empty() {
        out.push("answered with something that is not the protocol's JSON (not shown: it may hold secrets)".into());
    } else {
        out.push("answered nothing on stdout".into());
    }
    if stderr.trim().is_empty() {
        out.push("stderr: (empty)".into());
    } else {
        out.push("stderr:".into());
        for l in redact(&stderr).lines() {
            out.push(format!("  {l}"));
        }
    }
    out
}
