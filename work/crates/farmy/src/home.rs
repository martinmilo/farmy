//! The shared dotfiles checkout and each service's applied revision.
use crate::{
    R,
    commands::Ctx,
    docker,
    model::{Config, Definition, WORK, definition_services},
    refuse, usage,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Dotfiles {
    pub repo: String,
    pub install: Option<String>,
}
/// Where an app container has the shared dotfiles clone: the read-only `dotfiles` subpath of farmy-shared.
pub(crate) const DOTFILES_IN_APP: &str = "/home/dev/.farmy-shared/dotfiles";
fn state_path(name: &str) -> PathBuf {
    PathBuf::from(WORK).join(name).join("dotfiles.json")
}
pub(crate) fn status(cfg: &Config, name: &str) -> serde_json::Value {
    if cfg.dotfiles.is_none() {
        return serde_json::json!({"revision":null,"state":"unconfigured"});
    }
    std::fs::read_to_string(state_path(name))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| serde_json::json!({"revision":null,"state":"unconfigured"}))
}
pub(crate) fn provision(name: &str) -> R {
    // Subpaths must exist before Compose mounts them. The clone itself is published later atomically.
    let _ = docker::quiet(&[
        "run",
        "--rm",
        "-u",
        "0",
        "-v",
        "farmy-shared:/shared",
        "--entrypoint",
        "chown",
        &format!("farmy/{name}:dev"),
        "1001:1001",
        "/shared",
    ]);
    let script = "mkdir -p /shared/dotfiles /shared/tool-data";
    if !docker::quiet(&[
        "run",
        "--rm",
        "--label",
        "farmy.role=home-init",
        "-u",
        "dev",
        "-v",
        "farmy-shared:/shared",
        "--entrypoint",
        "sh",
        &format!("farmy/{name}:dev"),
        "-c",
        script,
    ]) {
        return refuse("dotfiles: could not initialize shared directories");
    }
    Ok(())
}
pub(crate) fn update(ctx: &Ctx, name: &str, pull: bool) -> R<Option<String>> {
    let Some(dot) = &ctx.cfg.dotfiles else {
        return Ok(None);
    };
    let mut request = crate::git_container::Request::new(name, "dotfiles");
    request.mounts.push("farmy-shared:/shared".into());
    request.workdir = "/shared".into();
    request
        .config
        .push(("safe.directory".into(), "/shared/dotfiles".into()));
    request.env.extend([
        (
            "FARMY_DOTFILES_REPO".into(),
            crate::commands::repo_url(ctx, &dot.repo),
        ),
        (
            "FARMY_DOTFILES_PULL".into(),
            if pull { "yes" } else { "no" }.into(),
        ),
    ]);
    let script = r#"set -eu
while ! mkdir /shared/.dotfiles-lock 2>/dev/null; do sleep 0.1; done
trap 'rm -rf /shared/.dotfiles-lock /shared/.dotfiles-new-$$' EXIT HUP INT TERM
if [ ! -d /shared/dotfiles/.git ]; then
  git clone "$FARMY_DOTFILES_REPO" /shared/.dotfiles-new-$$
  # Published into the directory that is there, never in place of it: a running app's read-only
  # submount holds that directory itself. .git goes last, so the clone exists only once it is whole;
  # anything else there is what an interrupted publication left.
  mkdir -p /shared/dotfiles
  rm -rf /shared/dotfiles/* /shared/dotfiles/.[!.]* /shared/dotfiles/..?*
  for f in /shared/.dotfiles-new-$$/* /shared/.dotfiles-new-$$/.[!.]* /shared/.dotfiles-new-$$/..?*; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      [ "${f##*/}" = .git ] || mv "$f" /shared/dotfiles/
    fi
  done
  mv /shared/.dotfiles-new-$$/.git /shared/dotfiles/.git
else
  cd /shared/dotfiles
  [ "$(git config --get remote.origin.url)" = "$FARMY_DOTFILES_REPO" ] || { echo 'dotfiles: configured repository changed unexpectedly' >&2; exit 1; }
  [ -z "$(git status --porcelain)" ] || { echo 'dotfiles: shared checkout is dirty' >&2; exit 1; }
  if [ "$FARMY_DOTFILES_PULL" = yes ]; then git pull --ff-only; fi
fi
git -C /shared/dotfiles rev-parse HEAD
"#;
    let (code, stdout, stderr) = crate::git_container::run(ctx, request, script);
    if code != 0 {
        return refuse(format!(
            "dotfiles {} failed: {}",
            if pull { "pull" } else { "clone" },
            stderr.trim()
        ));
    }
    let sha = stdout
        .lines()
        .rev()
        .find(|l| l.len() == 40 && l.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(String::from)
        .ok_or_else(|| "dotfiles: clone did not report a revision".to_string())?;
    Ok(Some(sha))
}
#[expect(
    clippy::print_stdout,
    reason = "the dotfiles installer's output and the result are for the user on the terminal"
)]
pub(crate) fn apply(
    ctx: &Ctx,
    name: &str,
    def: &Definition,
    cid: &str,
    revision: Option<&str>,
) -> R {
    let old = status(&ctx.cfg, name);
    // the routing refresh after the dotfiles needs the entrypoint's --git-config: an image without it is
    // skipped before anything runs in it
    if ctx.cfg.dotfiles.is_some() && !crate::entrypoint::supports(cid, "git-config") {
        return refuse(crate::entrypoint::older(name));
    }
    // the clone is applied only where an app cannot write it: a container made by an older farmy, or
    // while dotfiles were not configured, may have it writable through the shared parent mount
    if !docker::has_read_only_shared_submount(cid, DOTFILES_IN_APP) {
        return refuse(format!(
            "[{name}] the shared dotfiles clone is not read-only in this container (made by an older farmy or before dotfiles were configured), so nothing was applied: farmy restart {name}"
        ));
    }
    let mut opts: Vec<String> = vec![
        "-u".into(),
        "dev".into(),
        "-e".into(),
        "HOME=/home/dev".into(),
        "-e".into(),
        format!("FARMY_SHARED_DATA={}", ctx.cfg.shared_data.join(" ")),
        "-e".into(),
        format!(
            "FARMY_TOOL_VERSIONS={}",
            crate::toolbox::version_key(&ctx.cfg, def)?
        ),
    ];
    if let Some(d) = &ctx.cfg.dotfiles {
        opts.extend([
            "-e".into(),
            format!("FARMY_DOTFILES_DIR={DOTFILES_IN_APP}"),
            "-e".into(),
            format!(
                "FARMY_DOTFILES_INSTALL={}",
                d.install.as_deref().unwrap_or("")
            ),
        ]);
    }
    let mut failed = crate::entrypoint::run(
        name,
        "dotfiles/home installer",
        &opts,
        cid,
        &["sh", "/usr/local/bin/farmy-home.sh"],
    )
    .err();
    // Installing or pulling dotfiles can introduce more-specific personal URL rewrites. Refresh
    // system routing after that user's installer has completed, before setup or later Git commands.
    if failed.is_none() && ctx.cfg.dotfiles.is_some() {
        failed =
            crate::entrypoint::run_mode(name, cid, "0", "git-config", "git routing refresh").err();
    }
    let success = failed.is_none();
    if ctx.cfg.dotfiles.is_some() {
        let state = serde_json::json!({"revision":if success{revision.map(serde_json::Value::from).unwrap_or(serde_json::Value::Null)}else{old["revision"].clone()},"wanted_revision":revision,"state":if success{"applied"}else{"failed"}});
        std::fs::create_dir_all(PathBuf::from(WORK).join(name))?;
        std::fs::write(state_path(name), state.to_string())?;
    }
    if let Some(line) = failed {
        return refuse(line);
    }
    if let Some(sha) = revision {
        println!("[{name}] dotfiles applied {sha}");
    }
    Ok(())
}
pub(crate) fn main(args: &[String]) -> R {
    if args != ["pull"] {
        return usage("usage: farmy dotfiles pull");
    }
    let ctx = crate::commands::load_ctx()?;
    if ctx.cfg.dotfiles.is_none() {
        return refuse("farmy.yml: dotfiles.repo is not configured");
    }
    let apps: Vec<_> = definition_services()
        .into_iter()
        .filter_map(|n| docker::app_cid(&n).map(|c| (n, c)))
        .collect();
    let Some((name, _)) = apps.first() else {
        return refuse("dotfiles pull needs a running service for git authentication");
    };
    let revision = update(&ctx, name, true)?;
    let mut failed = false;
    for (name, cid) in apps {
        let def = Definition::load(&name)?;
        if let Err(e) = apply(&ctx, &name, &def, &cid, revision.as_deref()) {
            eprintln!("{e}");
            failed = true;
        }
    }
    if failed {
        return refuse("dotfiles pull: partial application; the shared clone remains updated");
    }
    Ok(())
}
