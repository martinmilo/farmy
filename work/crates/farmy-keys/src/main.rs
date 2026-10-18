//! farmy-keys — the keys broker next to each app container. One token proxy with named routes:
//! `http://keys:9181/<route>/<path>` is forwarded to the route's upstream with the secret added. It starts
//! with its routes and no secret; farmy loads the secrets over a Unix socket inside the container
//! (`farmy-keys load`, JSON on stdin) and the broker keeps them in memory. The contract is in FORMATS.md.
//!
//!   farmy-keys serve   FARMY_ROUTES, `FARMY_ROUTE_<NAME>`, FARMY_PORT (9181), FARMY_SOCKET (/run/farmy-keys.sock), FARMY_PUBLIC
//!   farmy-keys load    reads {"version":1,"secrets":{…}} on stdin and sends it to FARMY_SOCKET
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex, RwLock};

struct Route {
    name: String,
    upstream: String, // scheme://host[:port][/prefix], no trailing slash
    auth: String,     // basic | bearer | header
    who: String,      // the user (basic) or the header name (header)
    secret: String,   // the secret's name
    public: bool,     // forwarded without credentials while the secret is not loaded (a git route)
}

type Secrets = Arc<RwLock<HashMap<String, String>>>;

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    match mode.as_str() {
        "serve" => serve(),
        "load" => load(),
        "loaded" => loaded(),
        _ => {
            eprintln!("usage: farmy-keys serve | farmy-keys load | farmy-keys loaded");
            std::process::exit(2);
        }
    }
}

fn env_or(k: &str, def: &str) -> String {
    std::env::var(k)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| def.to_string())
}

fn routes_from_env() -> Vec<Route> {
    let mut out = vec![];
    for name in env_or("FARMY_ROUTES", "").split_whitespace() {
        let key = format!("FARMY_ROUTE_{}", name.to_uppercase().replace('-', "_"));
        let spec = std::env::var(&key).unwrap_or_default();
        let f: Vec<&str> = spec.split_whitespace().collect();
        if !(f.len() == 4 || (f.len() == 5 && f[4] == "public")) {
            eprintln!(
                "keys: route {name}: {key} must be \"<upstream> <auth> <user|header|-> <secret name> [public]\", got {spec:?}"
            );
            std::process::exit(1);
        }
        if !["basic", "bearer", "header", "ssh"].contains(&f[1]) {
            eprintln!(
                "keys: route {name}: auth must be basic, bearer, header or ssh, not {}",
                f[1]
            );
            std::process::exit(1);
        }
        out.push(Route {
            name: name.to_string(),
            upstream: f[0].trim_end_matches('/').to_string(),
            auth: f[1].into(),
            who: f[2].into(),
            secret: f[3].into(),
            public: f.len() == 5,
        });
    }
    out
}

fn serve() {
    let routes = Arc::new(routes_from_env());
    let secrets: Secrets = Arc::new(RwLock::new(HashMap::new()));
    let port = env_or("FARMY_PORT", "9181");
    let socket = env_or("FARMY_SOCKET", "/run/farmy-keys.sock");
    let public = std::env::var("FARMY_PUBLIC").ok().filter(|v| !v.is_empty());
    stop_with_parent_or_signal(&socket);
    start_agent_spawner();
    for r in routes.iter() {
        eprintln!(
            "keys: route {} → {} ({}, secret {})",
            r.name, r.upstream, r.auth, r.secret
        );
    }
    if routes.is_empty() {
        eprintln!("keys: no routes (FARMY_ROUTES is empty) — only /-/health answers");
    }

    // the loading socket: a private way in, inside the container only
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a stale socket from an earlier run may be there; the bind below reports a real problem"
    )]
    let _ = std::fs::remove_file(&socket);
    let listener = match UnixListener::bind(&socket) {
        Ok(l) => l,
        Err(e) => {
            use std::os::unix::fs::MetadataExt;
            let dir = std::path::Path::new(&socket)
                .parent()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "/".into());
            let about = std::fs::metadata(&dir)
                .map(|m| {
                    format!(
                        "owner {}:{}, mode {:o}",
                        m.uid(),
                        m.gid(),
                        m.mode() & 0o7777
                    )
                })
                .unwrap_or_else(|e| format!("cannot stat it: {e}"));
            let me = std::fs::metadata("/proc/self")
                .map(|m| m.uid())
                .unwrap_or(0);
            eprintln!(
                "keys: cannot listen on {socket}: {e} — the directory {dir} has {about}; this process runs as uid {me}"
            );
            std::process::exit(1);
        }
    };
    let loaded = secrets.clone();
    let ssh_routes: Vec<String> = routes
        .iter()
        .filter(|r| r.auth == "ssh")
        .map(|r| r.secret.clone())
        .collect();
    let agent_socket = env_or("FARMY_AGENT_SOCKET", "/run/farmy-keys/agent.sock");
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut s = stream;
            let mut buf = Vec::new();
            if s.read_to_end(&mut buf).is_ok() {
                // a query: the names of what the broker holds, one per line
                if serde_json::from_slice::<serde_json::Value>(&buf)
                    .ok()
                    .and_then(|v| {
                        v.get("query")
                            .and_then(|q| q.as_str())
                            .map(|q| q == "loaded")
                    })
                    .unwrap_or(false)
                {
                    let mut names: Vec<String> = loaded.read().expect("the secrets lock is poisoned only after a panic, which aborts in release builds").keys().cloned().collect();
                    names.sort();
                    #[expect(
                        clippy::let_underscore_must_use,
                        reason = "the answer goes back to `farmy-keys loaded`; if it has gone away there is no one to tell"
                    )]
                    let _ = s.write_all(
                        format!(
                            "ok\n{}",
                            names.iter().map(|n| format!("{n}\n")).collect::<String>()
                        )
                        .as_bytes(),
                    );
                    continue;
                }
                match parse_payload(&buf) {
                    Ok(mut map) => {
                        let ssh_keys: Vec<(String, String)> = ssh_routes
                            .iter()
                            .filter_map(|secret| {
                                map.get(secret).map(|v| (secret.clone(), v.clone()))
                            })
                            .collect();
                        let mut refused: Option<String> = None;
                        if !ssh_keys.is_empty() {
                            let keys: Vec<String> =
                                ssh_keys.iter().map(|(_, v)| v.clone()).collect();
                            match agent_load(&agent_socket, &keys) {
                                Ok(()) => {
                                    eprintln!("keys: the SSH agent holds {} key(s)", keys.len())
                                }
                                Err(e) => {
                                    // an SSH key counts as held only once the agent took it
                                    let hint = if ssh_keys
                                        .iter()
                                        .any(|(_, v)| looks_like_base64_key(v))
                                    {
                                        " — the value looks base64-encoded (it decodes to a key): encoding: base64 on the route"
                                    } else {
                                        ""
                                    };
                                    let why =
                                        format!("the SSH agent could not take the key: {e}{hint}");
                                    eprintln!("keys: {why}");
                                    for (secret, _) in &ssh_keys {
                                        map.remove(secret);
                                    }
                                    refused = Some(why);
                                }
                            }
                        }
                        let n = map.len();
                        *loaded.write().expect("the secrets lock is poisoned only after a panic, which aborts in release builds") = map;
                        eprintln!("keys: loaded {n} secret(s)");
                        match refused {
                            None => {
                                #[expect(
                                    clippy::let_underscore_must_use,
                                    reason = "the answer goes back to `farmy-keys load`; if it has gone away there is no one to tell"
                                )]
                                let _ = s.write_all(b"ok\n");
                            }
                            Some(why) => {
                                #[expect(
                                    clippy::let_underscore_must_use,
                                    reason = "the answer goes back to `farmy-keys load`; if it has gone away there is no one to tell"
                                )]
                                let _ = s.write_all(format!("error: {why}\n").as_bytes());
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("keys: a load was refused: {e}");
                        #[expect(
                            clippy::let_underscore_must_use,
                            reason = "the answer goes back to `farmy-keys load`; if it has gone away there is no one to tell"
                        )]
                        let _ = s.write_all(format!("error: {e}\n").as_bytes());
                    }
                }
            }
        }
    });

    let server = match tiny_http::Server::http(format!("0.0.0.0:{port}")) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("keys: cannot listen on :{port}: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("keys: listening on :{port}");
    let agent = Agents::from_env();
    for request in server.incoming_requests() {
        let routes = routes.clone();
        let secrets = secrets.clone();
        let agents = agent.clone();
        let public = public.clone();
        std::thread::spawn(move || handle(request, &routes, &secrets, &agents, public.as_deref()));
    }
}

/// The ssh-agent this broker started, with its socket: none while no SSH key was loaded, or while an agent
/// the broker did not start answers at the socket. It runs in the foreground as the broker's child, so the
/// broker can end it when it ends itself.
static AGENT: Mutex<Option<(std::process::Child, String)>> = Mutex::new(None);

type SpawnRequest = (
    String,
    std::sync::mpsc::Sender<std::io::Result<std::process::Child>>,
);

/// The thread that starts the SSH agent. On Linux the agent gets TERM when the thread that forked it ends
/// (PR_SET_PDEATHSIG), so it is forked from this thread, which lives as long as the broker; then even a
/// broker killed with KILL does not leave the agent behind.
static SPAWNER: Mutex<Option<std::sync::mpsc::Sender<SpawnRequest>>> = Mutex::new(None);

fn start_agent_spawner() {
    let (tx, rx) = std::sync::mpsc::channel::<SpawnRequest>();
    *SPAWNER.lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);
    std::thread::spawn(move || {
        for (socket, reply) in rx {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the asker blocks on recv until this arrives, so its receiver is still there"
            )]
            let _ = reply.send(spawn_agent(&socket));
        }
    });
}

/// `ssh-agent -D -a <socket>`: in the foreground, as the broker's child, so the broker can end it.
#[cfg_attr(
    target_os = "linux",
    expect(
        unsafe_code,
        reason = "pre_exec sets the agent's parent-death signal between fork and exec; no safe std or rustix API runs code there"
    )
)]
fn spawn_agent(socket: &str) -> std::io::Result<std::process::Child> {
    let mut cmd = std::process::Command::new("ssh-agent");
    cmd.args(["-D", "-a", socket])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::process::CommandExt;
        let broker = std::process::id();
        // SAFETY: the closure runs in the forked child before exec, where only async-signal-safe
        // calls are allowed. It makes three raw syscalls through rustix and std (prctl twice,
        // getppid), allocates nothing, takes no lock and touches no shared state; `broker` is a
        // copied u32.
        unsafe {
            cmd.pre_exec(move || {
                // an exec that changes the group (Debian installs ssh-agent setgid) clears the death signal;
                // without new privileges the exec keeps it. The agent still makes itself non-dumpable.
                rustix::thread::set_no_new_privs(true)?;
                rustix::process::set_parent_process_death_signal(Some(
                    rustix::process::Signal::Term,
                ))?;
                // the broker may have died before the prctl took effect
                if std::os::unix::process::parent_id() != broker {
                    return Err(rustix::io::Errno::SRCH.into());
                }
                Ok(())
            });
        }
    }
    cmd.spawn()
}

/// Asks the spawner thread for an agent; spawns here only when there is none (not expected in `serve`).
fn spawn_agent_from_spawner(socket: &str) -> std::io::Result<std::process::Child> {
    let sender = SPAWNER.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let Some(sender) = sender else {
        return spawn_agent(socket);
    };
    let (reply, answer) = std::sync::mpsc::channel();
    sender
        .send((socket.to_string(), reply))
        .map_err(|_| std::io::Error::other("the agent spawner is gone"))?;
    answer
        .recv()
        .map_err(|_| std::io::Error::other("the agent spawner is gone"))?
}

/// The broker ends on TERM or INT, and when the process that started it goes away; either way it first ends
/// the SSH agent it started and removes its loading socket.
fn stop_with_parent_or_signal(socket: &str) {
    use signal_hook::consts::{SIGINT, SIGTERM};
    // signal-hook's handler only writes to its own self-pipe; the stopping thread reads which signal came
    if let Ok(mut signals) = signal_hook::iterator::Signals::new([SIGTERM, SIGINT]) {
        let socket = socket.to_string();
        std::thread::spawn(move || {
            let why = match signals.forever().next() {
                Some(SIGINT) => "INT",
                _ => "TERM",
            };
            stop(&format!("stopped with {why}"), &socket);
        });
    }
    let parent = std::os::unix::process::parent_id();
    let socket = socket.to_string();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_millis(250));
            if std::os::unix::process::parent_id() != parent {
                stop("the process that started it went away", &socket);
            }
        }
    });
}

/// Ends the SSH agent this broker started, removes the loading socket and exits.
fn stop(why: &str, socket: &str) -> ! {
    // held until the exit, so no load starts another agent meanwhile
    let mut agent = AGENT.lock().unwrap_or_else(|e| e.into_inner());
    eprintln!("keys: {why} — stopping");
    if let Some((child, agent_socket)) = agent.take() {
        end_agent(child, &agent_socket);
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the broker exits next; a socket left behind is removed at the next start"
    )]
    let _ = std::fs::remove_file(socket);
    std::process::exit(0);
}

/// TERM, then KILL when the agent is still there 2 s later; its socket is removed either way.
fn end_agent(mut child: std::process::Child, socket: &str) {
    if child.try_wait().ok().flatten().is_none() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "a failed TERM is covered by the KILL after the deadline below"
        )]
        let _ = rustix::process::kill_process(
            rustix::process::Pid::from_child(&child),
            rustix::process::Signal::Term,
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while child.try_wait().ok().flatten().is_none() {
            if std::time::Instant::now() > deadline {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the agent may have exited since try_wait; the wait below reaps it either way"
                )]
                let _ = child.kill();
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "reaping only: the agent is gone either way"
                )]
                let _ = child.wait();
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "ssh-agent removes its own socket on TERM; this covers a KILL, and an absent file is fine"
    )]
    let _ = std::fs::remove_file(socket);
}

/// Whether an agent answers at `socket` (ssh-add -l exits 2 when it cannot reach one).
fn agent_answers(socket: &str) -> bool {
    std::process::Command::new("ssh-add")
        .arg("-l")
        .env("SSH_AUTH_SOCK", socket)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.code() != Some(2))
        .unwrap_or(false)
}

/// An ssh-agent at `socket` (started when none answers there), holding exactly the given keys, each fed on
/// the stdin of `ssh-add -`: the key text never touches a file or a command line.
fn agent_load(socket: &str, keys: &[String]) -> Result<(), String> {
    let mut agent = AGENT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((child, _)) = agent.as_mut()
        && child.try_wait().ok().flatten().is_some()
    {
        *agent = None;
    }
    if !agent_answers(socket) {
        if let Some((child, old)) = agent.take() {
            end_agent(child, &old);
        }
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the old agent is gone; an absent socket is fine, and the new agent's bind reports a real problem"
        )]
        let _ = std::fs::remove_file(socket);
        if let Some(dir) = std::path::Path::new(socket).parent() {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the new agent's bind reports a missing folder"
            )]
            let _ = std::fs::create_dir_all(dir);
        }
        let mut child = spawn_agent_from_spawner(socket).map_err(|e| format!("ssh-agent: {e}"))?;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if child.try_wait().ok().flatten().is_some() {
                return Err("ssh-agent did not start".into());
            }
            if agent_answers(socket) {
                break;
            }
            if std::time::Instant::now() > deadline {
                end_agent(child, socket);
                return Err("ssh-agent did not start".into());
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        *agent = Some((child, socket.to_string()));
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "emptying the agent before the keys go in; each ssh-add below is checked"
    )]
    let _ = std::process::Command::new("ssh-add")
        .arg("-D")
        .env("SSH_AUTH_SOCK", socket)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    for key in keys {
        let mut add = std::process::Command::new("ssh-add")
            .arg("-")
            .env("SSH_AUTH_SOCK", socket)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("ssh-add: {e}"))?;
        if let Some(mut stdin) = add.stdin.take() {
            let mut text = key.clone();
            if !text.ends_with('\n') {
                text.push('\n');
            }
            #[expect(
                clippy::let_underscore_must_use,
                reason = "ssh-add's exit status below says whether it took the key"
            )]
            let _ = stdin.write_all(text.as_bytes());
        }
        if !add.wait().map(|s| s.success()).unwrap_or(false) {
            return Err(
                "ssh-add did not accept a key (is it an unencrypted OpenSSH private key?)".into(),
            );
        }
    }
    Ok(())
}

fn parse_payload(buf: &[u8]) -> Result<HashMap<String, String>, String> {
    let v: serde_json::Value =
        serde_json::from_slice(buf).map_err(|e| format!("not JSON ({e})"))?;
    let map = v
        .get("secrets")
        .and_then(|s| s.as_object())
        .ok_or("no \"secrets\" object")?;
    let mut out = HashMap::new();
    for (k, val) in map {
        let s = val.as_str().ok_or_else(|| format!("{k} is not a string"))?;
        out.insert(k.clone(), s.to_string());
    }
    Ok(out)
}

fn text(status: u16, body: String) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    tiny_http::Response::from_string(body).with_status_code(status)
}

/// The upstream agents: direct, and through the proxy the environment names (HTTP_PROXY for http
/// upstreams, HTTPS_PROXY for https ones, as curl reads them; a host in NO_PROXY goes direct).
#[derive(Clone)]
struct Agents {
    direct: ureq::Agent,
    http_proxy: Option<ureq::Agent>,
    https_proxy: Option<ureq::Agent>,
    no_proxy: Vec<String>,
}

impl Agents {
    fn from_env() -> Agents {
        let builder = || {
            ureq::AgentBuilder::new()
                .redirects(0)
                .timeout(std::time::Duration::from_secs(300))
        };
        let var = |names: &[&str]| {
            names
                .iter()
                .find_map(|n| std::env::var(n).ok().filter(|v| !v.is_empty()))
        };
        let proxied = |url: Option<String>| {
            url.and_then(|u| ureq::Proxy::new(&u).ok())
                .map(|p| builder().proxy(p).build())
        };
        let http_proxy = proxied(var(&["http_proxy", "HTTP_PROXY"]));
        let https_proxy = proxied(var(&["https_proxy", "HTTPS_PROXY"]));
        if http_proxy.is_some() || https_proxy.is_some() {
            eprintln!("keys: upstreams through the proxy of the environment");
        }
        let no_proxy = var(&["no_proxy", "NO_PROXY"])
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        Agents {
            direct: builder().build(),
            http_proxy,
            https_proxy,
            no_proxy,
        }
    }

    fn for_upstream(&self, upstream: &str) -> &ureq::Agent {
        let host = upstream
            .split("://")
            .nth(1)
            .unwrap_or(upstream)
            .split('/')
            .next()
            .unwrap_or("")
            .split(':')
            .next()
            .unwrap_or("");
        let excluded = self.no_proxy.iter().any(|n| {
            n == "*" || host == n || host.ends_with(&format!(".{}", n.trim_start_matches('.')))
        });
        let proxied = if upstream.starts_with("https://") {
            &self.https_proxy
        } else {
            &self.http_proxy
        };
        match proxied {
            Some(a) if !excluded => a,
            _ => &self.direct,
        }
    }
}

fn handle(
    request: tiny_http::Request,
    routes: &[Route],
    secrets: &Secrets,
    agents: &Agents,
    public: Option<&str>,
) {
    let url = request.url().to_string();
    if url == "/-/health" {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the client may have hung up; there is no one left to answer"
        )]
        let _ = request.respond(text(200, "ok\n".into()));
        return;
    }
    let path = url.trim_start_matches('/');
    let (name, rest) = path.split_once('/').unwrap_or((path, ""));
    let Some(route) = routes.iter().find(|r| r.name == name) else {
        log(&request, 404);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the client may have hung up; there is no one left to answer"
        )]
        let _ = request.respond(text(
            404,
            format!(
                "farmy keys: no route named '{name}' (routes: {})\n",
                routes
                    .iter()
                    .map(|r| r.name.as_str())
                    .collect::<Vec<_>>()
                    .join(" ")
            ),
        ));
        return;
    };
    let secret = secret_for(route, rest, secrets);
    if route.auth == "ssh" {
        log(&request, 404);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the client may have hung up; there is no one left to answer"
        )]
        let _ = request.respond(text(
            404,
            format!(
                "farmy keys: '{}' is an SSH route: use the agent at SSH_AUTH_SOCK, not HTTP\n",
                route.name
            ),
        ));
        return;
    }
    if secret.is_none() && !route.public {
        log(&request, 503);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the client may have hung up; there is no one left to answer"
        )]
        let _ = request.respond(text(
            503,
            format!(
                "farmy keys: route '{}' is not loaded — farmy keys reload <service>\n",
                route.name
            ),
        ));
        return;
    };
    let target = format!("{}/{}", route.upstream, rest);
    let method = request.method().as_str().to_uppercase();
    let mut req = agents
        .for_upstream(&route.upstream)
        .request(&method, &target);
    for h in request.headers() {
        let field = h.field.as_str().as_str().to_ascii_lowercase();
        if [
            "host",
            "authorization",
            "content-length",
            "connection",
            "transfer-encoding",
            "accept-encoding",
        ]
        .contains(&field.as_str())
            || field == route.who.to_ascii_lowercase()
        {
            continue;
        }
        req = req.set(h.field.as_str().as_str(), h.value.as_str());
    }
    // a public route without its secret: the request goes on without credentials (public repositories)
    let Some(secret) = secret else {
        return forward(request, route, rest, req, public);
    };
    match route.auth.as_str() {
        "basic" => {
            let token = base64(&format!("{}:{secret}", route.who));
            req = req.set("Authorization", &format!("Basic {token}"));
        }
        "bearer" => req = req.set("Authorization", &format!("Bearer {secret}")),
        _ => req = req.set(&route.who, &secret),
    }
    forward(request, route, rest, req, public)
}

/// Sends the prepared request on and answers the client with what the upstream said.
fn forward(
    mut request: tiny_http::Request,
    route: &Route,
    rest: &str,
    req: ureq::Request,
    public: Option<&str>,
) {
    let method = request.method().as_str().to_uppercase();
    let mut body = Vec::new();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "kept as before: a body that fails mid-read is forwarded as far as it arrived (flagged in the sweep notes)"
    )]
    let _ = request.as_reader().read_to_end(&mut body);
    let result =
        if body.is_empty() && matches!(method.as_str(), "GET" | "HEAD" | "DELETE" | "OPTIONS") {
            req.call()
        } else {
            req.send_bytes(&body)
        };
    let response = match result {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => {
            eprintln!(
                "keys: ERROR {}: can't reach {}: {e}",
                route.name, route.upstream
            );
            log(&request, 502);
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the client may have hung up; there is no one left to answer"
            )]
            let _ = request.respond(text(
                502,
                format!(
                    "farmy keys: can't reach the upstream of '{}': {e}\n",
                    route.name
                ),
            ));
            return;
        }
    };
    let status = response.status();
    if status == 401 || status == 403 {
        eprintln!(
            "keys: WARN {} answered {status} for /{rest} — the secret {} may be expired, revoked or without access",
            route.name, route.secret
        );
    }
    let origin = origin_of(&route.upstream);
    let public_origin = public
        .map(str::to_string)
        .or_else(|| {
            request
                .headers()
                .iter()
                .find(|h| h.field.equiv("Host"))
                .map(|h| format!("http://{}", h.value))
        })
        .unwrap_or_default();
    let mut headers: Vec<tiny_http::Header> = vec![];
    for name in response.headers_names() {
        let lname = name.to_ascii_lowercase();
        if ["transfer-encoding", "connection", "content-length"].contains(&lname.as_str()) {
            continue;
        }
        for value in response.all(&name) {
            let value = if lname == "location" && value.starts_with(&format!("{origin}/")) {
                format!("{public_origin}/{}{}", route.name, &value[origin.len()..])
            } else {
                value.to_string()
            };
            if let Ok(h) = tiny_http::Header::from_bytes(name.as_bytes(), value.as_bytes()) {
                headers.push(h);
            }
        }
    }
    let mut out = Vec::new();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "kept as before: an upstream body that fails mid-read is returned as far as it arrived (flagged in the sweep notes)"
    )]
    let _ = response.into_reader().read_to_end(&mut out);
    log(&request, status);
    let mut resp = tiny_http::Response::from_data(out).with_status_code(status);
    for h in headers {
        resp.add_header(h);
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the client may have hung up; there is no one left to answer"
    )]
    let _ = request.respond(resp);
}

/// The secret for `/<owner>/…`: a per-owner one (`<secret>_<OWNER>`) when loaded, else the route's.
fn secret_for(route: &Route, rest: &str, secrets: &Secrets) -> Option<String> {
    let map = secrets
        .read()
        .expect("the secrets lock is poisoned only after a panic, which aborts in release builds");
    let owner = rest
        .split('/')
        .next()
        .unwrap_or("")
        .to_uppercase()
        .replace('-', "_");
    if !owner.is_empty()
        && let Some(v) = map.get(&format!("{}_{owner}", route.secret))
    {
        return Some(v.clone());
    }
    map.get(&route.secret).cloned()
}

fn origin_of(upstream: &str) -> String {
    let (scheme, rest) = upstream.split_once("://").unwrap_or(("http", upstream));
    format!("{scheme}://{}", rest.split('/').next().unwrap_or(rest))
}

fn log(request: &tiny_http::Request, status: u16) {
    eprintln!("keys: {} {} {status}", request.method(), request.url());
}

/// Standard base64 (padding optional, whitespace ignored) to bytes; None for anything else.
fn base64_decode(text: &str) -> Option<Vec<u8>> {
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
fn looks_like_base64_key(value: &str) -> bool {
    !value.contains("-----BEGIN")
        && base64_decode(value.trim())
            .map(|b| b.starts_with(b"-----BEGIN"))
            .unwrap_or(false)
}

fn base64(input: &str) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = input.as_bytes();
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = u32::from(b[0]) << 16 | u32::from(b[1]) << 8 | u32::from(b[2]);
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// `farmy-keys loaded`: asks the broker over its socket which secrets it holds, and prints their names.
#[expect(
    clippy::print_stdout,
    reason = "`farmy-keys loaded` prints the names for farmy to read"
)]
fn loaded() {
    let socket = env_or("FARMY_SOCKET", "/run/farmy-keys.sock");
    let mut stream = match UnixStream::connect(&socket) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("farmy-keys loaded: cannot reach the broker at {socket}: {e}");
            std::process::exit(1);
        }
    };
    if stream
        .write_all(br#"{"version":1,"query":"loaded"}"#)
        .is_err()
        || stream.shutdown(std::net::Shutdown::Write).is_err()
    {
        eprintln!("farmy-keys loaded: could not ask the broker");
        std::process::exit(1);
    }
    let mut answer = String::new();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "an unreadable answer is not \"ok\" and is reported as a failure below"
    )]
    let _ = stream.read_to_string(&mut answer);
    match answer.strip_prefix("ok\n") {
        Some(names) => print!("{names}"),
        None => {
            eprintln!("farmy-keys loaded: the broker answered: {}", answer.trim());
            std::process::exit(1);
        }
    }
}

fn load() {
    let socket = env_or("FARMY_SOCKET", "/run/farmy-keys.sock");
    let mut payload = Vec::new();
    if std::io::stdin().read_to_end(&mut payload).is_err() || parse_payload(&payload).is_err() {
        eprintln!("farmy-keys load: expected {{\"version\":1,\"secrets\":{{…}}}} on stdin");
        std::process::exit(1);
    }
    let mut stream = match UnixStream::connect(&socket) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("farmy-keys load: cannot reach the broker at {socket}: {e}");
            std::process::exit(1);
        }
    };
    if stream.write_all(&payload).is_err() || stream.shutdown(std::net::Shutdown::Write).is_err() {
        eprintln!("farmy-keys load: could not send the secrets");
        std::process::exit(1);
    }
    let mut answer = String::new();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "an unreadable answer is not \"ok\" and is reported as a failure below"
    )]
    let _ = stream.read_to_string(&mut answer);
    if answer.starts_with("ok") {
        std::process::exit(0);
    }
    eprintln!("farmy-keys load: the broker answered: {}", answer.trim());
    std::process::exit(1);
}
