//! Release identity and checks performed before interpreting a newer document.
use crate::{R, docker, refuse};
use serde_yaml::Value;

pub(crate) const CURRENT: &str = env!("FARMY_VERSION");
pub(crate) const FORMAT: u64 = 1;
pub(crate) fn registry() -> String {
    std::env::var("FARMY_REGISTRY")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| env!("FARMY_DEFAULT_REGISTRY").into())
}

pub(crate) fn valid(value: &str) -> bool {
    value.split('.').count() == 3
        && value.split('.').all(|s| {
            !s.is_empty()
                && s.bytes().all(|c| c.is_ascii_digit())
                && (s == "0" || !s.starts_with('0'))
        })
}
pub(crate) fn older(old: &str, current: &str) -> bool {
    valid(old)
        && valid(current)
        && old
            .split('.')
            .zip(current.split('.'))
            .map(|(a, b)| a.len().cmp(&b.len()).then(a.cmp(b)))
            .find(|c| !c.is_eq())
            .map(|c| c.is_lt())
            .unwrap_or(false)
}
pub(crate) fn check_workspace() -> R {
    match std::fs::read_to_string("farmy.yml") {
        Ok(text) => check_document(&text, "farmy.yml", true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}
pub(crate) fn check_document(text: &str, file: &str, pin: bool) -> R {
    let doc: Value = serde_yaml::from_str(text).map_err(|e| format!("{file}: {e}"))?;
    if let Some(value) = doc.get("format") {
        let raw = match value {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            _ => String::new(),
        };
        let requested = raw
            .parse::<u64>()
            .ok()
            .filter(|n| *n > 0)
            .filter(|_| raw.bytes().all(|c| c.is_ascii_digit()))
            .ok_or_else(|| format!("{file}: format must be a positive integer"))?;
        if requested > FORMAT {
            return refuse(format_refusal(file, requested));
        }
    }
    if pin && let Some(value) = doc.get("farmy") {
        let version = value
            .as_str()
            .filter(|s| valid(s))
            .ok_or_else(|| format!("{file}: farmy must pin an exact MAJOR.MINOR.PATCH version"))?;
        if version != CURRENT {
            return refuse(format!(
                "{file} pins farmy {version}, but this binary is {CURRENT}: farmy update --to {version}"
            ));
        }
    }
    Ok(())
}
fn format_refusal(file: &str, requested: u64) -> String {
    let mut reader = None;
    {
        let registry = registry();
        if !registry.trim().is_empty() {
            let image = format!("{}/farmy-control:latest", registry.trim_end_matches('/'));
            if docker::quiet(&["pull", "-q", &image]) {
                let format = docker::image_label(&image, "farmy.format")
                    .parse::<u64>()
                    .unwrap_or(0);
                let version = docker::image_label(&image, "farmy.version");
                if format >= requested && valid(&version) {
                    reader = Some(version);
                }
            }
        }
    }
    match reader {
        Some(version) => format!(
            "{file}: format {requested} requires a newer reader; farmy {version} supports it: farmy update --to {version}"
        ),
        None => format!(
            "{file}: format {requested} is newer than supported format {FORMAT}; required version unknown: farmy update"
        ),
    }
}
pub(crate) struct Toolbox {
    pub exists: bool,
    pub version: Option<String>,
}
impl Toolbox {
    pub(crate) fn outdated(&self) -> bool {
        self.exists
            && self
                .version
                .as_deref()
                .map(|v| older(v, CURRENT))
                .unwrap_or(true)
    }
}
pub(crate) fn toolbox(name: &str) -> Toolbox {
    if let Some(container) = docker::app_cid_any(name) {
        for field in ["{{.Image}}", "{{.Config.Image}}"] {
            if let Ok(image) = docker::out(&["inspect", "-f", field, &container])
                && !image.is_empty()
                && docker::quiet(&["image", "inspect", &image])
            {
                let value = docker::image_label(&image, "farmy.version");
                return Toolbox {
                    exists: true,
                    version: valid(&value).then_some(value),
                };
            }
        }
        let value = docker::container_label(&container, "farmy.version");
        return Toolbox {
            exists: true,
            version: valid(&value).then_some(value),
        };
    }
    let image = format!("farmy/{name}:dev");
    let exists = docker::quiet(&["image", "inspect", &image]);
    let value = if exists {
        docker::image_label(&image, "farmy.version")
    } else {
        String::new()
    };
    Toolbox {
        exists,
        version: valid(&value).then_some(value),
    }
}
pub(crate) fn drift(name: &str, version: Option<&str>) -> Option<String> {
    match version {
        None => Some(format!("built by an unknown farmy: farmy rebuild {name}")),
        Some(old) if older(old, CURRENT) => Some(format!(
            "built by {old}, now {CURRENT}: farmy rebuild {name}"
        )),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_comparison_is_numeric_and_rejects_ranges_and_ambiguous_pins() {
        assert!(older("0.9.0", "0.10.0"));
        assert!(!older("0.10.0", "0.9.0"));
        assert!(!older("0.1.0", "0.1.0"));
        for text in [
            "farmy: ^0.1.0",
            "farmy: 01.0.0",
            "farmy: [0.1.0]",
            "farmy: 0.1.0\nfarmy: 0.2.0",
        ] {
            assert!(check_document(text, "farmy.yml", true).is_err(), "{text}");
        }
        assert!(
            check_document(
                &format!("farmy: '{CURRENT}' # exact\nformat: \"1\" # supported"),
                "farmy.yml",
                true
            )
            .is_ok()
        );
    }
    #[test]
    fn a_future_format_wins_over_unfamiliar_keys() {
        let error = check_document(
            "format: 999999\nfuture_feature: {anything: true}",
            "services/shop.yml",
            false,
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("services/shop.yml"));
        assert!(error.contains("format 999999"));
        assert!(error.contains("farmy update"));
    }
}
