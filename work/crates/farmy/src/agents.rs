//! Agents as data (FORMATS.md, "Agents"): the shipped catalogue, `agents.yml` next to farmy, and the
//! entries under `agents:` in farmy.yml, resolved field by field. Nothing here knows one agent from
//! another; Claude is one catalogue entry.
use crate::model::farmy_home;
use crate::{R, refuse};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub(crate) const MODES: [&str; 3] = ["subscription", "api-key", "off"];

#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(untagged)]
pub(crate) enum Install {
    One(String),
    PerBase {
        #[serde(default)]
        apt: Option<String>,
        #[serde(default)]
        apk: Option<String>,
    },
}

#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(untagged)]
enum OneOrMany {
    One(String),
    Many(Vec<String>),
}

/// An unattended one-shot run (the factory): the command without the prompt, and how the prompt goes in.
#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct Headless {
    pub command: String,
    pub prompt: String, // stdin | argument
}

#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct Api {
    pub key: String,
    pub base_url: String,
    pub upstream: String,
}

/// A subscription login of the agent's own for its factory runs (FORMATS.md, "Factory logins"): the folder
/// under $HOME where the CLI keeps it, and the shell line that makes it without a browser.
#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct FactoryLogin {
    pub path: String,
    pub create: String,
}

impl FactoryLogin {
    /// The folder in a container: `/home/dev/<path>`.
    pub(crate) fn target(&self) -> String {
        let p = self
            .path
            .trim()
            .trim_start_matches("./")
            .trim_end_matches('/');
        format!("/home/dev/{p}")
    }

    /// A folder under $HOME (relative, no `..`) and a line to run; refused naming `factory_login`.
    pub(crate) fn check(&self, place: &str, name: &str) -> R {
        let p = self.path.trim();
        let tidy = p.trim_start_matches("./").trim_end_matches('/');
        if p.starts_with('/')
            || p.starts_with('~')
            || tidy.is_empty()
            || tidy.split('/').any(|part| part == "..")
        {
            return refuse(format!(
                "{place}: agents.{name}.factory_login: path '{p}' must be a folder under $HOME, relative and without .. (FORMATS.md, Factory logins)"
            ));
        }
        if self.create.trim().is_empty() {
            return refuse(format!(
                "{place}: agents.{name}.factory_login: create is empty — the shell line that makes the login without a browser"
            ));
        }
        Ok(())
    }
}

/// The volume holding an agent's factory login: one per agent on this Docker, whatever the service.
pub(crate) fn factory_login_volume(agent: &str) -> String {
    format!("farmy-factory-login-{agent}")
}

#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct Hooks {
    pub file: String,
    #[serde(default)]
    pub events: BTreeMap<String, String>,
}

/// One entry as written (in the catalogue or in farmy.yml): every field optional, so that an entry in
/// farmy.yml can override a catalogue entry field by field.
#[derive(Deserialize, Serialize, Default, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub(crate) struct Entry {
    #[serde(default)]
    install: Option<Install>,
    #[serde(default)]
    login: Option<OneOrMany>,
    #[serde(default)]
    state: Option<OneOrMany>,
    #[serde(default)]
    headless_login: Option<String>,
    #[serde(default)]
    headless: Option<Headless>,
    #[serde(default)]
    token_env: Option<String>,
    #[serde(default)]
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    api: Option<Api>,
    #[serde(default)]
    api_hosts: Option<Vec<String>>,
    #[serde(default)]
    mcp_add: Option<String>,
    #[serde(default)]
    status_hooks: Option<Hooks>,
    #[serde(default)]
    process: Option<String>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    factory_login: Option<FactoryLogin>,
}

impl Entry {
    fn over(self, base: Entry) -> Entry {
        Entry {
            install: self.install.or(base.install),
            login: self.login.or(base.login),
            state: self.state.or(base.state),
            headless_login: self.headless_login.or(base.headless_login),
            headless: self.headless.or(base.headless),
            token_env: self.token_env.or(base.token_env),
            env: self.env.or(base.env),
            api: self.api.or(base.api),
            api_hosts: self.api_hosts.or(base.api_hosts),
            mcp_add: self.mcp_add.or(base.mcp_add),
            status_hooks: self.status_hooks.or(base.status_hooks),
            process: self.process.or(base.process),
            mode: self.mode.or(base.mode),
            version: self.version.or(base.version),
            factory_login: self.factory_login.or(base.factory_login),
        }
    }
}

/// An agent as farmy uses it.
#[derive(Clone, Debug)]
pub(crate) struct Agent {
    pub name: String,
    pub install_apt: Option<String>,
    pub install_apk: Option<String>,
    pub login: Vec<String>,
    pub state: Vec<String>,
    pub headless_login: Option<String>,
    pub headless: Option<Headless>,
    pub token_env: Option<String>,
    pub env: BTreeMap<String, String>,
    pub api: Option<Api>,
    pub api_hosts: Vec<String>,
    pub mcp_add: Option<String>,
    pub status_hooks: Option<Hooks>,
    pub process: String,
    pub mode: String, // the default for every service: subscription | api-key | off
    pub version: Option<String>, // a shell line that prints the CLI's version
    pub factory_login: Option<FactoryLogin>, // a login of its own for factory runs in mode: login
    entry: Entry,     // the entry as resolved, for a run's record
}

fn paths(v: Option<OneOrMany>) -> Vec<String> {
    match v {
        None => vec![],
        Some(OneOrMany::One(s)) => vec![s],
        Some(OneOrMany::Many(v)) => v,
    }
}

impl Agent {
    pub(crate) fn from_entry(name: &str, e: Entry, place: &str) -> R<Agent> {
        let entry = e.clone();
        let (install_apt, install_apk) = match e.install {
            None => (None, None),
            Some(Install::One(s)) => (Some(s.clone()), Some(s)),
            Some(Install::PerBase { apt, apk }) => (apt, apk),
        };
        let mode = e.mode.unwrap_or_else(|| "subscription".into());
        if !MODES.contains(&mode.as_str()) {
            return refuse(format!(
                "{place}: agents.{name}.mode must be subscription, api-key or off, not '{mode}'"
            ));
        }
        if let Some(login) = &e.factory_login {
            login.check(place, name)?;
        }
        Ok(Agent {
            name: name.to_string(),
            install_apt,
            install_apk,
            login: paths(e.login),
            state: paths(e.state),
            headless_login: e.headless_login,
            headless: e.headless,
            token_env: e.token_env,
            env: e.env.unwrap_or_default(),
            api: e.api,
            api_hosts: e.api_hosts.unwrap_or_default(),
            mcp_add: e.mcp_add,
            status_hooks: e.status_hooks,
            process: e.process.unwrap_or_else(|| name.to_string()),
            version: e.version,
            factory_login: e.factory_login,
            mode,
            entry,
        })
    }

    /// The entry as resolved (the catalogue's with farmy.yml's overrides, or one of your own): every
    /// field, null when unset, with the defaults of `mode` and `process` filled in, plus `name`.
    pub(crate) fn config(&self) -> serde_json::Value {
        let mut value = serde_json::to_value(&self.entry).unwrap_or_default();
        if let Some(map) = value.as_object_mut() {
            map.insert("mode".into(), self.mode.clone().into());
            map.insert("process".into(), self.process.clone().into());
            map.insert("name".into(), self.name.clone().into());
        }
        value
    }

    /// The line for agents.tsv: name, install per base, login paths (:), state paths (,), mcp_add,
    /// hooks file, hooks events (Event=state,…), process, version (the line the toolbox runs as dev once
    /// the agents are installed); an empty column for null.
    pub(crate) fn tsv_line(&self) -> String {
        let clean = |s: &str| s.replace(['\t', '\n'], " ");
        let hooks_file = self
            .status_hooks
            .as_ref()
            .map(|h| h.file.clone())
            .unwrap_or_default();
        let hooks_events = self
            .status_hooks
            .as_ref()
            .map(|h| {
                h.events
                    .iter()
                    .map(|(e, s)| format!("{e}={s}"))
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .unwrap_or_default();
        [
            self.name.clone(),
            clean(self.install_apt.as_deref().unwrap_or("")),
            clean(self.install_apk.as_deref().unwrap_or("")),
            self.login
                .iter()
                .map(|p| login_kind(p))
                .collect::<Vec<_>>()
                .join(":"),
            self.state.join(","),
            clean(self.mcp_add.as_deref().unwrap_or("")),
            hooks_file,
            hooks_events,
            clean(&self.process),
            clean(self.version.as_deref().unwrap_or("")),
        ]
        .join("\t")
    }
}

fn tidy(e: String) -> String {
    e.replace(" at line", ", line")
}

/// The shipped catalogue, in its order; an empty list when farmy's folder has no agents.yml.
pub(crate) fn catalogue() -> R<Vec<(String, Entry)>> {
    let path = farmy_home().join("agents.yml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(vec![]);
    };
    let value: serde_yaml::Value = serde_yaml::from_str(&text)
        .map_err(|e| format!("{}: does not read: {e}", path.display()))?;
    let mut out = vec![];
    if let Some(map) = value.as_mapping() {
        for (k, v) in map {
            let name = k.as_str().unwrap_or("?").to_string();
            let entry: Entry = serde_yaml::from_value(v.clone())
                .map_err(|e| format!("{}: {name}: {}", path.display(), tidy(e.to_string())))?;
            out.push((name, entry));
        }
    }
    Ok(out)
}

/// The agents of farmy.yml (`agents:` as a map of name → fields, a list of catalogue names, or absent:
/// claude), each resolved over its catalogue entry when there is one.
pub(crate) fn resolve(
    value: Option<&serde_yaml::Value>,
    catalogue: &[(String, Entry)],
) -> R<Vec<Agent>> {
    let place = "farmy.yml";
    let from_catalogue = |name: &str| {
        catalogue
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, e)| e.clone())
    };
    let mut out = vec![];
    match value {
        None => {} // no default agent: farmy init asks, agents: in farmy.yml turns one on
        Some(serde_yaml::Value::Sequence(names)) => {
            for n in names {
                let name = n.as_str().ok_or_else(|| {
                    format!("{place}: agents: a list holds names of catalogue agents")
                })?;
                let Some(e) = from_catalogue(name) else {
                    return refuse(format!(
                        "{place}: agents: '{name}' is not in the catalogue ({}) — an agent of your own goes under agents: as a map with its fields (FORMATS.md, Agents)",
                        catalogue_names(catalogue)
                    ));
                };
                out.push(Agent::from_entry(name, e, place)?);
            }
        }
        Some(serde_yaml::Value::Mapping(map)) => {
            for (k, v) in map {
                let name = k.as_str().unwrap_or("?");
                let own: Entry = match v {
                    serde_yaml::Value::Null => Entry::default(),
                    other => serde_yaml::from_value(other.clone()).map_err(|e| format!("{place}: agents.{name}: {} — the fields are install, login, state, headless_login, headless, token_env, env, api, api_hosts, mcp_add, status_hooks, process, mode, version, factory_login (FORMATS.md, Agents)", tidy(e.to_string())))?,
                };
                let e = match from_catalogue(name) {
                    Some(base) => own.over(base),
                    None => own,
                };
                out.push(Agent::from_entry(name, e, place)?);
            }
        }
        Some(serde_yaml::Value::Null) => {}
        Some(_) => {
            return refuse(format!(
                "{place}: agents: a map of name → fields, or a list of catalogue names (FORMATS.md, Agents)"
            ));
        }
    }
    Ok(out)
}

pub(crate) fn catalogue_names(catalogue: &[(String, Entry)]) -> String {
    catalogue
        .iter()
        .map(|(n, _)| n.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

/// The catalogue's entries as agents, for listing.
pub(crate) fn catalogue_agents(catalogue: &[(String, Entry)]) -> Vec<Agent> {
    catalogue
        .iter()
        .filter_map(|(n, e)| Agent::from_entry(n, e.clone(), "agents.yml").ok())
        .collect()
}

/// A login path as agents.tsv writes it: a folder with a trailing `/` (written so, or its last part has
/// no extension), a file without (`.claude.json`, `auth.json`).
fn login_kind(path: &str) -> String {
    let p = path.trim_end_matches('/');
    let last = p.rsplit('/').next().unwrap_or(p);
    let has_extension = last.trim_start_matches('.').contains('.');
    if path.ends_with('/') || !has_extension {
        format!("{p}/")
    } else {
        p.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn login(path: &str) -> FactoryLogin {
        FactoryLogin {
            path: path.into(),
            create: "mytool login --device".into(),
        }
    }

    #[test]
    fn a_factory_login_is_a_folder_under_home_and_nothing_outside_it() {
        assert_eq!(login(".mytool").target(), "/home/dev/.mytool");
        assert_eq!(
            login("./.config/mytool/").target(),
            "/home/dev/.config/mytool"
        );
        assert!(login(".config/mytool").check("farmy.yml", "mytool").is_ok());
        for bad in [
            "/etc/mytool",
            "../../etc/mytool",
            ".mytool/../..",
            "~/.mytool",
            "",
            "./",
        ] {
            let refused = login(bad).check("farmy.yml", "mytool");
            assert!(
                matches!(&refused, Err(crate::Fail::Refuse(m)) if m.contains("factory_login")),
                "{bad:?} must be refused naming factory_login"
            );
        }
    }
}
