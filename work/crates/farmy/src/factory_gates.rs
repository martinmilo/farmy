fn validate_sidecars(def: &Definition) -> R {
    use serde_yaml::Value as V;
    if let Some(nets) = def.networks.as_ref().and_then(V::as_mapping) {
        for (n, v) in nets {
            if v.get("external")
                .map(|x| x.as_bool() != Some(false) && !x.is_null())
                .unwrap_or(false)
            {
                return refuse(format!(
                    "gate sidecar external network {} is forbidden",
                    n.as_str().unwrap_or("?")
                ));
            }
        }
    }
    for (n, v) in def.compose.iter().flat_map(|m| m.iter()) {
        let name = n.as_str().unwrap_or("?");
        if v.get("privileged").and_then(V::as_bool) == Some(true) {
            return refuse(format!("gate sidecar {name}: privileged is forbidden"));
        }
        if v.get("network_mode").and_then(V::as_str) == Some("host") {
            return refuse(format!("gate sidecar {name}: host networking is forbidden"));
        }
        for vol in v
            .get("volumes")
            .and_then(V::as_sequence)
            .into_iter()
            .flatten()
        {
            if serde_yaml::to_string(vol)
                .unwrap_or_default()
                .contains("docker.sock")
            {
                return refuse(format!(
                    "gate sidecar {name}: Docker socket mount is forbidden"
                ));
            }
        }
    }
    Ok(())
}
impl Run<'_> {
    fn gate_file(&self) -> PathBuf {
        run_dir(&self.p.name, &self.id).join("gate-compose.yml")
    }
    fn open_gate(&mut self) -> R {
        if self.p.gate_isolated {
            return Ok(());
        }
        use serde_yaml::{Mapping, Value as V};
        let s = |x: &str| V::String(x.into());
        let project = self.gate_network();
        let mut services = self.p.def.compose.clone().unwrap_or_default();
        let mut volumes = Mapping::new();
        for (name, svc) in &mut services {
            let name = name.as_str().unwrap_or("sidecar");
            let Some(m) = svc.as_mapping_mut() else {
                continue;
            };
            m.remove(s("ports"));
            m.remove(s("network_mode"));
            m.remove(s("restart"));
            m.insert(s("container_name"), s(&format!("{project}-{name}")));
            m.insert(s("init"), V::Bool(true));
            m.insert(
                s("networks"),
                serde_yaml::from_str(&format!("default:\n  aliases: [{name}]\n"))
                    .map_err(|e| e.to_string())?,
            );
            let mut labels = Mapping::new();
            labels.insert(s("farmy.run"), s(&self.id));
            labels.insert(s("farmy.service"), s(&self.p.name));
            labels.insert(s("farmy.role"), s("gate-sidecar"));
            m.insert(s("labels"), V::Mapping(labels));
            if let Some(vs) = m.get_mut(s("volumes")).and_then(V::as_sequence_mut) {
                for (index, v) in vs.iter_mut().enumerate() {
                    let (target, ro, bind) = if let Some(text) = v.as_str() {
                        let parts = text.split(':').collect::<Vec<_>>();
                        let target = if parts.len() == 1 { parts[0] } else { parts[1] };
                        (
                            target.to_string(),
                            parts
                                .get(2)
                                .map(|o| o.split(',').any(|x| x == "ro"))
                                .unwrap_or(false),
                            parts
                                .first()
                                .map(|x| x.starts_with('/') || x.starts_with('.'))
                                .unwrap_or(false),
                        )
                    } else {
                        (
                            v.get("target")
                                .and_then(V::as_str)
                                .unwrap_or("/data")
                                .into(),
                            v.get("read_only").and_then(V::as_bool).unwrap_or(false),
                            v.get("type").and_then(V::as_str) == Some("bind"),
                        )
                    };
                    if ro && bind {
                        continue;
                    }
                    let key = format!("{name}-{index}");
                    let mut volume = Mapping::new();
                    volume.insert(s("name"), s(&format!("{project}-{key}")));
                    volumes.insert(s(&key), V::Mapping(volume));
                    *v = s(&format!("{key}:{target}{}", if ro { ":ro" } else { "" }));
                }
            }
        }
        // Even a gate without sidecars needs its isolated DNS/network namespace.
        if services.is_empty() {
            if !self.make_network(&project, true) {
                return refuse("gate network could not be created");
            }
            return Ok(());
        }
        let mut network = Mapping::new();
        network.insert(s("name"), s(&project));
        network.insert(s("internal"), V::Bool(true));
        let mut networks = Mapping::new();
        networks.insert(s("default"), V::Mapping(network));
        let mut root = Mapping::new();
        root.insert(s("name"), s(&project));
        root.insert(s("services"), V::Mapping(services.clone()));
        root.insert(s("volumes"), V::Mapping(volumes));
        root.insert(s("networks"), V::Mapping(networks));
        std::fs::write(
            self.gate_file(),
            serde_yaml::to_string(&root).map_err(|e| e.to_string())?,
        )?;
        if !docker::compose(&project, Some(&self.gate_file()), &["up", "-d"], false) {
            return refuse("gate sidecars failed to start");
        }
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs(self.p.health_timeout);
        loop {
            let mut ready = true;
            for (name, svc) in &services {
                if svc.get("healthcheck").is_none() {
                    continue;
                }
                let container = format!("{project}-{}", name.as_str().unwrap_or("sidecar"));
                let health = docker::out(&[
                    "inspect",
                    "--format",
                    "{{.State.Health.Status}}",
                    &container,
                ])
                .unwrap_or_default();
                if health.trim() == "unhealthy" {
                    return refuse(format!("gate sidecar {container} unhealthy"));
                }
                if health.trim() != "healthy" {
                    ready = false;
                }
            }
            if ready {
                return Ok(());
            }
            if std::time::Instant::now() >= deadline {
                return refuse("gate sidecar health timeout");
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }
    fn close_gate(&self) {
        if self.gate_file().is_file() {
            let _ = docker::compose(
                &self.gate_network(),
                Some(&self.gate_file()),
                &["down", "-v", "--remove-orphans"],
                false,
            );
        }
    }
}
