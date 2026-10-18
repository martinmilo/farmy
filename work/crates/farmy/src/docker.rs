//! The docker CLI, and compose through it. Everything farmy does to containers goes through here, so
//! that the tests' fake docker on the PATH sees all of it.
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// stdout of a docker command (trimmed), or the error text when it failed.
pub(crate) fn out(args: &[&str]) -> Result<String, String> {
    let o = Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if o.status.success() {
        Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&o.stderr).trim().to_string())
    }
}

/// Whether what farmy prints reaches a terminal: its stdout is one, or the shim said its own stdout is
/// one (FARMY_TTY=1; with unlocking values on stdin `docker exec` cannot have `-t`).
pub(crate) fn tty_out() -> bool {
    use std::io::IsTerminal;
    std::io::stdout().is_terminal()
        || std::env::var("FARMY_TTY")
            .map(|v| v == "1")
            .unwrap_or(false)
}

/// Stdout and stderr together, whatever the exit code (a container's log: tailscaled logs on stderr).
pub(crate) fn out_both(args: &[&str]) -> String {
    match Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .output()
    {
        Ok(o) => format!(
            "{}\n{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        ),
        Err(_) => String::new(),
    }
}

/// A build: on a terminal its output is collapsed to its last line while it runs and shown in full
/// when it fails; without a terminal it comes as it is (`show`).
#[expect(
    clippy::print_stdout,
    reason = "a docker build's progress on the terminal, collapsed to one line"
)]
pub(crate) fn build_collapsed(args: &[&str]) -> bool {
    use std::io::{BufRead, Write};
    if !tty_out() {
        return show(args);
    }
    let Ok(mut child) = Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    else {
        return false;
    };
    let lines = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let mut readers = vec![];
    for stream in [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn std::io::Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn std::io::Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let lines = lines.clone();
        readers.push(std::thread::spawn(move || {
            for line in std::io::BufReader::new(stream)
                .lines()
                .map_while(Result::ok)
            {
                let shown: String = line.chars().take(100).collect();
                print!("\r\x1b[2K   {shown}");
                #[expect(clippy::let_underscore_must_use, reason = "progress on the terminal; a stdout that cannot flush must not stop the command")]
                let _ = std::io::stdout().flush();
                lines.lock().expect("the lines lock is poisoned only after a panic, which aborts in release builds").push(line);
            }
        }));
    }
    let ok = child.wait().map(|s| s.success()).unwrap_or(false);
    for r in readers {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "join only waits for the thread to finish; it fails only after a panic, which aborts in release builds"
        )]
        let _ = r.join();
    }
    print!("\r\x1b[2K");
    if !ok {
        for l in lines
            .lock()
            .expect("the lines lock is poisoned only after a panic, which aborts in release builds")
            .iter()
        {
            println!("   {l}");
        }
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "progress on the terminal; a stdout that cannot flush must not stop the command"
    )]
    let _ = std::io::stdout().flush();
    ok
}

pub(crate) fn ok(args: &[&str]) -> bool {
    out(args).is_ok()
}

/// A docker command with the terminal's stdout and stderr (builds, compose up, logs): true when it exited 0.
pub(crate) fn show(args: &[&str]) -> bool {
    Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Quiet unless it fails: stdout dropped, stderr shown.
pub(crate) fn quiet(args: &[&str]) -> bool {
    Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Interactive: the terminal's stdin, stdout and stderr (a shell, logs -f).
pub(crate) fn attach(args: &[&str]) -> bool {
    Command::new("docker")
        .args(args)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// `docker exec -i <container> <cmd…>` with a payload on its stdin, output dropped. The payload never
/// appears on a command line.
pub(crate) fn exec_stdin(container: &str, cmd: &[&str], payload: &str) -> bool {
    let mut args = vec!["exec", "-i", container];
    args.extend_from_slice(cmd);
    let child = Command::new("docker")
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn();
    let Ok(mut child) = child else { return false };
    if let Some(mut stdin) = child.stdin.take() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the command's exit status below says whether it took the payload"
        )]
        let _ = stdin.write_all(payload.as_bytes());
    }
    child.wait().map(|s| s.success()).unwrap_or(false)
}

pub(crate) fn daemon_up() -> bool {
    quiet(&["ps"])
}

/// Container ids matching every filter; all = stopped ones too.
pub(crate) fn ps(filters: &[String], all: bool) -> Vec<String> {
    let mut args: Vec<String> = vec!["ps".into(), "-q".into()];
    if all {
        args.push("-a".into());
    }
    for f in filters {
        args.push("-f".into());
        args.push(f.clone());
    }
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    out(&refs)
        .map(|s| s.lines().map(String::from).collect())
        .unwrap_or_default()
}

pub(crate) fn app_cid(project: &str) -> Option<String> {
    ps(
        &[
            format!("label=com.docker.compose.project={project}"),
            "label=com.docker.compose.service=app".into(),
        ],
        false,
    )
    .into_iter()
    .next()
}

pub(crate) fn app_cid_any(project: &str) -> Option<String> {
    ps(
        &[
            format!("label=com.docker.compose.project={project}"),
            "label=com.docker.compose.service=app".into(),
        ],
        true,
    )
    .into_iter()
    .next()
}

pub(crate) fn has_containers(project: &str) -> bool {
    !ps(
        &[format!("label=com.docker.compose.project={project}")],
        true,
    )
    .is_empty()
}

pub(crate) fn any_running(project: &str) -> bool {
    !ps(
        &[format!("label=com.docker.compose.project={project}")],
        false,
    )
    .is_empty()
}

pub(crate) fn container_label(container: &str, key: &str) -> String {
    out(&[
        "inspect",
        "-f",
        &format!("{{{{ index .Config.Labels \"{key}\" }}}}"),
        container,
    ])
    .unwrap_or_default()
}

pub(crate) fn image_label(image: &str, key: &str) -> String {
    out(&[
        "image",
        "inspect",
        "-f",
        &format!("{{{{ index .Config.Labels \"{key}\" }}}}"),
        image,
    ])
    .unwrap_or_default()
}

/// Whether a container has a subpath of the farmy-shared volume mounted read-only at `target`, over the
/// shared parent; false when it cannot be inspected.
pub(crate) fn has_read_only_shared_submount(container: &str, target: &str) -> bool {
    let Ok(json) = out(&["inspect", "-f", "{{json .Mounts}}", container]) else {
        return false;
    };
    serde_json::from_str::<Vec<serde_json::Value>>(&json).is_ok_and(|mounts| {
        mounts
            .iter()
            .any(|m| m["Destination"] == target && m["Name"] == "farmy-shared" && m["RW"] == false)
    })
}

pub(crate) fn volume_exists(name: &str) -> bool {
    ok(&["volume", "inspect", name])
}

pub(crate) fn ensure_volume(name: &str) {
    if !volume_exists(name) {
        let _ = quiet(&["volume", "create", name]);
    }
}

pub(crate) fn ensure_network(name: &str) {
    if !ok(&["network", "inspect", name]) {
        let _ = quiet(&["network", "create", name]);
    }
}

/// `docker compose -p <project> [-f <file>] <args…>`, output shown.
pub(crate) fn compose(project: &str, file: Option<&Path>, args: &[&str], visible: bool) -> bool {
    let mut full: Vec<String> = vec!["compose".into(), "-p".into(), project.into()];
    if let Some(f) = file {
        full.push("-f".into());
        full.push(f.display().to_string());
    }
    full.extend(args.iter().map(|a| a.to_string()));
    let refs: Vec<&str> = full.iter().map(String::as_str).collect();
    if visible { show(&refs) } else { quiet(&refs) }
}

/// `docker exec [-u user] [-w dir] <container> <cmd…>`, output shown; true when it exited 0.
/// Like `exec`, with the command's exit code (None when docker could not be run).
pub(crate) fn exec_code(
    container: &str,
    user: Option<&str>,
    workdir: Option<&str>,
    cmd: &[&str],
) -> Option<i32> {
    let mut args: Vec<&str> = vec!["exec"];
    if let Some(u) = user {
        args.push("-u");
        args.push(u);
    }
    if let Some(w) = workdir {
        args.push("-w");
        args.push(w);
    }
    args.push(container);
    args.extend_from_slice(cmd);
    Command::new("docker")
        .args(&args)
        .stdin(Stdio::null())
        .status()
        .ok()
        .and_then(|s| s.code())
}

pub(crate) fn exec_out(container: &str, cmd: &[&str]) -> String {
    let mut args = vec!["exec", container];
    args.extend_from_slice(cmd);
    out(&args).unwrap_or_default()
}
