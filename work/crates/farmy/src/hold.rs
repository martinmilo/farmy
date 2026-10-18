//! The holder: the values the host gave (the unlocking values, and without a provider the routes'
//! secrets), kept in one process's memory for the life of the control container, so that later loads
//! need nobody at a terminal. Never on disk. It listens on a Unix socket (`FARMY_HOLD_SOCKET`, default
//! `/run/farmy/hold.sock`, mode 0600), answers one JSON request per connection, and exits when its socket
//! file is gone or replaced; `farmy lock` clears it and ends it.
use crate::R;
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub(crate) fn socket() -> PathBuf {
    std::env::var("FARMY_HOLD_SOCKET")
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/farmy/hold.sock"))
}

fn ask(request: &serde_json::Value) -> Option<serde_json::Value> {
    let mut stream = UnixStream::connect(socket()).ok()?;
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the timeout only bounds a stuck holder; the exchange works without it"
    )]
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    writeln!(stream, "{request}").ok()?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// What the holder has; nothing when no holder runs.
pub(crate) fn get() -> BTreeMap<String, String> {
    ask(&serde_json::json!({ "op": "get" }))
        .and_then(|v| v.get("values").and_then(|m| m.as_object()).cloned())
        .map(|m| {
            m.into_iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// Hands values to the holder, starting it when none runs. Quietly does nothing where it cannot.
pub(crate) fn put(values: &BTreeMap<String, String>) {
    if values.is_empty() {
        return;
    }
    let request = serde_json::json!({ "op": "put", "values": values });
    if ask(&request).is_some() {
        return;
    }
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    use std::os::unix::process::CommandExt;
    // a session of its own (setsid, in busybox and util-linux), so that the end of a `docker exec -t` that
    // started it does not hang it up; a process group of its own where setsid is missing
    let spawn = |program: &std::path::Path, args: &[&str]| {
        std::process::Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .process_group(0)
            .spawn()
    };
    let exe_text = exe.display().to_string();
    let started = spawn(std::path::Path::new("setsid"), &[&exe_text, "hold"])
        .or_else(|_| spawn(&exe, &["hold"]));
    if started.is_err() {
        return;
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if ask(&request).is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Clears the holder and ends it; false when none was running.
pub(crate) fn clear() -> bool {
    ask(&serde_json::json!({ "op": "clear" })).is_some()
}

/// `farmy hold`: the holder itself.
pub(crate) fn serve() -> R {
    let path = socket();
    if let Some(dir) = path.parent() {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the bind below reports a missing folder"
        )]
        let _ = std::fs::create_dir_all(dir);
    }
    if UnixStream::connect(&path).is_ok() {
        return Ok(()); // one runs already
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a stale socket from an earlier run may be there; the bind below reports a real problem"
    )]
    let _ = std::fs::remove_file(&path);
    let listener = bind_socket(&path, make_private)?;
    let inode = std::fs::metadata(&path).map(|m| m.ino()).unwrap_or(0);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "cannot fail on a socket just bound; if it did, accept would block instead of polling"
    )]
    let _ = listener.set_nonblocking(true);
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "a socket option on an accepted connection; the exchange works without it"
                )]
                let _ = stream.set_nonblocking(false);
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "a socket option on an accepted connection; the exchange works without it"
                )]
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                let request: serde_json::Value =
                    serde_json::from_str(&line).unwrap_or(serde_json::Value::Null);
                let mut out = &stream;
                match request.get("op").and_then(|o| o.as_str()) {
                    Some("put") => {
                        if let Some(m) = request.get("values").and_then(|m| m.as_object()) {
                            for (k, v) in m {
                                if let Some(v) = v.as_str() {
                                    values.insert(k.clone(), v.to_string());
                                }
                            }
                        }
                        #[expect(
                            clippy::let_underscore_must_use,
                            reason = "the answer goes back to the asker; if it has gone away there is no one to tell"
                        )]
                        let _ = writeln!(out, "{}", serde_json::json!({ "ok": true }));
                    }
                    Some("get") => {
                        #[expect(
                            clippy::let_underscore_must_use,
                            reason = "the answer goes back to the asker; if it has gone away there is no one to tell"
                        )]
                        let _ = writeln!(out, "{}", serde_json::json!({ "values": values }));
                    }
                    Some("clear") => {
                        values.clear();
                        #[expect(
                            clippy::let_underscore_must_use,
                            reason = "the answer goes back to the asker; if it has gone away there is no one to tell"
                        )]
                        let _ = writeln!(out, "{}", serde_json::json!({ "ok": true }));
                        #[expect(
                            clippy::let_underscore_must_use,
                            reason = "the holder ends; a socket left behind is replaced at the next start"
                        )]
                        let _ = std::fs::remove_file(&path);
                        return Ok(());
                    }
                    _ => {
                        #[expect(
                            clippy::let_underscore_must_use,
                            reason = "the answer goes back to the asker; if it has gone away there is no one to tell"
                        )]
                        let _ =
                            writeln!(out, "{}", serde_json::json!({ "error": "unknown request" }));
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // gone or replaced: the folder was removed, or another holder took the path
                if std::fs::metadata(&path).map(|m| m.ino()).unwrap_or(0) != inode {
                    return Ok(());
                }
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(_) => std::thread::sleep(Duration::from_millis(200)),
        }
    }
}

/// Gives the socket file at `path` mode 0600, and checks that it has it.
fn make_private(path: &Path) -> std::io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let mode = std::fs::metadata(path)?.permissions().mode() & 0o777;
    if mode == 0o600 {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "its mode is {mode:o} after chmod"
        )))
    }
}

/// Binds the holder's socket at `path`, never open to anyone but its owner: created under umask
/// 0177, so it is 0600 from the start, then made 0600 by `make_private` (a chmod, checked). A socket
/// that cannot be made 0600 is removed, and the holder does not start.
fn bind_socket(
    path: &Path,
    make_private: impl Fn(&Path) -> std::io::Result<()>,
) -> R<UnixListener> {
    // the umask is the process's; this one is only the holder, with no other thread yet, and the
    // previous mask is back right after the bind, before anything else is created
    let previous = rustix::process::umask(rustix::fs::Mode::from_raw_mode(0o177));
    let bound = UnixListener::bind(path);
    rustix::process::umask(previous);
    let listener =
        bound.map_err(|e| format!("farmy hold: cannot listen on {}: {e}", path.display()))?;
    if let Err(e) = make_private(path) {
        drop(listener);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the holder refuses to start either way, and the error below names the socket"
        )]
        let _ = std::fs::remove_file(path);
        return Err(format!(
            "farmy hold: cannot make {} private (0600), so it is removed: {e}",
            path.display()
        )
        .into());
    }
    Ok(listener)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("farmy-hold-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("hold.sock")
    }

    #[test]
    fn a_socket_that_cannot_be_made_private_is_removed_and_refused_by_path() {
        let path = scratch("refused");
        let result = bind_socket(&path, |_| {
            Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
        });
        let exists = path.exists();
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
        let Err(error) = result else {
            panic!("bound a socket that could not be made 0600");
        };
        assert!(
            error.to_string().contains(&path.display().to_string()),
            "the error names the socket: {error}"
        );
        assert!(!exists, "the socket file was left behind");
    }

    #[test]
    fn the_holder_socket_is_0600() {
        let path = scratch("private");
        let listener = bind_socket(&path, make_private).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        drop(listener);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
        assert_eq!(mode, 0o600);
    }
}
