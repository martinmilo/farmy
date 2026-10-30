//! A build hash of the sources, so that `farmy --version` and `farmy tui --version` can say which build
//! runs: the complete control build-input fingerprint, as FARMY_BUILD_HASH.
#![forbid(unsafe_code)]
use std::path::Path;
use std::process::Command;

fn main() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let version_path = crates
        .parent()
        .expect("the crate sits in work/crates/")
        .join("VERSION");
    println!("cargo:rerun-if-changed={}", version_path.display());
    let version = std::fs::read_to_string(&version_path).expect("VERSION must exist");
    let version = version.trim();
    assert!(
        valid_version(version),
        "VERSION must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rc.N"
    );
    println!("cargo:rustc-env=FARMY_VERSION={version}");
    let root = crates.parent().expect("the crate sits in work/crates/");
    for input in [
        "VERSION",
        "Dockerfile",
        "release.Dockerfile",
        ".dockerignore",
        "Dockerfile.dockerignore",
        "release.Dockerfile.dockerignore",
        "Cargo.toml",
        "Cargo.lock",
        "farmy",
        "README.md",
        ".env.example",
        "farmy.example.yml",
        "agents.yml",
        "tools.yml",
        "egress-hosts.yml",
        "factory-prompt.md",
        "keys.Dockerfile",
        "knowledge.Dockerfile",
        "gate.Dockerfile",
        "release.yml",
        "crates",
        "docs",
        "toolbox",
        "providers",
        "bin/build",
        "bin/release",
        "bin/render-release",
        "bin/install",
    ] {
        let path = root.join(input);
        println!("cargo:rerun-if-changed={}", path.display());
    }
    let release: serde_yaml::Value = serde_yaml::from_str(
        &std::fs::read_to_string(root.join("release.yml")).expect("release.yml must exist"),
    )
    .expect("valid release configuration");
    let owner = release["owner"].as_str().expect("release owner");
    let github = release["github_url"]
        .as_str()
        .expect("public GitHub URL")
        .trim_end_matches('/')
        .trim_end_matches(".git");
    assert!(
        owner
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
        "invalid public owner"
    );
    println!("cargo:rustc-env=FARMY_DEFAULT_REGISTRY=ghcr.io/{owner}/farmy");
    println!("cargo:rustc-env=FARMY_DEFAULT_SOURCE={github}.git#v{version}:work");
    println!("cargo:rerun-if-env-changed=FARMY_SOURCE_HASH");
    let hash = std::env::var("FARMY_SOURCE_HASH")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let result = Command::new("sh")
                .arg(root.join("farmy"))
                .env("FARMY_HASH_ONLY", "1")
                .current_dir(root)
                .output()
                .expect("run source fingerprint");
            assert!(
                result.status.success(),
                "cannot fingerprint control build inputs: {}",
                String::from_utf8_lossy(&result.stderr)
            );
            String::from_utf8(result.stdout)
                .expect("fingerprint is ASCII")
                .trim()
                .to_string()
        });
    assert!(
        !hash.is_empty() && hash.bytes().all(|b| b.is_ascii_hexdigit()),
        "invalid control build fingerprint"
    );
    println!("cargo:rustc-env=FARMY_BUILD_HASH={hash}");
    commit(root);
}

/// One number of a version: digits, no leading zero.
fn number(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()) && (s == "0" || !s.starts_with('0'))
}

/// `MAJOR.MINOR.PATCH`, or a pre-release `MAJOR.MINOR.PATCH-rc.N` (N from 1).
fn valid_version(version: &str) -> bool {
    let (core, pre) = match version.split_once('-') {
        Some((core, pre)) => (core, Some(pre)),
        None => (version, None),
    };
    core.split('.').count() == 3
        && core.split('.').all(number)
        && pre.is_none_or(|p| p.strip_prefix("rc.").is_some_and(|n| number(n) && n != "0"))
}

/// The short commit (7 hex digits) the sources are built from: FARMY_COMMIT when the build is given it
/// (an image build, whose context has no .git), else the checkout's HEAD; `commit unknown` when neither
/// says. Rebuilt when HEAD moves.
fn commit(root: &Path) {
    println!("cargo:rerun-if-env-changed=FARMY_COMMIT");
    let given = std::env::var("FARMY_COMMIT").unwrap_or_default();
    let git = |args: &[&str]| {
        Command::new("git")
            .args(args)
            .current_dir(root)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    let full = if given.is_empty() {
        for path in ["HEAD", "packed-refs"] {
            if let Some(file) = git(&["rev-parse", "--git-path", path]) {
                println!("cargo:rerun-if-changed={}", root.join(file).display());
            }
        }
        if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"])
            && let Some(file) = git(&["rev-parse", "--git-path", &reference])
        {
            println!("cargo:rerun-if-changed={}", root.join(file).display());
        }
        git(&["rev-parse", "HEAD"]).unwrap_or_default()
    } else {
        given
    };
    let commit = if full.len() >= 7 && full.bytes().all(|b| b.is_ascii_hexdigit()) {
        full.get(..7).unwrap_or(&full).to_ascii_lowercase()
    } else {
        "commit unknown".to_string()
    };
    println!("cargo:rustc-env=FARMY_COMMIT={commit}");
}
