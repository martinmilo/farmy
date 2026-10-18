//! The factory loop (FORMATS.md, "The factory"): an agent works on a run volume of its own until a separate
//! gate passes. A git container clones and commits, the agent's container has no git history, agent socket,
//! git route or shared login, a new read-only test container each iteration gives the only verdict, and only
//! a passed gate publishes its draft. A run's state lives in `.work/<name>/runs/<id>/`.
#![expect(
    clippy::print_stdout,
    reason = "the factory commands: stdout is what farmy says to its user"
)]
use crate::agents::{Agent, Headless};
use crate::commands::{self, Ctx};
use crate::model::{Definition, FactoryProfile, WORK, definition_path, duration_secs, farmy_home};
use crate::secrets::{self, Route};
use crate::{R, docker, refuse, usage, warn};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

include!("factory_gates.rs");
include!("factory_pipelines.rs");
include!("factory_notify.rs");

const USAGE: &str = "usage: farmy factory start <name> --task <file or text> [--profile <name>] [--from <id|branch>] [--wait] | list [<name>] | show <id> | log <id> [<iteration>] | cancel <id> | approve <id> | answer <id> <text|file> [--wait] | prune [--older-than <n>d|h|m]";

fn default_profile() -> String {
    "default".into()
}

#[derive(Serialize, Deserialize, Clone, Default)]
pub(crate) struct Commit {
    pub iteration: u32,
    pub sha: String,
}

#[derive(Serialize, Deserialize, Clone, Default)]
pub(crate) struct Verdict {
    pub iteration: u32,
    pub exit: i32,
    #[serde(default)]
    pub commands: Vec<CommandVerdict>,
}

#[derive(Serialize, Deserialize, Clone, Default, PartialEq, Eq, Debug)]
pub(crate) struct CommandVerdict {
    pub name: String,
    pub exit: i32,
}

#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(default)]
pub(crate) struct State {
    pub pipeline_id: Option<String>,
    pub pipeline_name: Option<String>,
    pub pipeline_step: Option<usize>,
    pub source_commit: Option<String>,
    pub gated_commit: Option<String>,
    pub approved_commit: Option<String>,
    pub approved_profile: Option<FactoryProfile>,
    pub approved_gate: Option<crate::model::GateOptions>,
    pub approval_valid: bool,
    pub red_reference_commit: Option<String>,
    pub compare_url: Option<String>,
    pub gate_summary: Option<String>,
    pub revision_of: Option<String>,
    pub superseded_by: Option<String>,
    pub answer: Option<String>,
    pub answering: bool,
    pub answering_for: Option<String>,
    pub review_answer: bool,
    pub review_base: Option<String>,
    pub publish_result: Option<String>,
    pub queued_order: u64,
    pub notification: Option<String>,
    pub forbidden_paths: Vec<String>,
    pub edits_dropped: bool,
    pub id: String,
    pub service: String,
    pub task: String,
    pub base: Option<String>,
    pub branch: String,
    pub phase: String,
    pub iteration: u32,
    pub max_iterations: u32,
    pub result: Option<String>,
    pub started: String,
    pub ended: Option<String>,
    #[serde(default)]
    pub commits: Vec<Commit>,
    #[serde(default)]
    pub verdicts: Vec<Verdict>,
    #[serde(default)]
    pub pid: u32,
    #[serde(default)]
    pub remote: bool,
    #[serde(default = "default_profile")]
    pub profile: String,
    #[serde(default)]
    pub from: Option<String>,
    #[serde(default)]
    pub question: Option<String>,
    #[serde(default)]
    pub head: Option<String>, // the exact commit gated, questioned, or approved
    #[serde(default)]
    pub profile_config: Option<FactoryProfile>,
    pub definition_config: Option<serde_yaml::Value>,
    #[serde(default)]
    pub context: String, // source gate evidence or the answered question, also used after detaching
}

#[expect(
    clippy::large_enum_variant,
    reason = "one Model per factory plan; boxing the Route would save nothing that matters"
)]
enum Model {
    Api(Route),
    Token(String),
}

/// What a service's factory: says, checked.
struct Plan {
    name: String,
    def: Definition,
    base: String,
    agent: Agent,
    headless: Headless,
    writes: Option<Vec<String>>,
    protects: Vec<String>, // hidden ones included
    hidden: Vec<String>,
    test: String,
    test_name: String,
    gate: Gate,
    review: bool,
    profile: String,
    config: FactoryProfile,
    definition_config: serde_yaml::Value,
    max: u32,
    timeout_secs: u64,
    model: Model,
    red_pattern: Option<regex::Regex>,
    red_exit_codes: Option<Vec<i32>>,
    setup: Option<(String, String)>,
    health_timeout: u64,
    gate_isolated: bool, // factory.gate.network: none
}

enum Gate {
    Green,
    RedFirst { name: String, command: String },
    Custom { name: String, command: String },
}

pub(crate) fn main(args: &[String]) -> R {
    let rest = if args.is_empty() { args } else { &args[1..] };
    match args.first().map(String::as_str).unwrap_or("") {
        "start" => start(rest),
        "pipeline" => pipeline_main(rest),
        "revise" => revise(rest),
        "resume" => resume_run(rest),
        "list" => list(rest),
        "show" => show(rest),
        "log" => log(rest),
        "cancel" => cancel(rest),
        "approve" => approve(rest),
        "answer" => answer(rest),
        "prune" => prune(rest),
        "run" => run_detached(rest),
        _ => usage(USAGE),
    }
}

fn now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    commands::unix_to_rfc3339(secs)
}

fn run_dir(name: &str, id: &str) -> PathBuf {
    PathBuf::from(WORK).join(name).join("runs").join(id)
}

fn save(st: &State) {
    let dir = run_dir(&st.service, &st.id);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "kept as before: a failed write loses this state silently (flagged in the sweep notes)"
    )]
    let _ = std::fs::create_dir_all(&dir);
    // written beside and renamed: a reader never sees half a file
    let tmp = dir.join(format!(".state.json.{}", std::process::id()));
    if std::fs::write(&tmp, serde_json::to_string_pretty(st).unwrap_or_default()).is_ok() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "kept as before: a failed write loses this state silently (flagged in the sweep notes)"
        )]
        let _ = std::fs::rename(&tmp, dir.join("state.json"));
    }
}

/// A run by id, as it is on disk (no interrupted check): the controller reading its own run.
fn locate(id: &str) -> Option<State> {
    for _ in 0..40 {
        if let Ok(services) = std::fs::read_dir(WORK) {
            for s in services.flatten() {
                if let Some(st) = load(&s.file_name().to_string_lossy(), id) {
                    return Some(st);
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    None
}

fn load(name: &str, id: &str) -> Option<State> {
    serde_json::from_str(&std::fs::read_to_string(run_dir(name, id).join("state.json")).ok()?).ok()
}

/// Every run of a service (or of all), oldest first, with a gone controller marked interrupted.
pub(crate) fn runs(service: Option<&str>) -> Vec<State> {
    let mut out = vec![];
    let Ok(services) = std::fs::read_dir(WORK) else {
        return out;
    };
    for s in services.flatten() {
        let name = s.file_name().to_string_lossy().to_string();
        if service.map(|x| x != name).unwrap_or(false) {
            continue;
        }
        let Ok(ids) = std::fs::read_dir(s.path().join("runs")) else {
            continue;
        };
        for i in ids.flatten() {
            if let Some(st) = load(&name, &i.file_name().to_string_lossy()) {
                out.push(refresh(st));
            }
        }
    }
    out.sort_by(|a, b| a.started.cmp(&b.started).then(a.id.cmp(&b.id)));
    out
}

fn find(id: &str) -> R<State> {
    runs(None).into_iter().find(|s| s.id == id).ok_or_else(|| {
        crate::Fail::Usage(format!(
            "no factory run {id} — farmy factory list shows the runs"
        ))
    })
}

/// A run in progress whose controller is gone reads interrupted. A pipeline's runs are
/// left to the pipeline's controller, which relaunches them.
fn refresh(mut st: State) -> State {
    if st.phase == "done" || st.pipeline_id.is_some() || run_held(&st) {
        return st;
    }
    // Gone: held now, so that no one relaunches it while it is cleaned up.
    let Ok(Some(_gone)) = crate::locking::Lock::try_take(&run_lock(&st)) else {
        return st;
    };
    match load(&st.service, &st.id) {
        Some(current) if current.phase == "done" => current,
        current => {
            st = current.unwrap_or(st);
            cleanup_abandoned(&st);
            st.result = Some("interrupted".into());
            st.phase = "done".into();
            st.ended = Some(now());
            save(&st);
            st
        }
    }
}

/// A run's controller.lock: held, from before its state is first saved, by whoever
/// launches it, then by its own process until that process ends.
fn run_lock(st: &State) -> PathBuf {
    run_dir(&st.service, &st.id).join("controller.lock")
}

/// Whether some process holds the run (its controller.lock): its controller, or whoever
/// is launching it. Free means the run's process is gone.
fn run_held(st: &State) -> bool {
    crate::locking::Lock::held(&run_lock(st))
}

fn new_id() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let t = commands::unix_to_rfc3339(u64::try_from(secs / 1_000_000_000).unwrap_or(u64::MAX)); // 2026-10-15T09:15:00Z
    let digits: String = t.chars().filter(|c| c.is_ascii_digit()).collect();
    #[expect(
        clippy::cast_possible_truncation,
        reason = "only the low 64 bits of the nanoseconds are mixed into the id"
    )]
    let mix = (secs as u64) ^ (u64::from(std::process::id()) << 16);
    format!(
        "{}-{}-{:04x}",
        &digits[0..8],
        &digits[8..14],
        (mix ^ (mix >> 20)) & 0xffff
    )
}

fn plan(ctx: &Ctx, name: &str, selected: Option<&str>, saved: Option<&FactoryProfile>) -> R<Plan> {
    plan_with_definition(ctx, name, selected, saved, None)
}

fn saved_plan(ctx: &Ctx, st: &State) -> R<Plan> {
    plan_with_definition(
        ctx,
        &st.service,
        Some(&st.profile),
        st.profile_config.as_ref(),
        st.definition_config.as_ref(),
    )
}

fn plan_with_definition(
    ctx: &Ctx,
    name: &str,
    selected: Option<&str>,
    saved: Option<&FactoryProfile>,
    definition: Option<&serde_yaml::Value>,
) -> R<Plan> {
    let path = definition_path(name);
    let (def, definition_config) = if let Some(value) = definition {
        (
            serde_yaml::from_value(value.clone())
                .map_err(|e| format!("saved definition for {name}: {e}"))?,
            value.clone(),
        )
    } else {
        (
            Definition::load(name)?,
            serde_yaml::from_str(&std::fs::read_to_string(&path)?)
                .map_err(|e| format!("{path}: {e}"))?,
        )
    };
    let (profile, f) = if let Some(saved) = saved {
        (selected.unwrap_or("default").to_string(), saved.clone())
    } else {
        let Some(factory) = def.factory.as_ref() else {
            return refuse(format!(
                "{path} has no factory: — the factory loop needs one (base, agent, test; FORMATS.md, The factory)"
            ));
        };
        let available = factory
            .profiles
            .keys()
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        let chosen = selected
            .map(str::to_string)
            .or_else(|| {
                if factory.profiles.contains_key("default") {
                    Some("default".into())
                } else if factory.profiles.len() == 1 {
                    factory.profiles.keys().next().cloned()
                } else {
                    None
                }
            })
            .ok_or_else(|| {
                crate::Fail::Refuse(format!(
                    "{path}: choose --profile; available profiles: {available}"
                ))
            })?;
        let config = factory.profiles.get(&chosen).cloned().ok_or_else(|| {
            crate::Fail::Refuse(format!(
                "{path}: unknown profile '{chosen}'; available profiles: {available}"
            ))
        })?;
        (chosen, config)
    };
    let base = f.base.clone().filter(|b| !b.is_empty()).ok_or_else(|| {
        crate::Fail::Refuse(format!(
            "{path}: factory.base is missing — the branch runs start from"
        ))
    })?;
    let test_name = f.test.clone().ok_or_else(|| {
        crate::Fail::Refuse(format!(
            "{path}: factory.test is missing — a name under commands:"
        ))
    })?;
    let Some(test) = def.commands.get(&test_name).cloned() else {
        return refuse(format!(
            "{path}: factory.test is '{test_name}', which is not under commands: ({})",
            def.commands.keys().cloned().collect::<Vec<_>>().join(", ")
        ));
    };
    let agent_name = f.agent.clone().ok_or_else(|| {
        crate::Fail::Refuse(format!(
            "{path}: factory.agent is missing — an agent with a headless field"
        ))
    })?;
    let agent = match ctx.cfg.agent(&agent_name) {
        Some(a) => a.clone(),
        None => match ctx.cfg.catalogue.iter().find(|(n, _)| *n == agent_name) {
            Some((_, e)) => Agent::from_entry(&agent_name, e.clone(), "agents.yml")?,
            None => {
                return refuse(format!(
                    "{path}: factory.agent '{agent_name}' is neither in the catalogue nor under agents: in farmy.yml"
                ));
            }
        },
    };
    crate::filter::expand(&agent.api_hosts)?;
    let Some(headless) = agent.headless.clone() else {
        return refuse(format!(
            "{path}: factory.agent '{agent_name}' has no headless: (how it runs unattended) — give it in farmy.yml under agents.{agent_name}.headless"
        ));
    };
    let route = agent.api.as_ref().and_then(|api| {
        secrets::granted(&ctx.routes, name)
            .into_iter()
            .find(|r| !r.is_ssh() && r.upstream == api.upstream.trim_end_matches('/'))
            .cloned()
    });
    let model = match (f.mode.as_deref(), route, &agent.token_env) {
        (None | Some("api-key"), Some(r), _) => Model::Api(r),
        (None | Some("subscription"), _, Some(t)) => Model::Token(t.clone()),
        (Some(other), _, _) if !["api-key", "subscription"].contains(&other) => {
            return refuse(format!(
                "{path}: factory.{profile}.mode must be api-key or subscription, not '{other}'"
            ));
        }
        (mode, _, _) => {
            let api = agent
                .api
                .as_ref()
                .map(|a| {
                    format!(
                        "no usable route under keys: has its api upstream {}",
                        a.upstream
                    )
                })
                .unwrap_or_else(|| "its entry has no api".into());
            return refuse(format!(
                "{path}: factory.agent '{agent_name}' has no way to its model in {} mode: check api routes and token_env ({api})",
                mode.unwrap_or("automatic")
            ));
        }
    };
    let gate = match f.gate.as_ref().map(|g| g.kind()).unwrap_or("green") {
        "green" => Gate::Green,
        "red_first" => {
            let check = f.check.as_ref().ok_or_else(|| {
                crate::Fail::Refuse(format!(
                    "{path}: red_first requires check: naming a command under commands:"
                ))
            })?;
            let command = def.commands.get(check).cloned().ok_or_else(|| {
                crate::Fail::Refuse(format!("{path}: check '{check}' is not under commands:"))
            })?;
            Gate::RedFirst {
                name: check.clone(),
                command,
            }
        }
        other => {
            let command = def.commands.get(other).cloned().ok_or_else(|| {
                crate::Fail::Refuse(format!(
                    "{path}: gate '{other}' is not green, red_first, or a command under commands:"
                ))
            })?;
            Gate::Custom {
                name: other.into(),
                command,
            }
        }
    };
    let review = f.review.unwrap_or(matches!(gate, Gate::RedFirst { .. }));
    let timeout_text = f.iteration_timeout.clone().unwrap_or_else(|| "30m".into());
    let Some(timeout_secs) = duration_secs(&timeout_text) else {
        return refuse(format!(
            "{path}: factory.iteration_timeout must be a number with s, m or h (30m), not '{timeout_text}'"
        ));
    };
    let gate_isolated = match f.gate.as_ref().and_then(|g| g.network()) {
        None | Some("sidecars") => false,
        Some("none") => true,
        Some(other) => {
            return refuse(format!(
                "{path}: factory.gate.network must be none (or sidecars, the default), not '{other}'"
            ));
        }
    };
    let opts = f.gate.as_ref().map(|g| g.options()).unwrap_or_default();
    let red_pattern = opts
        .red_pattern
        .as_ref()
        .map(|pattern| {
            if pattern.is_empty() {
                return refuse(format!("{path}: red_pattern must be nonempty"));
            }
            regex::Regex::new(pattern)
                .map_err(|e| format!("{path}: red_pattern is invalid: {e}").into())
        })
        .transpose()?;
    if opts
        .red_exit_codes
        .as_ref()
        .map(|codes| codes.is_empty() || codes.iter().any(|c| *c <= 0 || *c > 255))
        .unwrap_or(false)
    {
        return refuse(format!(
            "{path}: red_exit_codes must be a nonempty list of nonzero test exits"
        ));
    }
    let setup = f
        .gate_setup
        .as_ref()
        .map(|name| {
            def.commands
                .get(name)
                .cloned()
                .map(|c| (name.clone(), c))
                .ok_or_else(|| {
                    crate::Fail::Refuse(format!(
                        "{path}: gate_setup command {name} is not under commands:"
                    ))
                })
        })
        .transpose()?;
    let health_timeout = duration_secs(opts.health_timeout.as_deref().unwrap_or("30s"))
        .filter(|n| *n > 0)
        .ok_or_else(|| format!("{path}: gate.health_timeout must be a positive duration"))?;
    if !gate_isolated {
        validate_sidecars(&def)?;
    }
    let mut protects = f.protects.clone();
    for h in &f.hidden {
        if !protects.contains(h) {
            protects.push(h.clone());
        }
    }
    Ok(Plan {
        name: name.to_string(),
        base,
        headless,
        writes: f.writes.clone().filter(|w| !w.is_empty()),
        protects,
        hidden: f.hidden.clone(),
        test,
        test_name,
        gate,
        review,
        profile,
        config: f.clone(),
        definition_config,
        max: f.max_iterations.unwrap_or(5).max(1),
        timeout_secs,
        model,
        gate_isolated,
        red_pattern,
        red_exit_codes: opts.red_exit_codes,
        setup,
        health_timeout,
        agent,
        def,
    })
}

fn clean_path(p: &str) -> String {
    p.trim()
        .trim_start_matches("./")
        .trim_end_matches('/')
        .to_string()
}

fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

// ── the containers ────────────────────────────────────────────────────────────────────────────

struct Run<'a> {
    ctx: &'a Ctx,
    p: &'a Plan,
    id: String,
    git_n: u32,
    made: Vec<String>, // the networks this run made, removed at its end
    broker: bool,      // the run's broker was started
    egress_gate: bool,
}

impl Run<'_> {
    fn volume(&self) -> String {
        format!("{}-run-{}", self.p.name, self.id)
    }
    fn network(&self) -> String {
        self.volume()
    }
    fn keys(&self) -> String {
        format!("{}-run-{}-keys", self.p.name, self.id)
    }
    fn gate_network(&self) -> String {
        format!("{}-run-{}-gate", self.p.name, self.id)
    }

    /// The service's fragment containers that run, with their compose service names.
    /// The gate's internal network, the service's sidecars on it by their names (nothing with gate.network: none).
    /// A network of the run's own: internal (no way out) or with a way out; remembered, so the end removes it.
    fn make_network(&mut self, net: &str, internal: bool) -> bool {
        if self.made.iter().any(|n| n == net) {
            return true;
        }
        let label = format!("farmy.run={}", self.id);
        let mut args = vec!["network", "create", "--label", &label];
        if internal {
            args.push("--internal");
        }
        args.push(net);
        let made = docker::quiet(&args);
        if made {
            self.made.push(net.to_string());
        }
        made
    }

    /// Everything the run made, and only that: the broker, the gate's sidecars off its network, the networks.
    fn cleanup(&self) {
        if self.egress_gate {
            crate::filter::retain(&self.p.name, &self.id, &self.filter_name());
            let _ = docker::ok(&["rm", "-f", &self.filter_name()]);
        }
        if self.broker {
            let _ = docker::ok(&["rm", "-f", &self.keys()]);
        }
        self.close_gate();
        for net in &self.made {
            let _ = docker::ok(&["network", "rm", net]);
        }
    }

    fn image(&self) -> String {
        format!("farmy/{}:dev", self.p.name)
    }
    fn labels(&self, role: &str, iteration: Option<u32>) -> Vec<String> {
        let mut l = vec![
            "--label".into(),
            format!("farmy.run={}", self.id),
            "--label".into(),
            format!("farmy.service={}", self.p.name),
        ];
        if !role.is_empty() {
            l.extend(["--label".into(), format!("farmy.role={role}")]);
        }
        if let Some(i) = iteration {
            l.extend(["--label".into(), format!("farmy.iteration={i}")]);
        }
        l
    }

    /// A git container: the run volume at /workspace, the service's network, its agent socket for an SSH
    /// route; `src`: the checkout read-only at /src. Returns the exit code, stdout and stderr.
    /// Always as the checkout's owner, the dev user: git accepts the repository, and what it writes is dev's.
    fn git(
        &mut self,
        script: &str,
        src: bool,
        extra_env: &[(&str, &str)],
    ) -> (i32, String, String) {
        let source = src.then(|| format!("{}-src", self.p.name));
        self.git_mounted(script, source.as_deref(), extra_env)
    }

    fn git_source(
        &mut self,
        script: &str,
        source: Option<&str>,
        extra_env: &[(&str, &str)],
    ) -> (i32, String, String) {
        let default = format!("{}-src", self.p.name);
        self.git_mounted(script, Some(source.unwrap_or(&default)), extra_env)
    }

    fn git_mounted(
        &mut self,
        script: &str,
        source: Option<&str>,
        extra_env: &[(&str, &str)],
    ) -> (i32, String, String) {
        self.git_n += 1;
        let mut request = crate::git_container::Request::new(&self.p.name, "factory");
        request.name = format!("{}-run-{}-git-{}", self.p.name, self.id, self.git_n);
        request.labels.push(("farmy.run".into(), self.id.clone()));
        request.mounts.push(format!("{}:/workspace", self.volume()));
        if let Some(source) = source {
            request.mounts.push(format!("{source}:/src:ro"));
        }
        request.env.extend(
            extra_env
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string())),
        );
        crate::git_container::run(self.ctx, request, script)
    }

    /// The run's broker: on the run's internal network (the agent's only one) as `keys`, and joined to the
    /// network with a way out, and with egress to farmy, where its proxy resolves.
    fn start_broker(&mut self, route: &Route, value: Option<&String>) {
        let internal = self.network();
        self.make_network(&internal, true);
        docker::ensure_network("farmy");
        let mut args: Vec<String> = vec!["run".into(), "-d".into(), "--name".into(), self.keys()];
        args.extend(self.labels("", None));
        args.extend([
            "--network".into(),
            self.network(),
            "--network-alias".into(),
            "keys".into(),
            "--init".into(),
        ]);
        args.extend([
            "-u".into(),
            "1001:1001".into(),
            "--read-only".into(),
            "--cap-drop".into(),
            "ALL".into(),
            "--security-opt".into(),
            "no-new-privileges:true".into(),
        ]);
        args.extend([
            "--tmpfs".into(),
            "/run:mode=1777".into(),
            "--tmpfs".into(),
            "/tmp:mode=1777".into(),
        ]);
        let mut env = vec![
            ("FARMY_ROUTES".to_string(), route.name.clone()),
            (
                format!(
                    "FARMY_ROUTE_{}",
                    route.name.to_uppercase().replace('-', "_")
                ),
                route.spec(),
            ),
            ("FARMY_PUBLIC".to_string(), "http://keys:9181".to_string()),
        ];
        env.extend(crate::egress::proxy_env(
            &self.ctx.cfg,
            &["keys".to_string()],
        ));
        for (k, v) in env {
            args.extend(["-e".into(), format!("{k}={v}")]);
        }
        args.push("farmy-keys:local".into());
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.broker = docker::quiet(&refs);
        if !self.broker {
            return;
        }
        let _ = docker::quiet(&["network", "connect", "farmy", &self.keys()]);
        if let Some(v) = value {
            let mut secrets_map = serde_json::Map::new();
            secrets_map.insert(route.secret.clone(), serde_json::Value::String(v.clone()));
            let payload = serde_json::json!({ "version": 1, "secrets": secrets_map }).to_string();
            for _ in 0..20 {
                if docker::exec_stdin(&self.keys(), &["farmy-keys", "load"], &payload) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        }
    }

    fn filter_name(&self) -> String {
        format!("{}-run-{}-egress-gate", self.p.name, self.id)
    }

    fn open_filter(&mut self, iteration: u32) -> R {
        if !self.egress_gate {
            crate::filter::ensure_image()?;
            let network = self.network();
            if !self.make_network(&network, true) {
                return refuse("the agent's internal network could not be created");
            }
            docker::ensure_network("farmy");
            let mut args = vec![
                "run".into(),
                "-d".into(),
                "--name".into(),
                self.filter_name(),
            ];
            args.extend(self.labels("egress-gate", None));
            args.extend([
                "--network".into(),
                network,
                "--network-alias".into(),
                "egress-gate".into(),
                "--init".into(),
                "--read-only".into(),
                "--cap-drop".into(),
                "ALL".into(),
                "--security-opt".into(),
                "no-new-privileges:true".into(),
                "--tmpfs".into(),
                "/run:mode=1777".into(),
                "-u".into(),
                "1001:1001".into(),
                "farmy-gate:local".into(),
            ]);
            self.egress_gate = docker::quiet(&args.iter().map(String::as_str).collect::<Vec<_>>());
            if !self.egress_gate
                || !docker::quiet(&["network", "connect", "farmy", &self.filter_name()])
            {
                return refuse("the agent's egress gate could not start");
            }
        }
        let client = format!("{}-run-{}-agent-{iteration}", self.p.name, self.id);
        crate::filter::load(
            &self.filter_name(),
            &self.ctx.cfg,
            &client,
            &self.p.name,
            &crate::filter::expand(&self.p.agent.api_hosts)?,
            "strict",
        )
    }

    /// The agent, headlessly: returns its exit code (124 when stopped at the limit) and its output.
    fn agent(&self, i: u32, prompt: &str, model_env: &[(String, String)]) -> (i32, String) {
        let p = self.p;
        let mut args: Vec<String> = vec![
            "run".into(),
            "--rm".into(),
            "-i".into(),
            "--name".into(),
            format!("{}-run-{}-agent-{i}", p.name, self.id),
        ];
        args.extend(self.labels("agent", Some(i)));
        args.extend(["-u".into(), "dev".into()]);
        // Both login modes stay internal and use the run's filtering proxy.
        args.extend(["--network".into(), self.network()]);
        args.extend(["-v".into(), format!("{}:/workspace", self.volume())]);
        args.extend(["--tmpfs".into(), "/workspace/.git:ro".into()]);
        for h in &p.hidden {
            args.extend(["--tmpfs".into(), format!("/workspace/{}:ro", clean_path(h))]);
        }
        for (m, at) in &p.def.mounts {
            args.extend(["-v".into(), format!("{}-{m}:{at}", p.name)]);
        }
        let mut env: Vec<(String, String)> = model_env.to_vec();
        for (k, v) in &p.agent.env {
            env.push((k.clone(), v.clone()));
        }
        env.extend(crate::filter::proxy_env("egress-gate", &["keys".into()]));
        env.push((
            "FARMY_LOGIN_DIR".into(),
            "/home/dev/.farmy-service/logins".into(),
        ));
        for (k, v) in env {
            args.extend(["-e".into(), format!("{k}={v}")]);
        }
        let by_stdin = p.headless.prompt == "stdin";
        let script = if by_stdin {
            p.headless.command.clone()
        } else {
            format!("{} \"$1\"", p.headless.command)
        };
        args.extend([
            "-w".into(),
            "/workspace".into(),
            "--entrypoint".into(),
            "timeout".into(),
            self.image(),
            p.timeout_secs.to_string(),
            "sh".into(),
            "-c".into(),
            script,
        ]);
        if !by_stdin {
            args.extend(["farmy-agent".into(), prompt.to_string()]);
        }
        let child = Command::new("docker")
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        let Ok(mut child) = child else {
            return (125, "docker could not be run".into());
        };
        if let Some(mut stdin) = child.stdin.take()
            && by_stdin
        {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the agent's exit status and output say whether it got the prompt"
            )]
            let _ = stdin.write_all(prompt.as_bytes());
        }
        match child.wait_with_output() {
            Ok(o) => (
                o.status.code().unwrap_or(1),
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                ),
            ),
            Err(e) => (1, e.to_string()),
        }
    }

    /// The gate: a new test container, the run volume read-only, a scratch tmpfs, no network.
    fn gate(&mut self, i: u32, changed: bool) -> GateReport {
        if let Err(error) = self.open_gate() {
            return GateReport {
                exit: 125,
                log: error.to_string(),
                commands: vec![],
                failed_to_run: true,
            };
        }
        let p = self.p;
        let mut args: Vec<String> = vec![
            "run".into(),
            "--rm".into(),
            "--name".into(),
            format!("{}-run-{}-test-{i}", p.name, self.id),
        ];
        args.extend(self.labels("test", Some(i)));
        let network = if p.gate_isolated {
            "none".to_string()
        } else {
            self.gate_network()
        };
        args.extend(["-u".into(), "dev".into(), "--network".into(), network]);
        args.extend(["-v".into(), format!("{}:/workspace:ro", self.volume())]);
        for (m, at) in &p.def.mounts {
            args.extend(["-v".into(), format!("{}-{m}:{at}:ro", p.name)]);
        }
        // the commit, exported into the scratch area: the suite may write into its tree, and none of it lasts
        let into = match p.def.workdir_clean() {
            Some(w) => format!("/scratch/tree/{}", w.trim_start_matches('/')),
            None => "/scratch/tree".to_string(),
        };
        let mut script = format!(
            "set -e\nmkdir -p /scratch/tree /scratch/home /scratch/tmp\ngit -C /workspace archive HEAD | tar -x -C /scratch/tree\ncd {}\nexport HOME=/scratch/home TMPDIR=/scratch/tmp\nset +e\n",
            sh_quote(&into)
        );
        let mut commands = vec![];
        if let Some((name, command)) = &p.setup {
            commands.push(("setup", name.as_str(), command.as_str()));
        }
        if let Gate::RedFirst { name, command } = &p.gate {
            commands.push(("check", name.as_str(), command.as_str()));
        }
        commands.push(("test", p.test_name.as_str(), p.test.as_str()));
        if let Gate::Custom { name, command } = &p.gate {
            commands.push(("gate", name.as_str(), command.as_str()));
        }
        let marker = format!("farmy-command-{}-{i}", self.id);
        for (n, (kind, name, command)) in commands.iter().enumerate() {
            let env_name = format!("FARMY_GATE_COMMAND_{n}");
            args.extend(["-e".into(), format!("{env_name}={command}")]);
            script.push_str(&format!("printf '%s\\n' {}\nsh -c \"${env_name}\" >/scratch/output 2>&1\ncode=$?\nif [ -s /scratch/output ]; then cat /scratch/output; else printf '(no output)\\n'; fi\nprintf '\\n%s %s\\n' {} \"$code\"\n", sh_quote(&format!("== {kind}: {name} ==")), sh_quote(&format!("{marker} {n}"))));
            if *kind == "setup" {
                script.push_str("[ \"$code\" -eq 0 ] || exit 0\n");
            }
        }
        script.push_str("exit 0\n");
        args.extend([
            "--tmpfs".into(),
            "/scratch:exec".into(),
            "-e".into(),
            format!("FARMY_TEST={}", p.test),
        ]);
        args.extend([
            "-w".into(),
            "/workspace".into(),
            "--entrypoint".into(),
            "sh".into(),
            self.image(),
            "-c".into(),
            script,
        ]);
        let (code, output) = match Command::new("docker")
            .args(&args)
            .stdin(Stdio::null())
            .output()
        {
            Ok(o) => (
                o.status.code().unwrap_or(125),
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                ),
            ),
            Err(e) => (125, e.to_string()),
        };
        let mut verdicts = vec![];
        let mut log = String::new();
        let mut test_output = String::new();
        let mut in_test = false;
        for line in output.lines() {
            if let Some(rest) = line.strip_prefix(&format!("{marker} ")) {
                let mut words = rest.split_whitespace();
                if let (Some(n), Some(exit)) = (
                    words.next().and_then(|s| s.parse::<usize>().ok()),
                    words.next().and_then(|s| s.parse::<i32>().ok()),
                ) && let Some((_, name, _)) = commands.get(n)
                {
                    in_test = false;
                    verdicts.push(CommandVerdict {
                        name: (*name).into(),
                        exit,
                    });
                    log.push_str(&format!("exit {exit}\n"));
                    continue;
                }
            }
            if line == format!("== test: {} ==", p.test_name) {
                in_test = true;
            } else if in_test {
                test_output.push_str(line);
                test_output.push('\n');
            }
            log.push_str(line);
            log.push('\n');
        }
        self.close_gate();
        let setup_count = usize::from(p.setup.is_some());
        let setup_failed =
            setup_count == 1 && verdicts.first().map(|v| v.exit != 0).unwrap_or(true);
        let failed_to_run = setup_failed
            || code != 0
            || verdicts.len() != commands.len()
            || verdicts.iter().any(|v| matches!(v.exit, 125..=127));
        let passed = !failed_to_run
            && match p.gate {
                Gate::Green => verdicts[setup_count].exit == 0,
                Gate::RedFirst { .. } => {
                    changed
                        && verdicts[setup_count].exit == 0
                        && verdicts[setup_count + 1].exit != 0
                        && p.red_pattern
                            .as_ref()
                            .map(|r| r.is_match(&test_output))
                            .unwrap_or(true)
                        && p.red_exit_codes
                            .as_ref()
                            .map(|codes| codes.contains(&verdicts[setup_count + 1].exit))
                            .unwrap_or(true)
                }
                Gate::Custom { .. } => verdicts.last().map(|v| v.exit == 0).unwrap_or(false),
            };
        let exit = if failed_to_run {
            125
        } else if passed {
            0
        } else {
            verdicts
                .iter()
                .rev()
                .find(|v| v.exit != 0)
                .map(|v| v.exit)
                .unwrap_or(1)
        };
        GateReport {
            exit,
            log,
            commands: verdicts,
            failed_to_run,
        }
    }
}

struct GateReport {
    exit: i32,
    log: String,
    commands: Vec<CommandVerdict>,
    failed_to_run: bool,
}

fn prompt_for(task: &str, i: u32, max: u32, last: Option<(i32, &str)>) -> String {
    let template = std::fs::read_to_string("factory/prompt.md")
        .or_else(|_| std::fs::read_to_string(farmy_home().join("factory-prompt.md")))
        .unwrap_or_else(|_| "{{TASK}}\n\nIteration {{ITERATION}}.\n\n{{TEST_OUTPUT}}\n".into());
    let output = match last {
        None => {
            "No test has run yet: a separate run of the tests decides after you finish.".to_string()
        }
        Some((code, text)) => {
            let lines: Vec<&str> = text.lines().collect();
            let tail = lines[lines.len().saturating_sub(200)..].join("\n");
            format!("The tests ended with exit {code}; the last lines of their output:\n\n{tail}")
        }
    };
    let prompt = template
        .replace("{{TASK}}", task)
        .replace("{{ITERATION}}", &format!("{i} of {max}"))
        .replace("{{TEST_OUTPUT}}", &output);
    format!(
        "{prompt}\n\nIf you need a human decision, write your question to .farmy/question.md and stop. You may write that file even outside the permitted writes paths. Farmy preserves your other permitted changes and asks the human; it never commits the question file.\n"
    )
}

fn marker(out: &str, key: &str) -> Option<String> {
    out.lines().rev().find_map(|l| {
        l.strip_prefix(&format!("{key} "))
            .map(|v| v.trim().to_string())
    })
}

// ── the commands ──────────────────────────────────────────────────────────────────────────────

fn start(args: &[String]) -> R {
    let mut name = None;
    let mut task = None;
    let mut profile = None;
    let mut from = None;
    let mut wait = false;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--task" => task = Some(required_value(&mut it, a)?),
            "--profile" => profile = Some(required_value(&mut it, a)?),
            "--from" => from = Some(required_value(&mut it, a)?),
            "--wait" => wait = true,
            f if f.starts_with('-') => return refuse(format!("unknown flag '{f}' — {USAGE}")),
            other if name.is_none() => name = Some(other.to_string()),
            other => return refuse(format!("unexpected '{other}' — {USAGE}")),
        }
    }
    let Some(name) = name else {
        return refuse(USAGE);
    };
    let Some(task) = task.filter(|t| !t.trim().is_empty()) else {
        return refuse("farmy factory start needs --task <file or text>: what the agent is to do");
    };
    let ctx = commands::load_ctx()?;
    commands::check_services(&ctx, std::slice::from_ref(&name), false)
        .map_err(|e| crate::Fail::Refuse(e.to_string()))?;
    let p = plan(&ctx, &name, profile.as_deref(), None)?;
    let task = read_text(task)?;
    let source = from
        .as_deref()
        .map(|f| source_run(&name, f))
        .transpose()?
        .flatten();
    let context = source.as_ref().map(source_evidence).unwrap_or_default();
    launch(&ctx, &p, task, from, source.as_ref(), false, context, wait)
}

fn required_value<'a>(it: &mut impl Iterator<Item = &'a String>, flag: &str) -> R<String> {
    it.next()
        .filter(|v| !v.starts_with("--") && !v.trim().is_empty())
        .cloned()
        .ok_or_else(|| crate::Fail::Refuse(format!("{flag} needs a value — {USAGE}")))
}

fn read_text(text: String) -> R<String> {
    if Path::new(&text).is_file() {
        Ok(std::fs::read_to_string(&text)?)
    } else {
        Ok(text)
    }
}

fn source_run(service: &str, source: &str) -> R<Option<State>> {
    let branch = source
        .strip_prefix("refs/heads/")
        .or_else(|| source.strip_prefix("origin/"))
        .unwrap_or(source);
    let found = runs(None)
        .into_iter()
        .rev()
        .find(|st| st.id == source || st.branch == branch);
    if let Some(st) = &found {
        if st.service != service {
            return refuse(format!(
                "source run {} belongs to {}, not {service}",
                st.id, st.service
            ));
        }
        if st.result.as_deref() != Some("green")
            || (st.superseded_by.is_some() && !st.approval_valid)
        {
            return refuse(format!(
                "source run {} is {}; a source must be green, and awaiting_review needs farmy factory approve {}",
                st.id,
                st.result.as_deref().unwrap_or(&st.phase),
                st.id
            ));
        }
    }
    Ok(found)
}

fn source_evidence(st: &State) -> String {
    let log = (1..=st.iteration)
        .rev()
        .find_map(|i| {
            std::fs::read_to_string(
                run_dir(&st.service, &st.id).join(format!("iteration-{i}.test.log")),
            )
            .ok()
        })
        .unwrap_or_else(|| "(no gate output)".into());
    let codes = st
        .verdicts
        .last()
        .map(|v| {
            if v.commands.is_empty() {
                format!("exit {}", v.exit)
            } else {
                v.commands
                    .iter()
                    .map(|c| format!("{} exit {}", c.name, c.exit))
                    .collect::<Vec<_>>()
                    .join("; ")
            }
        })
        .unwrap_or_else(|| "no gate".into());
    format!("Previous run {} gate evidence ({codes}):\n{log}", st.id)
}

#[expect(
    clippy::too_many_arguments,
    reason = "two callers, each passing its own mix; a parameter struct would only rename these"
)]
fn launch(
    ctx: &Ctx,
    p: &Plan,
    task: String,
    from: Option<String>,
    source: Option<&State>,
    answering: bool,
    context: String,
    wait: bool,
) -> R {
    commands::need_docker()?;
    if docker::app_cid(&p.name).is_none() {
        return refuse(format!(
            "{} is not running — farmy start {} first",
            p.name, p.name
        ));
    }
    let mut st = make_state(p, task, from, source, answering, context);
    let controller = crate::locking::Lock::take(&run_lock(&st))?;
    save(&st);
    if wait {
        let result = execute(ctx, p, st.clone(), &controller);
        if result.is_err() && st.base.is_none() {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "removing the failed launch's state; an absent file is fine"
            )]
            let _ = std::fs::remove_file(run_dir(&st.service, &st.id).join("state.json"));
        }
        return wait_result("run", &st.id, &result?);
    }
    spawn_run(&mut st, controller)?;
    println!(
        "run {} started — farmy factory show {}; branch {}",
        st.id, st.id, st.branch
    );
    Ok(())
}
fn make_state(
    p: &Plan,
    task: String,
    from: Option<String>,
    source: Option<&State>,
    answering: bool,
    context: String,
) -> State {
    let id = new_id();
    State {
        id: id.clone(),
        service: p.name.clone(),
        task,
        branch: format!("farmy/{}/{id}", p.name),
        phase: "queued".into(),
        max_iterations: p.max,
        started: now(),
        pid: std::process::id(),
        profile: p.profile.clone(),
        profile_config: Some(p.config.clone()),
        definition_config: Some(p.definition_config.clone()),
        from,
        context,
        source_commit: source.and_then(gated_head),
        answering,
        queued_order: u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
        )
        .unwrap_or(u64::MAX),
        gate_summary: Some(
            match p.gate {
                Gate::RedFirst { .. } if p.red_pattern.is_none() => "red (unverified)",
                Gate::RedFirst { .. } => "red",
                Gate::Green => "green",
                Gate::Custom { .. } => "custom",
            }
            .into(),
        ),
        ..Default::default()
    }
}
fn wait_result(kind: &str, id: &str, result: &str) -> R {
    let show = format!(
        "farmy factory {}show {id}",
        if kind == "pipeline" { "pipeline " } else { "" }
    );
    println!("{kind} {id}: {result} — {show}");
    match result {
        "green" | "answered" => Ok(()),
        "awaiting_review" | "question" => usage(format!("{kind} {id} paused {result} — {show}")),
        _ => refuse(format!("{kind} {id} ended {result} — {show}")),
    }
}
/// Starts the run's own process (`factory run <id>`) and hands it `controller`, the run's
/// controller.lock the caller took before saving the state, so that the run reads held
/// throughout. The child waits on launch.lock until its pid is recorded here.
fn spawn_run(st: &mut State, controller: crate::locking::Lock) -> R<std::process::Child> {
    use std::os::unix::process::CommandExt;
    let dir = run_dir(&st.service, &st.id);
    std::fs::create_dir_all(&dir)?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("controller.log"))?;
    let _launch = crate::locking::Lock::take(&dir.join("launch.lock"))?;
    let child = Command::new(std::env::current_exe()?)
        .args(["factory", "run", &st.id])
        .stdin(controller.into_stdio())
        .stdout(log.try_clone()?)
        .stderr(log)
        .process_group(0)
        .spawn()?;
    st.pid = child.id();
    save(st);
    Ok(child)
}
fn claim_slot(st: &mut State, p: &Plan) -> R<bool> {
    let path = PathBuf::from(WORK).join(&st.service).join("execution.lock");
    loop {
        let lock = crate::locking::Lock::take(&path)?;
        let mut current = load(&st.service, &st.id).unwrap_or_else(|| st.clone());
        if current.phase == "done" {
            return Ok(false);
        }
        if current.revision_of.is_none()
            && current
                .from
                .as_ref()
                .and_then(|id| load(&current.service, id))
                .map(|source| source.superseded_by.is_some())
                .unwrap_or(false)
        {
            current.phase = "done".into();
            current.result = Some("cancelled".into());
            current.ended = Some(now());
            save(&current);
            return Ok(false);
        }
        current.pid = std::process::id();
        save(&current);
        *st = current;
        let all = raw_runs(Some(&st.service));
        let executing = all
            .iter()
            .filter(|s| s.id != st.id && s.phase != "queued" && s.phase != "done" && run_held(s))
            .count();
        let first = all
            .iter()
            .filter(|s| s.phase == "queued" && run_held(s))
            .min_by_key(|s| (s.queued_order, s.id.clone()));
        let cap = p.def.factory.as_ref().map(|f| f.concurrency).unwrap_or(2);
        if executing < cap && first.map(|s| s.id == st.id).unwrap_or(true) {
            st.phase = "cloning".into();
            save(st);
            return Ok(true);
        }
        drop(lock);
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}
fn raw_runs(service: Option<&str>) -> Vec<State> {
    let mut out = vec![];
    if let Ok(services) = std::fs::read_dir(WORK) {
        for s in services.flatten() {
            let name = s.file_name().to_string_lossy().to_string();
            if service.map(|v| v != name).unwrap_or(false) {
                continue;
            }
            if let Ok(ids) = std::fs::read_dir(s.path().join("runs")) {
                for i in ids.flatten() {
                    if let Some(st) = load(&name, &i.file_name().to_string_lossy()) {
                        out.push(st);
                    }
                }
            }
        }
    }
    out.sort_by_key(|s| (s.queued_order, s.id.clone()));
    out
}
/// Runs the run in this process, which holds its controller.lock (`_controller`) until
/// the run ends.
fn execute(ctx: &Ctx, p: &Plan, mut st: State, _controller: &crate::locking::Lock) -> R<String> {
    if let Some(current) = load(&st.service, &st.id) {
        st = current;
    }
    if st.phase == "done" {
        return Ok(st.result.unwrap_or_else(|| "interrupted".into()));
    }
    if !claim_slot(&mut st, p)? {
        return Ok("cancelled".into());
    }
    let unlock = secrets::unlock(&ctx.cfg);
    let mut run = Run {
        ctx,
        p,
        id: st.id.clone(),
        git_n: 0,
        made: vec![],
        broker: false,
        egress_gate: false,
    };
    if st.base.is_none() {
        let source = st.from.as_deref().and_then(|f| {
            raw_runs(Some(&st.service))
                .into_iter()
                .rev()
                .find(|s| s.id == f || s.branch == f)
        });
        let source_volume = source
            .as_ref()
            .map(|s| format!("{}-run-{}", s.service, s.id))
            .filter(|v| docker::volume_exists(v));
        if source.is_some()
            && source_volume.is_none()
            && (st.answering || source.as_ref().map(|s| !s.remote).unwrap_or(false))
        {
            return refuse("source run volume was removed; it cannot be continued");
        }
        let _ = docker::quiet(&["volume", "create", &run.volume()]);
        let _ = docker::quiet(&[
            "run",
            "--rm",
            "-u",
            "0",
            "--label",
            &format!("farmy.run={}", st.id),
            "--label",
            &format!("farmy.service={}", p.name),
            "-v",
            &format!("{}:/workspace", run.volume()),
            "--entrypoint",
            "chown",
            &run.image(),
            "1001:1001",
            "/workspace",
        ]);
        let origin = commands::repo_of(ctx, &p.name, &p.def)
            .ok()
            .flatten()
            .map(|r| commands::repo_url(ctx, &r))
            .unwrap_or_default();
        let expected = st.source_commit.clone().unwrap_or_default();
        let branch = source
            .as_ref()
            .map(|s| s.branch.as_str())
            .or(st.from.as_deref())
            .unwrap_or(&p.base);
        let branch = branch
            .strip_prefix("refs/heads/")
            .or_else(|| branch.strip_prefix("origin/"))
            .unwrap_or(branch);
        let script = r#"set -e
git clone -q /src /workspace
cd /workspace
if [ -n "$FARMY_ORIGIN" ] && git -C /src remote get-url origin >/dev/null 2>&1; then
 git remote set-url origin "$FARMY_ORIGIN"
 git fetch -q origin
 echo 'remote yes'
else
 echo 'remote no'
fi
target="refs/remotes/origin/$FARMY_BASE"
if [ -n "$FARMY_EXPECTED" ]; then target="$FARMY_EXPECTED"; fi
head=$(git rev-parse --verify "$target^{commit}")
git checkout -q -B "$FARMY_BRANCH" "$head"
rm -f .farmy/question.md .farmy/answer.md
echo "base $(git rev-parse HEAD)"
"#;
        let (code, out, err) = run.git_source(
            script,
            source_volume.as_deref(),
            &[
                ("FARMY_ORIGIN", &origin),
                ("FARMY_BRANCH", &st.branch),
                ("FARMY_BASE", branch),
                ("FARMY_EXPECTED", &expected),
            ],
        );
        let dir = run_dir(&st.service, &st.id);
        std::fs::create_dir_all(&dir)?;
        std::fs::write(dir.join("git.log"), format!("{out}{err}"))?;
        let Some(base) = marker(&out, "base").filter(|_| code == 0) else {
            let _ = docker::quiet(&["volume", "rm", "-f", &run.volume()]);
            return refuse(format!(
                "[{}] the run could not clone the checkout and check out {branch}: {} (git.log in {})",
                p.name,
                commands::git_cause(&format!("{out}\n{err}")),
                dir.display()
            ));
        };
        st.base = Some(base.clone());
        st.head = Some(base.clone());
        st.source_commit = Some(base.clone());
        if st.review_base.is_none() {
            st.review_base = Some(base);
        }
        st.remote = marker(&out, "remote").as_deref() == Some("yes");
        save(&st);
    }
    Ok(control(ctx, p, st, unlock.as_ref(), run.git_n))
}

fn gated_head(st: &State) -> Option<String> {
    st.approved_commit
        .clone()
        .filter(|_| st.approval_valid)
        .or_else(|| st.gated_commit.clone())
        .or_else(|| st.head.clone())
        .or_else(|| st.commits.last().map(|c| c.sha.clone()))
        .or_else(|| st.base.clone())
}

fn answer(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return refuse(USAGE);
    };
    let st = find(id).map_err(|e| crate::Fail::Refuse(e.to_string()))?;
    if st.result.as_deref() != Some("question") {
        return refuse(format!(
            "run {id} is {}; answer accepts a question only",
            st.result.as_deref().unwrap_or(&st.phase)
        ));
    }
    let mut answer = None;
    let mut wait = false;
    for arg in &args[1..] {
        if arg == "--wait" {
            wait = true;
        } else if answer.is_none() {
            answer = Some(arg.clone());
        } else {
            return refuse(USAGE);
        }
    }
    let answer = read_text(
        answer
            .filter(|a| !a.trim().is_empty())
            .ok_or_else(|| crate::Fail::Refuse("answer needs <text|file>".into()))?,
    )?;
    let ctx = commands::load_ctx()?;
    let p = saved_plan(&ctx, &st)?;
    let context = format!(
        "{}\nThe previous run asked:\n{}\n\nThe human answered:\n{}\n",
        st.context,
        st.question.as_deref().unwrap_or(""),
        answer
    );
    if let Some(pid) = &st.pipeline_id {
        let transition =
            crate::locking::Lock::take(&pipeline_dir(&st.service, pid).join("transition.lock"))?;
        let mut ps = find_pipeline(pid)?;
        if ps.active_run.as_deref() != Some(id) {
            return refuse(format!(
                "run {id} is no longer the pipeline's current question"
            ));
        }
        let mut child = make_state(
            &p,
            st.task.clone(),
            Some(st.id.clone()),
            Some(&st),
            st.answering,
            context,
        );
        child.answering_for = st.answering_for.clone();
        child.red_reference_commit = st.red_reference_commit.clone();
        child.review_answer = st.review_answer;
        ps.pid = 0;
        reserve_child(&mut ps, child);
        drop(transition);
        if wait {
            let controller = crate::locking::Lock::take(&pipeline_lock(&ps))?;
            let result = drive_pipeline(pid, &controller)?;
            return wait_result("pipeline", pid, &result);
        }
        spawn_pipeline(&mut ps)?;
        println!("pipeline {pid} answered");
        return Ok(());
    }
    launch(
        &ctx,
        &p,
        st.task.clone(),
        Some(st.id.clone()),
        Some(&st),
        false,
        context,
        wait,
    )
}

const APPROVAL_SCRIPT: &str = "set -e\nhead=$(git rev-parse --verify \"refs/heads/$FARMY_BRANCH^{commit}\")\nif [ \"$head\" != \"$FARMY_EXPECTED\" ]; then echo 'error: branch changed since the gated commit' >&2; exit 1; fi\nif [ \"$FARMY_REMOTE\" = yes ]; then remote=$(git ls-remote origin \"refs/heads/$FARMY_BRANCH\" | cut -f1); if [ \"$remote\" != \"$FARMY_EXPECTED\" ]; then echo 'error: published branch changed since the gated commit' >&2; exit 1; fi; fi\n";
fn approve(args: &[String]) -> R {
    let Some(id) = args.first().filter(|_| args.len() == 1) else {
        return usage(USAGE);
    };
    let initial = find(id)?;
    let _pipeline = initial
        .pipeline_id
        .as_ref()
        .map(|pid| {
            crate::locking::Lock::take(&pipeline_dir(&initial.service, pid).join("transition.lock"))
        })
        .transpose()?;
    let _lock = crate::locking::Lock::take(&run_dir(&initial.service, id).join("approval.lock"))?;
    let mut st = load(&initial.service, id).unwrap_or(initial);
    if st.approval_valid {
        println!("run {id}: green (already approved)");
        return Ok(());
    }
    if st.result.as_deref() != Some("awaiting_review") || st.superseded_by.is_some() {
        return refuse(format!(
            "run {id} is {}; approve accepts awaiting_review only",
            st.result.as_deref().unwrap_or(&st.phase)
        ));
    }
    let ctx = commands::load_ctx()?;
    let p = saved_plan(&ctx, &st)?;
    let mut run = Run {
        ctx: &ctx,
        p: &p,
        id: st.id.clone(),
        git_n: 1000000,
        made: vec![],
        broker: false,
        egress_gate: false,
    };
    if !docker::volume_exists(&run.volume()) {
        return refuse(format!(
            "run {id} volume was removed; approval cannot verify its commit"
        ));
    }
    let expected = st
        .gated_commit
        .clone()
        .or_else(|| gated_head(&st))
        .ok_or_else(|| "run has no gated commit".to_string())?;
    let (code, out, err) = run.git(
        APPROVAL_SCRIPT,
        false,
        &[
            ("FARMY_BRANCH", &st.branch),
            ("FARMY_EXPECTED", &expected),
            ("FARMY_REMOTE", if st.remote { "yes" } else { "no" }),
        ],
    );
    append(
        &run_dir(&st.service, id).join("git.log"),
        &format!("{out}{err}"),
    );
    if code != 0 {
        return refuse(format!(
            "run {id} approval failed: {}; it remains awaiting_review",
            commands::git_cause(&format!("{out}\n{err}"))
        ));
    }
    st.approved_commit = Some(expected);
    st.approved_profile = Some(p.config.clone());
    let mut gate = p
        .config
        .gate
        .as_ref()
        .map(|g| g.options())
        .unwrap_or_default();
    if gate.kind.is_none() {
        gate.kind = Some("green".into());
    }
    st.approved_gate = Some(gate);
    st.approval_valid = true;
    st.result = Some("green".into());
    st.ended = Some(now());
    save(&st);
    drop(_lock);
    drop(_pipeline);
    println!("run {id}: green (approved)");
    notify_run(&ctx, &mut st);
    notify_parent(&st)?;
    Ok(())
}

/// `farmy factory run <id>`: the controller, detached by start.
fn run_detached(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return usage(USAGE);
    };
    let ctx = commands::load_ctx()?;
    let mut st = locate(id).ok_or_else(|| crate::Fail::Usage(format!("no factory run {id}")))?;
    let controller = crate::locking::Lock::inherit_or_take(&run_lock(&st))?;
    // spawn_run holds launch.lock until it has recorded this process's pid.
    drop(crate::locking::Lock::take(
        &run_dir(&st.service, &st.id).join("launch.lock"),
    )?);
    if let Some(current) = load(&st.service, &st.id) {
        st = current;
    }
    let p = saved_plan(&ctx, &st)?;

    if let Err(e) = execute(&ctx, &p, st.clone(), &controller) {
        st.phase = "done".into();
        st.result = Some("agent_failed".into());
        st.ended = Some(now());
        save(&st);
        return Err(e);
    }
    Ok(())
}

/// The loop. Returns the result.
fn control(
    ctx: &Ctx,
    p: &Plan,
    mut st: State,
    unlock: Option<&BTreeMap<String, String>>,
    git_n: u32,
) -> String {
    st.pid = std::process::id();
    save(&st);
    let mut run = Run {
        ctx,
        p,
        id: st.id.clone(),
        git_n,
        made: vec![],
        broker: false,
        egress_gate: false,
    };
    let dir = run_dir(&p.name, &st.id);
    // the agent's way to its model: the run's own broker with the agent's route, or its token
    let mut model_env: Vec<(String, String)> = vec![];
    match &p.model {
        Model::Api(route) => {
            let resolved = secrets::resolve(&ctx.cfg, &[route], unlock, &[]);
            run.start_broker(route, resolved.values.get(&route.secret));
            if let Some(api) = &p.agent.api {
                model_env.push((
                    api.base_url.clone(),
                    format!("http://keys:9181/{}", route.name),
                ));
                model_env.push((api.key.clone(), "via-farmy-keys".into()));
            }
        }
        Model::Token(t) => {
            let internal = run.network();
            run.make_network(&internal, true);
            let resolved = secrets::resolve(&ctx.cfg, &[], unlock, std::slice::from_ref(t));
            match resolved.values.get(t) {
                Some(v) => model_env.push((t.clone(), v.clone())),
                None => warn(format!(
                    "[{}] factory: the agent's token {t} was not given — the agent runs without it",
                    p.name
                )),
            }
        }
    }

    let base = st.base.clone().unwrap_or_default();
    let mut last: Option<GateReport> = None;
    let mut previous_empty = false;
    let mut result = String::from("max_iterations");
    for i in 1..=p.max {
        st.iteration = i;
        st.phase = "agent".into();
        save(&st);
        let mut prompt = prompt_for(
            &st.task,
            i,
            p.max,
            last.as_ref().map(|g| (g.exit, g.log.as_str())),
        );
        if !st.context.is_empty() {
            prompt.push_str("\n\n");
            prompt.push_str(&st.context);
        }
        if matches!(p.gate, Gate::RedFirst { .. }) {
            prompt.push_str("\nA test must fail if any check fails. Use set -e or equivalent shell error handling. Do not swallow assertions: an earlier failing command followed by a successful command must still make the test fail.\n");
        }
        if let Err(error) = run.open_filter(i) {
            warn(format!("factory egress: {error}"));
            result = "agent_failed".into();
            break;
        }
        let (agent_code, agent_out) = run.agent(i, &prompt, &model_env);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "an iteration's log for later reading; the run itself does not depend on it"
        )]
        let _ = std::fs::write(dir.join(format!("iteration-{i}.agent.log")), &agent_out);
        let timed_out = agent_code == 124;

        st.phase = "commit".into();
        save(&st);
        // Capture control text before protections, staging or cleanup can remove it.
        let (question_code, question_out, question_err) = run.git(
            "if [ -f .farmy/question.md ]; then printf 'question\\n'; cat .farmy/question.md; fi",
            false,
            &[],
        );
        append(&dir.join("git.log"), &question_err);
        let question = if question_code == 0 {
            question_out.strip_prefix("question\n").map(str::to_string)
        } else {
            None
        };
        let mut answer = None;
        if st.answering {
            let (_, text, _) = run.git(
                "if [ -f .farmy/answer.md ]; then printf 'answer\n'; cat .farmy/answer.md; fi",
                false,
                &[],
            );
            answer = text.strip_prefix("answer\n").map(str::to_string);
            let (_, paths, _) = run.git(
                "git diff --name-only -z --no-renames HEAD; git ls-files --others -z",
                false,
                &[],
            );
            st.forbidden_paths = forbidden_paths(&paths, p.writes.as_deref(), &p.protects);
            if !st.forbidden_paths.is_empty() {
                result = "permission_violation".into();
                st.answer = answer;
                save(&st);
                let (code, _, err) = run.git(DROP_CHANGES_SCRIPT, false, &[]);
                st.edits_dropped = code == 0;
                append(&dir.join("git.log"), &err);
                save(&st);
                break;
            }
        }
        let script = commit_script(p.writes.as_deref(), &p.protects);

        let iteration = i.to_string();
        let (code, out, err) = run.git(
            &script,
            false,
            &[("FARMY_BASE_SHA", &base), ("FARMY_ITERATION", &iteration)],
        );
        append(&dir.join("git.log"), &format!("{out}{err}"));
        if code != 0 {
            warn(format!(
                "[{}] factory commit failed: {} (git.log in the run's folder)",
                p.name,
                commands::git_cause(&err)
            ));
            result = "agent_failed".into();
            break;
        }
        let committed = marker(&out, "committed").as_deref() == Some("yes");
        let changed = committed && marker(&out, "changed").as_deref() == Some("yes");
        st.head = marker(&out, "head");
        if committed {
            st.commits.push(Commit {
                iteration: i,
                sha: st.head.clone().unwrap_or_default(),
            });
        }
        if let Some(question) = question {
            st.question = Some(question);
            result = "question".into();
            break;
        }
        if st.answering {
            st.answer = answer;
            if !committed {
                if st
                    .answer
                    .as_ref()
                    .map(|a| !a.trim().is_empty())
                    .unwrap_or(false)
                {
                    result = if st.review_answer {
                        "awaiting_review"
                    } else {
                        "answered"
                    }
                    .into();
                } else {
                    result = "answer_missing".into();
                }
                break;
            }
        }
        if agent_code != 0 && !timed_out && !committed {
            result = "agent_failed".into();
            break;
        }

        st.phase = "gate".into();
        save(&st);
        let gate = run.gate(i, changed);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "an iteration's log for later reading; the run itself does not depend on it"
        )]
        let _ = std::fs::write(dir.join(format!("iteration-{i}.test.log")), &gate.log);
        st.verdicts.push(Verdict {
            iteration: i,
            exit: gate.exit,
            commands: gate.commands.clone(),
        });
        save(&st);
        if gate.failed_to_run {
            result = "test_failed_to_run".into();
            break;
        }
        if gate.exit == 0 {
            result = if p.review { "awaiting_review" } else { "green" }.into();
            break;
        }
        if timed_out {
            result = "timeout".into();
            break;
        }
        if !committed
            && previous_empty
            && last
                .as_ref()
                .map(|last| {
                    last.exit == gate.exit && last.commands == gate.commands && last.log == gate.log
                })
                .unwrap_or(false)
        {
            result = "stalled".into();
            break;
        }
        previous_empty = !committed;
        last = Some(gate);
    }
    if matches!(result.as_str(), "green" | "awaiting_review")
        && !publish(&mut run, &mut st, &result)
    {
        result = "publish_failed".into();
    }
    if result != "publish_failed" && st.remote {
        st.compare_url = st
            .review_base
            .as_ref()
            .or(st.base.as_ref())
            .zip(st.head.as_ref())
            .and_then(|(base, head)| compare_url(&p.def, base, head));
    }
    run.cleanup();
    st.phase = "done".into();
    st.result = Some(result.clone());
    st.ended = Some(now());
    save(&st);
    notify_run(ctx, &mut st);
    result
}

const DROP_CHANGES_SCRIPT: &str = "set -e\ngit reset --hard -q HEAD\ngit clean -fdxq";
fn forbidden_paths(changes: &str, writes: Option<&[String]>, protects: &[String]) -> Vec<String> {
    let mut paths = changes
        .split('\0')
        .filter(|path| {
            if path.is_empty() || matches!(*path, ".farmy/question.md" | ".farmy/answer.md") {
                return false;
            }
            let within = |prefix: &str| {
                let prefix = clean_path(prefix);
                *path == prefix || path.starts_with(&(prefix + "/"))
            };
            protects.iter().any(|p| within(p))
                || writes
                    .map(|w| !w.iter().any(|p| within(p)))
                    .unwrap_or(false)
        })
        .map(String::from)
        .collect::<Vec<_>>();
    paths.sort();
    paths.dedup();
    paths
}
fn commit_script(writes: Option<&[String]>, protects: &[String]) -> String {
    let mut script = String::from("set -e\ncd /workspace\n");
    for prot in protects {
        let q = sh_quote(&clean_path(prot));
        script.push_str(&format!("git checkout -q \"$FARMY_BASE_SHA\" -- {q} 2>/dev/null || true\ngit clean -fdxq -- {q}\n"));
    }
    match &writes {
        Some(w) => script.push_str(&format!(
            "git add -A -- {} ':(exclude).farmy/question.md' ':(exclude).farmy/answer.md'\n",
            w.iter()
                .map(|x| sh_quote(&clean_path(x)))
                .collect::<Vec<_>>()
                .join(" ")
        )),
        None => script.push_str(
            "git add -A -- . ':(exclude).farmy/question.md' ':(exclude).farmy/answer.md'\n",
        ),
    }
    script.push_str("if [ -n \"$(git diff --cached --no-renames --name-only --diff-filter=AM)\" ]; then echo 'changed yes'; else echo 'changed no'; fi\nif git diff --cached --quiet; then echo 'committed no'; else git commit -q -m \"farmy: iteration $FARMY_ITERATION\"; echo 'committed yes'; fi\ngit reset -q --hard\ngit clean -fdq\nrm -f .farmy/question.md .farmy/answer.md\necho \"head $(git rev-parse HEAD)\"\n");
    script
}

fn append(path: &Path, text: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "appending to a run's log for later reading; the run itself does not depend on it"
        )]
        let _ = f.write_all(text.as_bytes());
    }
}

fn list(args: &[String]) -> R {
    let service = args.first().map(String::as_str);
    let all = runs(service);
    if all.is_empty() {
        println!(
            "no factory runs{} — farmy factory start <name> --task <file or text>",
            service.map(|s| format!(" of {s}")).unwrap_or_default()
        );
    }
    for st in all {
        let state = st.result.clone().unwrap_or_else(|| st.phase.clone());
        println!(
            "{}  {:<10} {:<18} {}/{}  {}{}",
            st.id,
            st.service,
            state,
            st.iteration,
            st.max_iterations,
            st.branch,
            st.pipeline_id
                .as_ref()
                .map(|id| format!(
                    " pipeline {id} {} step {}",
                    st.pipeline_name.as_deref().unwrap_or(""),
                    st.pipeline_step.unwrap_or(1)
                ))
                .unwrap_or_default()
        );
    }
    for p in pipelines(service) {
        println!(
            "pipeline {} {} {} step {}/{} {} child {}",
            p.id,
            p.name,
            p.state,
            p.step,
            p.steps,
            p.profile,
            p.active_run.as_deref().unwrap_or("-")
        );
    }
    Ok(())
}

fn show(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return usage(USAGE);
    };
    if id.starts_with("p-") {
        return pipeline_main(&["show".into(), id.clone()]);
    }
    let st = find(id)?;
    println!("run        {}", st.id);
    println!("service    {}", st.service);
    println!("profile    {}", st.profile);
    println!("from       {}", st.from.as_deref().unwrap_or("-"));
    if let Some(id) = &st.pipeline_id {
        println!(
            "pipeline   {id} {} step {}",
            st.pipeline_name.as_deref().unwrap_or(""),
            st.pipeline_step.unwrap_or(1)
        );
    }
    println!("gate       {}", st.gate_summary.as_deref().unwrap_or("-"));
    println!(
        "compare    {}",
        st.compare_url.as_deref().unwrap_or(&st.branch)
    );
    println!(
        "source_commit {}",
        st.source_commit.as_deref().unwrap_or("-")
    );
    println!("gated_commit {}", st.gated_commit.as_deref().unwrap_or("-"));
    println!(
        "approved_commit {}",
        st.approved_commit.as_deref().unwrap_or("-")
    );
    println!("approval_valid {}", st.approval_valid);
    if let Some(answer) = &st.answer {
        println!("answer     {answer}");
    }
    if let Some(reference) = &st.red_reference_commit {
        println!("red_reference_commit {reference}");
    }
    if let Some(note) = &st.notification {
        println!("{note}");
    }
    if !st.forbidden_paths.is_empty() {
        println!(
            "{}: {}",
            if st.edits_dropped {
                "forbidden edits dropped"
            } else {
                "forbidden edits could not be dropped"
            },
            st.forbidden_paths.join(", ")
        );
    }
    if let Some(question) = &st.question {
        println!("question   {question}");
    }
    println!("task       {}", st.task.lines().next().unwrap_or(""));
    println!(
        "base       {}",
        st.base.clone().unwrap_or_else(|| "-".into())
    );
    println!(
        "branch     {}{}",
        st.branch,
        if st.result.as_deref() == Some("green") && st.remote {
            " (pushed)"
        } else {
            ""
        }
    );
    let mut result = st
        .result
        .clone()
        .unwrap_or_else(|| format!("running ({})", st.phase));
    if result == "agent_failed" {
        let log = std::fs::read_to_string(
            run_dir(&st.service, &st.id)
                .join(format!("iteration-{}.agent.log", st.iteration.max(1))),
        )
        .unwrap_or_default();
        if let Some(cause) = agent_cause(&log) {
            result = format!("agent_failed — {cause}");
        }
    }
    println!("result     {result}");
    println!("iteration  {} of {}", st.iteration, st.max_iterations);
    let volume = format!("{}-run-{}", st.service, st.id);
    println!(
        "volume     {volume}  {}",
        if docker::volume_exists(&volume) {
            volume_size(&st, &volume)
        } else {
            "removed (farmy factory prune)".into()
        }
    );
    for i in 1..=st.iteration {
        let commit = st
            .commits
            .iter()
            .find(|c| c.iteration == i)
            .map(|c| c.sha.chars().take(12).collect::<String>())
            .unwrap_or_else(|| "-".into());
        let verdict = st
            .verdicts
            .iter()
            .find(|v| v.iteration == i)
            .map(|v| format!("exit {}", v.exit))
            .unwrap_or_else(|| "no gate".into());
        println!("  {i}  commit {commit}  {verdict}");
    }
    let last = (1..=st.iteration).rev().find_map(|i| {
        std::fs::read_to_string(
            run_dir(&st.service, &st.id).join(format!("iteration-{i}.test.log")),
        )
        .ok()
        .map(|t| (i, t))
    });
    if let Some((i, text)) = last {
        println!("\nthe last test output (iteration {i}):");
        let lines: Vec<&str> = text.lines().collect();
        if text.trim().is_empty() {
            // a gate that printed nothing: said, not left as an empty heading
            println!("  (no output)");
        } else {
            for l in &lines[lines.len().saturating_sub(40)..] {
                println!("  {l}");
            }
        }
    }
    Ok(())
}

fn log(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return usage(USAGE);
    };
    let st = find(id)?;
    let i: u32 = match args.get(1) {
        Some(n) => n
            .parse()
            .map_err(|_| crate::Fail::Usage(format!("'{n}' is not an iteration number")))?,
        None => st.iteration,
    };
    let dir = run_dir(&st.service, &st.id);
    for (what, file) in [
        ("agent", format!("iteration-{i}.agent.log")),
        ("test", format!("iteration-{i}.test.log")),
    ] {
        println!("== {what} (iteration {i})");
        print!(
            "{}",
            std::fs::read_to_string(dir.join(file)).unwrap_or_else(|_| "(none)\n".into())
        );
    }
    Ok(())
}

fn cancel(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return usage(USAGE);
    };
    let mut st = find(id)?;
    if st.phase == "done" {
        println!(
            "run {id} has ended already: {}",
            st.result.clone().unwrap_or_default()
        );
        return Ok(());
    }
    if st.pid != 0 && st.pid != std::process::id() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the process may have exited by itself already; nothing else to do either way"
        )]
        let _ = Command::new("kill")
            .args(["-KILL", &format!("-{}", st.pid)])
            .stderr(Stdio::null())
            .status();
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the process may have exited by itself already; nothing else to do either way"
        )]
        let _ = Command::new("kill")
            .args(["-KILL", &st.pid.to_string()])
            .stderr(Stdio::null())
            .status();
    }
    cleanup_abandoned(&st);
    st.phase = "done".into();
    st.result = Some("cancelled".into());
    st.ended = Some(now());
    save(&st);
    println!("run {id} cancelled");
    Ok(())
}

fn cleanup_abandoned(st: &State) {
    let id = &st.id;
    let gate = format!("{}-run-{id}-egress-gate", st.service);
    // what exists of the run, and only that: its containers (by label), the gate's sidecars off its network, its networks
    for c in docker::ps(&[format!("label=farmy.run={id}")], true) {
        if docker::container_label(&c, "farmy.role") != "egress-gate" {
            let _ = docker::ok(&["rm", "-f", &c]);
        }
    }
    if docker::ok(&["inspect", &gate]) {
        crate::filter::retain(&st.service, id, &gate);
        let _ = docker::ok(&["rm", "-f", &gate]);
    }
    let sidecars = Definition::load(&st.service)
        .map(|d| sidecar_names(&d))
        .unwrap_or_default();
    close_gate(&st.service, id, sidecars);
    for net in [
        format!("{}-run-{id}", st.service),
        format!("{}-run-{id}-out", st.service),
    ] {
        if docker::ok(&["network", "inspect", &net]) {
            let _ = docker::ok(&["network", "rm", &net]);
        }
    }
    if st.base.is_none() {
        let _ = docker::ok(&["volume", "rm", "-f", &format!("{}-run-{id}", st.service)]);
    }
}

/// The compose service names of the definition's fragment (its sidecars).
fn sidecar_names(def: &Definition) -> Vec<String> {
    def.compose
        .as_ref()
        .map(|m| {
            m.keys()
                .filter_map(|k| k.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// The sidecars off the gate's network, and the network gone.
fn close_gate(service: &str, id: &str, _sidecars: Vec<String>) {
    let net = format!("{service}-run-{id}-gate");
    let file = run_dir(service, id).join("gate-compose.yml");
    if file.is_file() {
        let _ = docker::compose(
            &net,
            Some(&file),
            &["down", "-v", "--remove-orphans"],
            false,
        );
    }
    if docker::ok(&["network", "inspect", &net]) {
        let _ = docker::ok(&["network", "rm", &net]);
    }
}

/// The first line of the agent's log that names a cause, else its last line.
fn agent_cause(text: &str) -> Option<String> {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    let causes = [
        "API Error",
        "Error:",
        "error:",
        "ENOTFOUND",
        "ECONNREFUSED",
        "401",
        "403",
        "rate limit",
    ];
    lines
        .iter()
        .find(|l| causes.iter().any(|c| l.contains(c)))
        .or(lines.last())
        .map(|l| l.to_string())
}

/// The run volume's size, as `du -sh` sees it from a short container.
fn volume_size(st: &State, volume: &str) -> String {
    let out = docker::out(&[
        "run",
        "--rm",
        "--label",
        &format!("farmy.run={}", st.id),
        "--label",
        &format!("farmy.service={}", st.service),
        "--label",
        "farmy.role=measure",
        "-v",
        &format!("{volume}:/v:ro"),
        "--entrypoint",
        "du",
        &format!("farmy/{}:dev", st.service),
        "-sh",
        "/v",
    ])
    .unwrap_or_default();
    out.split_whitespace()
        .next()
        .map(String::from)
        .unwrap_or_else(|| "size unknown".into())
}

/// Seconds since the epoch of an RFC 3339 UTC time as farmy writes it (2026-10-15T09:15:00Z).
fn epoch_of(t: &str) -> Option<u64> {
    let n = |a: usize, b: usize| t.get(a..b)?.parse::<i64>().ok();
    let (y, m, d, hh, mm, ss) = (
        n(0, 4)?,
        n(5, 7)?,
        n(8, 10)?,
        n(11, 13)?,
        n(14, 16)?,
        n(17, 19)?,
    );
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    u64::try_from(days * 86400 + hh * 3600 + mm * 60 + ss).ok()
}

/// `farmy factory prune [--older-than <n>d|h|m]`: the volumes of finished runs; their folders stay.
fn prune(args: &[String]) -> R {
    let mut limit: Option<u64> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--older-than" => {
                let v = it.next().cloned().unwrap_or_default();
                let secs = match v.strip_suffix('d') {
                    Some(days) => days.parse::<u64>().ok().map(|d| d * 86400),
                    None => duration_secs(&v),
                };
                limit = Some(secs.ok_or_else(|| {
                    crate::Fail::Usage(format!(
                        "--older-than takes a number with d, h or m (7d), not '{v}'"
                    ))
                })?);
            }
            other => return usage(format!("unexpected '{other}' — {USAGE}")),
        }
    }
    commands::need_docker()?;
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut removed = 0;
    for st in runs(None) {
        if st.phase != "done"
            || matches!(
                st.result.as_deref(),
                Some("awaiting_review" | "question" | "publish_failed")
            )
            || st
                .pipeline_id
                .as_ref()
                .and_then(|id| find_pipeline(id).ok())
                .map(|p| !matches!(p.state.as_str(), "green" | "cancelled"))
                .unwrap_or(false)
        {
            continue;
        }
        if let Some(l) = limit {
            let ended = st.ended.as_deref().and_then(epoch_of).unwrap_or(now_secs);
            if now_secs.saturating_sub(ended) < l {
                continue;
            }
        }
        let volume = format!("{}-run-{}", st.service, st.id);
        if docker::volume_exists(&volume) && docker::quiet(&["volume", "rm", "-f", &volume]) {
            println!(
                "removed {volume} ({} {})",
                st.result.clone().unwrap_or_default(),
                st.ended.clone().unwrap_or_default()
            );
            removed += 1;
        }
    }
    if removed == 0 {
        println!("nothing to prune");
    }
    Ok(())
}

/// The runs of a service for status --json.
pub(crate) fn status_json(service: &str) -> serde_json::Value {
    serde_json::Value::Array(
        runs(Some(service))
            .into_iter()
            .map(|st| {
                let mut v = serde_json::to_value(st).unwrap_or_default();
                if let Some(m) = v.as_object_mut() {
                    for k in [
                        "task",
                        "context",
                        "pid",
                        "queued_order",
                        "publish_result",
                        "definition_config",
                    ] {
                        m.remove(k);
                    }
                }
                v
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Repo(PathBuf);
    impl Repo {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("farmy-worker-{}", new_id()));
            std::fs::create_dir_all(&dir).unwrap();
            let repo = Self(dir);
            repo.git(&["init", "-q"]);
            repo.git(&["config", "user.name", "Example Developer"]);
            repo.git(&["config", "user.email", "dev@example.com"]);
            repo
        }
        fn write(&self, path: &str, content: &str) {
            let path = self.0.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        }
        fn git(&self, args: &[&str]) -> String {
            let output = Command::new("git")
                .args(args)
                .current_dir(&self.0)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim().into()
        }
        fn commit(&self) -> String {
            self.git(&["add", "-A"]);
            self.git(&["commit", "-qm", "baseline"]);
            self.git(&["rev-parse", "HEAD"])
        }
        fn iteration(&self, writes: Option<&[String]>, protects: &[String], base: &str) -> String {
            let script =
                commit_script(writes, protects).replace("/workspace", self.0.to_str().unwrap());
            let output = Command::new("sh")
                .args(["-c", &script])
                .current_dir(&self.0)
                .env("FARMY_BASE_SHA", base)
                .env("FARMY_ITERATION", "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).into()
        }
    }
    impl Drop for Repo {
        fn drop(&mut self) {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "test cleanup: a leftover temporary folder is harmless"
            )]
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn actual_hidden_edits_are_named_before_the_checkout_is_restored() {
        let repo = Repo::new();
        for path in [
            "private/notes.txt",
            "test/protected/contract.sh",
            "docs/guide.md",
        ] {
            repo.write(path, "original\n");
        }
        let before = repo.commit();
        for path in [
            "private/notes.txt",
            "test/protected/contract.sh",
            "docs/guide.md",
        ] {
            repo.write(path, "forbidden private content\n");
        }
        repo.write("private/new note.txt", "new forbidden content\n");
        repo.write(".farmy/answer.md", "permitted answer\n");
        let changed = format!(
            "{}{}",
            repo.git(&["diff", "--name-only", "-z", "--no-renames", "HEAD"]),
            repo.git(&["ls-files", "--others", "-z"])
        );
        let paths = forbidden_paths(
            &changed,
            Some(&["test/".into()]),
            &["test/protected/".into(), "private/".into()],
        );
        assert_eq!(
            paths,
            [
                "docs/guide.md",
                "private/new note.txt",
                "private/notes.txt",
                "test/protected/contract.sh"
            ]
        );
        let diagnostic = serde_json::to_string(&paths).unwrap();
        assert!(!diagnostic.contains("forbidden private content"));
        let output = Command::new("sh")
            .args(["-c", DROP_CHANGES_SCRIPT])
            .current_dir(&repo.0)
            .output()
            .unwrap();
        assert!(output.status.success());
        for path in [
            "private/notes.txt",
            "test/protected/contract.sh",
            "docs/guide.md",
        ] {
            assert_eq!(
                std::fs::read_to_string(repo.0.join(path)).unwrap(),
                "original\n"
            );
        }
        assert!(!repo.0.join("private/new note.txt").exists());
        assert_eq!(repo.git(&["rev-parse", "HEAD"]), before);
        assert_eq!(repo.git(&["status", "--porcelain"]), "");
    }

    #[test]
    fn a_real_commit_restores_the_chained_baseline_and_omits_control_and_unpermitted_files() {
        let repo = Repo::new();
        repo.write("implementation/app", "before\n");
        repo.write("checks/test", "approved contract\n");
        let base = repo.commit();
        repo.write("implementation/app", "after\n");
        repo.write("checks/test", "agent bypass\n");
        repo.write("checks/extra", "agent bypass\n");
        repo.write("outside", "unpermitted\n");
        repo.write(".farmy/question.md", "A human decision?\n");
        let output = repo.iteration(
            Some(&["implementation/".into()]),
            &["checks/".into()],
            &base,
        );
        assert_eq!(marker(&output, "committed").as_deref(), Some("yes"));
        assert_eq!(marker(&output, "changed").as_deref(), Some("yes"));
        assert_eq!(repo.git(&["show", "HEAD:implementation/app"]), "after");
        assert_eq!(repo.git(&["show", "HEAD:checks/test"]), "approved contract");
        assert_eq!(
            repo.git(&["ls-tree", "-r", "--name-only", "HEAD"]),
            "checks/test\nimplementation/app"
        );
        assert!(!repo.0.join(".farmy/question.md").exists());
        assert_eq!(repo.git(&["status", "--porcelain"]), "");
    }

    #[test]
    fn unrestricted_writes_never_commit_questions_and_a_deletion_is_not_a_changed_file() {
        let repo = Repo::new();
        repo.write("implementation/app", "before\n");
        let base = repo.commit();
        repo.write(".farmy/question.md", "Should it be removed?\n");
        std::fs::remove_file(repo.0.join("implementation/app")).unwrap();
        let output = repo.iteration(None, &[], &base);
        assert_eq!(marker(&output, "committed").as_deref(), Some("yes"));
        assert_eq!(marker(&output, "changed").as_deref(), Some("no"));
        assert_eq!(repo.git(&["ls-tree", "-r", "--name-only", "HEAD"]), "");
        let empty = repo.iteration(None, &[], &base);
        assert_eq!(marker(&empty, "committed").as_deref(), Some("no"));
    }

    #[test]
    fn approval_checks_the_branch_commit_before_any_publication() {
        let repo = Repo::new();
        repo.write("implementation/app", "gated\n");
        let gated = repo.commit();
        repo.git(&["checkout", "-qb", "farmy/example/review"]);
        repo.write("implementation/app", "ungated\n");
        repo.commit();
        let approve = || {
            Command::new("sh")
                .args(["-c", APPROVAL_SCRIPT])
                .current_dir(&repo.0)
                .env("FARMY_BRANCH", "farmy/example/review")
                .env("FARMY_EXPECTED", &gated)
                .env("FARMY_REMOTE", "no")
                .output()
                .unwrap()
        };
        let moved = approve();
        assert!(!moved.status.success());
        assert!(String::from_utf8_lossy(&moved.stderr).contains("changed since the gated commit"));
        repo.git(&["reset", "--hard", &gated]);
        assert!(
            approve().status.success(),
            "a workbench can approve the unchanged gated commit"
        );
    }

    #[test]
    fn old_states_load_with_the_default_profile_and_no_handoff() {
        let state: State = serde_json::from_str(r#"{"id":"old","service":"example","task":"task","base":null,"branch":"farmy/example/old","phase":"done","iteration":1,"max_iterations":5,"result":"green","started":"2026-01-01T00:00:00Z","ended":null}"#).unwrap();
        assert_eq!(state.profile, "default");
        assert!(state.question.is_none() && state.from.is_none());
    }

    #[test]
    fn a_spawned_child_is_alive_until_its_own_handle_says_it_exited() {
        let run = |id: &str| State {
            id: id.into(),
            service: "example".into(),
            phase: "queued".into(),
            ..Default::default()
        };
        let (mine, other) = (run("mine"), run("other"));
        let mut spawned = Spawned::default();
        let child = Command::new("sleep").arg("30").spawn().unwrap();
        let pid = child.id();
        spawned.add(&mine.id, child);
        // The injected check says gone, as /proc does while a fresh child is inside execve.
        assert!(
            spawned.alive(&mine, |_| false),
            "a child this controller spawned and that has not exited counts as alive"
        );
        assert!(
            spawned.alive(&other, |_| true),
            "another run follows the injected check"
        );
        assert!(
            !spawned.alive(&other, |_| false),
            "another run follows the injected check"
        );
        Command::new("kill")
            .args(["-KILL", &pid.to_string()])
            .status()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while spawned.alive(&mine, |_| false) {
            assert!(
                std::time::Instant::now() < deadline,
                "the killed child never read gone"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            spawned.0.is_empty(),
            "the exited child was reaped and forgotten"
        );
        assert!(
            spawned.alive(&mine, |_| true),
            "once its process is gone, a run that someone else holds counts as alive"
        );
    }
}
