//! Where farmy keeps things (FORMATS.md, "Where farmy keeps things"): the folder in use and its state
//! folder, the default home and its set-up, paths as messages write them, and `farmy config`.
//!
//! The folder in use, first match: `-C <dir>`, `FARMY_DIR`, the nearest folder holding a `farmy.yml`
//! (the current folder, then each parent), the default home. The default home keeps its configuration
//! in `$XDG_CONFIG_HOME/farmy` (else `~/.config/farmy`) and its state in `$XDG_STATE_HOME/farmy` (else
//! `~/.local/state/farmy`), on macOS too: never under `~/Library`. A project folder is its own state
//! folder. Once resolved, farmy works in the folder (it is the current folder for the rest of the
//! command) and `.work/` is under the state folder.
use crate::model::{Settings, parse_env};
use crate::{R, refuse, usage, warn};
use std::io::{IsTerminal, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;

/// The folder in use and where its state goes.
pub(crate) struct Folder {
    /// Absolute: the definitions, `.env`, `farmy.yml`.
    pub(crate) path: PathBuf,
    /// Absolute: `.work/` goes in it. The folder itself for a project folder.
    pub(crate) state: PathBuf,
    pub(crate) default_home: bool,
}

static FOLDER: OnceLock<Folder> = OnceLock::new();
static WORK_PATH: OnceLock<PathBuf> = OnceLock::new();

/// What a fresh `farmy.yml` holds: every default, and no `farmy:` pin.
const DEFAULT_FARMY_YML: &str = "# farmy's settings for the services defined here; every key is optional (farmy.example.yml shows them)\nformat: 1\n";

/// The `.gitignore` farmy writes when a folder has none, exactly so. Its last line keeps out a temporary
/// file a crash left behind: farmy's own in the folder are `.<file>.<anything>.tmp`.
const GITIGNORE: &str = "# farmy: kept out of git, so that no secret is ever committed\n.env\nservices/*.env\n.work/\n.*.tmp\n";

/// The marker of a machine that answered no to keeping the default home in git.
const DECLINED: &str = "config-git-declined";

/// `.work` of the folder in use: relative in a project folder (farmy runs in it), absolute under the
/// default home's state folder.
pub(crate) fn work() -> &'static Path {
    WORK_PATH.get_or_init(|| PathBuf::from(".work"))
}

/// The folder in use; before (or without) a resolution, the current folder as a project folder.
pub(crate) fn current() -> &'static Folder {
    FOLDER.get_or_init(|| {
        let here = cwd();
        Folder {
            path: here.clone(),
            state: here,
            default_home: false,
        }
    })
}

fn cwd() -> PathBuf {
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"))
}

/// The user's home: `FARMY_HOST_HOME` when set (the shim sets it: inside the control container `HOME`
/// is not the user's), else `HOME`.
/// An empty or relative value counts as unset.
pub(crate) fn user_home() -> Option<PathBuf> {
    ["FARMY_HOST_HOME", "HOME"].iter().find_map(|k| {
        std::env::var_os(k)
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
    })
}

/// An XDG base folder: the variable when it is an absolute path (empty or relative counts as unset),
/// else the fallback under the user's home; none without either.
fn xdg(var: &str, fallback: &str) -> Option<PathBuf> {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| user_home().map(|h| h.join(fallback)))
}

/// The default home's configuration folder; none when it needs `HOME` and there is none.
pub(crate) fn default_config() -> Option<PathBuf> {
    xdg("XDG_CONFIG_HOME", ".config").map(|p| p.join("farmy"))
}

/// The default home's state folder; none when it needs `HOME` and there is none.
pub(crate) fn default_state() -> Option<PathBuf> {
    xdg("XDG_STATE_HOME", ".local/state").map(|p| p.join("farmy"))
}

/// The default home was reached and one of its paths needs a `HOME` there is not: nothing is created.
fn no_home<T>() -> R<T> {
    refuse(
        "farmy: the default home needs HOME, which is not set or not an absolute path — set HOME (or XDG_CONFIG_HOME and XDG_STATE_HOME), or name the folder with FARMY_DIR or -C <dir>; nothing was created",
    )
}

/// A path as messages write it: `~/…` under the user's home, any other path absolute.
pub(crate) fn shown(p: &Path) -> String {
    if let Some(home) = user_home().filter(|h| h.parent().is_some())
        && let Ok(rest) = p.strip_prefix(&home)
    {
        return if rest.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", rest.display())
        };
    }
    p.display().to_string()
}

/// Absolute, from the current folder, with `.` and `..` taken as `cd` takes them.
fn absolute(p: &Path) -> PathBuf {
    let joined = if p.is_absolute() {
        p.to_path_buf()
    } else {
        cwd().join(p)
    };
    let mut out = PathBuf::from("/");
    for c in joined.components() {
        match c {
            Component::Normal(n) => out.push(n),
            Component::ParentDir => {
                out.pop();
            }
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
    out
}

fn same(a: &Path, b: &Path) -> bool {
    a == b
        || matches!(
            (std::fs::canonicalize(a), std::fs::canonicalize(b)),
            (Ok(x), Ok(y)) if x == y
        )
}

/// The folder in use (see the module's comment). `-C` naming no folder is a mistake in the command
/// line, `FARMY_DIR` naming none a refusal; neither creates anything.
pub(crate) fn resolve(dash_c: Option<&str>) -> R<Folder> {
    let path = if let Some(dir) = dash_c {
        let p = absolute(Path::new(dir));
        if !p.is_dir() {
            return usage(format!(
                "farmy: -C {}: no such folder — -C names a folder that exists; nothing was created",
                shown(&p)
            ));
        }
        p
    } else if let Some(dir) = std::env::var_os("FARMY_DIR").filter(|v| !v.is_empty()) {
        let p = absolute(Path::new(&dir));
        if !p.is_dir() {
            return refuse(format!(
                "farmy: FARMY_DIR names {}, which is no folder — make it, or unset FARMY_DIR to use {}; nothing was created",
                shown(&p),
                default_config().map_or_else(|| "the default home".into(), |h| shown(&h))
            ));
        }
        p
    } else {
        match cwd()
            .ancestors()
            .find(|d| d.join("farmy.yml").is_file())
            .map(Path::to_path_buf)
            .or_else(default_config)
        {
            Some(p) => p,
            None => return no_home(),
        }
    };
    // the default home's config folder is the default home however it is reached
    if let Some(home) = default_config().filter(|h| same(&path, h)) {
        let Some(state) = default_state() else {
            return no_home();
        };
        Ok(Folder {
            path: home,
            state,
            default_home: true,
        })
    } else {
        Ok(Folder {
            state: path.clone(),
            path,
            default_home: false,
        })
    }
}

/// Resolves the folder in use and goes into it for the rest of the command: the hint for an old
/// containers folder, the default home's set-up (unless `set_up` is false: `init` sets it up once
/// Docker answered), the current folder, `.work`.
pub(crate) fn enter(dash_c: Option<&str>, set_up: bool) -> R {
    let folder = resolve(dash_c)?;
    if folder.default_home {
        old_folder_hint(&folder.path);
        if set_up {
            set_up_default_home(&folder)?;
        }
    }
    if folder.path.is_dir() {
        std::env::set_current_dir(&folder.path)?;
    }
    let work = if folder.default_home {
        folder.state.join(".work")
    } else {
        PathBuf::from(".work")
    };
    #[expect(
        clippy::let_underscore_must_use,
        reason = "set once per command, here, before anything reads it"
    )]
    let _ = WORK_PATH.set(work);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "set once per command, here, before anything reads it"
    )]
    let _ = FOLDER.set(folder);
    Ok(())
}

/// `init`'s part, once Docker answered: the default home set up when it is not yet, and gone into.
pub(crate) fn set_up_for_init() -> R {
    let folder = current();
    if folder.default_home {
        set_up_default_home(folder)?;
        std::env::set_current_dir(&folder.path)?;
    }
    Ok(())
}

/// The current folder looks like a containers folder of the time before the default home: farmy says
/// which folder it uses and how to keep this one. It never writes here.
fn old_folder_hint(home: &Path) {
    let here = cwd();
    if same(&here, home) || here.join("farmy.yml").is_file() {
        return;
    }
    let definitions = std::fs::read_dir(here.join("services"))
        .into_iter()
        .flatten()
        .flatten()
        .any(|e| e.path().extension().is_some_and(|x| x == "yml"));
    let identity = std::fs::read_to_string(here.join(".env"))
        .map(|t| parse_env(&t).contains_key("GIT_USER_NAME"))
        .unwrap_or(false);
    if definitions || identity {
        warn(format!(
            "farmy: using {}; this folder has no farmy.yml — to keep using it: touch farmy.yml (or farmy -C .)",
            shown(home)
        ));
    }
}

/// Writes a `farmy.yml` with every default when the folder has none; true when it wrote one.
pub(crate) fn write_default_farmy_yml(dir: &Path) -> R<bool> {
    let file = dir.join("farmy.yml");
    if file.exists() {
        return Ok(false);
    }
    std::fs::write(&file, DEFAULT_FARMY_YML)?;
    Ok(true)
}

fn write_gitignore(dir: &Path) -> R {
    let file = dir.join(".gitignore");
    if !file.exists() {
        std::fs::write(&file, GITIGNORE)?;
    }
    Ok(())
}

/// The default home without a `farmy.yml` is set up: the folder, `services/`, `farmy.yml`, `.gitignore`,
/// and on a terminal the one question whether to keep it in git. One with a `farmy.yml` (a clone from
/// another machine) is left as it is.
fn set_up_default_home(folder: &Folder) -> R {
    let dir = &folder.path;
    if dir.join("farmy.yml").exists() {
        return Ok(());
    }
    std::fs::create_dir_all(dir.join("services"))?;
    write_default_farmy_yml(dir)?;
    write_gitignore(dir)?;
    let declined = folder.state.join(".work").join(DECLINED);
    if !std::io::stdin().is_terminal() || git_toplevel(dir).is_some() || declined.exists() {
        return Ok(());
    }
    let mut err = std::io::stderr();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "showing the question; an unflushed question still reads the answer"
    )]
    let _ = write!(err, "Keep {} in git? [y/N] ", shown(dir)).and_then(|()| err.flush());
    let mut line = String::new();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "end of input or a read error is a no, like an empty line"
    )]
    let _ = std::io::stdin().read_line(&mut line);
    if matches!(line.trim().to_lowercase().as_str(), "y" | "yes") {
        if let Err(e) = make_repository(dir, &|m| warn(m)) {
            warn(format!("farmy: {e}"));
        }
    } else {
        std::fs::create_dir_all(declined.parent().unwrap_or(&folder.state))?;
        std::fs::write(&declined, "")?;
    }
    Ok(())
}

/// `git -C <dir> …`, run as whoever farmy runs as: the folder may be the host user's.
fn git(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C").arg(dir).args(["-c", "safe.directory=*"]);
    c
}

fn git_ok(dir: &Path, args: &[&str]) -> R {
    let out = git(dir)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("git {} in {}: {e}", args.join(" "), shown(dir)))?;
    if out.status.success() {
        Ok(())
    } else {
        refuse(format!(
            "git {} in {} failed: {}",
            args.join(" "),
            shown(dir),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn git_value(dir: &Path, args: &[&str]) -> Option<String> {
    let out = git(dir)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !value.is_empty()).then_some(value)
}

/// The top folder of the Git repository the folder is in (its own or a parent's): `FARMY_HOST_GIT_TOP`
/// when set and not empty (the shim looks on the host: inside the control container a parent's `.git`
/// is not mounted), else what git says where farmy runs.
fn git_toplevel(dir: &Path) -> Option<PathBuf> {
    std::env::var_os("FARMY_HOST_GIT_TOP")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| git_value(dir, &["rev-parse", "--show-toplevel"]).map(PathBuf::from))
}

/// The commit's identity, first found: farmy's environment (the shim passes the host's), the folder's
/// `.env`; what neither has is left to git's own configuration (`user.name`, `GIT_AUTHOR_NAME`, …).
/// The `-c` options that give git what farmy found.
fn identity_options(dir: &Path) -> Vec<String> {
    let settings = std::fs::read_to_string(dir.join(".env"))
        .ok()
        .map(|t| Settings::from_text(&t))
        .unwrap_or_else(Settings::empty);
    let mut options = vec![];
    for (key, placeholder, git_key) in [
        ("GIT_USER_NAME", "Your Name", "user.name"),
        ("GIT_USER_EMAIL", "you@example.com", "user.email"),
    ] {
        let found = std::env::var(key)
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .or_else(|| {
                settings
                    .get(key)
                    .filter(|v| *v != placeholder)
                    .map(str::to_string)
            });
        if let Some(value) = found {
            options.extend(["-c".to_string(), format!("{git_key}={value}")]);
        }
    }
    options
}

/// git init in the folder and the first commit: `.gitignore` (written when there is none), `farmy.yml`
/// and whatever `services/` holds, never a `.env`. Without a Git identity the repository is made and
/// nothing is committed; the error says how to give one.
fn make_repository(dir: &Path, say: &dyn Fn(String)) -> R {
    write_gitignore(dir)?;
    git_ok(dir, &["init", "-q"])?;
    let mut add = vec!["add", "--", ".gitignore"];
    if dir.join("farmy.yml").is_file() {
        add.push("farmy.yml");
    }
    if dir.join("services").is_dir() {
        add.extend(["services", ":(exclude)services/*.env"]);
    }
    let later = format!("git -C {0} add -A && git -C {0} commit", shown(dir));
    let committed = git_ok(dir, &add).and_then(|()| {
        let mut commit = identity_options(dir);
        commit.extend(
            [
                "commit",
                "-q",
                "-m",
                "Keep farmy's settings and service definitions in git",
            ]
            .map(String::from),
        );
        let out = git(dir)
            .args(&commit)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("git commit in {}: {e}", shown(dir)))?;
        if out.status.success() {
            return Ok(());
        }
        let said = String::from_utf8_lossy(&out.stderr);
        if said.contains("tell me who you are")
            || said.contains("auto-detect")
            || said.contains("empty ident")
        {
            refuse(format!(
                "{0} is a Git repository now, with nothing committed: the commit needs a Git identity — GIT_USER_NAME and GIT_USER_EMAIL in {0}/.env (farmy init writes them) or git config --global user.name / user.email; then: {later}",
                shown(dir)
            ))
        } else {
            refuse(format!(
                "{} is a Git repository now, with nothing committed: git commit failed: {}",
                shown(dir),
                said.trim()
            ))
        }
    });
    committed?;
    say(format!(
        "{} is a Git repository now: .gitignore, farmy.yml and services/ committed (never a .env). Later changes: {later}",
        shown(dir)
    ));
    Ok(())
}

/// The folder as `status` prints it: for the default home with its state folder.
pub(crate) fn folder_text() -> String {
    let f = current();
    if f.default_home {
        format!("{} (state in {})", shown(&f.path), shown(&f.state))
    } else {
        shown(&f.path)
    }
}

/// The folder farmy looked in, as messages name it.
pub(crate) fn looked_in() -> String {
    shown(&current().path)
}

/// `"folder"` of `status --json`: both absolute (the same path twice for a project folder).
pub(crate) fn folder_json() -> serde_json::Value {
    let f = current();
    serde_json::json!({
        "path": f.path.display().to_string(),
        "state": f.state.display().to_string(),
    })
}

const CONFIG_USAGE: &str =
    "usage: farmy config path (the folder in use) | farmy config git (keep it in git)";

/// `farmy config`'s words, checked before the folder is resolved: a mistake sets nothing up.
pub(crate) fn check_config_args(args: &[String]) -> R {
    match args {
        [w] if w == "path" || w == "git" => Ok(()),
        [] => usage(format!("farmy config needs a word — {CONFIG_USAGE}")),
        [w, ..] => usage(format!("farmy config: unknown '{w}' — {CONFIG_USAGE}")),
    }
}

/// `farmy config path | git`.
#[expect(
    clippy::print_stdout,
    reason = "farmy config answers on stdout: the path, what git did"
)]
pub(crate) fn config(args: &[String]) -> R {
    check_config_args(args)?;
    let dir = &current().path;
    if args[0] == "path" {
        println!("{}", dir.display());
        return Ok(());
    }
    if let Some(top) = git_toplevel(dir) {
        println!(
            "{} is already in the Git repository {}: nothing to do",
            shown(dir),
            shown(&top)
        );
        return Ok(());
    }
    make_repository(dir, &|m| println!("{m}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absolute_takes_dots_as_cd_does() {
        assert_eq!(
            absolute(Path::new("/home/dana/work/../containers/./x")),
            PathBuf::from("/home/dana/containers/x")
        );
        assert_eq!(absolute(Path::new("/..")), PathBuf::from("/"));
    }

    #[test]
    fn the_gitignore_keeps_secrets_and_state_out() {
        assert_eq!(
            GITIGNORE,
            "# farmy: kept out of git, so that no secret is ever committed\n.env\nservices/*.env\n.work/\n.*.tmp\n"
        );
        assert!(DEFAULT_FARMY_YML.starts_with('#') && DEFAULT_FARMY_YML.ends_with("format: 1\n"));
        assert_eq!(DEFAULT_FARMY_YML.lines().count(), 2);
    }
}
