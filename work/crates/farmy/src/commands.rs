//! The commands: what each one checks, builds, starts, stops, prints. Names, exit codes and messages
//! follow FORMATS.md.
#![expect(
    clippy::print_stdout,
    reason = "the command implementations: stdout is what farmy says to its user"
)]
use crate::agents::{self, Agent};
use crate::folder::{folder_text, looked_in};
use crate::model::{
    Config, Definition, PortPair, Settings, WORK, block_text, booted_definition, definition_path,
    farmy_home, known_services,
};
use crate::secrets::{self, Route};
use crate::{Fail, R, compose, docker, egress, refuse, usage, warn};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::{BufRead, IsTerminal};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub(crate) enum Mode {
    Start,
    Restart,
    Rebuild,
}

pub(crate) fn help() {
    println!(
        "farmy — one set of containers per repository
It works in the folder in use: services/<name>.yml (the definition: repository, image, ports, commands,
a compose fragment), .env (this machine's settings), farmy.yml (the secrets provider, the routes, agents,
the knowledge container). That is ~/.config/farmy (its state in ~/.local/state/farmy), unless -C <dir>,
FARMY_DIR or a farmy.yml in this folder or one above names another. farmy config path prints it.

USAGE
  farmy [-C <dir>] <command> [service…] [args…]

COMMANDS
  session               Attach to the persistent session (the TUI; a window per thing started from it).
                        --background makes sure it runs without attaching. The shim runs this for a bare `farmy`.
  init                  Prepare the folder in use: Docker, .env (the Git identity from this host's git config),
                        farmy.yml when it has none (so that farmy finds that folder again), the services.
                        Through the shim: the control image, built when missing or when the checkout changed.
  config path           Print the folder in use (absolute).
  config git            Keep the folder in use in git: .gitignore, git init, the first commit (never a .env).
  add      <url>        Write services/<name>.yml for a repository: repo: from the URL, image: from --image <image>
                        (asked on a terminal), the name from the URL or --name <name>.
  start    <svc…>       Build what is missing and bring the service's containers up: the app container (the
                        repository cloned inside), its compose fragment, the keys broker; then its setup command.
                        What it start_after is started first. Already running: left alone.
  stop     [svc…]       Stop the containers; checkout and volumes are kept. No service named: all.
  restart  <svc…>       Make the containers anew from the definition and farmy.yml as they are now.
  rebuild  <svc…>       The same, and build the images again from scratch.
  destroy  <svc…>       Remove the containers AND the volumes: the checkout, uncommitted work, databases. Asks first (y).
  status [--json]       Every service: state, port block, repository, addresses, whether its definition changed.
                        --json: the same and more (containers with health, what listens, the agent's state), what the TUI shows.
  url      [svc…]       Where the service answers on the host, one line per published port.
  run      <svc> <cmd…> A named command of the service (commands: in its definition), or the words as a command,
                        in the checkout (or its workdir), as the dev user.
  keys                  Every route: upstream, state (loaded, missing, locked, provider failed, off), who may use it.
  keys reload [svc…]    Obtain the secrets again and load the brokers.
  keys --why            Run the provider once and print how it ended and its stderr, secret values [redacted]; loads nothing.
  factory               The factory loop: start <name> --task <file or text> [--profile <name>] [--from <id|branch>] [--wait],
                        list, show <id>, log <id> [<i>], cancel <id>, approve <id>, answer/revise <id> <text|file> [--wait], prune.
  factory login <svc> <agent>  Make the agent's own subscription login for factory runs in mode: login (farmy-factory-login-<agent>).
  factory pipeline      start <service> <pipeline> --task <text|file> [--wait], list, show, cancel, resume.
  toolbox list --json   Available vendor tools with resolved versions and verified artifact pins.
  toolbox bump [tool…]  Resolve stable releases and atomically update tools.lock.
  dotfiles pull        Update the shared clone and apply it to every running app.
  egress log [svc] [--json]  Show recent egress events as text or NDJSON.
  egress allow HOST [--service NAME]  Add an app destination and reload its live gate.
  lock                  Forget the values the control container holds; the next load asks this machine again.
  agents                Every agent of the catalogue and of farmy.yml: name, on or off, mode, how to log in without a browser.
  logs     <svc…>       Follow the containers' logs.
  ssh      <svc>        A shell in the app container, as the dev user.
  update [--to VERSION]  The host shim: install a pinned or newest release; FARMY_BUILD=1 builds locally.
  help                  This.
  --version             farmy <version> (<build hash>); farmy tui --version says the same, so the two can be compared.

Full docs: README.md next to farmy; the formats in FORMATS.md."
    );
}

/// What `status` and the session say when the folder in use defines no service.
pub(crate) const NO_SERVICES: &str = "No services yet: farmy add <git url> [--image …]";

// ── the folder, read once per command ─────────────────────────────────────────────────────────

pub(crate) struct Ctx {
    pub(crate) settings: Settings,
    pub(crate) cfg: Config,
    pub(crate) routes: Vec<Route>,
}

pub(crate) fn load_ctx() -> R<Ctx> {
    if Path::new("ports.yml").is_file() {
        return refuse(
            "ports.yml is not read any more — the host ports go into each definition as ports: [\"3100:3000\"] (services/<name>.yml); delete the file",
        );
    }
    let cfg = Config::load()?;
    let settings = Settings::load().unwrap_or_else(Settings::empty);
    let routes = secrets::routes(&cfg, &settings)?;
    Ok(Ctx {
        settings,
        cfg,
        routes,
    })
}

pub(crate) fn need_docker() -> R {
    if docker::daemon_up() {
        Ok(())
    } else {
        refuse(
            "Docker isn't running — start it (OrbStack, Docker Desktop or colima), then try again",
        )
    }
}

fn require_env(ctx: &Ctx) -> R {
    if !Path::new(".env").is_file() {
        return refuse(format!(
            "no .env in {} — run: farmy init  (it writes one; the keys are in .env.example next to farmy)",
            looked_in()
        ));
    }
    ctx.settings.require_identity()?;
    ctx.settings.check_lan_host()
}

/// Every name must be a service: known by a port block or a definition. --leftover: a name that still
/// has containers (a service since removed) passes too.
/// Every name must be a service: known by a definition. --leftover: a name that still has containers
/// (a service since removed) passes too.
pub(crate) fn check_services(_ctx: &Ctx, names: &[String], leftover: bool) -> R {
    let known = known_services();
    for s in names {
        if known.contains(s) {
            continue;
        }
        if leftover && docker::has_containers(s) {
            continue;
        }
        if known.is_empty() {
            return usage(format!(
                "unknown service '{s}' — no services are defined yet in {}: farmy add <url> --image <image> writes services/{s}.yml (README → Adding a service)",
                looked_in()
            ));
        }
        return usage(format!(
            "unknown service '{s}' in {} — known: {}",
            looked_in(),
            known.join(" ")
        ));
    }
    Ok(())
}

fn need_services(_ctx: &Ctx) -> R {
    if known_services().is_empty() {
        return usage(format!(
            "no services are defined yet in {} — farmy add <url> --image <image> writes a services/<name>.yml (README → Adding a service)",
            looked_in()
        ));
    }
    Ok(())
}

/// Both files, sound blocks, a fragment without farmy's names, routes it may use.
/// A sound definition, a fragment without farmy's names, routes it may use, a block of its own.
fn check_defined(ctx: &Ctx, names: &[String]) -> R {
    for s in names {
        let def = Definition::load(s)?;
        def.check(s)?;
        crate::toolbox::selection(&ctx.cfg, &def)?;
        crate::filter::app_allow(ctx, s, &def)?;
        if let Some(frag) = &def.compose {
            for k in frag.keys() {
                let k = k.as_str().unwrap_or("?");
                if k == "app" || k == "keys" {
                    return refuse(format!(
                        "{}: the compose fragment defines a service named '{k}', which farmy adds itself — rename it",
                        definition_path(s)
                    ));
                }
            }
        }
        if let Some(wanted) = &def.keys {
            for w in wanted {
                match ctx.routes.iter().find(|r| &r.name == w) {
                    None => {
                        return refuse(format!(
                            "{}: keys: names '{w}', which farmy.yml does not define under keys:",
                            definition_path(s)
                        ));
                    }
                    Some(r) if !r.granted_to(s) => {
                        return refuse(format!(
                            "{}: keys: names '{w}', which is not granted to {s} (farmy.yml: keys.{w}.services)",
                            definition_path(s)
                        ));
                    }
                    _ => {}
                }
            }
        }
        if let Some(modes) = &def.agents {
            for (agent, mode) in modes {
                if ctx.cfg.agent(agent).is_none()
                    && !ctx.cfg.catalogue.iter().any(|(n, _)| n == agent)
                {
                    return refuse(format!(
                        "{}: agents: names '{agent}', which is neither in the catalogue nor under agents: in farmy.yml (the catalogue: {})",
                        definition_path(s),
                        agents::catalogue_names(&ctx.cfg.catalogue)
                    ));
                }
                if !agents::MODES.contains(&mode.as_str()) {
                    return refuse(format!(
                        "{}: agents.{agent}: must be subscription, api-key or off, not '{mode}'",
                        definition_path(s)
                    ));
                }
            }
        }
        if let Some(w) = def.workdir_clean()
            && (w.starts_with('/') || w.contains(".."))
        {
            return refuse(format!(
                "{}: workdir must be a folder inside the repository",
                definition_path(s)
            ));
        }
    }
    check_blocks()
}

/// The block of every definition that reads; two services never share one.
fn blocks() -> Vec<(String, (u32, u32))> {
    known_services()
        .into_iter()
        .filter_map(|s| {
            Definition::load(&s)
                .ok()
                .and_then(|d| d.block())
                .map(|b| (s, b))
        })
        .collect()
}

fn check_blocks() -> R {
    let all = blocks();
    for (i, (a, ba)) in all.iter().enumerate() {
        for (b, bb) in &all[i + 1..] {
            if ba == bb {
                return refuse(format!(
                    "{a} and {b} both have host ports in the block {} (services/{a}.yml, services/{b}.yml: ports:) — each service needs a hundred of its own",
                    block_text(*ba)
                ));
            }
        }
    }
    Ok(())
}

/// A definition without ports: that something refers to (${url:x} / ${port:x} elsewhere, ${FARMY_PORT_n} in
/// its own fragment) is given the next free block, written into the file, and said so.
fn assign_ports() -> R {
    let names = known_services();
    let texts: Vec<(String, String)> = names
        .iter()
        .map(|n| {
            (
                n.clone(),
                std::fs::read_to_string(definition_path(n)).unwrap_or_default(),
            )
        })
        .collect();
    for name in &names {
        let Ok(def) = Definition::load(name) else {
            continue;
        };
        if !def.ports.is_empty() {
            continue;
        }
        let own = texts
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, t)| t.as_str())
            .unwrap_or("");
        let by_other = texts
            .iter()
            .filter(|(n, _)| n != name)
            .find(|(_, t)| {
                t.contains(&format!("${{url:{name}}}")) || t.contains(&format!("${{port:{name}}}"))
            })
            .map(|(n, _)| n.clone());
        let reason = if own.contains("${FARMY_PORT_") {
            "its compose fragment uses ${FARMY_PORT_<n>}".to_string()
        } else if let Some(other) = by_other {
            format!("services/{other}.yml refers to it with ${{url:{name}}} / ${{port:{name}}}")
        } else {
            continue;
        };
        let taken: Vec<(u32, u32)> = blocks().into_iter().map(|(_, b)| b).collect();
        let mut lo = 3100;
        while taken.iter().any(|b| b.0 == lo) {
            lo += 100;
        }
        let line = format!("ports: [\"{lo}:3000\"]");
        let mut text = own.to_string();
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(&line);
        text.push('\n');
        std::fs::write(definition_path(name), text)?;
        warn(format!(
            "{}: no ports: but {reason} — assigned {line} (written into the file; 3000 is the container port assumed, edit it if the app listens elsewhere)",
            definition_path(name)
        ));
    }
    Ok(())
}

/// The services to start, each start_after dependency before it (and started too); a cycle is refused.
fn start_order(_ctx: &Ctx, names: &[String]) -> R<Vec<String>> {
    let known = known_services();
    fn visit(s: &str, out: &mut Vec<String>, visiting: &mut Vec<String>, known: &[String]) -> R {
        if out.iter().any(|x| x == s) {
            return Ok(());
        }
        if visiting.iter().any(|x| x == s) {
            return refuse(format!(
                "start_after cycle: {} — each waits for another (services/<name>.yml)",
                visiting.join(" → ")
            ));
        }
        visiting.push(s.to_string());
        let def = Definition::load(s)?;
        for d in &def.start_after {
            if d == s || !known.contains(d) {
                return refuse(format!(
                    "{}: start_after names '{d}' — it takes other services: {}",
                    definition_path(s),
                    known
                        .iter()
                        .filter(|k| k.as_str() != s)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(" ")
                ));
            }
            visit(d, out, visiting, known)?;
        }
        visiting.pop();
        out.push(s.to_string());
        Ok(())
    }
    let mut out = vec![];
    for s in names {
        visit(s, &mut out, &mut vec![], &known)?;
    }
    Ok(out)
}

/// `${url:x}` / `${port:x}` in a definition's value, and the host ports they point at.
fn resolve_refs(ctx: &Ctx, value: &str) -> (String, Vec<u32>) {
    let mut out = String::new();
    let mut ports = vec![];
    let mut rest = value;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            out.push_str("${");
            rest = after;
            continue;
        };
        let reference = &after[..end];
        rest = &after[end + 1..];
        match reference.split_once(':') {
            Some(("port", svc)) => {
                if let Some(p) = first_host_port(svc) {
                    out.push_str(&p.to_string());
                    ports.push(p);
                }
            }
            Some(("url", svc)) => {
                if let Some(p) = first_host_port(svc) {
                    out.push_str(&format!("http://{}:{p}", ctx.settings.lan_host()));
                    ports.push(p);
                }
            }
            _ => warn(format!(
                "unknown reference ${{{reference}}} in a definition value — left empty"
            )),
        }
    }
    out.push_str(rest);
    (out, ports)
}

/// The first host port of a service's definition as it is now.
fn first_host_port(name: &str) -> Option<u32> {
    Definition::load(name)
        .ok()
        .and_then(|d| d.first_host_port())
}

/// Every agent of farmy.yml with its mode for a service: the definition's `agents.<name>`, else the entry's
/// mode; a catalogue agent the definition names and farmy.yml does not is on for this service alone.
pub(crate) fn agent_modes(ctx: &Ctx, name: &str) -> Vec<(Agent, String)> {
    let def = Definition::load(name).ok();
    let mut own = def
        .as_ref()
        .and_then(|d| d.agents.clone())
        .unwrap_or_default();
    // the factory's agent is in the image: api-key mode when a route has its upstream, else its own (token) mode
    for agent in def
        .as_ref()
        .and_then(|d| d.factory.as_ref())
        .into_iter()
        .flat_map(|f| f.profiles.values())
        .filter_map(|f| f.agent.as_ref())
    {
        if !own.contains_key(agent)
            && ctx
                .cfg
                .agent(agent)
                .map(|a| a.mode == "off")
                .unwrap_or(true)
        {
            let entry = ctx.cfg.agent(agent).cloned().or_else(|| {
                ctx.cfg
                    .catalogue
                    .iter()
                    .find(|(n, _)| n == agent)
                    .and_then(|(_, e)| Agent::from_entry(agent, e.clone(), "agents.yml").ok())
            });
            if let Some(a) = entry {
                let api = a
                    .api
                    .as_ref()
                    .map(|api| {
                        ctx.routes
                            .iter()
                            .any(|r| r.upstream == api.upstream.trim_end_matches('/'))
                    })
                    .unwrap_or(false);
                own.insert(
                    agent.clone(),
                    if api {
                        "api-key".into()
                    } else {
                        "subscription".into()
                    },
                );
            }
        }
    }
    let mut out: Vec<(Agent, String)> = ctx
        .cfg
        .agents
        .iter()
        .map(|a| {
            (
                a.clone(),
                own.get(&a.name).cloned().unwrap_or_else(|| a.mode.clone()),
            )
        })
        .collect();
    for (agent, mode) in &own {
        if out.iter().any(|(a, _)| &a.name == agent) {
            continue;
        }
        if let Some((_, e)) = ctx.cfg.catalogue.iter().find(|(n, _)| n == agent)
            && let Ok(a) = Agent::from_entry(agent, e.clone(), &definition_path(name))
        {
            out.push((a, mode.clone()));
        }
    }
    out
}

/// The agents a service's image carries: those on for it (`on`), then every factory profile's agent,
/// which can be off for interactive work in the app.
pub(crate) fn installed_agents(ctx: &Ctx, def: &Definition, on: &[Agent]) -> Vec<Agent> {
    let mut installed = on.to_vec();
    for agent in def
        .factory
        .iter()
        .flat_map(|f| f.profiles.values())
        .filter_map(|f| f.agent.as_ref())
    {
        if installed.iter().any(|a| &a.name == agent) {
            continue;
        }
        if let Some(entry) = ctx.cfg.agent(agent).cloned().or_else(|| {
            ctx.cfg
                .catalogue
                .iter()
                .find(|(n, _)| n == agent)
                .and_then(|(_, e)| Agent::from_entry(agent, e.clone(), "agents.yml").ok())
        }) {
            installed.push(entry);
        }
    }
    installed
}

/// The agents on for a service (every mode but off), in farmy.yml's order.
pub(crate) fn agents_on(ctx: &Ctx, name: &str) -> Vec<Agent> {
    agent_modes(ctx, name)
        .into_iter()
        .filter(|(_, m)| m != "off")
        .map(|(a, _)| a)
        .collect()
}

/// The environment the agents add to a service, and the variable names no route may set there.
type AgentEnvironment = (Vec<(String, String)>, Vec<String>);

/// What the agents put into a service's environment, and which variables no route may set there:
/// subscription — the agent's own env:, its api variables blocked (its token: `agent_tokens`);
/// api-key — the base URL and the placeholder from the route with the agent's upstream.
fn agent_environment(
    name: &str,
    modes: &[(Agent, String)],
    routes: &[&Route],
) -> R<AgentEnvironment> {
    let mut env = vec![];
    let mut blocked = vec![];
    for (a, mode) in modes {
        if mode == "off" {
            continue;
        }
        for (k, v) in &a.env {
            env.push((k.clone(), v.clone()));
        }
        match mode.as_str() {
            "subscription" => {
                if let Some(api) = &a.api {
                    blocked.push(api.key.clone());
                    blocked.push(api.base_url.clone());
                }
            }
            "api-key" => {
                let Some(api) = &a.api else {
                    return refuse(format!(
                        "[{name}] {}: api-key mode, and its entry has no api: (key, base_url, upstream) — FORMATS.md, Agents",
                        a.name
                    ));
                };
                let want = api.upstream.trim_end_matches('/');
                let Some(r) = routes
                    .iter()
                    .find(|r| r.upstream.trim_end_matches('/') == want)
                else {
                    return refuse(format!(
                        "[{name}] {}: api-key mode, and no route granted to {name} has the upstream {} — farmy.yml: keys, a route with that upstream (or agents.{}.mode: subscription)",
                        a.name, api.upstream, a.name
                    ));
                };
                env.push((api.base_url.clone(), format!("http://keys:9181/{}", r.name)));
                env.push((api.key.clone(), "via-farmy-keys".into()));
            }
            _ => {}
        }
    }
    Ok((env, blocked))
}

/// The agents' tokens for a service, name and value: each subscription agent's `token_env` the
/// provider (or the held unlocking values) answered. The compose file names them; the values go
/// only into the environment of `docker compose` (FORMATS.md, Agents). None answered: no variable.
fn agent_tokens(modes: &[(Agent, String)], resolved: &secrets::Resolved) -> Vec<(String, String)> {
    let mut tokens: Vec<(String, String)> = vec![];
    for (a, mode) in modes {
        if mode != "subscription" {
            continue;
        }
        if let Some(t) = &a.token_env
            && let Some(v) = resolved.values.get(t)
            && !tokens.iter().any(|(k, _)| k == t)
        {
            tokens.push((t.clone(), v.clone()));
        }
    }
    tokens
}

/// The tsv the toolbox and the entrypoint read: one line per agent on (FORMATS.md, Agents).
fn agents_tsv(agents: &[Agent]) -> String {
    agents.iter().map(|a| a.tsv_line() + "\n").collect()
}

/// The repository as the definition names it; None for a workbench (repo: none).
/// The clone URL as the definition names it; None for a workbench (repo: none).
pub(crate) fn repo_of(_ctx: &Ctx, name: &str, def: &Definition) -> R<Option<String>> {
    if def.is_workbench() {
        return Ok(None);
    }
    match def.repo.as_deref().map(str::trim) {
        Some(r) if crate::model::is_clone_url(r) => Ok(Some(r.to_string())),
        Some(r) if !r.is_empty() => refuse(format!(
            "{}: repo: {r} is not a clone URL — write the full one, such as https://github.com/{r}.git",
            definition_path(name)
        )),
        _ => refuse(format!(
            "{}: no repo: — the clone URL of the repository (https://github.com/<owner>/<name>.git), or none for a workbench",
            definition_path(name)
        )),
    }
}

/// The URL the clone uses: as written, except that an https:// repository on a host whose git route is an
/// SSH route is cloned over SSH (the pasted URL stays, the route decides the transport).
pub(crate) fn repo_url(ctx: &Ctx, repo: &str) -> String {
    let host = secrets::host_of(repo);
    if let Some(r) = secrets::git_route_for(&ctx.routes, &host)
        && r.is_ssh()
        && (repo.starts_with("https://") || repo.starts_with("http://"))
    {
        let path = repo
            .split("://")
            .nth(1)
            .unwrap_or("")
            .split_once('/')
            .map(|x| x.1)
            .unwrap_or("");
        return format!("{}/{path}", r.ssh_base());
    }
    repo.to_string()
}

// ── images ────────────────────────────────────────────────────────────────────────────────────

fn hash_dir(dir: &Path) -> String {
    let mut files: Vec<PathBuf> = vec![];
    fn walk(d: &Path, out: &mut Vec<PathBuf>) {
        if let Ok(rd) = std::fs::read_dir(d) {
            for e in rd.flatten() {
                let p = e.path();
                let name = e.file_name().to_string_lossy().to_string();
                if name.starts_with('.') || name == "target" {
                    continue;
                }
                if p.is_dir() {
                    walk(&p, out);
                } else {
                    out.push(p);
                }
            }
        }
    }
    walk(dir, &mut files);
    files.sort();
    let mut h = Sha256::new();
    for f in files {
        h.update(
            f.strip_prefix(dir)
                .unwrap_or(&f)
                .to_string_lossy()
                .as_bytes(),
        );
        h.update(std::fs::read(&f).unwrap_or_default());
    }
    format!("{:x}", h.finalize())
}

fn hash_text(parts: &[&str]) -> String {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p.as_bytes());
        h.update(b"\n");
    }
    format!("{:x}", h.finalize())
}

/// The containers folder's own toolbox, when it has one (a `toolbox/` with a Dockerfile).
fn custom_toolbox() -> Option<PathBuf> {
    let own = PathBuf::from("toolbox");
    own.join("Dockerfile").is_file().then_some(own)
}

/// The toolbox folder in effect: the containers folder's own, else farmy's.
fn toolbox_dir() -> PathBuf {
    custom_toolbox().unwrap_or_else(|| farmy_home().join("toolbox"))
}

fn agents_arg(agents: &[Agent]) -> String {
    agents
        .iter()
        .map(|a| a.name.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

fn toolbox_hash(agents: &[Agent]) -> String {
    hash_text(&[
        &hash_dir(&toolbox_dir()),
        // farmy's own layer goes on whichever toolbox is built
        &std::fs::read_to_string(farmy_home().join("toolbox/entrypoint.sh")).unwrap_or_default(),
        &std::fs::read_to_string(farmy_home().join("toolbox/farmy-home.sh")).unwrap_or_default(),
        &agents_tsv(agents),
        &std::fs::read_to_string("farmy.yml").unwrap_or_default(),
        &std::fs::read_to_string("tools.lock").unwrap_or_default(),
        &std::fs::read_to_string(farmy_home().join("tools.yml")).unwrap_or_default(),
    ])
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)? {
        let e = e?;
        let target = to.join(e.file_name());
        if e.path().is_dir() {
            copy_dir(&e.path(), &target)?;
        } else {
            std::fs::copy(e.path(), &target)?;
        }
    }
    Ok(())
}

/// `also`: files or folders of farmy's own the Dockerfile copies in besides the crate (hashed too).
pub(crate) fn ensure_helper_image(
    tag: &str,
    dockerfile: &str,
    crate_dir: &str,
    also: &[&str],
) -> R {
    if std::env::var("FARMY_BUILD").as_deref() != Ok("1") {
        {
            let registry = crate::version::registry();
            if !registry.is_empty() {
                if docker::image_label(tag, "farmy.version") == crate::version::CURRENT {
                    return Ok(());
                }
                let image = format!(
                    "{}/{}:{}",
                    registry.trim_end_matches('/'),
                    tag.trim_end_matches(":local"),
                    crate::version::CURRENT
                );
                println!("pulling {image}");
                if docker::show(&["pull", &image]) && docker::quiet(&["tag", &image, tag]) {
                    return Ok(());
                }
                return refuse(format!(
                    "could not pull {image}; check the registry or use FARMY_BUILD=1 with a checkout"
                ));
            }
        }
    }
    let home = farmy_home();
    let mut parts: Vec<String> = vec![
        crate::version::CURRENT.into(),
        hash_dir(&home.join("crates").join(crate_dir)),
        std::fs::read_to_string(home.join(dockerfile)).unwrap_or_default(),
    ];
    for a in also {
        let p = home.join(a);
        parts.push(if p.is_dir() {
            hash_dir(&p)
        } else {
            std::fs::read_to_string(&p).unwrap_or_default()
        });
    }
    let refs: Vec<&str> = parts.iter().map(String::as_str).collect();
    let hash = hash_text(&refs);
    if docker::image_label(tag, "farmy.hash") == hash {
        return Ok(());
    }
    println!("building {tag}");
    // The context holds only what the Dockerfile copies (`also`), as plain files: never farmy's whole
    // folder, and never a link (Docker sends links as links).
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let context = std::env::temp_dir().join(format!(
        "farmy-context-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let made = (|| -> std::io::Result<()> {
        std::fs::create_dir_all(&context)?;
        plain_copy(&home.join(dockerfile), &context.join("Dockerfile"))?;
        for a in also {
            plain_copy(&home.join(a), &context.join(a))?;
        }
        Ok(())
    })();
    let ok = made.is_ok()
        && docker::quiet(&[
            "build",
            "-q",
            "--label",
            &format!("farmy.hash={hash}"),
            "--label",
            &format!("farmy.version={}", crate::version::CURRENT),
            "-t",
            tag,
            "-f",
            &context.join("Dockerfile").display().to_string(),
            &context.display().to_string(),
        ]);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "removing the temporary build context; a leftover in the temporary folder harms nothing"
    )]
    let _ = std::fs::remove_dir_all(&context);
    if let Err(e) = made {
        return refuse(format!("the build context of {tag} could not be made: {e}"));
    }
    if ok {
        Ok(())
    } else {
        refuse(format!("the build of {tag} failed — see above"))
    }
}

/// A file or a folder copied as plain files and folders: a link is left out, never followed.
fn plain_copy(from: &Path, to: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(from)?;
    if meta.is_dir() {
        std::fs::create_dir_all(to)?;
        for entry in std::fs::read_dir(from)? {
            let entry = entry?;
            plain_copy(&entry.path(), &to.join(entry.file_name()))?;
        }
    } else if meta.is_file() {
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(from, to)?;
    }
    Ok(())
}

fn ensure_knowledge(ctx: &Ctx) {
    if !ctx.cfg.knowledge {
        return;
    }
    docker::ensure_network("farmy");
    if ensure_helper_image(
        "farmy-knowledge:local",
        "knowledge.Dockerfile",
        "farmy-knowledge",
        &["README.md", "docs"],
    )
    .is_err()
    {
        warn("note: the knowledge container's image did not build — going on without it");
        return;
    }
    let dir = PathBuf::from(WORK).join("farmy");
    #[expect(
        clippy::let_underscore_must_use,
        reason = "if a folder or the file is missing, compose up below fails and the warning says so"
    )]
    let _ = std::fs::create_dir_all(&dir);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "if a folder or the file is missing, compose up below fails and the warning says so"
    )]
    let _ = std::fs::create_dir_all(format!("{WORK}/status"));
    #[expect(
        clippy::let_underscore_must_use,
        reason = "if a folder or the file is missing, compose up below fails and the warning says so"
    )]
    let _ = std::fs::create_dir_all("services");
    let cwd = std::env::current_dir().unwrap_or_default();
    // only the folder in use and its state folder may be bind-mounted: the daemon resolves bind sources on
    // the host, and farmy's own files (README, docs) are in the knowledge image instead
    let volumes = [
        format!("{}:/kb/services:ro", cwd.join("services").display()),
        format!(
            "{}:/kb/status:ro",
            cwd.join(PathBuf::from(WORK)).join("status").display()
        ),
    ];
    let text = format!(
        "name: farmy\nservices:\n  knowledge:\n    image: farmy-knowledge:local\n    container_name: farmy-knowledge\n    hostname: farmy-knowledge\n    init: true\n    restart: unless-stopped\n    read_only: true\n    cap_drop: [ALL]\n    security_opt: [\"no-new-privileges:true\"]\n    networks: [farmy]\n{}    volumes:\n{}\nnetworks:\n  farmy:\n    external: true\n",
        {
            let p = egress::proxy_env(&ctx.cfg, &[]);
            if p.is_empty() {
                String::new()
            } else {
                format!(
                    "    environment:\n{}\n",
                    p.iter()
                        .map(|(k, v)| format!("      {k}: \"{v}\""))
                        .collect::<Vec<_>>()
                        .join("\n")
                )
            }
        },
        volumes
            .iter()
            .map(|v| format!("      - \"{v}\""))
            .collect::<Vec<_>>()
            .join("\n")
    );
    let file = dir.join("compose.yml");
    #[expect(
        clippy::let_underscore_must_use,
        reason = "if a folder or the file is missing, compose up below fails and the warning says so"
    )]
    let _ = std::fs::write(&file, text);
    if !docker::compose(
        "farmy",
        Some(&file),
        &["up", "-d", "--remove-orphans"],
        false,
    ) {
        warn(format!(
            "note: couldn't start the knowledge container — try: docker compose -p farmy -f {} up -d",
            file.display()
        ));
    }
}

fn stop_knowledge() {
    let file = PathBuf::from(WORK).join("farmy").join("compose.yml");
    if file.is_file() {
        let _ = docker::compose("farmy", Some(&file), &["stop"], false);
    }
}

/// Whether git reaches a repository over ssh: an `ssh://`, `git+ssh://` or `user@host:path` URL, or an
/// `https://` URL on the host of a granted git route that its `insteadOf` rule sends to ssh.
fn reaches_over_ssh(url: &str, routes: &[&Route]) -> bool {
    url.starts_with("ssh://")
        || url.starts_with("git+ssh://")
        || (!url.contains("://") && url.contains(':'))
        || routes
            .iter()
            .any(|r| r.git && r.is_ssh() && url.starts_with(&format!("https://{}/", r.host)))
}

/// What the git container said of one build file, in the order asked.
#[derive(Debug, PartialEq, Eq)]
enum Handed {
    /// The committed file's content, and whether it is executable.
    File { executable: bool, bytes: Vec<u8> },
    /// No such file in the committed tree.
    Missing,
    /// A link on the way leads out of the repository or to nothing: the link's own text.
    Outside(String),
}

/// The git container's output, one record per file asked for: a line `missing`, `outside <the link's
/// text>`, or `x <size>` (executable) / `- <size>` followed by that many bytes. `None` when the output is
/// cut short or not in that form.
fn handed_over(mut out: &[u8], count: usize) -> Option<Vec<Handed>> {
    let mut files = Vec::with_capacity(count);
    for _ in 0..count {
        let end = out.iter().position(|&b| b == b'\n')?;
        let head = std::str::from_utf8(out.get(..end)?).ok()?;
        out = out.get(end + 1..)?;
        if head == "missing" {
            files.push(Handed::Missing);
            continue;
        }
        if let Some(link) = head.strip_prefix("outside ") {
            files.push(Handed::Outside(link.to_string()));
            continue;
        }
        let (mode, size) = head.split_once(' ')?;
        let size: usize = size.parse().ok()?;
        files.push(Handed::File {
            executable: mode == "x",
            bytes: out.get(..size)?.to_vec(),
        });
        out = out.get(size..)?;
    }
    Some(files)
}

/// A `dockerfile:` or `build_files` entry farmy may read: a relative path inside the repository (record
/// 2026-10-29-1800): not empty, not absolute, no `..` part, not starting with `-`, nothing unprintable.
fn repository_path(entry: &str) -> bool {
    !entry.is_empty()
        && !entry.starts_with('/')
        && !entry.starts_with('-')
        && !entry.chars().any(char::is_control)
        && entry.split('/').all(|part| part != "..")
}

/// The script that hands a service's build files over: a shallow clone without a checkout in the git
/// container's own filesystem, and each file read from the committed tree (`git ls-tree`, `git cat-file`),
/// never from a working tree. A link is followed inside the repository, link by link, each step staying
/// in the committed tree; one that leads above the root, to an absolute path or to nothing is reported,
/// and what it points at is never read.
fn hand_over_script(selected: &str) -> String {
    format!(
        r#"set -eu
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
git clone --quiet --depth 1 ${{BRANCH:+--branch "$BRANCH"}} --filter=blob:none --no-checkout "$FARMY_REPO" "$src" >&2
cd "$src"
tab=$(printf '\t')
# resolve PATH: prints "<mode> <object>" of the committed file PATH names; exit 2 when there is none, 3
# (printing the last link's text) when a link on the way leads out of the repository or to nothing
resolve() {{
  todo=$1; at=; hops=0; link=; last=
  while [ -n "$todo" ]; do
    case $todo in
      */*) part=${{todo%%/*}}; todo=${{todo#*/}} ;;
      *) part=$todo; todo= ;;
    esac
    case $part in
      ''|.) continue ;;
      ..)
        if [ -z "$at" ]; then printf '%s\n' "$link"; return 3; fi
        case $at in */*) at=${{at%/*}} ;; *) at= ;; esac
        continue ;;
    esac
    path=${{at:+$at/}}$part
    entry=$(git --literal-pathspecs ls-tree HEAD -- "$path" | head -n 1)
    if [ -z "$entry" ]; then
      [ "$hops" = 0 ] && return 2
      printf '%s\n' "$link"; return 3
    fi
    mode=${{entry%% *}}
    object=${{entry#* * }}; object=${{object%%"$tab"*}}
    if [ "$mode" = 120000 ]; then
      hops=$((hops + 1))
      link=$(git cat-file blob "$object" | tr '\n' ' ')
      case $link in /*|'') printf '%s\n' "$link"; return 3 ;; esac
      [ "$hops" -le 40 ] || {{ printf '%s\n' "$link"; return 3; }}
      todo=$link${{todo:+/$todo}}
    else
      if [ -n "$todo" ] && [ "$mode" != 040000 ]; then
        [ "$hops" = 0 ] && return 2
        printf '%s\n' "$link"; return 3
      fi
      at=$path; last="$mode $object"
    fi
  done
  printf '%s\n' "$last"
}}
for f in {selected}; do
  if found=$(resolve "$f"); then code=0; else code=$?; fi
  case "$code:$found" in
    0:100644\ *|0:100755\ *)
      object=${{found#* }}
      if [ "${{found%% *}}" = 100755 ]; then m=x; else m=-; fi
      printf '%s %s\n' "$m" "$(git cat-file -s "$object")"
      git cat-file blob "$object" ;;
    3:*) printf 'outside %s\n' "$found" ;;
    *) echo missing ;;
  esac
done
"#
    )
}

/// The repository's Dockerfile and the build_files into the build context, read from the committed tree
/// of `branch` whatever the transport (record 2026-10-29-1800): a git container clones without a checkout
/// into its own filesystem, never into the state folder, and hands each file over on its output; farmy,
/// running as the user, writes them into the context as regular files, so they are that user's from the
/// moment they are written. Over ssh the git container runs as root (ssh refuses a uid the image has no
/// account for, and the route's agent answers only its own user and root); otherwise as the user. A link
/// that leads out of the repository stops the start before anything is written or built.
fn fetch_build_files(
    ctx: &Ctx,
    name: &str,
    repo: &str,
    branch: Option<&str>,
    context: &Path,
    files: &[String],
) -> R {
    let url = repo_url(ctx, repo);
    let over_ssh = reaches_over_ssh(&url, &secrets::granted(&ctx.routes, name));
    let mut request = crate::git_container::Request::new(name, "build-files");
    // The app image is what this fetch is about to build. The shim's control image already has Git,
    // SSH and nc, and the same loaded route broker is used.
    request.image = "farmy:local".into();
    request.user = if over_ssh {
        "0".into()
    } else {
        crate::model::running_as()
    };
    request.workdir = "/tmp".into();
    request.env.extend([
        ("FARMY_REPO".into(), url.clone()),
        ("BRANCH".into(), branch.unwrap_or("").into()),
    ]);
    let selected = files
        .iter()
        .map(|file| crate::git_container::shell_quote(file))
        .collect::<Vec<_>>()
        .join(" ");
    let (code, stdout, stderr) =
        crate::git_container::run_raw(ctx, request, &hand_over_script(&selected));
    let which = branch.map(|b| format!(" ({b})")).unwrap_or_default();
    if code != 0 {
        let said: Vec<&str> = stderr
            .lines()
            .filter(|l| !l.starts_with("warning: filtering"))
            .collect();
        let tail = said
            .iter()
            .rev()
            .take(3)
            .rev()
            .map(|l| format!("[{name}]   {l}"))
            .collect::<Vec<_>>()
            .join("\n");
        let cause = git_cause(&said.join("\n"));
        return refuse(format!(
            "[{name}] couldn't clone {url}{which} to read its Dockerfile: {cause} — git's last lines:\n{tail}\n[{name}]   check the git route's secret for {} (farmy keys) and repo: / branch: in {}",
            secrets::host_of(&url),
            definition_path(name)
        ));
    }
    let handed = handed_over(&stdout, files.len()).ok_or_else(|| {
        Fail::Refuse(format!(
            "[{name}] the git container that read {url}{which} handed its files over cut short; try again"
        ))
    })?;
    let kind = |i: usize| if i == 0 { "dockerfile" } else { "build_files" };
    for (i, (f, file)) in files.iter().zip(&handed).enumerate() {
        match file {
            Handed::File { .. } => {}
            Handed::Missing => {
                return refuse(format!(
                    "[{name}] {}: '{f}' is not in {repo}{which} — is it a file the target stage COPYs?",
                    kind(i)
                ));
            }
            Handed::Outside(link) => {
                return refuse(format!(
                    "[{name}] {}: '{f}' points outside the repository (a link to {}) — farmy reads build files from the repository only",
                    kind(i),
                    link.trim_end()
                ));
            }
        }
    }
    for (f, file) in files.iter().zip(handed) {
        let Handed::File { executable, bytes } = file else {
            continue;
        };
        let to = context.join(f);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // never through a link: the context is farmy's, made empty for this fetch
        #[expect(
            clippy::let_underscore_must_use,
            reason = "removing what may stand there; the write right after reports a real problem"
        )]
        let _ = std::fs::remove_file(&to);
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut out = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(if executable { 0o755 } else { 0o644 })
                .open(&to)?;
            out.write_all(&bytes)?;
        }
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(
            &to,
            std::fs::Permissions::from_mode(if executable { 0o755 } else { 0o644 }),
        )?;
    }
    Ok(())
}

/// image: → the toolbox on the stock image; dockerfile: → the repository's stage first, the toolbox on it.
fn build_service_image(
    ctx: &Ctx,
    name: &str,
    def: &Definition,
    repo: Option<&str>,
    branch: Option<&str>,
    agents: &[Agent],
    no_cache: bool,
) -> R {
    let base = match &def.image {
        Some(image) => image.clone(),
        None => {
            let repo = repo.ok_or_else(|| format!("[{name}] a Dockerfile build needs a repository, and the definition says repo: none"))?;
            let dockerfile = def
                .dockerfile
                .clone()
                .unwrap_or_else(|| "Dockerfile".into());
            // only paths inside the repository, before anything is fetched or cleared
            for (key, entry) in std::iter::once(("dockerfile", &dockerfile))
                .chain(def.build_files.iter().map(|f| ("build_files", f)))
            {
                if !repository_path(entry) {
                    return refuse(format!(
                        "[{name}] {key}: '{entry}' is not a relative path inside the repository (no leading /, no .. part) — {}",
                        definition_path(name)
                    ));
                }
            }
            let context = PathBuf::from(WORK).join(name).join("ctx");
            #[expect(
                clippy::let_underscore_must_use,
                reason = "clearing the build context; the copy or create right after reports a real problem"
            )]
            let _ = std::fs::remove_dir_all(&context);
            std::fs::create_dir_all(&context)?;
            let mut files = vec![dockerfile.clone()];
            files.extend(def.build_files.iter().cloned());
            fetch_build_files(ctx, name, repo, branch, &context, &files)?;
            let tag = format!("farmy/{name}:base");
            println!(
                "[{name}] building {}{dockerfile} from {repo}",
                def.target
                    .as_ref()
                    .map(|t| format!("stage {t} of "))
                    .unwrap_or_default()
            );
            let mut args: Vec<String> = vec!["build".into()];
            if no_cache {
                args.push("--no-cache".into());
            }
            if let Some(t) = &def.target {
                args.push("--target".into());
                args.push(t.clone());
            }
            args.extend([
                "--label".into(),
                format!("farmy.version={}", crate::version::CURRENT),
                "--label".into(),
                format!(
                    "farmy.hash={}",
                    hash_text(&[crate::version::CURRENT, &hash_dir(&context)])
                ),
                "-t".into(),
                tag.clone(),
                "-f".into(),
                context.join(&dockerfile).display().to_string(),
                context.display().to_string(),
            ]);
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            if !docker::build_collapsed(&refs) {
                return refuse(format!(
                    "[{name}] the build of {dockerfile} failed — see above"
                ));
            }
            tag
        }
    };
    // the toolbox's build context: the toolbox folder's files and agents.tsv (the agents on for this service)
    let tb = toolbox_dir();
    if let Some(own) = custom_toolbox() {
        let cwd = std::env::current_dir().unwrap_or_default();
        eprintln!("custom toolbox: {}", cwd.join(own).display());
    }
    let context = PathBuf::from(WORK).join(name).join("toolbox");
    #[expect(
        clippy::let_underscore_must_use,
        reason = "clearing the build context; the copy or create right after reports a real problem"
    )]
    let _ = std::fs::remove_dir_all(&context);
    copy_dir(&tb, &context).map_err(|e| {
        format!(
            "[{name}] the toolbox folder {} cannot be copied: {e}",
            tb.display()
        )
    })?;
    std::fs::write(context.join("agents.tsv"), agents_tsv(agents))?;
    crate::toolbox::prepare(&ctx.cfg, def, &context)?;
    let mut args: Vec<String> = vec!["build".into()];
    if no_cache {
        args.push("--no-cache".into());
    }
    args.extend([
        "--build-arg".into(),
        format!("BASE={base}"),
        "--build-arg".into(),
        format!("AGENTS={}", agents_arg(agents)),
        "--label".into(),
        format!("farmy.toolbox.hash={}", toolbox_hash(agents)),
        // the modes farmy's own entrypoint declares (the one the last layer installs, never a custom
        // toolbox's), so that farmy runs only those in this image
        "--label".into(),
        format!(
            "{}={}",
            crate::entrypoint::MODES_LABEL,
            crate::entrypoint::declared_modes(&std::fs::read_to_string(
                crate::toolbox::installed_entrypoint(&context)
            )?)
            .join(",")
        ),
        "--label".into(),
        format!("farmy.version={}", crate::version::CURRENT),
        "--label".into(),
        format!(
            "farmy.hash={}",
            hash_text(&[crate::version::CURRENT, &base, &toolbox_hash(agents)])
        ),
        "-t".into(),
        format!("farmy/{name}:dev"),
        "-f".into(),
        context.join("Dockerfile").display().to_string(),
        context.display().to_string(),
    ]);
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    if !docker::build_collapsed(&refs) {
        return refuse(format!(
            "[{name}] the toolbox did not build on {base} (toolbox: {}) — see above",
            tb.display()
        ));
    }
    Ok(())
}

// ── start ─────────────────────────────────────────────────────────────────────────────────────

fn work_dir(name: &str) -> PathBuf {
    PathBuf::from(WORK).join(name)
}

fn compose_file(name: &str) -> PathBuf {
    work_dir(name).join("compose.yml")
}

/// The tokens the service's compose file names, each with an empty value: for a compose command
/// that makes no container (stop, down, logs), so that compose does not warn of a variable unset.
fn blank_tokens(name: &str) -> Vec<(String, String)> {
    compose::named_variables(&std::fs::read_to_string(compose_file(name)).unwrap_or_default())
        .into_iter()
        .map(|k| (k, String::new()))
        .collect()
}

/// What to say when the definition (or farmy.yml) changed since the containers were made.
fn drift(name: &str) -> Option<String> {
    let built = std::fs::read_to_string(work_dir(name).join("definition.yml")).ok()?;
    let now = std::fs::read_to_string(definition_path(name)).ok()?;
    let norm = |t: &str| {
        t.lines()
            .map(str::trim_end)
            .filter(|l| !l.trim().is_empty() && !l.trim().starts_with('#'))
            .collect::<Vec<_>>()
            .join("\n")
    };
    if norm(&built) != norm(&now) {
        return Some(format!("definition changed — run farmy restart {name}"));
    }
    let cfg_then = std::fs::read_to_string(work_dir(name).join("farmy.yml")).unwrap_or_default();
    let cfg_now = std::fs::read_to_string("farmy.yml").unwrap_or_default();
    let config_value = |text: &str| {
        let mut v: serde_yaml::Value = serde_yaml::from_str(text).unwrap_or_default();
        if let Some(m) = v.as_mapping_mut() {
            m.remove(serde_yaml::Value::String("notify".into()));
        }
        v
    };
    if config_value(&cfg_then) != config_value(&cfg_now) {
        return Some(format!("farmy.yml changed — run farmy restart {name}"));
    }
    None
}

fn svc_state(name: &str) -> &'static str {
    if docker::app_cid(name).is_some() {
        "running"
    } else {
        "stopped"
    }
}

fn urls_of(ctx: &Ctx, name: &str) -> Vec<String> {
    let def = booted_definition(name).unwrap_or_default();
    def.port_pairs(name)
        .unwrap_or_default()
        .iter()
        .map(|p| format!("http://{}:{}", ctx.settings.lan_host(), p.host))
        .collect()
}

fn write_status(ctx: &Ctx) {
    let dir = format!("{WORK}/status");
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the status file is informational (the knowledge container reads it); it is written again at the next command"
    )]
    let _ = std::fs::create_dir_all(&dir);
    let mut text = String::new();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    text.push_str(&format!("generated\t{}\n", unix_to_rfc3339(now)));
    for svc in known_services() {
        let containers = docker::out(&[
            "ps",
            "-a",
            "--filter",
            &format!("label=com.docker.compose.project={svc}"),
            "--format",
            "{{.Names}}={{.State}}",
        ])
        .unwrap_or_default();
        let containers = containers.lines().collect::<Vec<_>>().join(",");
        text.push_str(&format!(
            "service\t{svc}\t{}\t{}\t{containers}\n",
            svc_state(&svc),
            urls_of(ctx, &svc).join(" ")
        ));
        if !containers.is_empty()
            && let Some(d) = drift(&svc)
        {
            text.push_str(&format!("problem\t{svc}\t{d}\n"));
        }
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the status file is informational (the knowledge container reads it); it is written again at the next command"
    )]
    let _ = std::fs::write(format!("{dir}/status.tsv"), text);
}

pub(crate) fn unix_to_rfc3339(secs: u64) -> String {
    // civil date from days since the epoch (Howard Hinnant's algorithm)
    let days = (secs / 86400).cast_signed(); // below 2^48: no wrap
    let rem = secs % 86400;
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Of git's output, the first line that names a cause (ownership, ssh's authentication, a host, a
/// repository), never its closing advice; with none of them, the last two lines.
pub(crate) fn git_cause(text: &str) -> String {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("Cloning into"))
        .collect();
    let causes = [
        "detected dubious ownership",
        "getaddrinfo",
        "Name or service not known",
        "Could not resolve hostname",
        "Error connecting to agent",
        "Permission denied",
        "Host key verification failed",
        "Authentication failed",
        "could not read Username",
        "returned error: 401",
        "returned error: 403",
        "Could not resolve host",
        "Connection refused",
        "Connection timed out",
        "No route to host",
        "SOCKS",
        "Repository not found",
        "not found",
        "unable to access",
    ];
    match lines.iter().find(|l| causes.iter().any(|c| l.contains(c))) {
        Some(cause) => cause.to_string(),
        None if lines.is_empty() => "git said nothing".to_string(),
        None => lines
            .iter()
            .rev()
            .take(2)
            .rev()
            .copied()
            .collect::<Vec<_>>()
            .join(" / "),
    }
}

/// Initialize the service's checkout in the shared Git launcher, after the app is up. On failure
/// the helper exits with Git's reason, while the app remains available for diagnosis and repair.
fn clone_checkout(ctx: &Ctx, name: &str, def: &Definition, cid: &str) -> Result<(), String> {
    let Some(repo) = repo_of(ctx, name, def).map_err(|e| e.to_string())? else {
        return Ok(());
    };
    // The app entrypoint does this too, but a fresh volume must be writable before the helper starts.
    docker::out(&["exec", "-u", "0", cid, "chown", "dev:dev", "/workspace"])?;
    let mut request = crate::git_container::Request::new(name, "clone");
    request.mounts.push(format!("{name}-src:/workspace"));
    request.env.extend([
        ("REPO".into(), repo_url(ctx, &repo)),
        ("BRANCH".into(), def.branch.clone().unwrap_or_default()),
    ]);
    let script = r#"set -eu
STATUS=/workspace/.farmy-clone
if [ ! -e /workspace/.git ]; then
  [ "$(ls -A /workspace 2>/dev/null)" != .farmy-clone ] || rm -f "$STATUS"
  if [ -n "$(ls -A /workspace 2>/dev/null)" ]; then
    printf 'failed\n/workspace is not empty and not a checkout\n' > "$STATUS"
    echo '/workspace is not empty and not a checkout — farmy destroy <service> starts over' >&2
    exit 1
  fi
  tries=0
  while :; do
    tries=$((tries + 1))
    if out=$(git clone ${BRANCH:+--branch "$BRANCH"} "$REPO" /workspace 2>&1); then ok=1; break; fi
    ok=""
    case "$out" in *"Permission denied"*|*"Repository not found"*|*"not found"*|*"Host key verification failed"*|*"Authentication failed"*|*"could not read Username"*|*"returned error: 401"*|*"returned error: 403"*) break ;; esac
    [ "$tries" -ge 4 ] && break
    echo "clone failed (try $tries of 4), trying again in 10 s: $(printf '%s\n' "$out" | tail -1)" >&2
    find /workspace -mindepth 1 -maxdepth 1 ! -name .farmy-clone -exec rm -rf {} + 2>/dev/null || true
    sleep 10
  done
  if [ -z "$ok" ]; then
    { echo failed; printf '%s\n' "$out" | grep -v '^Cloning into' | tail -20; } > "$STATUS"
    printf '%s\n' "$out" >&2
    exit 1
  fi
fi
if [ -d /workspace/.git/info ]; then
  grep -qxF .farmy-clone /workspace/.git/info/exclude 2>/dev/null || echo .farmy-clone >> /workspace/.git/info/exclude
fi
echo ok > "$STATUS"
"#;
    let (code, stdout, stderr) = crate::git_container::run(ctx, request, script);
    if code != 0 {
        return Err(git_cause(&format!("{stdout}\n{stderr}")));
    }
    Ok(())
}

/// What farmy knows of the git route a failed clone went through: a route without its secret (the broker
/// answers 503, an SSH agent holds no key), or a secret the host refused.
fn clone_route_note(
    ctx: &Ctx,
    resolved: &secrets::Resolved,
    repo: &str,
    reason: &str,
) -> Option<String> {
    let host = secrets::host_of(repo);
    let r = secrets::git_route_for(&ctx.routes, &host)?;
    if !resolved.has(&r.secret) {
        let state = resolved
            .states
            .get(&r.name)
            .map(|s| s.word())
            .unwrap_or("locked");
        return Some(format!(
            " The git route '{}' for {host} has no secret ({state}: {}), so only public repositories clone from {host} — give it (farmy keys --why says why it is missing), then farmy keys reload.",
            r.name, r.secret
        ));
    }
    let refused = [
        "Authentication failed",
        "could not read Username",
        "returned error: 401",
        "returned error: 403",
        "Permission denied",
    ]
    .iter()
    .any(|c| reason.contains(c));
    refused.then(|| {
        format!(
            " {host} refused the secret {} of the git route '{}' — check that it is valid and may read the repository, give it again, then farmy keys reload.",
            r.secret, r.name
        )
    })
}

/// The setup command, in the checkout as dev, under the time limit of farmy.yml (`timeout` is in
/// coreutils and in busybox, so it is in every image the toolbox builds on).
fn run_setup(name: &str, def: &Definition, cid: &str, cfg: &Config) -> bool {
    let Some(setup) = def.commands.get("setup") else {
        return true;
    };
    println!("[{name}] setup: {setup}");
    let limit = cfg.setup_timeout_secs.to_string();
    match docker::exec_code(
        cid,
        Some("dev"),
        Some(&def.app_dir()),
        &["timeout", &limit, "sh", "-lc", setup],
    ) {
        Some(0) => true,
        Some(124) => {
            warn(format!(
                "[{name}] setup did not finish within {} and was stopped: {setup} — a setup must end (a Rails bin/setup needs --skip-server); farmy.yml: setup_timeout",
                cfg.setup_timeout
            ));
            false
        }
        _ => {
            warn(format!(
                "[{name}] setup failed at: {setup} — fix it, then farmy restart {name} (or run it by hand: farmy run {name} setup)"
            ));
            false
        }
    }
}

pub(crate) fn start(args: &[String], mode: Mode) -> R {
    let cmd = match mode {
        Mode::Start => "start",
        Mode::Restart => "restart",
        Mode::Rebuild => "rebuild",
    };
    if let Some(flag) = args.iter().find(|a| a.starts_with('-')) {
        return usage(format!(
            "unknown flag '{flag}' — farmy {cmd} takes service names"
        ));
    }
    let ctx = load_ctx()?;
    check_services(&ctx, args, false)?;
    if args.is_empty() {
        need_services(&ctx)?;
        return usage(format!("usage: farmy {cmd} <service> [service…]"));
    }
    need_docker()?;
    // no .env yet: written here as init writes it, when the Git identity is found without a question
    let ctx = if Path::new(".env").is_file() {
        ctx
    } else {
        write_missing_env()?;
        load_ctx()?
    };
    require_env(&ctx)?;
    assign_ports()?;
    check_defined(&ctx, args)?;
    let order = start_order(&ctx, args)?;
    check_defined(&ctx, &order)?;

    // the secrets: once, for every route the services to start may use
    let mut needed: Vec<&Route> = vec![];
    let secrets_phase = || println!("== secrets");
    for s in &order {
        for r in secrets::granted(&ctx.routes, s) {
            if !needed.iter().any(|x| x.name == r.name) {
                needed.push(r);
            }
        }
    }
    let unlock = secrets::unlock(&ctx.cfg);
    // the mesh egress node first: the provider may sit behind the mesh
    egress::ensure(&ctx.cfg, unlock.as_ref())?;
    // the agents' tokens (token_env, subscription mode) are asked from the provider alongside
    let mut extra: Vec<String> = vec![];
    for s in &order {
        for (a, mode) in agent_modes(&ctx, s) {
            if let (Some(t), "subscription") = (&a.token_env, mode.as_str())
                && !extra.contains(t)
            {
                extra.push(t.clone());
            }
        }
    }
    secrets_phase();
    let resolved = secrets::resolve(&ctx.cfg, &needed, unlock.as_ref(), &extra);
    // what the provider answered, kept now: a start that stops at a clone still tells farmy keys why
    secrets::save_states(&resolved.states);
    // the git route of each repository's host: the warning, and the secret for a Dockerfile fetch
    let mut hosts: Vec<String> = vec![];
    for s in &order {
        let def = Definition::load(s)?;
        if let Some(repo) = repo_of(&ctx, s, &def)? {
            let host = secrets::host_of(&repo);
            if hosts.contains(&host) {
                continue;
            }
            hosts.push(host.clone());
            match secrets::git_route_for(&ctx.routes, &host) {
                None => warn(format!(
                    "no git route for {host} (farmy.yml: keys, a route with git: true and upstream https://{host}) — public repositories only on that host"
                )),
                Some(r) if !resolved.has(&r.secret) => warn(format!(
                    "the git route '{}' for {host} has no secret ({}) — public repositories only on that host until {} is given (then farmy keys reload)",
                    r.name,
                    resolved
                        .states
                        .get(&r.name)
                        .map(|s| s.word())
                        .unwrap_or("locked"),
                    r.secret
                )),
                _ => {}
            }
        }
    }
    ensure_helper_image("farmy-keys:local", "keys.Dockerfile", "farmy-keys", &[])?;
    ensure_knowledge(&ctx);
    docker::ensure_volume("farmy-shared");
    docker::ensure_network("farmy");

    let force = !matches!(mode, Mode::Start);
    let no_cache = matches!(mode, Mode::Rebuild);
    // Load the broker before any Git helper starts: the helpers sign through its agent, and token
    // routes send requests to its HTTP endpoint. No helper receives the private key or token.
    let load_now = |name: &str| {
        let granted = secrets::granted(&ctx.routes, name);
        if granted.iter().any(|r| resolved.has(&r.secret))
            && !secrets::load_broker(name, &granted, &resolved)
        {
            warn(format!(
                "[{name}] the keys broker could not be loaded — farmy keys reload {name} tries again"
            ));
        }
    };
    let mut booted: Vec<String> = vec![];
    let mut dotfiles_revisions = BTreeMap::new();
    for name in &order {
        let def = Definition::load(name)?;
        let modes = agent_modes(&ctx, name);
        let on: Vec<Agent> = modes
            .iter()
            .filter(|(_, m)| m != "off")
            .map(|(a, _)| a.clone())
            .collect();
        let installed = installed_agents(&ctx, &def, &on);
        let toolbox = toolbox_hash(&installed);
        let restricted = crate::filter::restricted(&ctx.cfg, &def);
        if restricted {
            crate::filter::ensure_image()?;
        }
        let wd = work_dir(name);
        std::fs::create_dir_all(&wd)?;
        // services/<name>.env → app.env: that app container only
        let app_env = std::fs::read_to_string(format!("services/{name}.env")).unwrap_or_default();
        std::fs::write(wd.join("app.env"), app_env)?;
        let cid_any = docker::app_cid_any(name);
        // the agents' tokens: named in the compose file, their values given to docker compose at
        // every up that may make or recreate the app container
        let tokens = agent_tokens(&modes, &resolved);
        if !force {
            if let Some(cid) = docker::app_cid(name) {
                if docker::container_label(&cid, "farmy.toolbox.hash") != toolbox {
                    println!(
                        "[{name}] note: the toolbox changed since this container was made — farmy rebuild {name} brings it in (checkout and data kept)"
                    );
                }
                if let Some(d) = drift(name) {
                    println!("[{name}] note: {d}");
                }
                println!(
                    "{name} is already running — farmy ssh {name}, farmy run {name} <cmd>, farmy url {name}"
                );
                continue;
            }
            // the existing compose file is reused when it names exactly the tokens there are now; a
            // token gone or new makes the containers anew, so that none is left blank or missing
            let same_tokens = || {
                let mut named = compose::named_variables(
                    &std::fs::read_to_string(compose_file(name)).unwrap_or_default(),
                );
                let mut now: Vec<String> = tokens.iter().map(|(k, _)| k.clone()).collect();
                named.sort();
                now.sort();
                named == now
            };
            if let Some(cid) = &cid_any
                && compose_file(name).is_file()
                && drift(name).is_none()
                && docker::container_label(cid, "farmy.toolbox.hash") == toolbox
                && same_tokens()
            {
                println!("[{name}] starting its containers again");
                if restricted {
                    if !docker::compose_with(
                        name,
                        Some(&compose_file(name)),
                        &["up", "-d", "--no-deps", "egress-gate"],
                        true,
                        &tokens,
                    ) {
                        return refuse(format!("[{name}] egress gate could not start"));
                    }
                    crate::filter::reload_app(&ctx, name, &def)?;
                }
                docker::compose_with(
                    name,
                    Some(&compose_file(name)),
                    &["up", "-d", "--remove-orphans"],
                    true,
                    &tokens,
                );
                if restricted {
                    crate::filter::reload_app(&ctx, name, &def)?;
                }
                load_now(name);
                booted.push(name.clone());
                continue;
            }
        }
        if cid_any.is_some() {
            println!(
                "[{name}] making its containers anew — the checkout, uncommitted work, databases and logins are kept"
            );
        }
        let repo = repo_of(&ctx, name, &def)?;
        let branch = def.branch.clone();
        let pairs = def.port_pairs(name)?;
        let block = def.block();
        println!(
            "[{name}] repo={}{} ports={}",
            repo.as_deref()
                .unwrap_or("none (a workbench: an empty /workspace)"),
            branch
                .as_ref()
                .map(|b| format!(" branch={b}"))
                .unwrap_or_default(),
            block.map(block_text).unwrap_or_else(|| "none".into())
        );
        std::fs::copy(definition_path(name), wd.join("definition.yml"))?;
        let mut saved_config: serde_yaml::Value =
            serde_yaml::from_str(&std::fs::read_to_string("farmy.yml").unwrap_or_default())
                .unwrap_or_default();
        if let Some(m) = saved_config.as_mapping_mut() {
            m.remove(serde_yaml::Value::String("notify".into()));
        }
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the service's copy of farmy.yml for its tools; it is written again at the next start"
        )]
        let _ = std::fs::write(
            wd.join("farmy.yml"),
            serde_yaml::to_string(&saved_config).unwrap_or_default(),
        );
        let granted = secrets::granted(&ctx.routes, name);
        let (agent_env, blocked) = agent_environment(name, &modes, &granted)?;
        let proxy_env = egress::proxy_env(&ctx.cfg, &{
            let mut names = vec![name.to_string(), "keys".to_string()];
            names.extend(
                def.compose
                    .as_ref()
                    .map(|m| {
                        m.keys()
                            .filter_map(|k| k.as_str().map(String::from))
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default(),
            );
            names
        });
        let pairs: Vec<PortPair> = pairs;
        let inputs = compose::Inputs {
            name,
            def: &def,
            ports: &pairs,
            block,
            settings: &ctx.settings,
            cfg: &ctx.cfg,
            routes: &granted,
            agents: &agents_arg(&on),
            agent_env: &agent_env,
            tokens: &tokens.iter().map(|(k, _)| k.clone()).collect::<Vec<_>>(),
            blocked: &blocked,
            proxy_env: &proxy_env,
            toolbox_hash: &toolbox,
            repo_url: &repo
                .as_deref()
                .map(|r| repo_url(&ctx, r))
                .unwrap_or_default(),
            branch: branch.as_deref().unwrap_or(""),
        };
        let text = compose::generate(&inputs, &|v| resolve_refs(&ctx, v))?;
        std::fs::write(compose_file(name), text)?;
        if def.image.is_none() {
            // Dockerfile/build-file fetches happen before the app image exists. Compose can start
            // just its broker now; the usual container recreation below reloads it afterwards.
            if !docker::compose_with(
                name,
                Some(&compose_file(name)),
                &["up", "-d", "--no-deps", "keys"],
                true,
                &tokens,
            ) {
                return refuse(format!(
                    "[{name}] keys broker could not start for the Dockerfile fetch"
                ));
            }
            load_now(name);
        }
        println!("== images: {name}");
        build_service_image(
            &ctx,
            name,
            &def,
            repo.as_deref(),
            branch.as_deref(),
            &installed,
            no_cache,
        )?;
        crate::home::provision(name)?;
        println!("== containers: {name}");
        let devc = wd.join(".devcontainer");
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the devcontainer file is for editors only; it is written again at the next start"
        )]
        let _ = std::fs::create_dir_all(&devc);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the devcontainer file is for editors only; it is written again at the next start"
        )]
        let _ = std::fs::write(
            devc.join("devcontainer.json"),
            format!(
                "{{\n  \"name\": \"{name} (farmy)\",\n  \"dockerComposeFile\": [\"../compose.yml\"],\n  \"service\": \"app\",\n  \"workspaceFolder\": \"/workspace\",\n  \"remoteUser\": \"dev\",\n  \"overrideCommand\": false,\n  \"shutdownAction\": \"none\",\n  \"updateRemoteUserUID\": false\n}}\n"
            ),
        );
        if docker::has_containers(name) {
            let _ = docker::compose_with(
                name,
                Some(&compose_file(name)),
                &["down", "--remove-orphans"],
                false,
                &tokens,
            );
        }
        if restricted {
            if !docker::compose_with(
                name,
                Some(&compose_file(name)),
                &["up", "-d", "--no-deps", "egress-gate"],
                true,
                &tokens,
            ) {
                return refuse(format!("[{name}] egress gate could not start"));
            }
            crate::filter::reload_app(&ctx, name, &def)?;
        }
        if ctx.cfg.dotfiles.is_some() {
            if !docker::compose_with(
                name,
                Some(&compose_file(name)),
                &["up", "-d", "--no-deps", "keys"],
                true,
                &tokens,
            ) {
                return refuse("dotfiles: keys broker could not start");
            }
            load_now(name);
            dotfiles_revisions.insert(name.clone(), crate::home::update(&ctx, name, false)?);
        }
        if !docker::compose_with(
            name,
            Some(&compose_file(name)),
            &["up", "-d", "--remove-orphans"],
            true,
            &tokens,
        ) {
            return refuse(format!("[{name}] docker compose up failed — see above"));
        }
        println!(
            "[{name}] containers up{}",
            if repo.is_some() {
                " — cloning inside"
            } else {
                ""
            }
        );
        if restricted {
            crate::filter::reload_app(&ctx, name, &def)?;
        }
        load_now(name);
        booted.push(name.clone());
    }
    let mut failed = false;
    for name in &booted {
        let Some(cid) = docker::app_cid(name) else {
            continue;
        };
        let def = booted_definition(name)?;
        if !def.is_workbench() {
            println!("== clone: {name}");
            if let Err(reason) = clone_checkout(&ctx, name, &def, &cid) {
                let mesh = egress::unregistered_url(&ctx.cfg).map(|u| format!(" The mesh node is unregistered, so a host on the mesh is out of reach: {u}.")).unwrap_or_default();
                let route = repo_of(&ctx, name, &def)
                    .ok()
                    .flatten()
                    .and_then(|repo| clone_route_note(&ctx, &resolved, &repo, &reason))
                    .unwrap_or_default();
                return refuse(format!(
                    "[{name}] the clone failed: {reason}.{route}{mesh} The container is up (farmy ssh {name}); farmy restart {name} tries again"
                ));
            }
        }
        let revision = match dotfiles_revisions.get(name) {
            Some(r) => r.clone(),
            None => crate::home::update(&ctx, name, false)?,
        };
        if let Err(error) = crate::home::apply(&ctx, name, &def, &cid, revision.as_deref()) {
            warn(error.to_string());
            failed = true;
            continue;
        }
        if !run_setup(name, &def, &cid, &ctx.cfg) {
            failed = true;
        }
        if let Some(repo) = repo_of(&ctx, name, &def).ok().flatten() {
            let host = secrets::host_of(&repo);
            if secrets::git_route_for(&ctx.routes, &host).is_some()
                && docker::exec_out(
                    &cid,
                    &[
                        "sh",
                        "-c",
                        "cd /workspace && git ls-remote --heads origin >/dev/null 2>&1 && echo ok",
                    ],
                ) == "ok"
            {
                println!(
                    "[{name}] git: reaches {host} through the keys broker (the secret is not in this container)"
                );
            }
        }
        let urls = urls_of(&ctx, name);
        if urls.is_empty() {
            println!("{name}: no ports published");
        } else {
            println!("{name} → {}", urls.join(" "));
        }
    }
    secrets::save_states(&resolved.states);
    write_status(&ctx);
    if failed {
        return refuse("a setup or dotfiles/home installer failed (see above)");
    }
    Ok(())
}

// ── stop, destroy, status, url, run ───────────────────────────────────────────────────────────

pub(crate) fn stop(args: &[String]) -> R {
    let ctx = load_ctx()?;
    check_services(&ctx, args, true)?;
    need_docker()?;
    let known = known_services();
    let all = args.is_empty();
    let names: Vec<String> = if all {
        known
            .iter()
            .filter(|s| docker::any_running(s))
            .cloned()
            .collect()
    } else {
        args.to_vec()
    };
    if all && names.is_empty() {
        println!("nothing is running");
        stop_knowledge();
        egress::stop(&ctx.cfg);
        return Ok(());
    }
    for name in &names {
        if docker::any_running(name) {
            docker::compose_with(
                name,
                compose_file(name)
                    .is_file()
                    .then(|| compose_file(name))
                    .as_deref(),
                &["stop"],
                false,
                &blank_tokens(name),
            );
            println!(
                "{name} stopped — its containers and volumes are kept; farmy start {name} brings it back"
            );
        } else if docker::has_containers(name) {
            println!("{name} is not running (its containers are kept — farmy start {name})");
        } else {
            println!("{name} is not running");
        }
    }
    if all || !known.iter().any(|s| docker::any_running(s)) {
        stop_knowledge();
        egress::stop(&ctx.cfg);
    }
    if WORK.path().is_dir() {
        write_status(&ctx);
    }
    Ok(())
}

/// The farmy-named volumes of a service: the checkout, the agents' state, the agent socket, the
/// definition's mounts, and the factory's run volumes.
fn remove_own_volumes(name: &str) {
    let mut own = vec![
        format!("{name}-src"),
        format!("{name}-agents"),
        format!("{name}-keys-agent"),
    ];
    if let Ok(def) = Definition::load(name) {
        own.extend(def.mounts.keys().map(|m| format!("{name}-{m}")));
    }
    let runs = format!("{name}-run-");
    own.extend(
        docker::out(&["volume", "ls", "-q", "--filter", &format!("name={runs}")])
            .unwrap_or_default()
            .lines()
            .map(str::trim)
            .filter(|v| v.starts_with(&runs))
            .map(String::from),
    );
    for v in own {
        if docker::volume_exists(&v) {
            let _ = docker::quiet(&["volume", "rm", "-f", &v]);
        }
    }
}

pub(crate) fn destroy(args: &[String]) -> R {
    if args.is_empty() {
        return usage("usage: farmy destroy <service> [service…]");
    }
    let ctx = load_ctx()?;
    check_services(&ctx, args, true)?;
    need_docker()?;
    let stdin = std::io::stdin();
    for name in args {
        print!(
            "Destroy {name} — its containers and its volumes (the checkout, uncommitted work, databases)? [y/N] "
        );
        #[expect(
            clippy::let_underscore_must_use,
            reason = "showing the prompt; an unflushed prompt still reads the answer"
        )]
        let _ = std::io::Write::flush(&mut std::io::stdout());
        let mut answer = String::new();
        #[expect(
            clippy::let_underscore_must_use,
            reason = "an unreadable answer is empty, which is no: nothing is destroyed"
        )]
        let _ = stdin.lock().read_line(&mut answer);
        if matches!(answer.trim().to_lowercase().as_str(), "y" | "yes") {
            docker::compose_with(
                name,
                compose_file(name)
                    .is_file()
                    .then(|| compose_file(name))
                    .as_deref(),
                &["down", "-v", "--remove-orphans"],
                false,
                &blank_tokens(name),
            );
            // compose removes only the volumes it made; farmy's own are removed whoever made them
            remove_own_volumes(name);
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the containers and volumes are gone; a leftover work folder is replaced at the next start"
            )]
            let _ = std::fs::remove_dir_all(work_dir(name));
            println!("{name} destroyed — its definition stays; farmy start {name} makes it anew");
        } else {
            println!("nothing destroyed");
        }
    }
    if WORK.path().is_dir() {
        write_status(&ctx);
    }
    Ok(())
}

pub(crate) fn status(args: &[String]) -> R {
    let json = args.iter().any(|a| a == "--json");
    if let Some(a) = args.iter().find(|a| *a != "--json") {
        return usage(format!(
            "unknown argument '{a}' — usage: farmy status [--json]"
        ));
    }
    let ctx = load_ctx()?;
    need_docker()?;
    if !json {
        println!("{:<12} {}", "folder", folder_text());
    }
    for note in crate::toolbox::outdated() {
        if json {
            warn(note);
        } else {
            println!("{note}");
        }
    }
    if json {
        assign_ports()?;
        println!(
            "{}",
            serde_json::to_string(&snapshot(&ctx)).unwrap_or_default()
        );
        if WORK.path().is_dir() {
            write_status(&ctx);
        }
        return Ok(());
    }
    let known = known_services();
    if known.is_empty() {
        println!("{NO_SERVICES}");
        return Ok(());
    }
    assign_ports()?;
    if let Some(line) = egress::status_line(&ctx.cfg) {
        println!("{line}");
    }
    match ctx
        .settings
        .get("LAN_HOST")
        .filter(|_| compose::lan_open(&ctx.settings))
    {
        Some(lan) => println!("{:<12} every interface (LAN_HOST={lan})", "ports"),
        None => println!(
            "{:<12} 127.0.0.1 only (LAN_HOST in .env opens them to the network)",
            "ports"
        ),
    }
    for name in &known {
        let state = svc_state(name);
        let def = match booted_definition(name) {
            Ok(d) => d,
            Err(e) => {
                println!("{name:<12} {state:<8} {:<10} {e}", "-");
                continue;
            }
        };
        let block = def.block().map(block_text).unwrap_or_else(|| "-".into());
        let repo = match repo_of(&ctx, name, &def) {
            Ok(Some(r)) => r,
            Ok(None) => "none".into(),
            Err(_) => "(no repo: — see farmy start)".into(),
        };
        let urls = if state == "running" {
            format!("  {}", urls_of(&ctx, name).join(" "))
        } else {
            String::new()
        };
        let note = if docker::has_containers(name) {
            drift(name).map(|d| format!("  ({d})")).unwrap_or_default()
        } else {
            String::new()
        };
        let toolbox = crate::version::toolbox(name);
        let version_note = toolbox
            .exists
            .then(|| crate::version::drift(name, toolbox.version.as_deref()))
            .flatten()
            .map(|n| format!("  ({n})"))
            .unwrap_or_default();
        println!("{name:<12} {state:<8} {block:<10} {repo}{urls}{note}{version_note}");
    }
    if WORK.path().is_dir() {
        write_status(&ctx);
    }
    Ok(())
}

pub(crate) fn url(args: &[String]) -> R {
    let ctx = load_ctx()?;
    check_services(&ctx, args, false)?;
    ctx.settings.check_lan_host()?;
    let names: Vec<String> = if args.is_empty() {
        need_services(&ctx)?;
        known_services()
    } else {
        args.to_vec()
    };
    for name in &names {
        for u in urls_of(&ctx, name) {
            if names.len() == 1 {
                println!("{u}");
            } else {
                println!("{name}  {u}");
            }
        }
    }
    Ok(())
}

pub(crate) fn run(args: &[String]) -> R {
    let Some(name) = args.first() else {
        return usage("usage: farmy run <service> <command…>");
    };
    let ctx = load_ctx()?;
    check_services(&ctx, std::slice::from_ref(name), false)?;
    need_docker()?;
    let Some(cid) = docker::app_cid(name) else {
        return refuse(format!("{name} is not running — farmy start {name}"));
    };
    let words = &args[1..];
    if words.is_empty() {
        return usage("usage: farmy run <service> <command…>");
    }
    let def = booted_definition(name)?;
    let dir = def.app_dir();
    let tty = std::io::stdin().is_terminal();
    let mut argv: Vec<String> = vec!["exec".into()];
    if tty {
        argv.push("-it".into());
    }
    // no pager: git log and friends print and end instead of waiting in less
    argv.extend([
        "-e".into(),
        "GIT_PAGER=cat".into(),
        "-e".into(),
        "PAGER=cat".into(),
    ]);
    argv.extend(["-u".into(), "dev".into(), "-w".into(), dir, cid]);
    match (words.len(), def.commands.get(&words[0])) {
        (1, Some(named)) => argv.extend(["sh".into(), "-lc".into(), named.clone()]),
        _ => argv.extend(words.iter().cloned()),
    }
    let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
    if docker::attach(&refs) {
        Ok(())
    } else {
        Err(Fail::Refuse(String::new()))
    }
}

pub(crate) fn logs(args: &[String]) -> R {
    if args.is_empty() {
        return usage("usage: farmy logs <service> [service…]");
    }
    let ctx = load_ctx()?;
    check_services(&ctx, args, false)?;
    need_docker()?;
    for name in args {
        if !docker::has_containers(name) {
            return refuse(format!("{name} has no containers — farmy start {name}"));
        }
    }
    docker::compose_with(
        &args[0],
        compose_file(&args[0])
            .is_file()
            .then(|| compose_file(&args[0]))
            .as_deref(),
        &["logs", "-f", "--tail", "100"],
        true,
        &blank_tokens(&args[0]),
    );
    Ok(())
}

pub(crate) fn ssh(args: &[String]) -> R {
    let Some(name) = args.first() else {
        return usage("usage: farmy ssh <service>");
    };
    let ctx = load_ctx()?;
    check_services(&ctx, std::slice::from_ref(name), false)?;
    need_docker()?;
    let Some(cid) = docker::app_cid(name) else {
        return refuse(format!("{name} is not running — farmy start {name}"));
    };
    let def = booted_definition(name)?;
    let booted_config: serde_yaml::Value = serde_yaml::from_str(
        &std::fs::read_to_string(work_dir(name).join("farmy.yml")).unwrap_or_default(),
    )
    .unwrap_or_default();
    let shell = format!("/bin/{}", booted_config["shell"].as_str().unwrap_or("zsh"));
    docker::attach(&[
        "exec",
        "-it",
        "-u",
        "dev",
        "-w",
        &def.app_dir(),
        &cid,
        &shell,
        "-il",
    ]);
    Ok(())
}

// ── keys ──────────────────────────────────────────────────────────────────────────────────────

pub(crate) fn keys(args: &[String]) -> R {
    let ctx = load_ctx()?;
    if args.first().map(String::as_str) == Some("reload") {
        return keys_reload(&ctx, &args[1..]);
    }
    if args.first().map(String::as_str) == Some("--why") && args.len() == 1 {
        return keys_why(&ctx);
    }
    if !args.is_empty() {
        return usage("usage: farmy keys [reload [service…] | --why]");
    }
    if ctx.routes.is_empty() {
        println!(
            "no routes defined — farmy.yml: keys: (farmy.example.yml next to farmy shows the usual ones)"
        );
        return Ok(());
    }
    let states = secrets::saved_states();
    let known = known_services();
    for r in &ctx.routes {
        let mut state = states
            .get(&r.name)
            .cloned()
            .unwrap_or_else(|| "not resolved yet".into());
        // loaded is what a running broker holds, not what farmy once sent
        if state == "loaded" {
            let answers: Vec<Vec<String>> = known
                .iter()
                .filter(|s| r.granted_to(s) && docker::any_running(s))
                .filter_map(|s| secrets::broker_holds(s))
                .collect();
            if !answers.is_empty() && !answers.iter().any(|held| held.contains(&r.secret)) {
                state = "not loaded (farmy keys reload)".into();
            }
        }
        let who = match &r.services {
            Some(l) => l.join(", "),
            None => {
                if known.is_empty() {
                    "every service".into()
                } else {
                    known.join(", ")
                }
            }
        };
        println!(
            "{:<12} →  {:<36} {state:<16} for: {who}{}",
            r.name,
            if r.is_ssh() {
                "ssh agent in the broker".to_string()
            } else {
                r.upstream.clone()
            },
            r.expose
                .as_ref()
                .map(|x| format!("  (exposes {x})"))
                .unwrap_or_default()
        );
    }
    Ok(())
}

/// `farmy keys --why`: the provider once, for every route, as a load would ask it; nothing is loaded.
fn keys_why(ctx: &Ctx) -> R {
    let unlock = secrets::unlock(&ctx.cfg);
    egress::ensure(&ctx.cfg, unlock.as_ref())?;
    let routes: Vec<&Route> = ctx.routes.iter().filter(|r| !r.secret.is_empty()).collect();
    for line in secrets::why(&ctx.cfg, &routes, unlock.as_ref()) {
        println!("{line}");
    }
    Ok(())
}

fn keys_reload(ctx: &Ctx, args: &[String]) -> R {
    check_services(ctx, args, false)?;
    need_docker()?;
    let names: Vec<String> = if args.is_empty() {
        known_services()
            .into_iter()
            .filter(|s| docker::any_running(s))
            .collect()
    } else {
        args.to_vec()
    };
    let mut needed: Vec<&Route> = vec![];
    for s in &names {
        for r in secrets::granted(&ctx.routes, s) {
            if !needed.iter().any(|x| x.name == r.name) {
                needed.push(r);
            }
        }
    }
    let unlock = secrets::unlock(&ctx.cfg);
    egress::ensure(&ctx.cfg, unlock.as_ref())?;
    let resolved = secrets::resolve(&ctx.cfg, &needed, unlock.as_ref(), &[]);
    for name in &names {
        if docker::app_cid(name).is_none() {
            println!("{name} is not running — nothing to load");
            continue;
        }
        let granted = secrets::granted(&ctx.routes, name);
        if secrets::load_broker(name, &granted, &resolved) {
            println!(
                "{name}: keys loaded ({})",
                granted
                    .iter()
                    .map(|r| format!(
                        "{} {}",
                        r.name,
                        resolved
                            .states
                            .get(&r.name)
                            .map(|s| s.word())
                            .unwrap_or("locked")
                    ))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        } else {
            warn(format!("{name}: the keys broker could not be loaded"));
        }
    }
    secrets::save_states(&resolved.states);
    Ok(())
}

/// `farmy unlock-names [--missing]`: the names the host is asked for; with --missing only those the
/// control container does not hold, which is what the shim asks for.
pub(crate) fn unlock_names(args: &[String]) -> R {
    let cfg = Config::load()?;
    let missing = args.iter().any(|a| a == "--missing");
    let held = if missing {
        crate::hold::get()
    } else {
        Default::default()
    };
    for n in secrets::host_names(&cfg)
        .into_iter()
        .filter(|n| !held.contains_key(n))
    {
        println!("{n}");
    }
    Ok(())
}

/// `farmy lock`: the control container forgets the values it holds.
pub(crate) fn lock(args: &[String]) -> R {
    if let Some(a) = args.first() {
        return usage(format!("unexpected '{a}' — farmy lock takes no arguments"));
    }
    if crate::hold::clear() {
        println!(
            "the held values are forgotten — the next start, restart, rebuild or keys reload asks this machine again"
        );
    } else {
        println!(
            "nothing was held — the next start, restart, rebuild or keys reload asks this machine"
        );
    }
    Ok(())
}

// ── init, session ─────────────────────────────────────────────────────────────────────────────

fn ok_line(m: &str) {
    println!("        ✓ {m}");
}

/// A line asked on a terminal; None without one, or when nothing was typed.
fn ask_line(prompt: &str) -> Option<String> {
    if !std::io::stdin().is_terminal() {
        return None;
    }
    print!("{prompt}");
    #[expect(
        clippy::let_underscore_must_use,
        reason = "showing the prompt; an unflushed prompt still reads the answer"
    )]
    let _ = std::io::Write::flush(&mut std::io::stdout());
    let mut line = String::new();
    std::io::stdin().read_line(&mut line).ok()?;
    let line = line.trim().to_string();
    if line.is_empty() { None } else { Some(line) }
}

pub(crate) fn init(args: &[String]) -> R {
    if let Some(a) = args.first() {
        return usage(format!(
            "unknown argument '{a}' — farmy init takes no arguments"
        ));
    }
    println!("\n  farmy init — {}, ready for farmy.", folder_text());
    if !std::io::stdin().is_terminal() {
        println!(
            "        (not on a terminal — nothing is asked; what is not found is left for you to set)"
        );
    }
    println!("\n  [1/4] Docker");
    if !docker::daemon_up() {
        return refuse(
            "        ✗ Docker isn't running — start it (OrbStack, Docker Desktop or colima), then re-run farmy init",
        );
    }
    ok_line("Docker is running");
    // nothing is written before Docker answered: the default home is set up only now
    crate::folder::set_up_for_init()?;
    println!("\n  [2/4] .env  (written when missing; a value already set is kept)");
    if crate::folder::write_default_farmy_yml(Path::new("."))? {
        ok_line(&format!(
            "wrote farmy.yml (every default) — farmy finds {} by it from now on",
            looked_in()
        ));
    }
    if Path::new(".env").is_file() {
        ok_line(".env exists");
    } else {
        std::fs::write(".env", env_example())?;
        println!("        ✓ wrote .env (from farmy's .env.example)");
    }
    let mut settings = Settings::load().unwrap_or_else(Settings::empty);
    for (key, git_key) in [
        ("GIT_USER_NAME", "user.name"),
        ("GIT_USER_EMAIL", "user.email"),
    ] {
        match settings.get(key) {
            Some(v) if v != "Your Name" && v != "you@example.com" => {
                ok_line(&format!("{key} = {v} (kept)"))
            }
            _ => {
                // farmy's own environment, then git where farmy runs, then a question on a terminal
                let found = identity_found(key, git_key).or_else(|| {
                    ask_line(&format!(
                        "        {key} (git's {git_key}; written to .env): "
                    ))
                });
                match found {
                    Some(v) => {
                        set_env_key(key, &v)?;
                        println!("        ✓ {key} = {v}");
                    }
                    None => warn(format!("        ! {key} still unset — set it in .env")),
                }
            }
        }
    }
    settings = Settings::load().unwrap_or_else(Settings::empty);
    let cfg = Config::load()?;
    let routes = secrets::routes(&cfg, &settings)?;
    let git_routes: Vec<&Route> = routes.iter().filter(|r| r.git).collect();
    if git_routes.is_empty() {
        warn(
            "        ! no git route (farmy.yml: keys: github … with git: true, see farmy.example.yml) — public repositories only",
        );
    } else if cfg.secrets.provider.is_empty() {
        for r in &git_routes {
            ok_line(&format!(
                "the git route '{}' for {}: {} is asked for on this machine at start (FARMY_UNLOCK_COMMAND, the Keychain, the secret service or a prompt)",
                r.name, r.host, r.secret
            ));
        }
    } else {
        for r in &git_routes {
            ok_line(&format!(
                "the git route '{}' for {} takes its secret from the provider",
                r.name, r.host
            ));
        }
    }
    println!("\n  [3/4] Agents  (installed in every app image; none unless you say so)");
    choose_agents(&cfg)?;
    println!("\n  [4/4] Services");
    let services = known_services();
    if services.is_empty() {
        println!(
            "        no services defined yet in {} — farmy add <url> --image <image> writes a services/<name>.yml (README → Adding a service), then: farmy start <name>",
            looked_in()
        );
        println!("\n  Done.");
        return Ok(());
    }
    for s in &services {
        println!("        {s:<17} {}", svc_state(s));
    }
    println!(
        "\n  Done. Next:\n    farmy start {0}      # bring it up: the repository is cloned inside, the setup runs\n    farmy ssh {0}        # a shell inside, as the dev user\n    farmy                 # the session: every service, every action",
        services[0]
    );
    Ok(())
}

/// What a new service's image will carry: the agents of farmy.yml with their modes.
fn agents_line(cfg: &Config) -> String {
    let on: Vec<String> = cfg
        .agents
        .iter()
        .filter(|a| a.mode != "off")
        .map(|a| format!("{} ({})", a.name, a.mode))
        .collect();
    if on.is_empty() {
        "agents: none (agents: in farmy.yml turns one on)".to_string()
    } else {
        format!("agents: {}", on.join(", "))
    }
}

/// init's question: which agents every image carries. A farmy.yml with agents: is left alone; without a
/// terminal none is turned on and nothing is written.
fn choose_agents(cfg: &Config) -> R {
    let has_key = std::fs::read_to_string("farmy.yml")
        .ok()
        .and_then(|t| serde_yaml::from_str::<serde_yaml::Value>(&t).ok())
        .map(|v| v.get("agents").is_some())
        .unwrap_or(false);
    if has_key {
        ok_line(&agents_line(cfg).replacen("agents: ", "agents in farmy.yml: ", 1));
        return Ok(());
    }
    let names = agents::catalogue_names(&cfg.catalogue);
    if !std::io::stdin().is_terminal() {
        println!(
            "        no agent turned on (not on a terminal to ask) — agents: in farmy.yml turns one on, e.g. agents: {{claude: {{}}}}; the catalogue: {names}"
        );
        return Ok(());
    }
    let answer = ask_line(&format!(
        "        agents to install, space-separated ({names}; empty for none): "
    ))
    .unwrap_or_default();
    let chosen: Vec<&str> = answer
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|w| !w.is_empty())
        .collect();
    if let Some(bad) = chosen
        .iter()
        .find(|w| !cfg.catalogue.iter().any(|(n, _)| n == *w))
    {
        return refuse(format!(
            "        '{bad}' is not in the catalogue ({names}) — run farmy init again, or write agents: into farmy.yml"
        ));
    }
    if chosen.is_empty() {
        ok_line("no agent — agents: in farmy.yml turns one on later");
        return Ok(());
    }
    let block = format!(
        "agents:\n{}",
        chosen
            .iter()
            .map(|n| format!("  {n}: {{}}\n"))
            .collect::<String>()
    );
    let text = std::fs::read_to_string("farmy.yml").unwrap_or_default();
    let joined = if text.is_empty() {
        block
    } else {
        format!(
            "{}{}\n{block}",
            text,
            if text.ends_with('\n') { "" } else { "\n" }
        )
    };
    std::fs::write("farmy.yml", joined)?;
    ok_line(&format!(
        "wrote agents: {} into farmy.yml",
        chosen.join(", ")
    ));
    Ok(())
}

/// `farmy add <url> [--image <image>] [--name <name>]`: a definition from a clone URL.
pub(crate) fn add(args: &[String]) -> R {
    let mut url: Option<String> = None;
    let mut image: Option<String> = None;
    let mut name: Option<String> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--image" => image = it.next().cloned().or(None),
            "--name" => name = it.next().cloned(),
            flag if flag.starts_with('-') => {
                return usage(format!(
                    "unknown flag '{flag}' — usage: farmy add <url> [--image <image>] [--name <name>]"
                ));
            }
            other if url.is_none() => url = Some(other.to_string()),
            other => {
                return usage(format!(
                    "unexpected '{other}' — usage: farmy add <url> [--image <image>] [--name <name>]"
                ));
            }
        }
    }
    let Some(url) = url else {
        return usage(
            "usage: farmy add <url> [--image <image>] [--name <name>] — the repository's clone URL",
        );
    };
    if url != "none" && !crate::model::is_clone_url(&url) {
        return usage(format!(
            "'{url}' is not a clone URL — farmy add takes the full one, such as https://github.com/<owner>/<name>.git"
        ));
    }
    let derived = url
        .trim_end_matches('/')
        .rsplit(['/', ':'])
        .next()
        .unwrap_or("")
        .trim_end_matches(".git")
        .to_string();
    let name = name.unwrap_or(derived);
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return usage(format!(
            "could not make a service name from '{url}' — give one with --name <name>"
        ));
    }
    let path = definition_path(&name);
    if Path::new(&path).exists() {
        return refuse(format!(
            "{path} exists already — edit it, or farmy add … --name <another name>"
        ));
    }
    let image = match image {
        Some(i) if !i.is_empty() => i,
        _ => match ask_line(&format!(
            "image for {name} (an official Debian image, e.g. ruby:3.4-slim or node:22-bookworm-slim): "
        )) {
            Some(i) => i,
            None => {
                return usage("--image <image> is needed — the image the app container is built on (an official Debian image, e.g. ruby:3.4-slim); nothing written".to_string());
            }
        },
    };
    std::fs::create_dir_all("services")?;
    std::fs::write(&path, format!("repo: {url}\nimage: {image}\n"))?;
    println!(
        "{path} written — ports: [\"3100:3000\"] and commands: go there when the app needs them; then: farmy start {name}"
    );
    if let Ok(cfg) = Config::load() {
        println!("{}", agents_line(&cfg));
    }
    Ok(())
}

fn set_env_key(key: &str, value: &str) -> R {
    let text = std::fs::read_to_string(".env").unwrap_or_default();
    std::fs::write(".env", with_env_key(&text, key, value))?;
    Ok(())
}

/// `.env`'s text with `key` set to `value`: its first line replaced, or one added.
fn with_env_key(text: &str, key: &str, value: &str) -> String {
    let mut lines: Vec<String> = text.lines().map(String::from).collect();
    let mut done = false;
    for l in lines.iter_mut() {
        if l.starts_with(&format!("{key}=")) && !done {
            *l = format!("{key}={value}");
            done = true;
        }
    }
    if !done {
        lines.push(format!("{key}={value}"));
    }
    lines.join("\n") + "\n"
}

/// What a new `.env` starts from: farmy's `.env.example`.
fn env_example() -> String {
    std::fs::read_to_string(farmy_home().join(".env.example"))
        .unwrap_or_else(|_| "GIT_USER_NAME=Your Name\nGIT_USER_EMAIL=you@example.com\n".into())
}

/// The Git identity a missing `.env` gets without a question: `GIT_USER_NAME` / `GIT_USER_EMAIL` in
/// farmy's environment (the shim passes the host's git configuration that way: the control container
/// never sees it), then the global git configuration where farmy runs.
fn identity_found(key: &str, git_key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .or_else(|| {
            Command::new("git")
                .args(["config", "--global", git_key])
                .stdin(Stdio::null())
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|v| !v.is_empty())
        })
}

/// `start`, `restart` and `rebuild` in a folder without `.env`: it is written as `init` writes it, with
/// the Git identity found without a question, and said on stderr. Without an identity nothing is
/// written and the start is refused as before.
fn write_missing_env() -> R {
    let (Some(name), Some(email)) = (
        identity_found("GIT_USER_NAME", "user.name"),
        identity_found("GIT_USER_EMAIL", "user.email"),
    ) else {
        return refuse(format!(
            "no .env in {} and no Git identity to write one with (GIT_USER_NAME / GIT_USER_EMAIL, git config --global user.name / user.email) — run: farmy init  (it writes .env and asks for what it does not find)",
            looked_in()
        ));
    };
    let text = with_env_key(&env_example(), "GIT_USER_NAME", &name);
    std::fs::write(".env", with_env_key(&text, "GIT_USER_EMAIL", &email))?;
    warn(format!(
        "wrote {} with the Git identity {name} <{email}> (farmy init does the same; LAN_HOST and the rest go there too)",
        crate::folder::shown(&crate::folder::current().path.join(".env"))
    ));
    Ok(())
}

/// The persistent tmux session in the control container: the TUI in its one window. tmux is only how the
/// session survives a closed terminal: no status bar, no prefix key, so nothing of it reaches the user.
/// A session made by another build of farmy is replaced, so the TUI never runs stale.
pub(crate) fn session(args: &[String]) -> R {
    let background = args.iter().any(|a| a == "--background");
    let tmux = |args: &[&str]| {
        Command::new("tmux")
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    let mut exists = tmux(&["has-session", "-t", "farmy"]);
    if exists {
        let built = Command::new("tmux")
            .args(["show-environment", "-t", "farmy", "FARMY_BUILD"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        if built != format!("FARMY_BUILD={}", crate::build_hash()) {
            println!("the session was made by another build of farmy — starting it anew");
            tmux(&["kill-session", "-t", "farmy"]);
            exists = false;
        }
    }
    if !exists {
        let exe = std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "farmy".into());
        // the TUI works in the folder in use, whatever environment a tmux server already running holds
        let folder = crate::folder::current();
        let mut new_session: Vec<String> =
            ["new-session", "-d", "-s", "farmy", "-n", "farmy", "-c"]
                .iter()
                .map(|s| s.to_string())
                .collect();
        new_session.push(folder.path.display().to_string());
        new_session.extend(["-e".into(), format!("FARMY_DIR={}", folder.path.display())]);
        for key in [
            "XDG_CONFIG_HOME",
            "XDG_STATE_HOME",
            "FARMY_HOST_HOME",
            "GIT_USER_NAME",
            "GIT_USER_EMAIL",
        ] {
            if let Ok(value) = std::env::var(key) {
                new_session.extend(["-e".into(), format!("{key}={value}")]);
            }
        }
        new_session.push(format!("{exe} tui"));
        let ok = tmux(&new_session.iter().map(String::as_str).collect::<Vec<_>>());
        if !ok {
            return refuse(
                "could not start the session — is tmux installed here? (the control container has it)",
            );
        }
        tmux(&[
            "set-environment",
            "-t",
            "farmy",
            "FARMY_BUILD",
            crate::build_hash(),
        ]);
        tmux(&["set-option", "-t", "farmy", "status", "off"]);
        tmux(&["set-option", "-t", "farmy", "prefix", "None"]);
        tmux(&["set-option", "-t", "farmy", "prefix2", "None"]);
    }
    if background {
        println!("the session farmy runs — farmy (or farmy session) attaches to it");
        return Ok(());
    }
    let status = Command::new("tmux")
        .args(["attach", "-t", "farmy"])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        refuse("could not attach to the session (a terminal is needed)")
    }
}

// ── status --json: what the TUI renders from ──────────────────────────────────────────────────

/// Every container of a service's compose project: name, compose service, state, health.
fn containers_of(name: &str) -> Vec<serde_json::Value> {
    let listed = docker::out(&[
        "ps",
        "-a",
        "--filter",
        &format!("label=com.docker.compose.project={name}"),
        "--format",
        "{{.Names}}\t{{.State}}\t{{.Label \"com.docker.compose.service\"}}",
    ])
    .unwrap_or_default();
    let mut out = vec![];
    for line in listed.lines() {
        let mut parts = line.split('\t');
        let (Some(cname), Some(state), service) =
            (parts.next(), parts.next(), parts.next().unwrap_or(""))
        else {
            continue;
        };
        let health = docker::out(&["inspect", "-f", "{{json .State}}", cname])
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .and_then(|v| {
                v.get("Health")
                    .and_then(|h| h.get("Status"))
                    .and_then(|s| s.as_str())
                    .map(String::from)
            });
        out.push(serde_json::json!({ "name": cname, "service": service, "state": state, "health": health }));
    }
    out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    out
}

/// Whether something listens on a container port: a line with the port in hex in /proc/net/tcp or tcp6.
fn listening(cid: &str, port: &str) -> bool {
    let Ok(p) = port.parse::<u32>() else {
        return false;
    };
    let probe = format!(
        "grep -qi ':{:04X} ' /proc/net/tcp /proc/net/tcp6 2>/dev/null",
        p
    );
    docker::exec_code(cid, None, None, &["sh", "-c", &probe]) == Some(0)
}

/// Each agent's state, one entry per agent on for the service: the status file its hooks write on the
/// service's agents volume, else whether its process runs in the container.
fn agents_of(ctx: &Ctx, name: &str, cid: &str) -> serde_json::Value {
    let mut out = serde_json::Map::new();
    let mut top: Option<String> = None;
    for a in agents_on(ctx, name) {
        let file = docker::exec_out(
            cid,
            &[
                "cat",
                &format!("/home/dev/.farmy-service/{}/agent.status", a.name),
            ],
        );
        let from_hooks = file.lines().next().and_then(|line| {
            let mut parts = line.split('\t');
            match (parts.next(), parts.next()) {
                (Some(state), since) if ["working", "waiting", "idle"].contains(&state) => {
                    Some(serde_json::json!({ "state": state, "since": since.map(str::trim), "source": "hooks" }))
                }
                _ => None,
            }
        });
        let entry = match from_hooks {
            Some(v) => v,
            None => {
                let top = top.get_or_insert_with(|| docker::out(&["top", cid]).unwrap_or_default());
                let p = a.process.as_str();
                let is_it = |w: &str| {
                    w == p
                        || w.ends_with(&format!("/{p}"))
                        || w.contains(&format!("/{p}/"))
                        || w.contains(&format!("/{p}-"))
                };
                let running = top
                    .lines()
                    .skip(1)
                    .any(|l| l.split_whitespace().skip(7).any(is_it));
                serde_json::json!({ "state": if running { "running" } else { "idle" }, "since": serde_json::Value::Null, "source": "process" })
            }
        };
        out.insert(a.name.clone(), entry);
    }
    serde_json::Value::Object(out)
}

/// `farmy agents`: the catalogue's entries and farmy.yml's own, one line each: name, on or off, the mode
/// in farmy.yml, how to log in without a browser.
pub(crate) fn agents(args: &[String]) -> R {
    if !args.is_empty() {
        return usage("usage: farmy agents");
    }
    let cfg = Config::load()?;
    let mut rows: Vec<(String, bool, String, String)> = vec![];
    for c in agents::catalogue_agents(&cfg.catalogue) {
        let own = cfg.agent(&c.name);
        let on = own.map(|a| a.mode != "off").unwrap_or(false);
        let mode = own.map(|a| a.mode.clone()).unwrap_or(c.mode);
        let login = own
            .and_then(|a| a.headless_login.clone())
            .or(c.headless_login)
            .unwrap_or_else(|| "-".into());
        rows.push((c.name, on, mode, login));
    }
    for a in &cfg.agents {
        if !rows.iter().any(|r| r.0 == a.name) {
            rows.push((
                a.name.clone(),
                a.mode != "off",
                a.mode.clone(),
                a.headless_login.clone().unwrap_or_else(|| "-".into()),
            ));
        }
    }
    if rows.is_empty() {
        println!("no agents: farmy's folder has no agents.yml and farmy.yml names none");
        return Ok(());
    }
    for (name, on, mode, login) in rows {
        println!(
            "{name:<10} {:<4} {mode:<13} {login}",
            if on { "on" } else { "off" }
        );
    }
    Ok(())
}

/// Everything `status --json` says, as one value.
fn snapshot(ctx: &Ctx) -> serde_json::Value {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let lan = ctx.settings.get("LAN_HOST").map(String::from);
    let mut services = vec![];
    for name in known_services() {
        let cid = docker::app_cid(&name);
        let state = if cid.is_some() { "running" } else { "stopped" };
        let def = booted_definition(&name).unwrap_or_default();
        let repo = match repo_of(ctx, &name, &def) {
            Ok(Some(r)) => serde_json::Value::String(r),
            Ok(None) => serde_json::Value::String("none".into()),
            Err(_) => serde_json::Value::Null,
        };
        let note = if docker::has_containers(&name) {
            drift(&name)
        } else {
            None
        };
        let toolbox = crate::version::toolbox(&name);
        let ports: Vec<serde_json::Value> = def
            .port_pairs(&name)
            .unwrap_or_default()
            .iter()
            .map(|p| {
                serde_json::json!({
                    "host": p.host,
                    "container": p.container.parse::<u32>().ok(),
                    "url": format!("http://localhost:{}", p.host),
                    "lan_url": lan.as_ref().map(|h| format!("http://{h}:{}", p.host)),
                    "listening": cid.as_ref().map(|c| listening(c, &p.container)),
                })
            })
            .collect();
        services.push(serde_json::json!({
            "name": name,
            "state": state,
            "block": def.block().map(block_text),
            "repo": repo,
            "note": note,
            "toolbox_outdated":toolbox.outdated(),
            "toolbox_version":toolbox.version,
            "commands": def.commands.keys().cloned().collect::<Vec<_>>(),
            "ports": ports,
            "containers": containers_of(&name),
            "agents": cid.as_ref().map(|c| agents_of(ctx, &name, c)),
            "runs": crate::factory::status_json(&name),
            "dotfiles": crate::home::status(&ctx.cfg, &name),
            "pipelines": crate::factory::pipelines_json(&name),
            "egress": crate::filter::status(ctx, &name, &def),
        }));
    }
    serde_json::json!({ "generated": unix_to_rfc3339(now), "folder": crate::folder::folder_json(), "lan_host": lan, "bind": if compose::lan_open(&ctx.settings) { "0.0.0.0" } else { "127.0.0.1" }, "egress": egress::status_json(&ctx.cfg), "services": services })
}

/// The snapshot for the TUI, which reads the folder itself.
pub(crate) fn snapshot_now() -> R<serde_json::Value> {
    let ctx = load_ctx()?;
    Ok(snapshot(&ctx))
}

pub(crate) fn states_summary() -> BTreeMap<String, String> {
    secrets::saved_states()
}

#[cfg(test)]
mod build_files_tests {
    use super::{Handed, Route, handed_over, reaches_over_ssh, repository_path};

    fn route(auth: &str, host: &str) -> Route {
        Route {
            name: "git-example".into(),
            secret: "GIT_KEY".into(),
            upstream: "-".into(),
            host: host.into(),
            ssh_user: "git".into(),
            ssh_port: None,
            auth: auth.into(),
            who: "-".into(),
            git: true,
            expose: None,
            placeholder: None,
            services: None,
            encoding: None,
        }
    }

    #[test]
    fn a_url_reaches_ssh_by_its_form_or_through_an_ssh_git_route() {
        let ssh = route("ssh", "git.example.com");
        let token = route("bearer", "git.example.com");
        for url in [
            "ssh://git@git.example.com/acme/toolkit.git",
            "git+ssh://git@git.example.com/acme/toolkit.git",
            "git@git.example.com:acme/toolkit.git",
        ] {
            assert!(reaches_over_ssh(url, &[]), "{url}");
        }
        let https = "https://git.example.com/acme/toolkit.git";
        assert!(reaches_over_ssh(https, &[&ssh]));
        assert!(!reaches_over_ssh(https, &[&token]));
        assert!(!reaches_over_ssh(https, &[]));
        assert!(!reaches_over_ssh(
            "https://other.example.com/acme/toolkit.git",
            &[&ssh]
        ));
    }

    #[test]
    fn the_files_the_git_container_hands_over_are_read_in_order() {
        let out = [
            &b"- 6\nFROM x"[..],
            b"missing\n",
            b"outside ../.env\n",
            b"x 3\n\x00\n!",
        ]
        .concat();
        let files = handed_over(&out, 4).unwrap();
        assert_eq!(
            files[0],
            Handed::File {
                executable: false,
                bytes: b"FROM x".to_vec()
            }
        );
        assert_eq!(files[1], Handed::Missing);
        assert_eq!(files[2], Handed::Outside("../.env".into()));
        assert_eq!(
            files[3],
            Handed::File {
                executable: true,
                bytes: b"\x00\n!".to_vec()
            }
        );
        assert!(handed_over(b"- 10\nshort", 1).is_none());
        assert!(handed_over(b"- 1\na", 2).is_none());
    }

    #[test]
    fn build_file_entries_are_relative_paths_inside_the_repository() {
        for entry in [
            "Dockerfile",
            "docker/app.Dockerfile",
            "./Gemfile.lock",
            "a..b",
        ] {
            assert!(repository_path(entry), "{entry}");
        }
        for entry in [
            "",
            "/home/dana/containers/.env",
            "../.env",
            "a/../../.env",
            "-x",
            "a\nb",
        ] {
            assert!(!repository_path(entry), "{entry:?}");
        }
    }
}
