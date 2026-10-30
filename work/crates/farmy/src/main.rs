//! farmy — one set of containers per repository. It works in the folder in use (folder.rs): the default
//! home `~/.config/farmy`, or a project folder holding a `farmy.yml` (`services/<name>.yml`, .env). On a host, the `farmy` shim runs this
//! binary inside the control container; the acceptance tests run it directly. See README.md; the
//! formats and names are in FORMATS.md.
#![forbid(unsafe_code)]
mod agents;
mod commands;
mod compose;
mod docker;
mod egress;
mod entrypoint;
mod factory;
mod filter;
mod folder;
mod git_container;
mod hold;
mod home;
mod locking;
mod model;
mod secrets;
mod toolbox;
mod tui;
mod version;

use std::fmt;
use std::path::{Path, PathBuf};

/// How a command ends when it does not succeed: refused (exit 1, something to fix first) or a mistake
/// in the command line (exit 2). Every message goes to stderr and names what to look at.
#[derive(Debug)]
pub enum Fail {
    Refuse(String),
    Usage(String),
}

pub type R<T = ()> = Result<T, Fail>;

impl fmt::Display for Fail {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Fail::Refuse(m) | Fail::Usage(m) => write!(f, "{m}"),
        }
    }
}

impl From<String> for Fail {
    fn from(m: String) -> Self {
        Fail::Refuse(m)
    }
}

impl From<std::io::Error> for Fail {
    fn from(e: std::io::Error) -> Self {
        Fail::Refuse(e.to_string())
    }
}

pub(crate) fn refuse<T>(m: impl Into<String>) -> R<T> {
    Err(Fail::Refuse(m.into()))
}

pub(crate) fn usage<T>(m: impl Into<String>) -> R<T> {
    Err(Fail::Usage(m.into()))
}

/// `farmy <version> (<commit>)`: the short commit the sources were built from, or `commit unknown`
/// (build.rs). The build hash stays inside: the session compares it.
pub fn version_line() -> String {
    format!("farmy {} ({})", version::CURRENT, env!("FARMY_COMMIT"))
}

pub fn build_hash() -> &'static str {
    env!("FARMY_BUILD_HASH")
}

pub fn warn(m: impl AsRef<str>) {
    eprintln!("{}", m.as_ref());
}

/// The commands that work in a folder: every one but `help`, `--version`, `tui --version` and the
/// holder resolves the folder in use first (folder.rs). An unknown word sets nothing up.
const IN_A_FOLDER: &[&str] = &[
    "init",
    "config",
    "add",
    "update",
    "start",
    "restart",
    "rebuild",
    "stop",
    "destroy",
    "status",
    "url",
    "run",
    "keys",
    "agents",
    "logs",
    "ssh",
    "session",
    "tui",
    "unlock-names",
    "lock",
    "factory",
    "toolbox",
    "dotfiles",
    "egress",
];

/// Run as the user in the control container, farmy may have no account there: the shim gives it a home
/// (`HOME`) of its own, made here when it is not there yet, only for farmy's user (Docker's client
/// config, git's global config, the holder's socket go in it).
fn make_home() {
    use std::os::unix::fs::DirBuilderExt;
    if let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute() && h.parent().is_some_and(Path::is_dir) && !h.exists())
    {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "a home that cannot be made shows where it is needed, as before"
        )]
        let _ = std::fs::DirBuilder::new().mode(0o700).create(&home);
    }
}

#[expect(
    clippy::print_stdout,
    reason = "`farmy --version` and the update hint are farmy's answer on stdout"
)]
fn main() {
    make_home();
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    // -C <dir> before the command: the folder to use
    let mut dash_c: Option<String> = None;
    if args.first().map(String::as_str) == Some("-C") {
        if args.len() < 2 {
            eprintln!("farmy: -C needs a folder — farmy -C <dir> <command>");
            std::process::exit(2);
        }
        dash_c = Some(args[1].clone());
        args.drain(..2);
    }
    let cmd = args
        .first()
        .map(String::as_str)
        .unwrap_or("help")
        .to_string();
    let rest: Vec<String> = args.iter().skip(1).cloned().collect();
    let exempt = matches!(
        cmd.as_str(),
        "help" | "-h" | "--help" | "--version" | "-V" | "version" | "update"
    ) || (cmd == "tui" && rest.iter().any(|a| a == "--version"));
    let in_folder = IN_A_FOLDER.contains(&cmd.as_str())
        && !(cmd == "tui" && rest.iter().any(|a| a == "--version"));
    let entered = if !in_folder {
        Ok(())
    } else if cmd == "config" {
        folder::check_config_args(&rest).and_then(|()| folder::enter(dash_c.as_deref(), true))
    } else {
        // init sets the default home up only once Docker answered: nothing is written before. The shim's
        // unlock-names (no terminal) runs before the command itself, which is the one to set it up
        folder::enter(dash_c.as_deref(), cmd != "init" && cmd != "unlock-names")
    };
    let result = entered
        .and_then(|()| {
            if in_folder && !exempt {
                version::check_workspace()
            } else {
                Ok(())
            }
        })
        .and_then(|()| match cmd.as_str() {
            "help" | "-h" | "--help" => {
                commands::help();
                Ok(())
            }
            "--version" | "-V" | "version" => {
                println!("{}", version_line());
                Ok(())
            }
            "init" => commands::init(&rest),
            "config" => folder::config(&rest),
            "add" => commands::add(&rest),
            "update" => {
                println!("farmy update runs through the host shim: install the folder pin or latest release, or choose --to VERSION (FARMY_BUILD=1 rebuilds a local checkout)");
                Ok(())
            }
            "start" => commands::start(&rest, commands::Mode::Start),
            "restart" => commands::start(&rest, commands::Mode::Restart),
            "rebuild" => commands::start(&rest, commands::Mode::Rebuild),
            "stop" => commands::stop(&rest),
            "destroy" => commands::destroy(&rest),
            "status" => commands::status(&rest),
            "url" => commands::url(&rest),
            "run" => commands::run(&rest),
            "keys" => commands::keys(&rest),
            "agents" => commands::agents(&rest),
            "logs" => commands::logs(&rest),
            "ssh" => commands::ssh(&rest),
            "session" => commands::session(&rest),
            "tui" if rest.iter().any(|a| a == "--version") => {
                println!("{}", version_line());
                Ok(())
            }
            "tui" => tui::run(),
            "unlock-names" => commands::unlock_names(&rest),
            "lock" => commands::lock(&rest),
            "factory" => factory::main(&rest),
            "toolbox" => toolbox::main(&rest),
            "dotfiles" => home::main(&rest),
            "egress" => filter::main(&rest),
            "hold" => hold::serve(),
            other => usage(format!(
                "farmy: unknown command '{other}' — farmy help lists the commands"
            )),
        });
    match result {
        Ok(()) => {}
        Err(Fail::Refuse(m)) => {
            eprintln!("{m}");
            std::process::exit(1);
        }
        Err(Fail::Usage(m)) => {
            eprintln!("{m}");
            std::process::exit(2);
        }
    }
}
