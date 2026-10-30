//! Enforced egress: app policies, trusted gate loading, and retained run denials.
use crate::{
    R,
    commands::{self, Ctx},
    docker,
    model::{self, Config, Definition, Restriction, WORK},
    refuse,
};
use farmy_gate::HostRule;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub(crate) fn expand(entries: &[String]) -> R<Vec<String>> {
    let sets: std::collections::BTreeMap<String, Vec<String>> =
        serde_yaml::from_str(include_str!("../../../egress-hosts.yml"))
            .map_err(|e| e.to_string())?;
    let mut result = vec![];
    for entry in entries {
        if let Some(set) = entry.strip_prefix('@') {
            let hosts = sets
                .get(set)
                .ok_or_else(|| format!("unknown egress allow set {entry}"))?;
            result.extend(hosts.clone());
        } else {
            result.push(
                HostRule::parse(entry)
                    .map_err(|e| format!("invalid egress allow entry '{entry}': {e}"))?
                    .normalized(),
            );
        }
    }
    result.sort();
    result.dedup();
    Ok(result)
}
pub(crate) fn restricted(cfg: &Config, def: &Definition) -> bool {
    mode(cfg, def) != Restriction::Unrestricted
}
pub(crate) fn mode(cfg: &Config, def: &Definition) -> Restriction {
    def.restrict
        .max(def.egress.restrict)
        .max(cfg.egress.as_ref().map(|e| e.restrict).unwrap_or_default())
}
pub(crate) fn upstream(cfg: &Config) -> Option<String> {
    let proxy = std::env::var("FARMY_EGRESS_PROXY")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            cfg.egress.as_ref().and_then(|e| {
                e.proxy
                    .clone()
                    .or_else(|| e.mesh.then(|| crate::egress::PROXY.into()))
            })
        });
    proxy.map(|p| {
        if p.starts_with("http://") {
            p
        } else {
            format!("http://{p}")
        }
    })
}
pub(crate) fn proxy_env(host: &str, locals: &[String]) -> Vec<(String, String)> {
    let mut no = vec!["localhost".into(), "127.0.0.1".into(), "::1".into()];
    no.extend_from_slice(locals);
    let proxy = format!("http://{host}:9182");
    let mut result = vec![];
    for (k, v) in [
        ("HTTP_PROXY", proxy.clone()),
        ("HTTPS_PROXY", proxy.clone()),
        ("ALL_PROXY", proxy),
        ("NO_PROXY", no.join(",")),
    ] {
        result.push((k.into(), v.clone()));
        result.push((k.to_lowercase(), v));
    }
    result
}
pub(crate) fn app_allow(ctx: &Ctx, name: &str, def: &Definition) -> R<Vec<String>> {
    let mut entries = vec!["@registries".into()];
    for (agent, mode) in commands::agent_modes(ctx, name) {
        if mode != "off" {
            entries.extend(agent.api_hosts);
        }
    }
    for route in ctx.routes.iter().filter(|r| r.git) {
        // SSH broker routes use a sentinel upstream; reconstruct their actual authority.
        let upstream = if route.is_ssh() {
            route.ssh_base()
        } else {
            route.upstream.clone()
        };
        let authority = upstream
            .split_once("://")
            .map(|(_, s)| s)
            .unwrap_or(&upstream)
            .split('/')
            .next()
            .unwrap_or("");
        entries.push(authority.rsplit('@').next().unwrap_or(authority).into());
    }
    if let Some(e) = &ctx.cfg.egress {
        entries.extend(e.allow.clone());
        if let Some(s) = e.services.get(name) {
            entries.extend(s.allow.clone());
        }
    }
    entries.extend(def.egress.allow.clone());
    expand(&entries)
}
pub(crate) fn ensure_image() -> R {
    commands::ensure_helper_image("farmy-gate:local", "gate.Dockerfile", "farmy-gate", &[])
}
pub(crate) fn load(
    gate: &str,
    cfg: &Config,
    client: &str,
    service: &str,
    allow: &[String],
    mode: &str,
) -> R {
    let payload = json!({"version":1,"upstream":upstream(cfg),"clients":{client:{"service":service,"allow":allow,"mode":mode}}}).to_string();
    for _ in 0..30 {
        if docker::exec_stdin(gate, &["farmy-gate", "load"], &payload) {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    refuse(format!("egress gate {gate} could not load its policy"))
}
pub(crate) fn gate_name(service: &str) -> String {
    format!("{service}-egress-gate")
}
pub(crate) fn reload_app(ctx: &Ctx, name: &str, def: &Definition) -> R {
    let wire_mode = if mode(&ctx.cfg, def) == Restriction::Audit {
        "audit"
    } else {
        "strict"
    };
    load(
        &gate_name(name),
        &ctx.cfg,
        name,
        name,
        &app_allow(ctx, name, def)?,
        wire_mode,
    )
}
fn gate_records(gate: &str) -> Vec<Value> {
    let text = docker::out(&["exec", gate, "farmy-gate", "log"])
        .unwrap_or_else(|_| docker::out(&["logs", gate]).unwrap_or_default());
    let mut records = parse_records(&text);
    records.drain(..records.len().saturating_sub(100));
    records
}
fn parse_records(text: &str) -> Vec<Value> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|r| matches!(r["event"].as_str(), Some("denied" | "allowed")))
        .collect()
}
fn gate_count(gate: &str) -> u64 {
    serde_json::from_str::<Value>(&docker::exec_out(gate, &["farmy-gate", "status"]))
        .ok()
        .and_then(|v| {
            v["denied"]
                .as_object()
                .map(|m| m.values().filter_map(Value::as_u64).sum())
        })
        .unwrap_or_else(|| {
            parse_records(&docker::out(&["logs", gate]).unwrap_or_default())
                .iter()
                .filter(|record| record["event"] == "denied")
                .count() as u64
        })
}
pub(crate) fn retain(service: &str, id: &str, gate: &str) {
    let dir = PathBuf::from(WORK).join(service).join("runs").join(id);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "kept as before: a failed write loses this state silently (flagged in the sweep notes)"
    )]
    let _ = std::fs::create_dir_all(&dir);
    let data = json!({"gate":gate,"denied":gate_count(gate),"log":gate_records(gate)});
    let temp = dir.join(format!(".egress.json.{}", std::process::id()));
    if std::fs::write(&temp, data.to_string()).is_ok() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "kept as before: a failed write loses this state silently (flagged in the sweep notes)"
        )]
        let _ = std::fs::rename(temp, dir.join("egress.json"));
    }
}
fn history(service: &str) -> Vec<Value> {
    let path = PathBuf::from(WORK).join(service).join("runs");
    let mut paths: Vec<_> = std::fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|r| r.path())
        .collect();
    paths.sort();
    paths
        .into_iter()
        .filter_map(|r| std::fs::read_to_string(r.join("egress.json")).ok())
        .filter_map(|t| serde_json::from_str(&t).ok())
        .collect()
}
fn live(service: Option<&str>) -> Vec<String> {
    let mut filters = vec!["label=farmy.role=egress-gate".into()];
    if let Some(s) = service {
        filters.push(format!("label=farmy.service={s}"));
    }
    docker::ps(&filters, false)
        .into_iter()
        .map(|id| {
            docker::out(&["inspect", "-f", "{{.Name}}", &id])
                .ok()
                .map(|n| n.trim().trim_start_matches('/').to_string())
                .filter(|n| !n.is_empty())
                .unwrap_or(id)
        })
        .collect()
}
pub(crate) fn status(ctx: &Ctx, name: &str, def: &Definition) -> Value {
    let gates = live(Some(name));
    let old = history(name);
    let count: u64 = gates.iter().map(|g| gate_count(g)).sum::<u64>()
        + old
            .iter()
            .filter(|r| !gates.iter().any(|g| r["gate"] == *g))
            .filter_map(|r| r["denied"].as_u64())
            .sum::<u64>();
    json!({"restricted":restricted(&ctx.cfg,def),"denied":count,"mode":mode(&ctx.cfg,def).name()})
}
pub(crate) fn main(args: &[String]) -> R {
    match args.first().map(String::as_str) {
        Some("allow") => allow(&args[1..]),
        Some("log") => log(&args[1..]),
        _ => refuse("usage: farmy egress log [SERVICE] [--json] | allow HOST [--service NAME]"),
    }
}
#[expect(
    clippy::print_stdout,
    reason = "`farmy egress allow` answers the user on the terminal"
)]
fn allow(args: &[String]) -> R {
    let Some(host) = args.first() else {
        return refuse("egress allow needs a HOST");
    };
    let value = HostRule::parse(host)
        .map_err(|e| format!("invalid egress allow '{host}': {e}"))?
        .normalized();
    let service = match args.len() {
        1 => None,
        3 if args[1] == "--service" => Some(args[2].as_str()),
        _ => return refuse("usage: farmy egress allow HOST [--service NAME]"),
    };
    let ctx = commands::load_ctx()?;
    if let Some(name) = service
        && !Path::new(&model::definition_path(name)).is_file()
    {
        return refuse(format!(
            "unknown service {name} in {}",
            crate::folder::looked_in()
        ));
    }
    let text = std::fs::read_to_string("farmy.yml").unwrap_or_default();
    let mut root: serde_yaml::Value = serde_yaml::from_str(&text).map_err(|e| e.to_string())?;
    if root.is_null() {
        root = serde_yaml::Value::Mapping(Default::default());
    }
    let e = &mut root["egress"];
    if e.is_null() {
        *e = serde_yaml::Value::Mapping(Default::default());
    }
    // Adding a filtering field to the legacy empty map must keep its mesh upstream.
    if let Some(old) = ctx.cfg.egress.as_ref().filter(|old| old.mesh)
        && e["authkey"].is_null()
        && e["tailscale"].is_null()
        && e["join_timeout"].is_null()
    {
        e["join_timeout"] = serde_yaml::Value::String(old.join_timeout.clone());
    }
    let target = if let Some(name) = service {
        if e["services"].is_null() {
            e["services"] = serde_yaml::Value::Mapping(Default::default());
        }
        if e["services"][name].is_null() {
            e["services"][name] = serde_yaml::Value::Mapping(Default::default());
        }
        &mut e["services"][name]["allow"]
    } else {
        &mut e["allow"]
    };
    if target.is_null() {
        *target = serde_yaml::Value::Sequence(vec![]);
    }
    let list = target
        .as_sequence_mut()
        .ok_or_else(|| "egress.allow must be a sequence".to_string())?;
    if !list.iter().filter_map(|v| v.as_str()).any(|v| {
        HostRule::parse(v)
            .map(|r| r.normalized() == value)
            .unwrap_or(false)
    }) {
        list.push(serde_yaml::Value::String(value.clone()));
    }
    // written beside and renamed: in the folder itself, since the state folder may be another mount
    let temp = PathBuf::from(format!(".farmy.yml.{}.tmp", std::process::id()));
    std::fs::write(
        &temp,
        serde_yaml::to_string(&root).map_err(|e| e.to_string())?,
    )?;
    std::fs::rename(temp, "farmy.yml")?;
    let updated = commands::load_ctx()?;
    for name in model::known_services() {
        if service.map(|s| s != name).unwrap_or(false) {
            continue;
        }
        let def = Definition::load(&name)?;
        if restricted(&updated.cfg, &def) && docker::app_cid(&name).is_some() {
            reload_app(&updated, &name, &def)?;
        }
    }
    println!(
        "egress allows {value}{}",
        service.map(|s| format!(" for {s}")).unwrap_or_default()
    );
    Ok(())
}
#[expect(
    clippy::print_stdout,
    reason = "`farmy egress log` prints the events for the user or, with --json, for a program"
)]
fn log(args: &[String]) -> R {
    let json = args.iter().any(|a| a == "--json");
    let names: Vec<_> = args.iter().filter(|a| a.as_str() != "--json").collect();
    if names.len() > 1 || names.iter().any(|n| n.starts_with('-')) {
        return refuse("usage: farmy egress log [SERVICE] [--json]");
    }
    let service = names.first().map(|s| s.as_str());
    let gates = live(service);
    let mut records = vec![];
    for name in model::known_services() {
        if service.map(|s| s != name).unwrap_or(false) {
            continue;
        }
        for old in history(&name) {
            if gates.iter().any(|g| old["gate"] == *g) {
                continue;
            }
            records.extend(old["log"].as_array().cloned().unwrap_or_default());
        }
    }
    for gate in gates {
        records.extend(gate_records(&gate));
    }
    records.sort_by_key(|r| r["timestamp"].as_str().unwrap_or("").to_string());
    if records.is_empty() {
        if !json {
            println!("no egress events");
        }
    } else {
        for record in records.iter().skip(records.len().saturating_sub(100)) {
            if json {
                println!("{record}");
            } else {
                println!("{}", readable(record));
            }
        }
    }
    Ok(())
}

fn readable(record: &Value) -> String {
    let host = record["host"].as_str().unwrap_or("unknown");
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.into()
    };
    format!(
        "{} {} {} {}:{} {}",
        record["timestamp"].as_str().unwrap_or("-"),
        record["service"].as_str().unwrap_or("unknown"),
        record["container"].as_str().unwrap_or("unknown"),
        host,
        record["port"],
        record["event"].as_str().unwrap_or("unknown")
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        model::{SecretsCfg, Settings},
        secrets,
    };

    #[test]
    fn readable_legacy_events_keep_missing_timestamps_and_ipv6_unambiguous() {
        let legacy = json!({"event":"denied","service":"shop","container":"shop-run","host":"2001:db8::1","port":443});
        assert_eq!(
            readable(&legacy),
            "- shop shop-run [2001:db8::1]:443 denied"
        );
        let current = json!({"timestamp":"2026-01-01T00:00:00Z","event":"allowed","mode":"audit","service":"notes","container":"notes","host":"docs.example.com","port":80});
        assert_eq!(
            readable(&current),
            "2026-01-01T00:00:00Z notes notes docs.example.com:80 allowed"
        );
        assert_eq!(
            parse_records(&format!(
                "{legacy}\n{current}\nnot JSON\n{{\"event\":\"started\"}}\n"
            ))
            .len(),
            2
        );
    }

    #[test]
    fn ssh_git_allowances_use_the_destination_and_preserve_only_explicit_ports() {
        for (url, expected) in [
            ("ssh://git@git.example.com:2222", "git.example.com:2222"),
            ("ssh://git@git.example.com", "git.example.com"),
        ] {
            let route = serde_yaml::from_str(&format!(
                "upstream: {url}\nauth: ssh\nsecret: GIT_KEY\ngit: true\n"
            ))
            .unwrap();
            let cfg = Config {
                tools: vec![],
                packages: vec![],
                toolbox: Default::default(),
                shell: "zsh".into(),
                shared_data: vec!["nvim".into()],
                dotfiles: None,
                tool_catalogue: std::collections::BTreeMap::new(),
                notify: None,
                secrets: SecretsCfg::default(),
                keys: vec![("git".into(), route)],
                agents: vec![],
                catalogue: vec![],
                knowledge: false,
                egress: None,
                setup_timeout: "30m".into(),
                setup_timeout_secs: 1800,
            };
            let settings = Settings::empty();
            let routes = secrets::routes(&cfg, &settings).unwrap();
            let ctx = Ctx {
                cfg,
                settings,
                routes,
            };
            let allow = app_allow(&ctx, "shop", &Definition::default()).unwrap();
            assert!(allow.contains(&expected.to_string()));
            if expected.contains(':') {
                assert!(!allow.contains(&"git.example.com".to_string()));
            }
            assert!(!allow.contains(&"-".to_string()));
        }
    }
}
