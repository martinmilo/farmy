#[derive(Serialize, Deserialize, Clone)]
struct PipelineState {
    id: String,
    service: String,
    name: String,
    state: String,
    step: usize,
    steps: usize,
    profile: String,
    active_run: Option<String>,
    handoffs: u32,
    handoff_limit: u32,
    task: String,
    config: crate::model::PipelineCfg,
    profiles: BTreeMap<String, FactoryProfile>,
    #[serde(default)]
    definition: Option<serde_yaml::Value>,
    #[serde(default)]
    pending: Option<State>,
    #[serde(default)]
    question_run: Option<String>,
    #[serde(default)]
    pid: u32,
}
fn pipeline_dir(service: &str, id: &str) -> PathBuf {
    PathBuf::from(WORK).join(service).join("pipelines").join(id)
}
fn save_pipeline(st: &PipelineState) {
    let dir = pipeline_dir(&st.service, &st.id);
    #[expect(clippy::let_underscore_must_use, reason = "kept as before: a failed write loses this state silently (flagged in the sweep notes)")]
    let _ = std::fs::create_dir_all(&dir);
    let tmp = dir.join(format!("state.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, serde_json::to_vec_pretty(st).unwrap_or_default()).is_ok() {
        #[expect(clippy::let_underscore_must_use, reason = "kept as before: a failed write loses this state silently (flagged in the sweep notes)")]
        let _ = std::fs::rename(tmp, dir.join("state.json"));
    }
}
fn pipelines(service: Option<&str>) -> Vec<PipelineState> {
    let mut out = vec![];
    if let Ok(services) = std::fs::read_dir(WORK) {
        for s in services.flatten() {
            let name = s.file_name().to_string_lossy().to_string();
            if service.map(|n| n != name).unwrap_or(false) {
                continue;
            }
            if let Ok(ids) = std::fs::read_dir(s.path().join("pipelines")) {
                for id in ids.flatten() {
                    if let Ok(text) = std::fs::read_to_string(id.path().join("state.json"))
                        && let Ok(st) = serde_json::from_str(&text) {
                            out.push(st)
                        }
                }
            }
        }
    }
    out.sort_by(|a: &PipelineState, b| a.id.cmp(&b.id));
    out
}
fn find_pipeline(id: &str) -> R<PipelineState> {
    pipelines(None)
        .into_iter()
        .find(|p| p.id == id)
        .ok_or_else(|| format!("no pipeline {id}").into())
}
pub(crate) fn pipelines_json(service: &str) -> serde_json::Value {
    serde_json::Value::Array(pipelines(Some(service)).into_iter().map(|p|serde_json::json!({"id":p.id,"name":p.name,"state":p.state,"step":p.step,"steps":p.steps,"profile":p.profile,"active_run":p.active_run,"handoffs":p.handoffs,"handoff_limit":p.handoff_limit})).collect())
}
#[expect(clippy::print_stdout, reason = "the pipeline commands' answers are for the user on the terminal")]
fn pipeline_main(args: &[String]) -> R {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str){
        Some("start")=>{
            let Some(service)=rest.first()else{return usage(USAGE)};let Some(name)=rest.get(1)else{return usage(USAGE)};
            let mut task=None;let mut wait=false;let mut it=rest[2..].iter();while let Some(a)=it.next(){match a.as_str(){"--task"=>task=Some(required_value(&mut it,a)?),"--wait"=>wait=true,_=>return usage(USAGE)}}
            let task=read_text(task.ok_or_else(||"pipeline start needs --task".to_string())?)?;
            let ctx=commands::load_ctx()?;commands::check_services(&ctx,std::slice::from_ref(service),false)?;let def=Definition::load(service)?;
            let cfg=def.pipelines.get(name).cloned().ok_or_else(||format!("services/{service}.yml: unknown pipeline {name}"))?;
            if cfg.steps.is_empty(){return refuse(format!("pipeline {name}: steps must not be empty"));}
            let mut plans=vec![];let mut profiles=BTreeMap::new();for profile in cfg.steps.iter().chain(cfg.on_question.iter()){let p=plan(&ctx,service,Some(profile),None)?;profiles.insert(profile.clone(),p.config.clone());plans.push(p);}
            commands::need_docker()?;if docker::app_cid(service).is_none(){return refuse(format!("{service} is not running — farmy start {service}"));}for p in &plans{check_login(p)?;}
            let mut ps=PipelineState{id:format!("p-{}",new_id()),service:service.clone(),name:name.clone(),state:"queued".into(),step:1,steps:cfg.steps.len(),profile:cfg.steps[0].clone(),active_run:None,handoffs:0,handoff_limit:cfg.handoff_limit.unwrap_or(3),task,config:cfg,profiles,definition:Some(serde_yaml::from_str(&std::fs::read_to_string(definition_path(service))?).map_err(|e|e.to_string())?),pending:None,question_run:None,pid:0};save_pipeline(&ps);
            if wait{let controller=crate::locking::Lock::take(&pipeline_lock(&ps))?;let result=drive_pipeline(&ps.id,&controller)?;wait_result("pipeline",&ps.id,&result)}else{spawn_pipeline(&mut ps)?;println!("pipeline {} started",ps.id);Ok(())}
        }
        Some("run")=>{let id=rest.first().ok_or_else(||"pipeline run needs ID".to_string())?;let controller=crate::locking::Lock::inherit_or_take(&pipeline_lock(&find_pipeline(id)?))?;drive_pipeline(id,&controller)?;Ok(())}
        Some("resume")=>{let id=rest.first().ok_or_else(||"pipeline resume needs ID".to_string())?;let mut ps=find_pipeline(id)?;
            if let Some(r)=ps.active_run.as_ref().and_then(|id|load(&ps.service,id))&& r.result.as_deref()==Some("publish_failed"){retry_publish(&r.id)?;}
            if rest.iter().any(|a|a=="--wait"){let controller=crate::locking::Lock::take(&pipeline_lock(&ps))?;let result=drive_pipeline(id,&controller)?;wait_result("pipeline",id,&result)}else{spawn_pipeline(&mut ps)?;println!("pipeline {id}: {}",ps.state);Ok(())}
        }
        Some("list")=>{for p in pipelines(rest.first().map(String::as_str)){println!("{} {} {} {}/{} {} child {}",p.id,p.name,p.state,p.step,p.steps,p.profile,p.active_run.as_deref().unwrap_or("-"));}Ok(())}
        Some("show")=>{let id=rest.first().ok_or_else(||"pipeline show needs ID".to_string())?;let p=find_pipeline(id)?;println!("pipeline {}\nname {}\nservice {}\nstate {}\nstep {}/{} {}\nactive_run {}\nhandoffs {}/{}",p.id,p.name,p.service,p.state,p.step,p.steps,p.profile,p.active_run.as_deref().unwrap_or("-"),p.handoffs,p.handoff_limit);if let Some(id)=p.active_run{show(&[id])?;}Ok(())}
        Some("cancel")=>{
            let id=rest.first().ok_or_else(||"pipeline cancel needs ID".to_string())?;let mut p=find_pipeline(id)?;
            if p.pid!=0&&crate::locking::Lock::held(&pipeline_lock(&p)){#[expect(clippy::let_underscore_must_use, reason = "the process may have exited by itself already; nothing else to do either way")] let _=Command::new("kill").args(["-KILL",&p.pid.to_string()]).status();}
            let _lock=crate::locking::Lock::take(&pipeline_dir(&p.service,id).join("transition.lock"))?;
            p=find_pipeline(id)?;p.state="cancelled".into();save_pipeline(&p);
            for st in raw_runs(Some(&p.service)).into_iter().filter(|s|s.pipeline_id.as_deref()==Some(id)&&s.phase!="done"){cancel(&[st.id])?;}
            println!("pipeline {id} cancelled");Ok(())
        }
        _=>usage("usage: farmy factory pipeline start <service> <pipeline> --task <text|file> [--wait] | list [service] | show <id> | cancel <id> | resume <id> [--wait]")
    }
}
/// A pipeline's controller.lock: held by the process that drives it.
fn pipeline_lock(p: &PipelineState) -> PathBuf {
    pipeline_dir(&p.service, &p.id).join("controller.lock")
}
/// Starts a controller for the pipeline (`pipeline run <id>`) unless one holds it, and
/// hands it the pipeline's controller.lock.
fn spawn_pipeline(p: &mut PipelineState) -> R {
    let _launch =
        crate::locking::Lock::take(&pipeline_dir(&p.service, &p.id).join("transition.lock"))?;
    *p = find_pipeline(&p.id)?;
    let Some(controller) = crate::locking::Lock::try_take(&pipeline_lock(p))? else {
        return Ok(());
    };
    use std::os::unix::process::CommandExt;
    let dir = pipeline_dir(&p.service, &p.id);
    std::fs::create_dir_all(&dir)?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("controller.log"))?;
    let child = Command::new(std::env::current_exe()?)
        .args(["factory", "pipeline", "run", &p.id])
        .stdin(controller.into_stdio())
        .stdout(log.try_clone()?)
        .stderr(log)
        .process_group(0)
        .spawn()?;
    p.pid = child.id();
    save_pipeline(p);
    Ok(())
}
fn reserve_child(p: &mut PipelineState, mut child: State) {
    child.pipeline_id = Some(p.id.clone());
    child.pipeline_name = Some(p.name.clone());
    child.pipeline_step = Some(p.step);
    p.profile = child.profile.clone();
    p.active_run = Some(child.id.clone());
    p.pending = Some(child);
    p.state = "queued".into();
    save_pipeline(p);
}
/// The runs a pipeline controller spawned, each with its own process handle.
#[derive(Default)]
struct Spawned(BTreeMap<String, std::process::Child>);
impl Spawned {
    fn add(&mut self, id: &str, child: std::process::Child) {
        self.0.insert(id.to_string(), child);
    }
    /// Whether the run still has a process. One this controller spawned is alive until its
    /// own handle says it exited (`try_wait`, which also reaps it), whatever else says;
    /// after that, and for the runs it did not spawn (a previous controller's, after a
    /// resume), `held` answers: in production whether the run's controller.lock is held.
    fn alive(&mut self, st: &State, held: impl Fn(&State) -> bool) -> bool {
        if let Some(child) = self.0.get_mut(&st.id) {
            if matches!(child.try_wait(), Ok(None)) {
                return true;
            }
            self.0.remove(&st.id);
        }
        held(st)
    }
    /// Reaps the children that have exited.
    fn reap(&mut self) {
        self.0.retain(|_, child| matches!(child.try_wait(), Ok(None)));
    }
}
/// Drives the pipeline until it ends or pauses; the caller holds its controller.lock
/// (`_controller`).
fn drive_pipeline(id: &str, _controller: &crate::locking::Lock) -> R<String> {
    let first = find_pipeline(id)?;
    let ctx = commands::load_ctx()?;
    let mut spawned = Spawned::default();
    loop {
        let _transition =
            crate::locking::Lock::take(&pipeline_dir(&first.service, id).join("transition.lock"))?;
        let mut p = find_pipeline(id)?;
        p.pid = std::process::id();
        if matches!(
            p.state.as_str(),
            "green"
                | "cancelled"
                | "handoff_limit"
                | "permission_violation"
                | "answer_missing"
                | "max_iterations"
                | "test_failed_to_run"
                | "agent_failed"
                | "timeout"
                | "stalled"
                | "login_blocked"
        ) {
            p.pid = 0;
            save_pipeline(&p);
            return Ok(p.state);
        }
        if p.active_run.is_none() {
            let profile = &p.config.steps[p.step - 1];
            let plan = plan_with_definition(
                &ctx,
                &p.service,
                Some(profile),
                p.profiles.get(profile),
                p.definition.as_ref(),
            )?;
            let child = make_state(&plan, p.task.clone(), None, None, false, String::new());
            reserve_child(&mut p, child);
        }
        spawned.reap();
        let child_id = p.active_run.clone().expect("set before, or reserved just above");
        let mut child = match load(&p.service, &child_id) {
            Some(child) => child,
            None => {
                let mut child = p.pending.clone().ok_or_else(|| {
                    "pipeline reserved child has no durable launch state".to_string()
                })?;
                // No process yet: not the pid of whoever reserved it.
                child.pid = 0;
                let controller = crate::locking::Lock::take(&run_lock(&child))?;
                save(&child);
                let handle = spawn_run(&mut child, controller)?;
                spawned.add(&child.id, handle);
                p.pending = Some(child.clone());
                p.state = "running".into();
                save_pipeline(&p);
                child
            }
        };
        if child.phase != "done" && !spawned.alive(&child, run_held) {
            // Its process is gone. Held from here, so that nothing else starts it meanwhile.
            if let Some(controller) = crate::locking::Lock::try_take(&run_lock(&child))? {
                match load(&p.service, &child.id) {
                    // It ended between the two looks.
                    Some(current) if current.phase == "done" => child = current,
                    current => {
                        child = current.unwrap_or(child);
                        cleanup_abandoned(&child);
                        child.phase = "queued".into();
                        save(&child);
                        let handle = spawn_run(&mut child, controller)?;
                        spawned.add(&child.id, handle);
                    }
                }
            }
        }
        if child.phase != "done" {
            p.state = if child.phase == "queued" {
                "queued"
            } else {
                "running"
            }
            .into();
            save_pipeline(&p);
            drop(_transition);
            std::thread::sleep(std::time::Duration::from_millis(100));
            continue;
        }
        let result = child.result.as_deref().unwrap_or("interrupted");
        match result {
            "green" | "answered" => {
                if child.answering {
                    let question_id = child
                        .answering_for
                        .as_ref()
                        .or(p.question_run.as_ref())
                        .ok_or_else(|| "answer has no question identity".to_string())?;
                    let question = load(&p.service, question_id)
                        .ok_or_else(|| "question history is missing".to_string())?;
                    let plan = saved_plan(&ctx, &question)?;
                    let source = if result == "answered" {
                        &question
                    } else {
                        &child
                    };
                    let context = format!(
                        "{}\nThe previous run asked:\n{}\n\nThe answer:\n{}\n",
                        question.context,
                        question.question.as_deref().unwrap_or(""),
                        child.answer.as_deref().unwrap_or("")
                    );
                    let next = make_state(
                        &plan,
                        question.task.clone(),
                        Some(source.id.clone()),
                        Some(source),
                        false,
                        context,
                    );
                    p.question_run = None;
                    reserve_child(&mut p, next);
                } else if p.step == p.steps {
                    p.state = "green".into();
                    p.pid = 0;
                    save_pipeline(&p);
                    return Ok(p.state);
                } else {
                    p.step += 1;
                    let profile = &p.config.steps[p.step - 1];
                    let plan = plan_with_definition(
                        &ctx,
                        &p.service,
                        Some(profile),
                        p.profiles.get(profile),
                        p.definition.as_ref(),
                    )?;
                    let next = make_state(
                        &plan,
                        p.task.clone(),
                        Some(child.id.clone()),
                        Some(&child),
                        false,
                        source_evidence(&child),
                    );
                    reserve_child(&mut p, next);
                }
            }
            "question" if !child.answering && p.config.on_question.is_some() && p.config.on_question.as_deref()!=Some(child.profile.as_str()) => {
                if p.handoffs >= p.handoff_limit {
                    p.state = "handoff_limit".into();
                    p.pid = 0;
                    save_pipeline(&p);
                    notify_pipeline_failure(&ctx, &p, &child, "handoff_limit");
                    return Ok(p.state);
                }
                p.handoffs += 1;
                p.question_run = Some(child.id.clone());
                let profile = p.config.on_question.as_ref().expect("the match guard checked on_question");
                let plan = plan_with_definition(
                    &ctx,
                    &p.service,
                    Some(profile),
                    p.profiles.get(profile),
                    p.definition.as_ref(),
                )?;
                let mut next=make_state(&plan,child.question.clone().unwrap_or_default(),Some(child.id.clone()),Some(&child),true,"Answer the worker's question in .farmy/answer.md. This control file is permitted outside writes and is never committed. Preserve the worker's captured work.".into());
                next.answering_for = Some(child.id.clone());
                next.red_reference_commit = gated_head(&child);
                next.review_answer = p.config.review_answers;
                reserve_child(&mut p, next);
            }
            _ => {
                p.state = result.into();
                p.pid = 0;
                save_pipeline(&p);
                return Ok(p.state);
            }
        }
    }
}
fn notify_parent(st: &State) -> R {
    if let Some(id) = &st.pipeline_id {
        let mut p = find_pipeline(id)?;
        spawn_pipeline(&mut p)?;
    }
    Ok(())
}
#[expect(clippy::print_stdout, reason = "the revise command's answer is for the user on the terminal")]
fn revise(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return usage(USAGE);
    };
    let mut wait = false;
    let mut feedback = None;
    for a in &args[1..] {
        if a == "--wait" {
            wait = true;
        } else if feedback.is_none() {
            feedback = Some(a.clone());
        } else {
            return usage(USAGE);
        }
    }
    let feedback = read_text(feedback.ok_or_else(|| "revise needs <text|file>".to_string())?)?;
    let old = find(id)?;
    let _pipeline_lock = old
        .pipeline_id
        .as_ref()
        .map(|pid| {
            crate::locking::Lock::take(&pipeline_dir(&old.service, pid).join("transition.lock"))
        })
        .transpose()?;
    let _approval = crate::locking::Lock::take(&run_dir(&old.service, id).join("approval.lock"))?;
    let mut old = load(&old.service, id).unwrap_or(old);
    let _execution = crate::locking::Lock::take(
        &PathBuf::from(WORK)
            .join(&old.service)
            .join("execution.lock"),
    )?;
    if old.superseded_by.is_some()
        || !matches!(old.result.as_deref(), Some("awaiting_review" | "green"))
    {
        return refuse(format!(
            "run {id}: only the latest awaiting_review or approved attempt can be revised"
        ));
    }
    let downstream: Vec<_> = raw_runs(Some(&old.service))
        .into_iter()
        .filter(|s| {
            s.from.as_deref() == Some(id)
                && s.revision_of.is_none()
                && s.result.as_deref() != Some("cancelled")
        })
        .collect();
    if downstream.iter().any(|s| s.phase != "queued") {
        return refuse(format!("run {id}: downstream work has already begun"));
    }
    for mut child in downstream {
        child.phase = "done".into();
        child.result = Some("cancelled".into());
        child.ended = Some(now());
        save(&child);
    }
    let ctx = commands::load_ctx()?;
    let p = saved_plan(&ctx, &old)?;
    let mut next = make_state(
        &p,
        old.task.clone(),
        Some(old.id.clone()),
        Some(&old),
        old.answering,
        format!("{}\nReview feedback:\n{feedback}\n", old.context),
    );
    next.branch = old.branch.clone();
    next.revision_of = Some(old.id.clone());
    next.review_base = old.review_base.clone().or(old.base.clone());
    next.pipeline_id = old.pipeline_id.clone();
    next.pipeline_name = old.pipeline_name.clone();
    next.pipeline_step = old.pipeline_step;
    next.red_reference_commit = old.red_reference_commit.clone();
    next.answering_for = old.answering_for.clone();
    next.review_answer = old.review_answer;
    old.approval_valid = false;
    old.superseded_by = Some(next.id.clone());
    old.result = Some("superseded".into());
    save(&old);
    let controller = crate::locking::Lock::take(&run_lock(&next))?;
    save(&next);
    if let Some(id) = &next.pipeline_id {
        let mut ps = find_pipeline(id)?;
        ps.step = old.pipeline_step.unwrap_or(ps.step);
        reserve_child(&mut ps, next.clone());
    }
    drop(_execution);
    drop(_approval);
    drop(_pipeline_lock);
    if wait {
        let result = execute(&ctx, &p, next.clone(), &controller)?;
        if let Some(pid) = &next.pipeline_id {
            let _transition = crate::locking::Lock::take(
                &pipeline_dir(&next.service, pid).join("transition.lock"),
            )?;
            let mut ps = find_pipeline(pid)?;
            if ps.active_run.as_deref() == Some(&next.id) {
                ps.state = result.clone();
                save_pipeline(&ps);
            }
        }
        if result == "green" || result == "answered" {
            notify_parent(&next)?;
        }
        wait_result("run", &next.id, &result)
    } else {
        spawn_run(&mut next, controller)?;
        println!("run {} revision of {}", next.id, id);
        if let Some(pid) = &next.pipeline_id {
            let mut ps = find_pipeline(pid)?;
            spawn_pipeline(&mut ps)?;
        }
        Ok(())
    }
}
fn resume_run(args: &[String]) -> R {
    let Some(id) = args.first() else {
        return usage(USAGE);
    };
    let mut st = find(id)?;
    if st.result.as_deref() == Some("publish_failed") {
        retry_publish(id)?;
        st = find(id)?;
    }
    if let Some(pid) = st.pipeline_id {
        return pipeline_main(
            &["resume".into(), pid]
                .into_iter()
                .chain(args.iter().skip(1).cloned())
                .collect::<Vec<_>>(),
        );
    }
    wait_result("run", id, st.result.as_deref().unwrap_or(&st.phase))
}
fn percent(s: &str, slash: bool) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) || (slash && b == b'/') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
fn compare_url(def: &Definition, base: &str, head: &str) -> Option<String> {
    let raw = def.repo_web_url.as_deref().or(def.repo.as_deref())?;
    let (host, path) = if let Some((_, rest)) = raw.split_once("://") {
        let (authority, path) = rest.split_once('/')?;
        (authority.rsplit('@').next()?.to_string(), path.to_string())
    } else {
        let (authority, path) = raw.split_once(':')?;
        (authority.rsplit('@').next()?.to_string(), path.to_string())
    };
    let kind = def.forge.as_deref().or(match host.as_str() {
        "github.com" => Some("github"),
        "gitlab.com" => Some("gitlab"),
        _ => None,
    })?;
    let web = def
        .repo_web_url
        .clone()
        .unwrap_or_else(|| format!("https://{host}/{}", path.trim_end_matches(".git")))
        .trim_end_matches('/')
        .to_string();
    let separator = if kind == "gitlab" {
        "/-/compare/"
    } else {
        "/compare/"
    };
    if !matches!(kind, "github" | "gitlab" | "forgejo" | "gitea") {
        return None;
    }
    Some(format!(
        "{}{separator}{}...{}",
        percent_url_path(&web),
        percent(base, false),
        percent(head, false)
    ))
}
fn percent_url_path(url: &str) -> String {
    if let Some((scheme, rest)) = url.split_once("://")
        && let Some((authority, path)) = rest.split_once('/') {
            return format!("{scheme}://{authority}/{}", percent(path, true));
        }
    url.to_string()
}
fn retry_publish(id: &str) -> R {
    let st = find(id)?;
    let _lock = crate::locking::Lock::take(&run_dir(&st.service, id).join("approval.lock"))?;
    let mut st = load(&st.service, id).unwrap_or(st);
    if st.result.as_deref() != Some("publish_failed") {
        return Ok(());
    }
    let ctx = commands::load_ctx()?;
    let p = saved_plan(&ctx, &st)?;
    let mut run = Run {
        ctx: &ctx,
        p: &p,
        id: st.id.clone(),
        git_n: 2000000.into(),
        made: vec![],
        broker: false,
        egress_gate: false,
    };
    let wanted = st
        .publish_result
        .clone()
        .unwrap_or_else(|| "awaiting_review".into());
    let published = publish(&mut run, &mut st, &wanted);
    if published {
        st.result = Some(wanted);
    }
    save(&st);
    drop(_lock);
    if published {
        notify_run(&ctx, &mut st);
    }
    Ok(())
}
fn publish(run: &mut Run<'_>, st: &mut State, wanted: &str) -> bool {
    st.gated_commit = st.head.clone();
    if st.remote {
        let expected = st.gated_commit.clone().unwrap_or_default();
        let(code,out,err)=run.git("set -e\nhead=$(git rev-parse HEAD)\n[ \"$head\" = \"$FARMY_EXPECTED\" ] || exit 1\ngit push -q origin \"$FARMY_EXPECTED:refs/heads/$FARMY_BRANCH\"",false,&[("FARMY_BRANCH",&st.branch),("FARMY_EXPECTED",&expected)]);
        append(
            &run_dir(&st.service, &st.id).join("git.log"),
            &format!("{out}{err}"),
        );
        if code != 0 {
            st.publish_result = Some(wanted.into());
            st.compare_url = None;
            st.result = Some("publish_failed".into());
            return false;
        }
        st.compare_url = compare_url(
            &run.p.def,
            st.review_base
                .as_deref()
                .or(st.base.as_deref())
                .unwrap_or(""),
            &expected,
        );
    }
    true
}
