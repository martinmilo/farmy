// Factory logins (FORMATS.md, "Factory logins"): an agent's subscription login of its own for its factory
// runs, kept on the volume `farmy-factory-login-<agent>`, never the interactive login in farmy-shared.
// Included into factory.rs.

const LOGIN_USAGE: &str = "usage: farmy factory login <name> <agent>";

/// `farmy factory login <name> <agent>`: makes the agent's factory login with the service's image, running
/// its `create` line in a container that goes out the way the factory's git containers do.
fn login(args: &[String]) -> R {
    let (Some(name), Some(agent_name), None) = (args.first(), args.get(1), args.get(2)) else {
        return usage(LOGIN_USAGE);
    };
    let ctx = commands::load_ctx()?;
    commands::check_services(&ctx, std::slice::from_ref(name), false)?;
    let agent = match ctx.cfg.agent(agent_name) {
        Some(a) => a.clone(),
        None => match ctx.cfg.catalogue.iter().find(|(n, _)| n == agent_name) {
            Some((_, e)) => Agent::from_entry(agent_name, e.clone(), "agents.yml")?,
            None => {
                return refuse(format!(
                    "agent '{agent_name}' is neither in the catalogue nor under agents: in farmy.yml — farmy agents lists them"
                ));
            }
        },
    };
    let Some(login) = agent.factory_login.clone() else {
        return refuse(format!(
            "{agent_name} has no factory_login — farmy.yml: agents.{agent_name}.factory_login: {{path, create}}, the folder under $HOME holding its login and the line that makes it without a browser (FORMATS.md, Factory logins)"
        ));
    };
    login.check("farmy.yml", agent_name)?;
    commands::need_docker()?;
    let image = format!("farmy/{name}:dev");
    if !docker::ok(&["image", "inspect", &image]) {
        return refuse(format!(
            "{image} is not built — farmy start {name} builds it, then farmy factory login {name} {agent_name}"
        ));
    }
    let def = Definition::load(name)?;
    let on = commands::agents_on(&ctx, name);
    if !commands::installed_agents(&ctx, &def, &on)
        .iter()
        .any(|a| a.name == agent.name)
    {
        return refuse(format!(
            "{image} does not carry {agent_name} — turn it on for {name} (agents: in farmy.yml, or a factory profile with agent: {agent_name}), then farmy restart {name}"
        ));
    }

    let volume = crate::agents::factory_login_volume(agent_name);
    let target = login.target();
    let created = !docker::volume_exists(&volume);
    if created && !docker::quiet(&["volume", "create", &volume]) {
        return refuse(format!("the volume {volume} could not be created"));
    }
    let forget = || {
        if created {
            let _ = docker::quiet(&["volume", "rm", "-f", &volume]);
        }
    };
    let mount = format!("{volume}:{target}");
    let service_label = format!("farmy.service={name}");
    let agent_label = format!("farmy.agent={agent_name}");
    // the volume is the dev user's at the login path, so that the CLI can write its login there
    if !docker::quiet(&[
        "run",
        "--rm",
        "-u",
        "0",
        "--label",
        &service_label,
        "--label",
        &agent_label,
        "-v",
        &mount,
        "--entrypoint",
        "chown",
        &image,
        "1001:1001",
        &target,
    ]) {
        forget();
        return refuse(format!(
            "the volume {volume} could not be made the dev user's (chown 1001:1001 {target})"
        ));
    }

    let container = format!("{name}-factory-login-{agent_name}");
    let mut create: Vec<String> = vec!["create".into(), "--rm".into(), "-i".into()];
    {
        use std::io::IsTerminal;
        if std::io::stdin().is_terminal() {
            create.push("-t".into());
        }
    }
    create.extend([
        "--name".into(),
        container.clone(),
        "--label".into(),
        "farmy.role=login".into(),
        "--label".into(),
        service_label.clone(),
        "--label".into(),
        agent_label.clone(),
        "-u".into(),
        "dev".into(),
        "--network".into(),
        format!("{name}_default"),
    ]);
    for (k, v) in crate::egress::proxy_env(&ctx.cfg, &["keys".into(), name.clone()]) {
        create.extend(["-e".into(), format!("{k}={v}")]);
    }
    create.extend([
        "-v".into(),
        mount.clone(),
        "--entrypoint".into(),
        "sh".into(),
        image.clone(),
        "-c".into(),
        login.create.clone(),
    ]);
    if let Err(error) = docker::out(&create.iter().map(String::as_str).collect::<Vec<_>>()) {
        forget();
        return refuse(format!(
            "the login container {container} could not be made: {error}"
        ));
    }
    docker::ensure_network("farmy");
    if let Err(error) = docker::out(&["network", "connect", "farmy", &container]) {
        let _ = docker::quiet(&["rm", "-f", &container]);
        forget();
        return refuse(format!(
            "the login container {container} could not join the farmy network: {error}"
        ));
    }
    // the terminal's stdin, stdout and stderr: a device-code login prints its code and waits
    let code = match Command::new("docker")
        .args(["start", "-a", "-i", &container])
        .status()
    {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            let _ = docker::quiet(&["rm", "-f", &container]);
            forget();
            return refuse(format!("docker could not be run: {error}"));
        }
    };
    if code != 0 {
        forget();
        return refuse(format!(
            "[{name}] the factory login of {agent_name} failed: `{}` ended with exit {code}{}",
            login.create,
            if created {
                format!(" — {volume} removed")
            } else {
                String::new()
            }
        ));
    }
    println!(
        "{agent_name}'s factory login is in {volume} — a factory profile with agent: {agent_name} and mode: login uses it"
    );
    Ok(())
}

/// Login mode needs the login made: refused before any run container starts.
fn check_login(p: &Plan) -> R {
    if matches!(p.model, Model::Login(_)) {
        let volume = crate::agents::factory_login_volume(&p.agent.name);
        if !docker::volume_exists(&volume) {
            return refuse(format!(
                "[{}] {} has no factory login yet (no volume {volume}) — farmy factory login {} {} makes it",
                p.name, p.agent.name, p.name, p.agent.name
            ));
        }
    }
    Ok(())
}

/// The file whose exclusive lock is a factory login's turn, for every controller of this containers folder.
fn login_turn_path(agent: &str) -> PathBuf {
    let safe: String = agent
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    PathBuf::from(WORK).join(format!("factory-login-{safe}.lock"))
}

/// What asking for a login turn gave: the turn (None outside login mode), or the orphaned agent container
/// of the same login that could not be removed, in which case no turn is held and no agent may start.
enum Turn {
    Granted(Option<crate::locking::Lock>),
    Blocked(LoginBlock),
}

/// The pauses between the tries of removing an orphaned agent container: four tries over 10 s.
const ORPHAN_RETRY_PAUSES: [std::time::Duration; 3] = [
    std::time::Duration::from_secs(2),
    std::time::Duration::from_secs(3),
    std::time::Duration::from_secs(5),
];

/// In login mode, the login's turn: taken at once when no other agent container of the same login runs,
/// else waited for in phase `login_wait`. Held until it is dropped (after the agent's container ends);
/// a killed controller lets go of it with its process. None in the other modes. When an orphan of the
/// login cannot be removed the turn is let go of again and the run is told so: two agents never share a login.
fn login_turn(p: &Plan, st: &mut State) -> R<Turn> {
    if !matches!(p.model, Model::Login(_)) {
        return Ok(Turn::Granted(None));
    }
    let path = login_turn_path(&p.agent.name);
    std::fs::create_dir_all(WORK)?;
    let turn = if let Some(turn) = crate::locking::Lock::try_take(&path)? {
        turn
    } else {
        st.phase = "login_wait".into();
        save(st);
        let turn = crate::locking::Lock::take(&path)?;
        st.phase = "agent".into();
        save(st);
        turn
    };
    if let Err(block) = stop_orphans(p, st) {
        drop(turn);
        return Ok(Turn::Blocked(block));
    }
    Ok(Turn::Granted(Some(turn)))
}

/// Before a login turn: removes the running agent containers of the same factory login whose run is one of
/// this containers folder's and whose controller is gone (its controller.lock free), each with its run's
/// egress gate, and records each in the run's state. Another login's, a live run's and another containers folder's containers stay. A
/// removal that fails is tried again (ORPHAN_RETRY_PAUSES); an orphan still there after the last try is
/// the error, with Docker's message.
fn stop_orphans(p: &Plan, st: &mut State) -> Result<(), LoginBlock> {
    let filters = [
        "label=farmy.role=agent".to_string(),
        format!("label=farmy.factory-login={}", p.agent.name),
    ];
    let mut blocked = None;
    let mut stopped = false;
    for id in docker::ps(&filters, false) {
        let service = docker::container_label(&id, "farmy.service");
        let run = docker::container_label(&id, "farmy.run");
        if run == st.id || !path_part(&service) || !path_part(&run) {
            continue;
        }
        let dir = run_dir(&service, &run);
        if !dir.is_dir() || crate::locking::Lock::held(&dir.join("controller.lock")) {
            continue;
        }
        let name = docker::out(&["inspect", "-f", "{{.Name}}", &id])
            .ok()
            .map(|n| n.trim().trim_start_matches('/').to_string())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| id.clone());
        match remove_orphan(&name) {
            Ok(true) => {
                let gate = remove_orphan_gate(&service, &run);
                st.orphans_stopped.push(Orphan {
                    container: name,
                    run,
                    gate,
                });
                stopped = true;
            }
            // gone by itself meanwhile: nothing left to block the turn, nothing this run stopped
            Ok(false) => {}
            Err(error) => {
                blocked = Some(LoginBlock {
                    container: name,
                    run,
                    error,
                });
                break;
            }
        }
    }
    if stopped {
        save(st);
    }
    blocked.map_or(Ok(()), Err)
}

/// `docker rm -f` of an orphan, tried again after each pause while it fails and the container is still
/// there: Ok(true) when a removal worked, Ok(false) when the container went away by itself, else the
/// last try's error.
fn remove_orphan(name: &str) -> Result<bool, String> {
    let mut pauses = ORPHAN_RETRY_PAUSES.iter();
    loop {
        let error = match docker::out(&["rm", "-f", name]) {
            Ok(_) => return Ok(true),
            Err(error) => error,
        };
        if !docker::ok(&["inspect", name]) {
            return Ok(false);
        }
        let Some(pause) = pauses.next() else {
            return Err(if error.is_empty() {
                "docker rm -f failed".into()
            } else {
                error
            });
        };
        warn(format!(
            "factory: could not remove the orphaned agent container {name} ({error}) — trying again in {} s",
            pause.as_secs()
        ));
        std::thread::sleep(*pause);
    }
}

/// Removes the egress gate of an orphan's run (`<service>-run-<id>-egress-gate`) when it is there: its name
/// once it is gone, None when there was none. A gate that cannot be removed is warned about and left (None):
/// only the agent container decides the login turn.
fn remove_orphan_gate(service: &str, run: &str) -> Option<String> {
    let gate = format!("{service}-run-{run}-egress-gate");
    if !docker::ok(&["inspect", &gate]) {
        return None;
    }
    match docker::out(&["rm", "-f", &gate]) {
        Ok(_) => Some(gate),
        Err(_) if !docker::ok(&["inspect", &gate]) => Some(gate),
        Err(error) => {
            warn(format!(
                "factory: could not remove the egress gate {gate} of the orphaned run {run} ({error})"
            ));
            None
        }
    }
}

/// A label value that is safe as one path component under `.work/`.
fn path_part(value: &str) -> bool {
    !value.is_empty() && value != "." && value != ".." && !value.contains(['/', '\\'])
}

/// Removes a container that outlived its `docker run` client (returned or failed while it still exists).
fn remove_leftover(container: &str) {
    if docker::ok(&["inspect", container]) && !docker::ok(&["rm", "-f", container]) {
        warn(format!(
            "factory: could not remove the agent container {container}"
        ));
    }
}
