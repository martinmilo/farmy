//! Execs into a running app container that run its entrypoint in a mode (`farmy-entrypoint --git-config`),
//! FORMATS.md → Execs into a running app container. An entrypoint from before a mode ignores the flag,
//! starts up as usual and waits forever, so a mode is run only when the container's image says it has it:
//! the `farmy.entrypoint.modes` label, which the toolbox build sets from the script's own declaration
//! (`# farmy-entrypoint-modes: …`). Each exec is limited to FARMY_EXEC_TIMEOUT seconds, stopped inside
//! the container on expiry (`timeout` runs there), and a failure always names its exit status.
use crate::docker;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub(crate) const ENTRYPOINT: &str = "/usr/local/bin/farmy-entrypoint";
pub(crate) const MODES_LABEL: &str = "farmy.entrypoint.modes";
const DECLARATION: &str = "# farmy-entrypoint-modes:";
const DEFAULT_TIMEOUT: u64 = 60;
/// How long past the in-container limit the `docker exec` client is given before it is killed too.
const GRACE: Duration = Duration::from_secs(5);

/// The modes an entrypoint script declares in a `# farmy-entrypoint-modes: git-config …` line.
pub(crate) fn declared_modes(script: &str) -> Vec<String> {
    script
        .lines()
        .filter_map(|l| l.trim().strip_prefix(DECLARATION))
        .flat_map(|rest| {
            rest.split([',', ' ', '\t'])
                .filter(|m| !m.is_empty())
                .map(String::from)
        })
        .collect()
}

/// The modes the image of a running container has; none for an image built before modes were labelled.
pub(crate) fn container_modes(cid: &str) -> Vec<String> {
    // a missing label reads as "<no value>"
    let label = |v: String| if v == "<no value>" { String::new() } else { v };
    let mut value = label(docker::container_label(cid, MODES_LABEL));
    if value.is_empty() {
        let image = docker::out(&["inspect", "-f", "{{.Image}}", cid]).unwrap_or_default();
        if !image.is_empty() {
            value = label(docker::image_label(&image, MODES_LABEL));
        }
    }
    value
        .split([',', ' ', '\t'])
        .filter(|m| !m.is_empty())
        .map(String::from)
        .collect()
}

pub(crate) fn supports(cid: &str, mode: &str) -> bool {
    container_modes(cid).iter().any(|m| m == mode)
}

/// The line for a container whose image predates a mode farmy needs.
pub(crate) fn older(name: &str) -> String {
    format!("[{name}] built by an older farmy: farmy rebuild {name}")
}

/// FARMY_EXEC_TIMEOUT in seconds; 60 when unset or not a positive whole number.
pub(crate) fn timeout_secs() -> u64 {
    std::env::var("FARMY_EXEC_TIMEOUT")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(DEFAULT_TIMEOUT)
}

pub(crate) struct Ran {
    /// The exit status; a signal is given as 128 + its number, as a shell does.
    pub(crate) code: i32,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
    pub(crate) timed_out: bool,
}

fn collect(stream: Option<impl Read + Send + 'static>) -> mpsc::Receiver<String> {
    let (tx, rx) = mpsc::channel();
    if let Some(mut s) = stream {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            #[expect(
                clippy::let_underscore_must_use,
                reason = "a read error keeps what was read so far; the output is only shown"
            )]
            let _ = s.read_to_end(&mut buf);
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the receiver stops waiting after a while; a late result is not needed"
            )]
            let _ = tx.send(String::from_utf8_lossy(&buf).into_owned());
        });
    }
    rx
}

/// `docker exec <opts…> <container> timeout <n> <cmd…>`: the command under the time limit inside the
/// container, and the client killed shortly after the limit should the container not end it.
pub(crate) fn exec_limited(
    opts: &[String],
    cid: &str,
    cmd: &[&str],
    secs: u64,
) -> std::io::Result<Ran> {
    let mut args: Vec<String> = vec!["exec".into()];
    args.extend(opts.iter().cloned());
    args.push(cid.into());
    args.extend(["timeout".into(), secs.to_string()]);
    args.extend(cmd.iter().map(|c| c.to_string()));
    let started = Instant::now();
    let mut child = Command::new("docker")
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let out = collect(child.stdout.take());
    let err = collect(child.stderr.take());
    let deadline = started + Duration::from_secs(secs) + GRACE;
    let mut killed = false;
    let status = loop {
        if let Some(s) = child.try_wait()? {
            break s;
        }
        if Instant::now() >= deadline {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the client may have ended by itself just now; it is waited for next either way"
            )]
            let _ = child.kill();
            killed = true;
            break child.wait()?;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    // Something left running in the container can hold the output open; it is not waited for.
    let wait = Duration::from_secs(2);
    let stdout = out.recv_timeout(wait).unwrap_or_default();
    let stderr = err.recv_timeout(wait).unwrap_or_default();
    let code = status.code().unwrap_or_else(|| {
        use std::os::unix::process::ExitStatusExt;
        128 + status.signal().unwrap_or(0)
    });
    // `timeout` ends with 124 when the limit stopped the command
    let timed_out = killed || (code == 124 && started.elapsed() >= Duration::from_secs(secs));
    Ok(Ran {
        code,
        stdout,
        stderr,
        timed_out,
    })
}

/// `[<name>] <what> failed: exit <n>`, then the last lines the command wrote to stderr.
pub(crate) fn failure(name: &str, what: &str, code: i32, stderr: &str) -> String {
    let lines: Vec<&str> = stderr
        .lines()
        .map(str::trim_end)
        .filter(|l| !l.trim().is_empty())
        .collect();
    let mut m = format!("[{name}] {what} failed: exit {code}");
    for l in &lines[lines.len().saturating_sub(5)..] {
        m.push_str(&format!("\n[{name}]   {l}"));
    }
    m
}

/// Runs `cmd` in the container under FARMY_EXEC_TIMEOUT. Its stdout is shown whatever the outcome; Err
/// is the line to report when it does not end in time or fails.
#[expect(
    clippy::print_stdout,
    reason = "the command's output in the container is for the user on the terminal"
)]
pub(crate) fn run(
    name: &str,
    what: &str,
    opts: &[String],
    cid: &str,
    cmd: &[&str],
) -> Result<(), String> {
    let secs = timeout_secs();
    let ran = exec_limited(opts, cid, cmd, secs)
        .map_err(|e| format!("[{name}] {what} failed: docker could not be run: {e}"))?;
    print!("{}", ran.stdout);
    if ran.timed_out {
        return Err(format!(
            "[{name}] {what} timed out after {secs}s: {}",
            cmd.join(" ")
        ));
    }
    if ran.code != 0 {
        return Err(failure(name, what, ran.code, &ran.stderr));
    }
    Ok(())
}

/// Runs the entrypoint in `mode` as `user`, as `run` does; an image without the mode is skipped
/// without running anything in it.
pub(crate) fn run_mode(
    name: &str,
    cid: &str,
    user: &str,
    mode: &str,
    what: &str,
) -> Result<(), String> {
    if !supports(cid, mode) {
        return Err(older(name));
    }
    run(
        name,
        what,
        &["-u".into(), user.into()],
        cid,
        &[ENTRYPOINT, &format!("--{mode}")],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_declared_modes() {
        assert_eq!(
            declared_modes("#!/bin/sh\n# farmy-entrypoint-modes: git-config home\nset -e\n"),
            vec!["git-config", "home"]
        );
        assert!(declared_modes("#!/bin/sh\n# given --git-config it starts up anyway\n").is_empty());
    }

    #[test]
    fn a_failure_always_names_its_exit_status() {
        assert_eq!(failure("shop", "x", 3, ""), "[shop] x failed: exit 3");
        assert_eq!(
            failure("shop", "x", 1, "a\n\nb\n"),
            "[shop] x failed: exit 1\n[shop]   a\n[shop]   b"
        );
    }
}
