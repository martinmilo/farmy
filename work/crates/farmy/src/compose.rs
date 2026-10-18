//! The compose file of a service: farmy's `app` and `keys`, then the definition's own fragment as it is.
use crate::model::{Config, Definition, PortPair, Settings};
use crate::secrets::Route;
use crate::{R, refuse};
use serde_yaml::{Mapping, Value};

pub(crate) struct Inputs<'a> {
    pub name: &'a str,
    pub def: &'a Definition,
    pub ports: &'a [PortPair],
    pub block: Option<(u32, u32)>, // the hundred the host ports lie in; None without ports:
    pub settings: &'a Settings,
    pub cfg: &'a Config,
    pub routes: &'a [&'a Route],
    pub agents: &'a str, // the agents on for this service, space-separated (FARMY_AGENTS); empty: none
    pub agent_env: &'a [(String, String)], // what the agents put into the environment (a token, api variables, their env:)
    pub blocked: &'a [String], // variables no route may set here (an agent's api variables in subscription mode)
    pub proxy_env: &'a [(String, String)], // the mesh egress proxy variables; empty without egress:
    pub toolbox_hash: &'a str,
    pub repo_url: &'a str,
    pub branch: &'a str,
}

/// Published ports open to the network: only with LAN_HOST in .env.
pub(crate) fn lan_open(settings: &Settings) -> bool {
    settings
        .get("LAN_HOST")
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false)
}

fn s(v: &str) -> Value {
    Value::String(v.to_string())
}

fn map(pairs: Vec<(&str, Value)>) -> Value {
    let mut m = Mapping::new();
    for (k, v) in pairs {
        m.insert(s(k), v);
    }
    Value::Mapping(m)
}

fn list(items: &[String]) -> Value {
    Value::Sequence(items.iter().map(|i| s(i)).collect())
}

/// `$` → `$$`: compose would interpolate it otherwise.
fn lit(v: &str) -> Value {
    s(&v.replace('$', "$$"))
}

// Dotfiles may replace the global Git configuration with a read-only link. Keep routing in Git's
// process configuration so that the user's file can supply their other preferences unchanged.
fn dotfiles_git_config(env: &mut Mapping, routes: &[&Route], _settings: &Settings) {
    let proxy: Vec<_> = env
        .iter()
        .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v.as_str()?.to_string())))
        .collect();
    let pairs = crate::git_container::transport_config(routes, &proxy);
    let mut count = env
        .get(s("GIT_CONFIG_COUNT"))
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    for (key, value) in pairs {
        env.insert(s(&format!("GIT_CONFIG_KEY_{count}")), lit(&key));
        env.insert(s(&format!("GIT_CONFIG_VALUE_{count}")), lit(&value));
        count += 1;
    }
    env.insert(s("GIT_CONFIG_COUNT"), s(&count.to_string()));
}

/// The compose file as text. `resolve` turns `${url:x}` / `${port:x}` into their values; `forward`
/// collects the host ports those references point at (the entrypoint's localhost forwarders).
pub(crate) fn generate(i: &Inputs<'_>, resolve: &dyn Fn(&str) -> (String, Vec<u32>)) -> R<String> {
    let name = i.name;
    let restricted = crate::filter::restricted(i.cfg, i.def);
    let mut services = Mapping::new();

    // the fragment first, to refuse its names before anything is built
    let mut fragment: Vec<(String, Value)> = vec![];
    if let Some(frag) = &i.def.compose {
        for (k, v) in frag {
            let key = k.as_str().unwrap_or("?").to_string();
            if key == "app" || key == "keys" || key == "egress-gate" {
                return refuse(format!(
                    "services/{name}.yml: the compose fragment defines a service named '{key}', which farmy adds itself — rename it"
                ));
            }
            let mut svc = v.clone();
            if let Value::Mapping(m) = &mut svc
                && !m.contains_key(s("init"))
            {
                m.insert(s("init"), Value::Bool(true));
            }
            fragment.push((key, svc));
        }
    }

    // the app's environment: farmy's own, the routes' exposed variables, the definition's env
    let mut env: Vec<(String, Value)> = vec![];
    if !i.repo_url.is_empty() {
        // Kept in the app environment as repository metadata; checkout initialization uses the Git launcher.
        env.push(("REPO".into(), lit(i.repo_url)));
        env.push(("BRANCH".into(), lit(i.branch)));
    }
    env.push((
        "GIT_USER_NAME".into(),
        lit(i.settings.get("GIT_USER_NAME").unwrap_or("")),
    ));
    env.push((
        "GIT_USER_EMAIL".into(),
        lit(i.settings.get("GIT_USER_EMAIL").unwrap_or("")),
    ));
    let ssh = i.routes.iter().any(|r| r.is_ssh());
    // every granted git route over http(s): the entrypoint rewrites each host to its route
    let rewrites: Vec<String> = i
        .routes
        .iter()
        .filter(|r| r.git && !r.is_ssh())
        .map(|r| format!("{}=http://keys:9181/{}/", r.upstream, r.name))
        .collect();
    if !rewrites.is_empty() {
        env.push(("DEV_GIT_ROUTES".into(), lit(&rewrites.join(" "))));
    }
    // every granted SSH git route: its host's https URL goes over SSH, with the route's user and port,
    // for later fetches and pushes as for the clone
    let ssh_rewrites: Vec<String> = i
        .routes
        .iter()
        .filter(|r| r.git && r.is_ssh())
        .map(|r| format!("https://{}/={}/", r.host, r.ssh_base()))
        .collect();
    if !ssh_rewrites.is_empty() {
        env.push(("DEV_GIT_SSH_ROUTES".into(), lit(&ssh_rewrites.join(" "))));
    }
    if ssh {
        env.push(("SSH_AUTH_SOCK".into(), s("/run/farmy-keys/agent.sock")));
    }
    for (k, v) in i.proxy_env {
        env.push((k.clone(), s(v)));
    }
    env.push((
        "FARMY_SHARED_DATA".into(),
        lit(&i.cfg.shared_data.join(" ")),
    ));
    env.push((
        "FARMY_TOOL_VERSIONS".into(),
        lit(&crate::toolbox::version_key(i.cfg, i.def)?),
    ));
    env.push(("SHELL".into(), lit(&format!("/bin/{}", i.cfg.shell))));
    if let Some(dotfiles) = &i.cfg.dotfiles {
        env.push(("FARMY_DOTFILES_DIR".into(), s(crate::home::DOTFILES_IN_APP)));
        env.push((
            "FARMY_DOTFILES_INSTALL".into(),
            lit(dotfiles.install.as_deref().unwrap_or("")),
        ));
    }
    let agents_on = !i.agents.is_empty();
    let shared = i.def.shared_logins.unwrap_or(true);
    env.push((
        "FARMY_LOGIN_DIR".into(),
        s(if shared {
            "/home/dev/.farmy-shared"
        } else {
            "/home/dev/.farmy-service/logins"
        }),
    ));
    if agents_on {
        env.push(("FARMY_AGENTS".into(), s(i.agents)));
        if i.cfg.knowledge {
            env.push(("FARMY_MCP_URL".into(), s("http://farmy-knowledge:9190/mcp")));
        }
        for (k, v) in i.agent_env {
            env.push((k.clone(), lit(v))); // a token here is the one documented exception (FORMATS.md, Agents)
        }
    }
    // An agent's api variables outrank its login: in subscription mode no route may set them.
    // Every granted route is configured whatever its secret's state: the broker answers 503 until
    // `farmy keys reload` loads it, and the container is never made anew for a secret.
    let keep = |k: &str| !i.blocked.iter().any(|b| b == k);
    for r in i.routes {
        if let Some(x) = &r.expose
            && keep(x)
        {
            env.push((x.clone(), s(&format!("http://keys:9181/{}", r.name))));
        }
        if let Some(p) = &r.placeholder
            && keep(p)
        {
            env.push((p.clone(), s("via-farmy-keys")));
        }
    }
    let mut forward: Vec<u32> = vec![];
    for (k, v) in i.def.env_strings() {
        let (value, ports) = resolve(&v);
        forward.extend(ports);
        env.push((k, lit(&value)));
    }
    forward.sort_unstable();
    forward.dedup();
    forward.retain(|p| i.block.map(|(lo, hi)| *p < lo || *p > hi).unwrap_or(true));
    if !forward.is_empty() {
        env.push((
            "DEV_FORWARD_PORTS".into(),
            s(&forward
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(" ")),
        ));
    }
    if let Some(w) = i.def.workdir_clean() {
        env.push(("DEV_WORKDIR".into(), lit(&w)));
    }
    if !i.def.mounts.is_empty() {
        // the entrypoint makes these the dev user's
        env.push((
            "DEV_MOUNTS".into(),
            lit(&i.def.mounts.values().cloned().collect::<Vec<_>>().join(" ")),
        ));
    }
    // a later line of a key wins
    let mut env_map = Mapping::new();
    for (k, v) in env {
        env_map.insert(s(&k), v);
    }

    if restricted {
        let mut locals = vec![name.to_string(), "keys".into(), "egress-gate".into()];
        locals.extend(fragment.iter().map(|(n, _)| n.clone()));
        for (k, v) in crate::filter::proxy_env("egress-gate", &locals) {
            env_map.insert(s(&k), s(&v));
        }
    }
    dotfiles_git_config(&mut env_map, i.routes, i.settings);
    // the host only, unless LAN_HOST says other machines reach this one
    let bind = if lan_open(i.settings) {
        ""
    } else {
        "127.0.0.1:"
    };
    let ports: Vec<String> = i
        .ports
        .iter()
        .map(|p| format!("{bind}{}:{}", p.host, p.container))
        .collect();
    let mut nets = vec!["default".to_string()];
    let on_farmy = restricted || i.cfg.knowledge || i.cfg.egress.is_some();
    if on_farmy && !restricted {
        nets.push("farmy".into());
    }
    // the app waits for every fragment service: healthy when it has a healthcheck, started otherwise
    let mut depends = Mapping::new();
    for (k, v) in &fragment {
        let checked = v
            .as_mapping()
            .map(|m| m.contains_key(s("healthcheck")))
            .unwrap_or(false);
        depends.insert(
            s(k),
            map(vec![(
                "condition",
                s(if checked {
                    "service_healthy"
                } else {
                    "service_started"
                }),
            )]),
        );
    }
    depends.insert(s("keys"), map(vec![("condition", s("service_started"))]));

    // one volume shared across every app container (logins, editor extensions: a folder per tool), the
    // checkout, and the service's own agents volume (a folder per agent: transcripts, sessions, the status
    // file); the entrypoint links each agent's login into the shared one and its state paths into the service's
    let mut app_volumes = vec!["src:/workspace".to_string(), "home:/home/dev".to_string()];
    if shared {
        app_volumes.push("farmy-shared:/home/dev/.farmy-shared".into());
    }
    if agents_on {
        app_volumes.push("agents:/home/dev/.farmy-service".into());
    }
    if ssh {
        app_volumes.push("keys-agent:/run/farmy-keys".into());
    }
    for (m, target) in &i.def.mounts {
        app_volumes.push(format!("{m}:{target}"));
    }
    let mut mounted = app_volumes.iter().map(|v| s(v)).collect::<Vec<_>>();
    let subpath = |path: &str, readonly: bool| {
        map(vec![
            ("type", s("volume")),
            ("source", s("farmy-shared")),
            ("target", s(&format!("/home/dev/.farmy-shared/{path}"))),
            ("read_only", Value::Bool(readonly)),
            ("volume", map(vec![("subpath", s(path))])),
        ])
    };
    if !shared && !i.cfg.shared_data.is_empty() {
        mounted.push(subpath("tool-data", false));
    }
    // the shared dotfiles clone, read-only in every app whether or not dotfiles are configured: over a
    // read-write parent it shadows the clone there, so no path in the app can write it (FORMATS.md →
    // Dotfiles lifecycle); `home::provision` makes the subpath before Compose mounts it
    mounted.push(subpath("dotfiles", true));
    let app = map(vec![
        ("image", s(&format!("farmy/{name}:dev"))),
        ("container_name", s(name)),
        ("hostname", s(name)),
        ("init", Value::Bool(true)),
        ("restart", s("unless-stopped")),
        (
            "labels",
            map(vec![
                (
                    "devcontainer.metadata",
                    s("[{\"remoteUser\":\"dev\",\"workspaceFolder\":\"/workspace\"}]"),
                ),
                ("farmy.toolbox.hash", s(i.toolbox_hash)),
            ]),
        ),
        (
            "extra_hosts",
            list(&["host.docker.internal:host-gateway".to_string()]),
        ),
        ("env_file", list(&["app.env".to_string()])),
        ("environment", Value::Mapping(env_map)),
        ("volumes", Value::Sequence(mounted)),
        ("networks", list(&nets)),
        ("ports", list(&ports)),
        ("depends_on", Value::Mapping(depends)),
    ]);
    services.insert(s("app"), app);

    let mut keys_env = Mapping::new();
    keys_env.insert(
        s("FARMY_ROUTES"),
        s(&i.routes
            .iter()
            .map(|r| r.name.as_str())
            .collect::<Vec<_>>()
            .join(" ")),
    );
    keys_env.insert(s("FARMY_PUBLIC"), s("http://keys:9181"));
    for (k, v) in i.proxy_env {
        keys_env.insert(s(k), s(v));
    }
    for r in i.routes {
        keys_env.insert(
            s(&format!(
                "FARMY_ROUTE_{}",
                r.name.to_uppercase().replace('-', "_")
            )),
            lit(&r.spec()),
        );
    }
    let mut keys_pairs = vec![
        ("image", s("farmy-keys:local")),
        ("container_name", s(&format!("{name}-keys"))),
        ("init", Value::Bool(true)),
        ("restart", s("unless-stopped")),
        ("user", s("1001:1001")),
        ("read_only", Value::Bool(true)),
        ("cap_drop", list(&["ALL".to_string()])),
        (
            "security_opt",
            list(&["no-new-privileges:true".to_string()]),
        ),
        ("environment", Value::Mapping(keys_env)),
    ];
    // /run (the loading socket) and /tmp as tmpfs mounts the broker's user can write: the daemon mounts a
    // tmpfs root-owned when no mode is given, and the broker runs as 1001 on a read-only root
    let tmpfs = |target: &str| {
        map(vec![
            ("type", s("tmpfs")),
            ("target", s(target)),
            ("tmpfs", map(vec![("mode", Value::Number(0o1777.into()))])),
        ])
    };
    let mut keys_volumes = vec![tmpfs("/run"), tmpfs("/tmp")];
    if ssh {
        keys_volumes.push(map(vec![
            ("type", s("volume")),
            ("source", s("keys-agent")),
            ("target", s("/run/farmy-keys")),
        ]));
    }
    keys_pairs.push(("volumes", Value::Sequence(keys_volumes)));
    if on_farmy {
        keys_pairs.push(("networks", list(&["default".into(), "farmy".into()])));
    }
    let keys = map(keys_pairs);
    services.insert(s("keys"), keys);
    if restricted {
        services.insert(
            s("egress-gate"),
            map(vec![
                ("image", s("farmy-gate:local")),
                ("container_name", s(&crate::filter::gate_name(name))),
                ("init", Value::Bool(true)),
                ("restart", s("unless-stopped")),
                ("read_only", Value::Bool(true)),
                ("user", s("1001:1001")),
                ("cap_drop", list(&["ALL".into()])),
                ("security_opt", list(&["no-new-privileges:true".into()])),
                ("tmpfs", list(&["/run:mode=1777".into()])),
                ("networks", list(&["default".into(), "farmy".into()])),
                (
                    "labels",
                    map(vec![
                        ("farmy.role", s("egress-gate")),
                        ("farmy.service", s(name)),
                    ]),
                ),
            ]),
        );
    }
    for (k, mut v) in fragment {
        if !i.proxy_env.is_empty() {
            with_env(&mut v, i.proxy_env);
        }
        if i.cfg.egress.is_some() {
            on_network(&mut v, "farmy");
        }
        services.insert(s(&k), v);
    }

    let mut volumes = Mapping::new();
    volumes.insert(s("src"), map(vec![("name", s(&format!("{name}-src")))]));
    volumes.insert(s("home"), map(vec![("name", s(&format!("{name}-home")))]));
    // every app mounts at least the dotfiles subpath of it
    volumes.insert(
        s("farmy-shared"),
        map(vec![("external", Value::Bool(true))]),
    );
    if agents_on {
        volumes.insert(
            s("agents"),
            map(vec![("name", s(&format!("{name}-agents")))]),
        );
    }
    if ssh {
        volumes.insert(
            s("keys-agent"),
            map(vec![("name", s(&format!("{name}-keys-agent")))]),
        );
    }
    for m in i.def.mounts.keys() {
        volumes.insert(s(m), map(vec![("name", s(&format!("{name}-{m}")))]));
    }
    if let Some(Value::Mapping(m)) = &i.def.volumes {
        for (k, v) in m {
            volumes.insert(
                k.clone(),
                if v.is_null() {
                    Value::Mapping(Mapping::new())
                } else {
                    v.clone()
                },
            );
        }
    }
    let mut networks = Mapping::new();
    if on_farmy {
        networks.insert(s("farmy"), map(vec![("external", Value::Bool(true))]));
    }
    if let Some(Value::Mapping(m)) = &i.def.networks {
        for (k, v) in m {
            networks.insert(
                k.clone(),
                if v.is_null() {
                    Value::Mapping(Mapping::new())
                } else {
                    v.clone()
                },
            );
        }
    }

    if restricted {
        networks.insert(s("default"), map(vec![("internal", Value::Bool(true))]));
    }
    let mut root = Mapping::new();
    root.insert(s("name"), s(name));
    root.insert(s("services"), Value::Mapping(services));
    root.insert(s("volumes"), Value::Mapping(volumes));
    if !networks.is_empty() {
        root.insert(s("networks"), Value::Mapping(networks));
    }
    let text = serde_yaml::to_string(&Value::Mapping(root)).map_err(|e| e.to_string())?;
    Ok(substitute_ports(&text, i.block.map(|b| b.0).unwrap_or(0)))
}

/// `${FARMY_PORT_<n>}` → the n-th port of the block.
fn substitute_ports(text: &str, first: u32) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(pos) = rest.find("${FARMY_PORT_") {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + "${FARMY_PORT_".len()..];
        if let Some(end) = after.find('}')
            && let Ok(n) = after[..end].parse::<u32>()
        {
            out.push_str(&(first + n).to_string());
            rest = &after[end + 1..];
            continue;
        }
        out.push_str("${FARMY_PORT_");
        rest = after;
    }
    out.push_str(rest);
    out
}

/// The proxy variables added to a fragment service's `environment`, whatever its form (a map, a list, none).
fn with_env(service: &mut Value, pairs: &[(String, String)]) {
    let Some(m) = service.as_mapping_mut() else {
        return;
    };
    let key = s("environment");
    match m.get_mut(&key) {
        Some(Value::Sequence(list)) => {
            for (k, v) in pairs {
                if !list.iter().any(|e| {
                    e.as_str()
                        .map(|e| e.starts_with(&format!("{k}=")))
                        .unwrap_or(false)
                }) {
                    list.push(s(&format!("{k}={v}")));
                }
            }
        }
        Some(Value::Mapping(env)) => {
            for (k, v) in pairs {
                env.entry(s(k)).or_insert_with(|| s(v));
            }
        }
        _ => {
            let mut env = Mapping::new();
            for (k, v) in pairs {
                env.insert(s(k), s(v));
            }
            m.insert(key, Value::Mapping(env));
        }
    }
}

/// A fragment service joins a network as well as its own: a service without `networks:` is on the
/// project's `default`, so it keeps that one too.
fn on_network(service: &mut Value, net: &str) {
    let Some(m) = service.as_mapping_mut() else {
        return;
    };
    let key = s("networks");
    match m.get_mut(&key) {
        Some(Value::Sequence(list)) => {
            if !list.iter().any(|n| n.as_str() == Some(net)) {
                list.push(s(net));
            }
        }
        Some(Value::Mapping(nets)) => {
            nets.entry(s(net)).or_insert(Value::Null);
        }
        _ => {
            m.insert(key, Value::Sequence(vec![s("default"), s(net)]));
        }
    }
}

#[cfg(test)]
mod dotfiles_git_tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::process::Command;

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "test cleanup: a leftover temporary folder is harmless"
            )]
            let _ = std::fs::set_permissions(
                self.0.join("dotfiles"),
                std::fs::Permissions::from_mode(0o755),
            );
            #[expect(
                clippy::let_underscore_must_use,
                reason = "test cleanup: a leftover temporary folder is harmless"
            )]
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn real_git_resolves_broker_urls_and_ssh_proxies_with_a_read_only_dotfiles_config() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = Scratch(
            std::env::temp_dir().join(format!("farmy-git-config-{}-{stamp}", std::process::id())),
        );
        let home = root.0.join("home");
        let dotfiles = root.0.join("dotfiles");
        let repo = root.0.join("repo");
        for path in [&home, &dotfiles, &repo] {
            std::fs::create_dir_all(path).unwrap();
        }
        let personal = "[core]\n\teditor = nvim\n[alias]\n\tst = status --short\n";
        let config = dotfiles.join(".gitconfig");
        std::fs::write(&config, personal).unwrap();
        std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o444)).unwrap();
        std::fs::set_permissions(&dotfiles, std::fs::Permissions::from_mode(0o555)).unwrap();
        symlink(&config, home.join(".gitconfig")).unwrap();
        let http = Route {
            name: "git".into(),
            secret: "GIT_TOKEN".into(),
            upstream: "https://git.example.com".into(),
            host: "git.example.com".into(),
            ssh_user: "git".into(),
            ssh_port: None,
            auth: "bearer".into(),
            who: "-".into(),
            git: true,
            expose: None,
            placeholder: None,
            services: None,
            encoding: None,
        };
        let ssh = Route {
            name: "forge".into(),
            host: "forge.example.com".into(),
            upstream: "-".into(),
            auth: "ssh".into(),
            ssh_port: Some("2222".into()),
            ..http.clone()
        };
        for (proxy, expected_proxy) in [
            (
                "http://egress-gate:9182",
                "nc -X connect -x egress-gate:9182",
            ),
            (
                "socks5h://farmy-egress:1055",
                "nc -X 5 -x farmy-egress:1055",
            ),
        ] {
            let mut environment = Mapping::new();
            environment.insert(s("ALL_PROXY"), s(proxy));
            environment.insert(s("HTTPS_PROXY"), s("http://egress-gate:9182"));
            environment.insert(s("GIT_CONFIG_COUNT"), s("1"));
            environment.insert(s("GIT_CONFIG_KEY_0"), s("core.pager"));
            environment.insert(s("GIT_CONFIG_VALUE_0"), s("cat"));
            dotfiles_git_config(&mut environment, &[&http, &ssh], &Settings::empty());
            let git = |args: &[&str]| {
                let output = Command::new("git")
                    .args(args)
                    .current_dir(&repo)
                    .env("HOME", &home)
                    .env("XDG_CONFIG_HOME", home.join(".config"))
                    .env("GIT_CONFIG_NOSYSTEM", "1")
                    .envs(
                        environment
                            .iter()
                            .map(|(k, v)| (k.as_str().unwrap(), v.as_str().unwrap())),
                    )
                    .output()
                    .unwrap();
                assert!(
                    output.status.success(),
                    "git {args:?}: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
                String::from_utf8(output.stdout).unwrap().trim().to_string()
            };
            git(&["init", "-q"]);
            git(&[
                "config",
                "remote.http.url",
                "https://git.example.com/acme/shop.git",
            ]);
            git(&[
                "config",
                "remote.ssh.url",
                "https://forge.example.com/acme/shop.git",
            ]);
            assert_eq!(
                git(&["remote", "get-url", "http"]),
                "http://keys:9181/git/acme/shop.git"
            );
            assert_eq!(
                git(&["remote", "get-url", "ssh"]),
                "ssh://git@forge.example.com:2222/acme/shop.git"
            );
            assert!(git(&["config", "--get", "core.sshCommand"]).contains(expected_proxy));
            assert_eq!(git(&["config", "--get", "core.editor"]), "nvim");
            assert_eq!(git(&["config", "--get", "core.pager"]), "cat");
        }
        assert_eq!(std::fs::read_to_string(config).unwrap(), personal);
    }
}
