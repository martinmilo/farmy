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
        version.split('.').count() == 3
            && version.split('.').all(|s| !s.is_empty()
                && s.bytes().all(|c| c.is_ascii_digit())
                && (s == "0" || !s.starts_with('0'))),
        "VERSION must be MAJOR.MINOR.PATCH"
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
}
