//! Farmy-owned Git processes all start here. The caller supplies a checkout and a script;
//! transport, credentials and Docker lifecycle are identical for every operation.
use crate::{
    commands::Ctx,
    docker, egress,
    secrets::{self, Route},
};
use std::{
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};

pub(crate) type Output = (i32, String, String);

pub(crate) struct Request {
    pub service: String,
    pub operation: String,
    pub image: String,
    pub name: String,
    pub user: String,
    pub workdir: String,
    pub mounts: Vec<String>,
    pub labels: Vec<(String, String)>,
    pub env: Vec<(String, String)>,
    pub config: Vec<(String, String)>,
}

impl Request {
    pub(crate) fn new(service: &str, operation: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Self {
            service: service.into(),
            operation: operation.into(),
            image: format!("farmy/{service}:dev"),
            name: format!(
                "{service}-git-{operation}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ),
            user: "dev".into(),
            workdir: "/workspace".into(),
            mounts: vec![],
            labels: vec![],
            env: vec![],
            config: vec![],
        }
    }
}

/// App Git and the short-lived helpers use the same routes and proxy command. Passing the
/// hostname to nc's SOCKS5/CONNECT request leaves name resolution to the remote proxy.
pub(crate) fn transport_config(
    routes: &[&Route],
    proxy: &[(String, String)],
) -> Vec<(String, String)> {
    let mut pairs = vec![];
    for route in routes.iter().filter(|r| r.git) {
        if route.is_ssh() {
            pairs.push((
                format!("url.{}/.insteadOf", route.ssh_base()),
                format!("https://{}/", route.host),
            ));
        } else {
            pairs.push((
                format!("url.http://keys:9181/{}/.insteadOf", route.name),
                format!("{}/", route.upstream.trim_end_matches('/')),
            ));
        }
    }
    let value = |key| {
        proxy
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    };
    let socks = value("ALL_PROXY").filter(|v| v.starts_with("socks5"));
    let via = match socks.or_else(|| value("HTTPS_PROXY")) {
        Some(url) => {
            let address = url
                .split_once("://")
                .map(|(_, a)| a)
                .unwrap_or(url)
                .trim_end_matches('/');
            let address = if address
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b".-_:".contains(&b))
            {
                address.to_string()
            } else {
                shell_quote(address)
            };
            let command = format!(
                "nc -X {} -x {address} %h %p",
                if socks.is_some() { "5" } else { "connect" }
            );
            format!(" -o ProxyCommand={}", shell_quote(&command))
        }
        None => String::new(),
    };
    if !via.is_empty() || routes.iter().any(|r| r.git && r.is_ssh()) {
        pairs.push((
            "core.sshCommand".into(),
            format!("ssh -o StrictHostKeyChecking=accept-new{via}"),
        ));
    }
    pairs
}

pub(crate) fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// [`run_raw`], with what the script printed as text.
pub(crate) fn run(ctx: &Ctx, request: Request, script: &str) -> Output {
    let (code, stdout, stderr) = run_raw(ctx, request, script);
    (code, String::from_utf8_lossy(&stdout).into(), stderr)
}

/// Create first, join farmy, then start: older Docker engines accept only one network at
/// creation. No Git process runs before both its broker and its proxy are reachable. What the
/// script printed comes back byte for byte.
pub(crate) fn run_raw(ctx: &Ctx, request: Request, script: &str) -> (i32, Vec<u8>, String) {
    let routes = secrets::granted(&ctx.routes, &request.service);
    let proxy = egress::proxy_env(&ctx.cfg, &["keys".into(), request.service.clone()]);
    let mut config = vec![
        ("core.hooksPath".into(), "/dev/null".into()),
        ("core.fsmonitor".into(), "false".into()),
    ];
    for (env, key) in [
        ("GIT_USER_NAME", "user.name"),
        ("GIT_USER_EMAIL", "user.email"),
    ] {
        if let Some(value) = ctx.settings.get(env) {
            config.push((key.into(), value.into()));
        }
    }
    config.extend(request.config);
    config.extend(transport_config(&routes, &proxy));
    let mut env = vec![
        ("GIT_TERMINAL_PROMPT".into(), "0".into()),
        ("HOME".into(), "/tmp".into()),
    ];
    env.extend(request.env);
    env.extend(proxy);
    env.push(("GIT_CONFIG_COUNT".into(), config.len().to_string()));
    for (i, (key, value)) in config.into_iter().enumerate() {
        env.push((format!("GIT_CONFIG_KEY_{i}"), key));
        env.push((format!("GIT_CONFIG_VALUE_{i}"), value));
    }
    let mut args = vec![
        "create".into(),
        "--rm".into(),
        "--name".into(),
        request.name.clone(),
        "--label".into(),
        "farmy.role=git".into(),
        "--label".into(),
        format!("farmy.operation={}", request.operation),
        "--label".into(),
        format!("farmy.service={}", request.service),
        "-u".into(),
        request.user,
        "--network".into(),
        format!("{}_default", request.service),
    ];
    for (key, value) in request.labels {
        args.extend(["--label".into(), format!("{key}={value}")]);
    }
    for mount in request.mounts {
        args.extend(["-v".into(), mount]);
    }
    if routes.iter().any(|r| r.is_ssh()) {
        args.extend([
            "-v".into(),
            format!("{}-keys-agent:/run/farmy-keys", request.service),
        ]);
        env.push(("SSH_AUTH_SOCK".into(), "/run/farmy-keys/agent.sock".into()));
    }
    for (key, value) in env {
        args.extend(["-e".into(), format!("{key}={value}")]);
    }
    args.extend([
        "-w".into(),
        request.workdir,
        "--entrypoint".into(),
        "sh".into(),
        request.image,
        "-c".into(),
        script.into(),
    ]);
    match Command::new("docker")
        .args(&args)
        .stdin(Stdio::null())
        .output()
    {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            return (
                o.status.code().unwrap_or(1),
                vec![],
                String::from_utf8_lossy(&o.stderr).into(),
            );
        }
        Err(e) => return (1, vec![], e.to_string()),
    }
    docker::ensure_network("farmy");
    if let Err(error) = docker::out(&["network", "connect", "farmy", &request.name]) {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "removing the helper container; the error that led here is what is reported"
        )]
        let _ = docker::out(&["rm", "-f", &request.name]);
        return (
            1,
            vec![],
            format!(
                "the git container {} could not join the farmy network: {error}",
                request.name
            ),
        );
    }
    match Command::new("docker")
        .args(["start", "-a", &request.name])
        .stdin(Stdio::null())
        .output()
    {
        Ok(o) => (
            o.status.code().unwrap_or(1),
            o.stdout,
            String::from_utf8_lossy(&o.stderr).into(),
        ),
        Err(e) => {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "removing the helper container; the error that led here is what is reported"
            )]
            let _ = docker::out(&["rm", "-f", &request.name]);
            (1, vec![], e.to_string())
        }
    }
}
