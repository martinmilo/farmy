fn notify_run(ctx: &Ctx, st: &mut State) {
    let result = st.result.as_deref().unwrap_or("");
    let event = match result {
        "awaiting_review" => "awaiting_review",
        "question" => "question",
        "green" => "green",
        "cancelled" | "answered" | "superseded" => return,
        _ => "failed",
    };
    let event_id = format!("{}-{event}-{result}", st.id);
    let mut payload = serde_json::json!({"event_id":event_id,"event":event,"service":st.service,"pipeline_id":st.pipeline_id,"run_id":st.id,"profile":st.profile,"step":st.pipeline_step,"result":result,"branch":st.branch,"commit":st.gated_commit.as_ref().or(st.head.as_ref()),"compare_url":st.compare_url,"timestamp":now()});
    if !st.forbidden_paths.is_empty() {
        payload["forbidden_paths"]=serde_json::json!(st.forbidden_paths);
        payload["edits_dropped"]=serde_json::json!(st.edits_dropped);
        payload["diagnostic"]=serde_json::json!(if st.edits_dropped { "forbidden edits dropped" } else { "forbidden edits could not be dropped" });
    }
    if let Some(message) = deliver_notification(ctx, &payload, &run_dir(&st.service, &st.id)) {
        if message.contains("failed") {
            warn(&message);
        }
        if let Ok(_lock) =
            crate::locking::Lock::take(&run_dir(&st.service, &st.id).join("approval.lock"))
        {
            let mut current = load(&st.service, &st.id).unwrap_or_else(|| st.clone());
            current.notification = Some(message);
            save(&current);
            *st = current;
        }
    }
}
fn notify_pipeline_failure(ctx: &Ctx, p: &PipelineState, child: &State, result: &str) {
    let mut copy = child.clone();
    copy.pipeline_id = Some(p.id.clone());
    copy.result = Some(result.into());
    let payload = serde_json::json!({"event_id":format!("{}-{result}",p.id),"event":"failed","service":p.service,"pipeline_id":p.id,"run_id":child.id,"profile":child.profile,"step":p.step,"result":result,"branch":child.branch,"commit":child.head,"compare_url":child.compare_url,"timestamp":now()});
    let _ = deliver_notification(ctx, &payload, &pipeline_dir(&p.service, &p.id));
}
fn deliver_notification(ctx: &Ctx, event: &serde_json::Value, dir: &Path) -> Option<String> {
    let config = ctx.cfg.notify.as_ref()?;
    let refs = [
        config["url_secret"].as_str(),
        config["token_secret"].as_str(),
    ]
    .into_iter()
    .flatten()
    .map(String::from)
    .collect::<Vec<_>>();
    let unlock = secrets::unlock(&ctx.cfg);
    let resolved = secrets::resolve(&ctx.cfg, &[], unlock.as_ref(), &refs);
    let url = config["url"].as_str().map(String::from).or_else(|| {
        config["url_secret"]
            .as_str()
            .and_then(|s| resolved.values.get(s).cloned())
    });
    let token = config["token_secret"]
        .as_str()
        .and_then(|s| resolved.values.get(s));
    let Some(url) = url else {
        return Some("notification delivery failed: endpoint secret unavailable".into());
    };
    let mut summary = format!(
        "{}: {} {} run {} profile {}{} — {} branch {}{}",
        event["event"].as_str().unwrap_or("event"),
        event["service"].as_str().unwrap_or(""),
        event["pipeline_id"].as_str().unwrap_or("standalone"),
        event["run_id"].as_str().unwrap_or(""),
        event["profile"].as_str().unwrap_or(""),
        event["step"]
            .as_u64()
            .map(|s| format!(" step {s}"))
            .unwrap_or_default(),
        event["result"].as_str().unwrap_or(""),
        event["branch"].as_str().unwrap_or(""),
        event["compare_url"]
            .as_str()
            .map(|url| format!(" {url}"))
            .unwrap_or_default()
    );
    if let Some(paths)=event["forbidden_paths"].as_array() {
        summary.push_str(&format!("; {}: {}",event["diagnostic"].as_str().unwrap_or("forbidden edits"),paths.iter().filter_map(|p|p.as_str()).collect::<Vec<_>>().join(", ")));
    }
    let (body, content) = match config["format"].as_str().unwrap_or("json") {
        "slack" => (
            serde_json::json!({"text":summary}).to_string(),
            "application/json",
        ),
        "ntfy" => (summary, "text/plain"),
        _ => (event.to_string(), "application/json"),
    };
    let file = dir.join(format!(
        "notification-{}.json",
        event["event_id"].as_str().unwrap_or("event")
    ));
    let quoted = |s: &str| serde_json::to_string(s).unwrap_or_default();
    let mut conf = format!(
        "url = {}\nheader = {}\ndata-binary = {}\n",
        quoted(&url),
        quoted(&format!("Content-Type: {content}")),
        quoted(&body)
    );
    if let Some(token) = token {
        conf.push_str(&format!(
            "header = {}\n",
            quoted(&format!("Authorization: Bearer {token}"))
        ));
    }
    for attempt in 1..=3 {
        let state = serde_json::json!({"event":event,"attempts":attempt,"destination":"workspace notify configuration","state":"pending"});
        #[expect(clippy::let_underscore_must_use, reason = "the notification's state file for `farmy factory show`; delivery itself is what is reported")]
        let _ = std::fs::write(&file, state.to_string());
        let child = Command::new("curl")
            .args([
                "--silent",
                "--fail",
                "--max-time",
                "10",
                "--output",
                "/dev/null",
                "--request",
                "POST",
                "--config",
                "-",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let ok = if let Ok(mut child) = child {
            if let Some(mut input) = child.stdin.take() {
                #[expect(clippy::let_underscore_must_use, reason = "curl's exit status below says whether the notification went out")]
                let _ = input.write_all(conf.as_bytes());
            }
            child.wait().map(|s| s.success()).unwrap_or(false)
        } else {
            false
        };
        if ok {
            #[expect(clippy::let_underscore_must_use, reason = "the notification's state file for `farmy factory show`; delivery itself is what is reported")]
            let _=std::fs::write(&file,serde_json::json!({"event":event,"attempts":attempt,"state":"delivered","destination":"workspace notify configuration"}).to_string());
            return Some("notification delivered".into());
        }
        if attempt < 3 {
            std::thread::sleep(std::time::Duration::from_millis(100 * attempt));
        }
    }
    #[expect(clippy::let_underscore_must_use, reason = "the notification's state file for `farmy factory show`; delivery itself is what is reported")]
    let _=std::fs::write(&file,serde_json::json!({"event":event,"attempts":3,"state":"failed","destination":"workspace notify configuration"}).to_string());
    Some("notification delivery failed after 3 attempts".into())
}
