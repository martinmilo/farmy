//! The mesh egress node (FORMATS.md, "Mesh egress"): one container, farmy-egress, running tailscaled in
//! userspace mode as a SOCKS5 and HTTP CONNECT proxy on the farmy network; the proxy variables every
//! container and the provider get; joining by auth key or by the registration URL from the node's log.
use crate::model::{Config, WORK};
use crate::{R, docker, warn};
use std::collections::BTreeMap;
use std::path::PathBuf;

pub(crate) const PROXY: &str = "farmy-egress:1055";
const NAME: &str = "farmy-egress";

/// The proxy variables, in both cases; `names`: the compose project's own names (the service, keys,
/// the fragment's services) that must not go through the proxy. Empty without egress:.
pub(crate) fn proxy_env(cfg: &Config, names: &[String]) -> Vec<(String, String)> {
    if cfg
        .egress
        .as_ref()
        .map(|e| !e.mesh && e.proxy.is_none())
        .unwrap_or(true)
    {
        return vec![];
    }
    let mut no_proxy: Vec<String> = vec![
        "localhost".into(),
        "127.0.0.1".into(),
        "host.docker.internal".into(),
    ];
    no_proxy.extend(names.iter().cloned());
    no_proxy.extend(["farmy", "farmy-egress", "farmy-knowledge"].map(String::from));
    // FARMY_EGRESS_PROXY: a proxy of your own (or a test's) instead of the egress node's
    let existing = cfg.egress.as_ref().and_then(|e| e.proxy.clone());
    let proxy = std::env::var("FARMY_EGRESS_PROXY")
        .ok()
        .filter(|p| !p.trim().is_empty())
        .or_else(|| existing.clone())
        .unwrap_or_else(|| PROXY.to_string());
    let http = if proxy.starts_with("http://") {
        proxy.clone()
    } else {
        format!("http://{proxy}")
    };
    let mut pairs = vec![("HTTP_PROXY", http.clone()), ("HTTPS_PROXY", http)];
    if existing.is_none() {
        pairs.push((
            "ALL_PROXY",
            format!("socks5h://{}", proxy.trim_start_matches("http://")),
        ));
    }
    pairs.push(("NO_PROXY", no_proxy.join(",")));
    let mut out = vec![];
    for (k, v) in pairs {
        out.push((k.to_string(), v.clone()));
        out.push((k.to_lowercase(), v));
    }
    out
}

const USERSPACE_NOTE: &str = "only names under the tailnet's suffix resolve through the proxy";

/// The node's compose file. Everything is written into the command itself: compose fills $NAME in the
/// whole file from the environment of `docker compose`, so a `$` written here is `$$`. The node's own
/// `tailscale up` runs once beside tailscaled when the login goes by URL (every up or login makes a new
/// node key); with an auth key the one login is farmy's exec.
fn compose_text(kernel: bool, by_url: bool, login_args: &str) -> String {
    let tun = if kernel {
        ""
    } else {
        " --tun=userspace-networking"
    };
    let mut script = format!(
        "tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock{tun} --socks5-server=:1055 --outbound-http-proxy-listen=:1055 & sleep 2; "
    );
    if by_url {
        script.push_str(&format!("tailscale up --timeout=0{login_args} || true; "));
    }
    script.push_str("wait");
    let kernel_keys = if kernel {
        "    devices: [\"/dev/net/tun:/dev/net/tun\"]\n    cap_add: [NET_ADMIN]\n"
    } else {
        ""
    };
    format!(
        "name: {NAME}\nservices:\n  egress:\n    image: tailscale/tailscale:stable\n    container_name: {NAME}\n    hostname: {NAME}\n    init: true\n    restart: unless-stopped\n    networks: [farmy]\n{kernel_keys}    entrypoint: [\"/bin/sh\", \"-c\"]\n    command:\n      - {}\n    volumes:\n      - {NAME}:/var/lib/tailscale\nvolumes:\n  {NAME}:\n    external: true\nnetworks:\n  farmy:\n    external: true\n",
        serde_json::to_string(&script.replace('$', "$$")).unwrap_or_default()
    )
}

/// The node came up: tailscaled answers within a few seconds (a kernel-mode node without a working
/// TUN device exits instead).
fn node_answers() -> bool {
    for _ in 0..15 {
        let out = docker::exec_out(NAME, &["tailscale", "status", "--json"]);
        if serde_json::from_str::<serde_json::Value>(&out)
            .map(|v| v.get("BackendState").is_some())
            .unwrap_or(false)
        {
            return true;
        }
        let running = docker::out(&["inspect", "-f", "{{.State.Running}}", NAME])
            .map(|s| s.trim() == "true")
            .unwrap_or(false);
        if !running {
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    true
}

fn mode_file() -> PathBuf {
    dir().join("mode")
}

fn mode() -> String {
    std::fs::read_to_string(mode_file())
        .map(|m| m.trim().to_string())
        .ok()
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "kernel".into())
}

fn dir() -> PathBuf {
    PathBuf::from(WORK).join(NAME)
}

fn url_file() -> PathBuf {
    dir().join("registration-url")
}

/// The node's state from `tailscale status --json` in the container: Running with name and address, or
/// the backend state as a word.
fn node_status() -> (String, Option<String>, Option<String>) {
    let out = docker::exec_out(NAME, &["tailscale", "status", "--json"]);
    let v: serde_json::Value = serde_json::from_str(&out).unwrap_or(serde_json::Value::Null);
    let state = v["BackendState"].as_str().unwrap_or("").to_string();
    let name = v["Self"]["DNSName"]
        .as_str()
        .map(|n| n.trim_end_matches('.').to_string());
    let address = v["Self"]["TailscaleIPs"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|a| a.as_str())
        .map(String::from);
    (state, name, address)
}

/// The registration URL: a line of the node's log (stdout or stderr) that is nothing but an https URL,
/// as tailscale prints it under "To authenticate, visit:".
fn registration_url_from_log() -> Option<String> {
    let log = docker::out_both(&["logs", NAME]);
    log.lines()
        .map(str::trim)
        .find(|l| l.starts_with("https://") && !l.contains(' '))
        .map(String::from)
}

fn elapsed_text(secs: u64) -> String {
    if secs >= 60 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{secs}s")
    }
}

/// The node up and joined, before the provider runs: nothing without egress:.
#[expect(
    clippy::print_stdout,
    reason = "the egress node's progress and its login URL are for the user on the terminal"
)]
pub(crate) fn ensure(cfg: &Config, unlock: Option<&BTreeMap<String, String>>) -> R {
    let Some(e) = &cfg.egress else { return Ok(()) };
    if !e.mesh {
        return Ok(()); // an existing proxy: nothing to start
    }
    println!("== egress");
    docker::ensure_network("farmy");
    docker::ensure_volume(NAME);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the mode and URL files below are best effort; the node itself runs from its volume"
    )]
    let _ = std::fs::create_dir_all(dir());
    // the node's own process: tailscaled, and one `tailscale up` beside it when the login goes by URL
    // (the container stays up whatever that call does; every up or login makes a new node key, so it
    // runs once); with an auth key the one login is farmy's exec below
    // Everything is written into the command itself: compose fills $NAME in the whole file from the
    // environment of `docker compose`, before the container exists, so a value under environment: never
    // reaches a $NAME in the command. A `$` in what is written here would be compose's, hence `$$`.
    let login_server = e
        .login_server
        .as_deref()
        .map(|u| format!("--login-server={u}"));
    let login_args = format!(
        " --accept-dns=true{}",
        login_server
            .as_ref()
            .map(|l| format!(" {l}"))
            .unwrap_or_default()
    );
    // kernel mode first (the TUN device and NET_ADMIN: tailscaled manages the resolver, so the proxies
    // resolve every name the tailnet's DNS knows); userspace mode when the daemon will not have it
    let file = dir().join("compose.yml");
    let mut mode = "kernel";
    std::fs::write(&file, compose_text(true, e.authkey.is_none(), &login_args))?;
    let mut up = docker::compose(NAME, Some(&file), &["up", "-d", "--remove-orphans"], false)
        && node_answers();
    if !up {
        mode = "userspace";
        let _ = docker::compose(NAME, Some(&file), &["down"], false);
        std::fs::write(&file, compose_text(false, e.authkey.is_none(), &login_args))?;
        up = docker::compose(NAME, Some(&file), &["up", "-d", "--remove-orphans"], false);
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the recorded mode only saves a restart next time; a missing file means the node is brought up again"
    )]
    let _ = std::fs::write(mode_file(), format!("{mode}\n"));
    if !up {
        warn(format!(
            "note: couldn't start the egress node — try: docker compose -p {NAME} -f {} up -d",
            file.display()
        ));
        return Ok(());
    }
    if mode == "userspace" {
        warn(format!(
            "egress: {USERSPACE_NOTE} (the Docker daemon gave the node no TUN device or no NET_ADMIN, so it runs in userspace mode)"
        ));
    }
    // the auth key: an unlocking value, handed to the node on stdin, never on a command line or in a file
    let key = e
        .authkey
        .as_ref()
        .and_then(|k| unlock.and_then(|u| u.get(k)));
    if let (Some(key), state) = (key, node_status().0)
        && state != "Running"
    {
        let up = format!("read -r k; tailscale up --auth-key=\"$k\"{login_args}");
        if !docker::exec_stdin(NAME, &["sh", "-c", &up], &format!("{key}\n")) {
            warn("note: the egress node did not take the auth key — docker logs farmy-egress");
        }
    }
    let started = std::time::Instant::now();
    let deadline = started + std::time::Duration::from_secs(e.join_timeout_secs);
    let tty = docker::tty_out();
    let mut printed: Option<String> = None;
    let mut last_line: Option<std::time::Instant> = None;
    let live = |elapsed: u64, url: &str, tty: bool| {
        let line = format!(
            "egress: waiting for registration · {} of {} · {url}",
            elapsed_text(elapsed),
            e.join_timeout
        );
        if tty {
            print!("\r\x1b[2K{line}");
        } else {
            println!("{line}");
        }
        #[expect(
            clippy::let_underscore_must_use,
            reason = "progress on the terminal; a stdout that cannot flush must not stop the command"
        )]
        let _ = std::io::Write::flush(&mut std::io::stdout());
    };
    loop {
        let (state, name, address) = node_status();
        if state == "Running" {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the login URL is no longer needed; an absent file is fine"
            )]
            let _ = std::fs::remove_file(url_file());
            if printed.is_some() {
                if tty {
                    print!("\r\x1b[2K");
                }
                println!(
                    "egress: registered as {} {}",
                    name.unwrap_or_default(),
                    address.unwrap_or_default()
                );
            }
            return Ok(());
        }
        // the log is read again and again: the URL may appear only once tailscaled has reached the control server
        if printed.is_none()
            && let Some(url) = registration_url_from_log()
        {
            println!(
                "egress: this node is not registered on the mesh yet. Register it on the control server:\n\n    {url}\n\nwaiting up to {} for that; farmy start goes on after (services that need no mesh still work)",
                e.join_timeout
            );
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the login URL is also printed; the file only lets a later command show it again"
            )]
            let _ = std::fs::write(url_file(), format!("{url}\n"));
            printed = Some(url);
        }
        if let Some(url) = &printed {
            let due = last_line
                .map(|t| t.elapsed() >= std::time::Duration::from_secs(if tty { 1 } else { 30 }))
                .unwrap_or(true);
            if due {
                live(started.elapsed().as_secs(), url, tty);
                last_line = Some(std::time::Instant::now());
            }
        }
        if std::time::Instant::now() >= deadline {
            if tty && printed.is_some() {
                println!();
            }
            match &printed {
                Some(url) => warn(format!(
                    "egress: the node is still unregistered — mesh hosts stay out of reach until it is: {url}"
                )),
                None => warn(
                    "egress: the node did not join within the time limit and printed no registration URL — docker logs farmy-egress",
                ),
            }
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(
            if e.join_timeout_secs <= 5 { 300 } else { 2000 },
        ));
    }
}

/// The registration URL of an unregistered node, for the messages of others (a failed clone).
pub(crate) fn unregistered_url(cfg: &Config) -> Option<String> {
    let v = status_json(cfg);
    (v["state"] == "unregistered")
        .then(|| v["registration_url"].as_str().map(String::from))
        .flatten()
}

/// The egress entry of status --json: null without egress:.
pub(crate) fn status_json(cfg: &Config) -> serde_json::Value {
    let Some(e) = &cfg.egress else {
        return serde_json::Value::Null;
    };
    if let Some(p) = &e.proxy {
        return serde_json::json!({ "state": "proxy", "name": null, "address": null, "registration_url": null, "proxy": p, "mode": "proxy", "note": null });
    }
    if !e.mesh {
        return serde_json::Value::Null;
    }
    let running = docker::out(&["inspect", "-f", "{{.State.Running}}", NAME])
        .map(|s| s.trim() == "true")
        .unwrap_or(false);
    let (state, name, address, url) = if !running {
        ("stopped", None, None, None)
    } else {
        let (s, name, address) = node_status();
        if s == "Running" {
            ("registered", name, address, None)
        } else {
            let url = std::fs::read_to_string(url_file())
                .ok()
                .map(|u| u.trim().to_string())
                .filter(|u| !u.is_empty())
                .or_else(registration_url_from_log);
            ("unregistered", None, None, url)
        }
    };
    let mode = mode();
    let note = (mode == "userspace").then_some(USERSPACE_NOTE);
    serde_json::json!({ "state": state, "name": name, "address": address, "registration_url": url, "proxy": PROXY, "mode": mode, "note": note })
}

/// The status line: `egress  <state>  <name> <address>`, the URL instead when unregistered.
pub(crate) fn status_line(cfg: &Config) -> Option<String> {
    let v = status_json(cfg);
    if v.is_null() {
        return None;
    }
    let state = v["state"].as_str().unwrap_or("");
    let rest = match state {
        "proxy" => {
            return Some(format!(
                "{:<12} proxy    {}",
                "egress",
                v["proxy"].as_str().unwrap_or("")
            ));
        }
        "registered" => format!(
            "{} {}",
            v["name"].as_str().unwrap_or(""),
            v["address"].as_str().unwrap_or("")
        ),
        "unregistered" => v["registration_url"]
            .as_str()
            .map(|u| format!("register this node: {u}"))
            .unwrap_or_else(|| "no registration URL yet — docker logs farmy-egress".into()),
        _ => "farmy start <service> brings it up".into(),
    };
    let note = v["note"]
        .as_str()
        .map(|n| format!("  ({n})"))
        .unwrap_or_default();
    let mode = v["mode"]
        .as_str()
        .map(|m| format!("  {m} mode"))
        .unwrap_or_default();
    Some(format!("{:<12} {state:<8} {rest}{mode}{note}", "egress"))
}

pub(crate) fn stop(cfg: &Config) {
    if cfg.egress.as_ref().map(|e| !e.mesh).unwrap_or(true) {
        return;
    }
    let file = dir().join("compose.yml");
    if file.is_file() {
        let _ = docker::compose(NAME, Some(&file), &["stop"], false);
    }
}
