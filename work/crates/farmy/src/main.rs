//! farmy — one set of containers per repository. Run in the folder that defines them
//! (`services/<name>.yml`, .env, farmy.yml): the containers folder. On a host, the `farmy` shim runs this
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

/// `farmy <version> (<build hash>)`: the hash is of the sources, set at build time (build.rs).
pub fn version_line() -> String {
    format!("farmy {} ({})", version::CURRENT, env!("FARMY_BUILD_HASH"))
}

pub fn build_hash() -> &'static str {
    env!("FARMY_BUILD_HASH")
}

pub fn warn(m: impl AsRef<str>) {
    eprintln!("{}", m.as_ref());
}

#[expect(
    clippy::print_stdout,
    reason = "`farmy --version` and the update hint are farmy's answer on stdout"
)]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
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
    let result = if !exempt { version::check_workspace() } else { Ok(()) }.and_then(|_| match cmd.as_str() {
        "help" | "-h" | "--help" => {
            commands::help();
            Ok(())
        }
        "--version" | "-V" | "version" => {
            println!("{}", version_line());
            Ok(())
        }
        "init" => commands::init(&rest),
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
        other => usage(format!("farmy: unknown command '{other}' — farmy help lists the commands")),
    });
    // on Docker Engine farmy runs as the control container's root: what it wrote is handed to the folder's owner
    if cmd != "help" && cmd != "--version" {
        model::hand_to_folder_owner();
    }
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
