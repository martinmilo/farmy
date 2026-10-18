//! Pinned, verified tool catalogue and reproducible toolbox build inputs.
use crate::{
    R,
    model::{Config, Definition, definition_services, farmy_home},
    refuse, usage,
};
use serde::{Deserialize, Serialize};
use serde_yaml::Value;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::Path, process::Command};

#[derive(Clone, Deserialize, Serialize, Default)]
#[serde(deny_unknown_fields)]
pub(crate) struct Managed {
    pub managed: Option<bool>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Artifact {
    pub url: String,
    pub sha256: String,
    pub format: String,
    pub min_libc: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Releases {
    pub kind: String,
    pub repo: String,
    pub api: Option<String>,
    pub assets: BTreeMap<String, String>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Entry {
    pub version: String,
    pub releases: Option<Releases>,
    pub artifacts: BTreeMap<String, Artifact>,
    pub install: BTreeMap<String, String>,
}
#[derive(Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct Lock {
    version: u32,
    tools: BTreeMap<String, Entry>,
}

fn merge(base: &mut Value, over: Value) {
    if let (Some(a), Some(b)) = (base.as_mapping_mut(), over.as_mapping()) {
        for (k, v) in b {
            merge(a.entry(k.clone()).or_insert(Value::Null), v.clone());
        }
    } else {
        *base = over;
    }
}
fn shipped() -> R<BTreeMap<String, Value>> {
    serde_yaml::from_str(&std::fs::read_to_string(farmy_home().join("tools.yml"))?)
        .map_err(|e| format!("tools.yml: {e}").into())
}
fn lock() -> R<Lock> {
    if !Path::new("tools.lock").exists() {
        return Ok(Lock {
            version: 1,
            ..Default::default()
        });
    }
    let l: Lock = serde_yaml::from_str(&std::fs::read_to_string("tools.lock")?)
        .map_err(|e| format!("tools.lock: {e}"))?;
    if l.version != 1 {
        return refuse("tools.lock: unsupported version");
    }
    Ok(l)
}
fn validate(name: &str, e: &Entry) -> R {
    if e.version.is_empty() {
        return refuse(format!("tool_catalogue.{name}: version is empty"));
    }
    let required: Vec<_> = e
        .releases
        .as_ref()
        .map(|r| r.assets.keys().collect())
        .unwrap_or_else(|| e.artifacts.keys().collect());
    if required.is_empty() {
        return refuse(format!("tool_catalogue.{name}: incomplete artifacts"));
    }
    for key in required {
        let Some(a) = e.artifacts.get(key) else {
            return refuse(format!("tool_catalogue.{name}: missing artifact {key}"));
        };
        if !matches!(
            key.as_str(),
            "linux-amd64-glibc" | "linux-arm64-glibc" | "linux-amd64-musl" | "linux-arm64-musl"
        ) {
            return refuse(format!("tool_catalogue.{name}: unknown platform {key}"));
        }
        if a.url.is_empty()
            || a.sha256.len() != 64
            || !a.sha256.bytes().all(|b| b.is_ascii_hexdigit())
            || !matches!(a.format.as_str(), "raw" | "tar.gz" | "tar.xz" | "zip")
        {
            return refuse(format!(
                "tool_catalogue.{name}: incomplete URL/SHA-256/format pin for {key}"
            ));
        }
    }
    for base in e.install.keys() {
        if !matches!(base.as_str(), "apt" | "apk") {
            return refuse(format!(
                "tool_catalogue.{name}: unknown install base {base}"
            ));
        }
    }
    Ok(())
}
pub(crate) fn catalogue(cfg: &Config) -> R<BTreeMap<String, Entry>> {
    let mut all = shipped()?;
    for (name, over) in &cfg.tool_catalogue {
        let base = all.entry(name.clone()).or_insert(Value::Null);
        let changed = over.get("version").is_some() && over.get("version") != base.get("version");
        let inherited_required = base
            .get("releases")
            .and_then(|r| r.get("assets"))
            .and_then(Value::as_mapping)
            .map(|m| m.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_else(|| {
                base.get("artifacts")
                    .and_then(Value::as_mapping)
                    .map(|m| m.keys().cloned().collect())
                    .unwrap_or_default()
            });
        if changed {
            for key in inherited_required {
                if over.get("artifacts").and_then(|a| a.get(&key)).is_none() {
                    return refuse(format!(
                        "farmy.yml: tool_catalogue.{name} version override requires complete artifacts, missing {}",
                        key.as_str().unwrap_or("platform")
                    ));
                }
            }
            if let Some(m) = base.as_mapping_mut() {
                m.remove(Value::String("artifacts".into()));
            }
        }
        if let Some(artifacts) = over.get("artifacts").and_then(Value::as_mapping) {
            for (key, a) in artifacts {
                if a.get("url").is_some() != a.get("sha256").is_some() {
                    return refuse(format!(
                        "farmy.yml: tool_catalogue.{name} {} URL and sha256 must be overridden together",
                        key.as_str().unwrap_or("artifact")
                    ));
                }
            }
        }
        merge(base, over.clone());
    }
    let mut out = BTreeMap::new();
    for (name, value) in all {
        let entry: Entry =
            serde_yaml::from_value(value).map_err(|e| format!("tool_catalogue.{name}: {e}"))?;
        validate(&name, &entry)?;
        out.insert(name, entry);
    }
    for (name, entry) in lock()?.tools {
        validate(&name, &entry)?;
        out.insert(name, entry);
    }
    Ok(out)
}
pub(crate) fn selection(cfg: &Config, def: &Definition) -> R<BTreeMap<String, Entry>> {
    let all = catalogue(cfg)?;
    let mut out = BTreeMap::new();
    for name in cfg.tools.iter().chain(&def.tools) {
        let e = all.get(name).ok_or_else(|| {
            format!("tools: unknown tool '{name}' in farmy.yml or service definition")
        })?;
        let family = if def.image.as_deref().unwrap_or("").contains("alpine") {
            "apk"
        } else {
            "apt"
        };
        let libc = if family == "apk" { "musl" } else { "glibc" };
        for arch in ["amd64", "arm64"] {
            let key = format!("linux-{arch}-{libc}");
            if !e.artifacts.contains_key(&key) || !e.install.contains_key(family) {
                return refuse(format!(
                    "tool {name}: missing compatible artifact or install recipe for {key} ({family})"
                ));
            }
        }
        out.insert(name.clone(), e.clone());
    }
    Ok(out)
}
pub(crate) fn version_key(cfg: &Config, def: &Definition) -> R<String> {
    let selected = selection(cfg, def)?;
    let set = selected
        .iter()
        .map(|(n, e)| format!("{n}={}", e.version))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(format!("{:x}", Sha256::digest(set.as_bytes())))
}
pub(crate) fn validate_config(cfg: &Config) -> R {
    if !matches!(cfg.shell.as_str(), "sh" | "bash" | "zsh") {
        return refuse(format!(
            "farmy.yml: unknown shell '{}'; shell must be sh, bash or zsh",
            cfg.shell
        ));
    }
    for n in &cfg.shared_data {
        if n.is_empty()
            || n == "."
            || n == ".."
            || !n
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        {
            return refuse(format!(
                "farmy.yml: shared_data '{n}' must be a single directory name"
            ));
        }
    }
    if let Some(d) = &cfg.dotfiles {
        if !crate::model::is_clone_url(&d.repo) {
            return refuse("farmy.yml: dotfiles.repo must be a clone URL");
        }
        if d.install
            .as_ref()
            .map(|p| p.starts_with('/') || p.split('/').any(|c| c == "..") || p.is_empty())
            .unwrap_or(false)
        {
            return refuse("farmy.yml: dotfiles.install must be repository-relative");
        }
    }
    catalogue(cfg)?;
    Ok(())
}
fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
pub(crate) fn prepare(cfg: &Config, def: &Definition, context: &Path) -> R {
    let selected = selection(cfg, def)?;
    let mut packages = cfg.packages.clone();
    packages.extend(def.packages.clone());
    packages.sort();
    packages.dedup();
    for p in &packages {
        if p.is_empty()
            || p.starts_with('-')
            || !p
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-+.:_=".contains(&b))
        {
            return refuse(format!("packages: invalid distro package '{p}'"));
        }
    }
    std::fs::write(
        context.join("tools.yml"),
        serde_yaml::to_string(&selected).map_err(|e| e.to_string())?,
    )?;
    std::fs::write(
        context.join("packages.txt"),
        packages.join("\n") + if packages.is_empty() { "" } else { "\n" },
    )?;
    std::fs::copy(
        farmy_home().join("toolbox/farmy-home.sh"),
        context.join("farmy-home.sh"),
    )?;
    let managed = cfg.toolbox.managed.unwrap_or(true);
    let mut script = String::from(
        "#!/bin/sh\nset -eu\nDESTDIR=${DESTDIR:-/}\nexport DESTDIR\ncase ${TARGETARCH:-$(uname -m)} in x86_64|amd64) TARGETARCH=amd64 ;; aarch64|arm64) TARGETARCH=arm64 ;; *) echo 'farmy toolbox: unsupported architecture' >&2; exit 1 ;; esac\nif [ -z \"${FARMY_BASE_FAMILY:-}\" ]; then if command -v apt-get >/dev/null 2>&1; then FARMY_BASE_FAMILY=apt; elif command -v apk >/dev/null 2>&1; then FARMY_BASE_FAMILY=apk; else echo 'farmy toolbox: unknown base family' >&2; exit 1; fi; fi\ncase $FARMY_BASE_FAMILY in apt) libc=glibc ;; apk) libc=musl ;; *) echo 'farmy toolbox: unsupported base family' >&2; exit 1 ;; esac\nexport TARGETARCH FARMY_BASE_FAMILY\nmkdir -p \"$DESTDIR/usr/local/bin\"\n",
    );
    if managed {
        if !packages.is_empty() {
            let pk = packages
                .iter()
                .map(|s| quote(s))
                .collect::<Vec<_>>()
                .join(" ");
            script.push_str(&format!("case $FARMY_BASE_FAMILY in apt) apt-get update; apt-get install -y --no-install-recommends {pk} ;; apk) apk add --no-cache {pk} ;; esac\n"));
        }
        script.push_str("tmp=$(mktemp -d)\ntrap 'rm -rf \"$tmp\"' EXIT HUP INT TERM\n");
        for (name, e) in &selected {
            script.push_str(&format!(
                "# {name} {}\ncase linux-$TARGETARCH-$libc in\n",
                e.version
            ));
            for (key, a) in &e.artifacts {
                script.push_str(&format!(
                    "{key}) url={}; sha={} ;;\n",
                    quote(&a.url),
                    quote(&a.sha256)
                ));
            }
            script.push_str(&format!("*) echo \"farmy toolbox: {name} has no artifact for linux-$TARGETARCH-$libc\" >&2; exit 1 ;;\nesac\nARCHIVE=\"$tmp/archive\"\nexport ARCHIVE\ncurl -fsSL --retry 2 \"$url\" -o \"$ARCHIVE\"\nprintf '%s  %s\\n' \"$sha\" \"$ARCHIVE\" | sha256sum -c - || {{ echo \"farmy toolbox: {name} linux-$TARGETARCH-$libc checksum verification failed\" >&2; exit 1; }}\ncase $FARMY_BASE_FAMILY in\n"));
            for (base, recipe) in &e.install {
                script.push_str(&format!("{base}) sh -ec {} ;;\n", quote(recipe)));
            }
            script.push_str(&format!(
                "*) echo 'farmy toolbox: {name} unsupported base' >&2; exit 1 ;;\nesac\n"
            ));
        }
    }
    std::fs::write(context.join("tools-install.sh"), script)?;
    use std::os::unix::fs::PermissionsExt;
    for f in ["tools-install.sh", "farmy-home.sh"] {
        std::fs::set_permissions(context.join(f), std::fs::Permissions::from_mode(0o755))?;
    }
    let path = context.join("Dockerfile");
    let mut df = std::fs::read_to_string(&path)?;
    if managed {
        df.push_str("\nUSER root\nARG TARGETARCH\nCOPY tools.yml packages.txt /etc/farmy/\nCOPY tools-install.sh /usr/local/lib/tools-install.sh\nRUN sh /usr/local/lib/tools-install.sh\n");
        for (n, e) in &selected {
            for (k, a) in &e.artifacts {
                df.push_str(&format!(
                    "# {n} {} {k}: {} sha256 {}\n",
                    e.version, a.url, a.sha256
                ));
            }
        }
    }
    df.push_str(&format!("\nUSER root\nCOPY farmy-home.sh /usr/local/bin/farmy-home.sh\nRUN chmod 755 /usr/local/bin/farmy-home.sh && usermod -s /bin/{} dev\nENV SHELL=/bin/{}\n",cfg.shell,cfg.shell));
    df.push_str(&entrypoint_layer(context)?);
    std::fs::write(path, df)?;
    Ok(())
}

/// The folder in a toolbox build context that holds farmy's own layer files. A custom toolbox may not
/// bring one, so nothing it ships can stand in for them.
pub(crate) const LAYER_DIR: &str = "farmy-layer";
/// Where a custom toolbox's `toolbox/start.sh` is installed; farmy's entrypoint runs it as dev at every start.
const START_SH: &str = "/usr/local/lib/farmy/toolbox-start.sh";

/// farmy's entrypoint as it goes into the image: farmy's own file, whichever toolbox is built.
pub(crate) fn installed_entrypoint(context: &Path) -> std::path::PathBuf {
    context.join(LAYER_DIR).join("entrypoint.sh")
}

/// The last layer of every toolbox (FORMATS.md → Custom toolbox and farmy's entrypoint): farmy's own
/// entrypoint as the image's ENTRYPOINT, and the toolbox's `start.sh`, when it has one, for it to run.
fn entrypoint_layer(context: &Path) -> R<String> {
    use std::os::unix::fs::PermissionsExt;
    let dir = context.join(LAYER_DIR);
    if dir.exists() {
        return refuse(format!(
            "toolbox/{LAYER_DIR} is the name farmy keeps for its own files in the toolbox build: rename it"
        ));
    }
    std::fs::create_dir_all(&dir)?;
    let entrypoint = installed_entrypoint(context);
    std::fs::copy(farmy_home().join("toolbox/entrypoint.sh"), &entrypoint)?;
    std::fs::set_permissions(&entrypoint, std::fs::Permissions::from_mode(0o755))?;
    let mut layer = format!(
        "\n# farmy's entrypoint, always last: a toolbox cannot replace it (its own startup goes into start.sh)\nUSER root\nCOPY {LAYER_DIR}/entrypoint.sh {}\n",
        crate::entrypoint::ENTRYPOINT
    );
    let mut executables = crate::entrypoint::ENTRYPOINT.to_owned();
    if context.join("start.sh").is_file() {
        let start = dir.join("start.sh");
        std::fs::copy(context.join("start.sh"), &start)?;
        std::fs::set_permissions(&start, std::fs::Permissions::from_mode(0o755))?;
        layer.push_str(&format!("COPY {LAYER_DIR}/start.sh {START_SH}\n"));
        executables.push(' ');
        executables.push_str(START_SH);
    }
    layer.push_str(&format!(
        "RUN chmod 755 {executables}\nENTRYPOINT [\"{}\"]\n",
        crate::entrypoint::ENTRYPOINT
    ));
    // a toolbox's own ignore file must not keep farmy's layer out of the build
    for ignore in [".dockerignore", "Dockerfile.dockerignore"] {
        let p = context.join(ignore);
        if p.is_file() {
            let mut text = std::fs::read_to_string(&p)?;
            text.push_str(&format!("\n!{LAYER_DIR}\n!{LAYER_DIR}/**\n"));
            std::fs::write(p, text)?;
        }
    }
    Ok(layer)
}
fn fetch(url: &str) -> R<Vec<u8>> {
    let o = Command::new("curl")
        .args(["-fsSL", "--max-time", "30", url])
        .output()?;
    if !o.status.success() {
        return refuse("toolbox bump: release or artifact download failed");
    }
    Ok(o.stdout)
}
#[expect(
    clippy::print_stdout,
    reason = "`farmy toolbox bump` reports each new version to the user"
)]
fn bump(cfg: &Config, names: &[String]) -> R {
    let _lock = crate::locking::Lock::take(Path::new(".work/toolbox.lock"))?;
    let all = catalogue(cfg)?;
    let mut names = names.to_vec();
    if names.is_empty() {
        names.extend(cfg.tools.clone());
        for n in definition_services() {
            names.extend(Definition::load(&n)?.tools);
        }
    }
    names.sort();
    names.dedup();
    // Keep untouched entries as their original mappings, including optional-field presence.
    // Resolving the catalogue above has already validated the entire lock.
    let mut locked: Value = if Path::new("tools.lock").exists() {
        serde_yaml::from_str(&std::fs::read_to_string("tools.lock")?)
            .map_err(|e| format!("tools.lock: {e}"))?
    } else {
        serde_yaml::to_value(Lock {
            version: 1,
            ..Default::default()
        })
        .map_err(|e| e.to_string())?
    };
    for name in names {
        let mut e = all
            .get(&name)
            .cloned()
            .ok_or_else(|| format!("toolbox bump: unknown tool {name}"))?;
        let rel = e
            .releases
            .as_ref()
            .ok_or_else(|| format!("toolbox bump: {name} has no releases resolver"))?;
        if rel.kind != "github" {
            return refuse(format!(
                "toolbox bump: {name} unknown releases kind {}",
                rel.kind
            ));
        }
        let url = format!(
            "{}/repos/{}/releases/latest",
            rel.api
                .as_deref()
                .unwrap_or("https://api.github.com")
                .trim_end_matches('/'),
            rel.repo
        );
        let data: serde_json::Value = serde_json::from_slice(&fetch(&url)?)
            .map_err(|e| format!("toolbox bump: {name} release data: {e}"))?;
        if data["prerelease"].as_bool() == Some(true) || data["draft"].as_bool() == Some(true) {
            return refuse(format!("toolbox bump: {name} latest release is not stable"));
        }
        let tag = data["tag_name"]
            .as_str()
            .ok_or_else(|| format!("toolbox bump: {name} missing release version"))?;
        let version = tag
            .trim_start_matches('v')
            .trim_start_matches("jq-")
            .to_string();
        let assets = data["assets"]
            .as_array()
            .ok_or_else(|| format!("toolbox bump: {name} missing assets"))?;
        let mut metadata = Vec::new();
        for a in assets {
            let n = a["name"].as_str().unwrap_or("").to_lowercase();
            if (n.contains("checksum") || n.contains("sha256"))
                && let Some(u) = a["browser_download_url"].as_str()
            {
                metadata.push(String::from_utf8_lossy(&fetch(u)?).into_owned());
            }
        }
        let mut artifacts = BTreeMap::new();
        for (key, template) in &rel.assets {
            let filename = template.replace("{version}", &version);
            let a = assets
                .iter()
                .find(|a| a["name"].as_str() == Some(&filename))
                .ok_or_else(|| {
                    format!("toolbox bump: {name} missing artifact {key}: {filename}")
                })?;
            let url = a["browser_download_url"]
                .as_str()
                .ok_or_else(|| format!("toolbox bump: {name} missing artifact URL {key}"))?;
            let sha = format!("{:x}", Sha256::digest(fetch(url)?));
            if let Some(d) = a["digest"].as_str()
                && d != format!("sha256:{sha}")
            {
                return refuse(format!("toolbox bump: {name} checksum mismatch {key}"));
            }
            for text in &metadata {
                for line in text.lines().filter(|l| l.contains(&filename)) {
                    let published = line
                        .split_whitespace()
                        .find(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()));
                    if let Some(p) = published
                        && p.to_lowercase() != sha
                    {
                        return refuse(format!("toolbox bump: {name} checksum mismatch {key}"));
                    }
                }
            }
            let previous = e
                .artifacts
                .get(key)
                .ok_or_else(|| format!("toolbox bump: {name} missing format for {key}"))?;
            artifacts.insert(
                key.clone(),
                Artifact {
                    url: url.into(),
                    sha256: sha,
                    format: previous.format.clone(),
                    min_libc: previous.min_libc.clone(),
                },
            );
        }
        e.version = version;
        e.artifacts = artifacts;
        validate(&name, &e)?;
        println!("{name}: {}", e.version);
        locked["tools"][&name] = serde_yaml::to_value(e).map_err(|e| e.to_string())?;
    }
    let tmp = format!(".work/tools.lock.{}.tmp", std::process::id());
    std::fs::create_dir_all(".work")?;
    std::fs::write(
        &tmp,
        serde_yaml::to_string(&locked).map_err(|e| e.to_string())?,
    )?;
    std::fs::rename(tmp, "tools.lock")?;
    Ok(())
}
pub(crate) fn outdated() -> Vec<String> {
    let Ok(shipped) = shipped() else {
        return vec![];
    };
    let Ok(l) = lock() else { return vec![] };
    l.tools
        .iter()
        .filter_map(|(n, e)| {
            let v = shipped.get(n)?.get("version")?.as_str()?;
            crate::version::older(&e.version, v).then(|| {
                format!(
                    "{n}: tools.lock {} is outdated; newer shipped pin {v}; farmy toolbox bump",
                    e.version
                )
            })
        })
        .collect()
}
#[expect(
    clippy::print_stdout,
    reason = "`farmy toolbox list` prints the entries for the user or, with --json, for a program"
)]
pub(crate) fn main(args: &[String]) -> R {
    let cfg = Config::load()?;
    match args.first().map(String::as_str) {
        Some("list") => {
            let c = catalogue(&cfg)?;
            if args.iter().any(|a| a == "--json") {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&c).map_err(|e| e.to_string())?
                );
            } else {
                for (n, e) in c {
                    println!("{n} {}", e.version);
                }
            }
            Ok(())
        }
        Some("bump") => bump(&cfg, &args[1..]),
        _ => usage("usage: farmy toolbox list [--json] | bump [tool ...]"),
    }
}
