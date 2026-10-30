//! The session's screen: every service with its state, the sidecars and ports of the selected one, the
//! agent's activity. An action's output streams into a pane of the screen; a shell and the logs take the
//! terminal over and give it back. tmux (the session this runs in) is never shown to the user. It renders what
//! `farmy status --json` says and nothing else, re-read after every action, when Docker reports an
//! event on a container, and every few seconds as a fallback.
use crate::R;
use crate::commands;
use crossterm::ExecutableCommand;
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Row, Table, TableState, Wrap};
use serde_json::Value;
use std::io::BufRead;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_secs(3);

struct App {
    services: Vec<Value>,
    table: TableState,
    message: String,
    keys: Vec<(String, String)>,
    generated: String,
    egress: Value,
    /// The folder in use, as `farmy status` prints it.
    folder: String,
    pane: Option<Pane>,
}

/// An action's output, streamed into the screen: scroll with the arrows and PageUp/PageDown, Esc closes it
/// once the action ended.
struct Pane {
    title: String,
    lines: Vec<String>,
    scroll: usize,
    follow: bool,
    done: Option<i32>,
    rx: Receiver<Option<i32>>,
    lines_rx: Receiver<String>,
}

impl App {
    fn load() -> App {
        let snap =
            commands::snapshot_now().unwrap_or_else(|_| serde_json::json!({ "services": [] }));
        let services = snap["services"].as_array().cloned().unwrap_or_default();
        let mut table = TableState::default();
        if !services.is_empty() {
            table.select(Some(0));
        }
        let keys = commands::states_summary().into_iter().collect();
        App {
            services,
            table,
            message: HELP.into(),
            keys,
            generated: snap["generated"].as_str().unwrap_or("").to_string(),
            egress: snap["egress"].clone(),
            folder: crate::folder::folder_text(),
            pane: None,
        }
    }

    fn refresh(&mut self) {
        let selected = self.table.selected();
        let message = self.message.clone();
        let pane = self.pane.take();
        *self = App::load();
        self.message = message;
        self.pane = pane;
        if let Some(i) = selected
            && i < self.services.len()
        {
            self.table.select(Some(i));
        }
    }

    fn current(&self) -> Option<&Value> {
        self.table.selected().and_then(|i| self.services.get(i))
    }

    fn move_by(&mut self, delta: i32) {
        if self.services.is_empty() {
            return;
        }
        let last = self.services.len() - 1;
        let current = self.table.selected().unwrap_or(0);
        let step = usize::try_from(delta.unsigned_abs()).unwrap_or(usize::MAX);
        let i = if delta < 0 {
            current.saturating_sub(step)
        } else {
            current.saturating_add(step)
        };
        self.table.select(Some(i.min(last)));
    }
}

const HELP: &str = "s start · x stop · r restart · D destroy · l logs · e shell · c command · a add · k keys reload · R refresh · q leave (the session stays)";

fn text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn egress_text(service: &Value) -> String {
    let mode = service["egress"]["mode"].as_str().unwrap_or(
        if service["egress"]["restricted"].as_bool().unwrap_or(false) {
            "restricted"
        } else {
            "unrestricted"
        },
    );
    format!(
        "{} denied{}",
        service["egress"]["denied"].as_u64().unwrap_or(0),
        if mode == "unrestricted" {
            String::new()
        } else {
            format!(" ({mode})")
        }
    )
}
fn toolbox_drift(service: &Value) -> Option<String> {
    service["toolbox_outdated"]
        .as_bool()
        .unwrap_or(false)
        .then(|| {
            crate::version::drift(&text(&service["name"]), service["toolbox_version"].as_str())
        })
        .flatten()
}

fn service_table(services: &[Value]) -> Table<'static> {
    let header = Row::new(vec![
        "service",
        "state",
        "ports",
        "agent",
        "egress",
        "repository",
        "address / note",
    ])
    .style(Style::default().add_modifier(Modifier::BOLD));
    let rows: Vec<Row<'_>> = services
        .iter()
        .map(|s| {
            let state = text(&s["state"]);
            let state_style = if state == "running" {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            let urls: Vec<String> = s["ports"]
                .as_array()
                .map(|ps| {
                    ps.iter()
                        .map(|p| {
                            format!(
                                "{}{}",
                                text(&p["url"]),
                                match p["listening"] {
                                    Value::Bool(true) => " ●",
                                    Value::Bool(false) => " ○",
                                    _ => "",
                                }
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            let last = format!(
                "{} {} {}",
                urls.join(" "),
                text(&s["note"]),
                toolbox_drift(s).unwrap_or_default()
            );
            let block = if s["block"].is_null() {
                "-".to_string()
            } else {
                text(&s["block"])
            };
            Row::new(vec![
                Span::raw(text(&s["name"])),
                Span::styled(state, state_style),
                Span::raw(block),
                Span::raw(agent_text(s)),
                Span::raw(egress_text(s)),
                Span::raw(text(&s["repo"])),
                Span::raw(last),
            ])
        })
        .collect();
    Table::new(
        rows,
        [
            Constraint::Length(14),
            Constraint::Length(9),
            Constraint::Length(11),
            Constraint::Length(12),
            Constraint::Length(23),
            Constraint::Percentage(30),
            Constraint::Min(20),
        ],
    )
    .header(header)
    .block(Block::default().borders(Borders::ALL).title(" services "))
    .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED))
}

/// Pending handoffs stay visible even when newer runs have finished.
fn factory_lines(service: &Value) -> Vec<Line<'static>> {
    let empty = vec![];
    let runs = service["runs"].as_array().unwrap_or(&empty);
    let pending =
        |run: &&Value| matches!(run["result"].as_str(), Some("awaiting_review" | "question"));
    let mut lines = vec![];
    for pipeline in service["pipelines"].as_array().into_iter().flatten() {
        let state = text(&pipeline["state"]);
        let style = if matches!(state.as_str(), "awaiting_review" | "question") {
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };
        lines.push(Line::styled(
            format!(
                "pipeline {} [{}] — {} step {}/{} [{}] child {}",
                text(&pipeline["id"]),
                text(&pipeline["name"]),
                state,
                text(&pipeline["step"]),
                text(&pipeline["steps"]),
                text(&pipeline["profile"]),
                pipeline["active_run"].as_str().unwrap_or("queued")
            ),
            style,
        ));
    }
    for run in runs
        .iter()
        .filter(pending)
        .chain(runs.iter().rev().filter(|r| !pending(r)).take(3))
    {
        let id = text(&run["id"]);
        let profile = run["profile"].as_str().unwrap_or("default");
        let result = run["result"]
            .as_str()
            .or(run["phase"].as_str())
            .unwrap_or("");
        let source = run["from"]
            .as_str()
            .map(|s| format!(" from {s}"))
            .unwrap_or_default();
        let summary = format!(
            "run {id} [{profile}]{source} — {result} {}/{}",
            text(&run["iteration"]),
            text(&run["max_iterations"])
        );
        let style = if pending(&run) {
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };
        lines.push(Line::styled(summary, style));
        if let Some(summary) = run["gate_summary"].as_str() {
            lines.push(Line::from(format!("Gate: {summary}")));
        }
        if let Some(url) = run["compare_url"].as_str() {
            lines.push(Line::from(format!("Review: {url}")));
        } else if result == "awaiting_review"
            && let Some(branch) = run["branch"].as_str()
        {
            lines.push(Line::from(format!("Review branch: {branch}")));
        }
        match result {
            "awaiting_review" => lines.push(Line::styled(
                format!("Approval needed: farmy factory approve {id}"),
                style,
            )),
            "question" => {
                for line in run["question"].as_str().unwrap_or("").lines() {
                    lines.push(Line::styled(format!("Question: {line}"), style));
                }
                lines.push(Line::from(format!(
                    "Continue: farmy factory answer {id} <text|file>"
                )));
            }
            _ => {}
        }
    }
    lines
}

/// The most active of a service's agents: working > waiting > running > idle.
fn busiest_agent(svc: &Value) -> Option<(&str, &Value)> {
    let rank = |s: &str| {
        ["working", "waiting", "running", "idle"]
            .iter()
            .position(|x| *x == s)
            .unwrap_or(9)
    };
    svc["agents"]
        .as_object()?
        .iter()
        .map(|(k, v)| (k.as_str(), v))
        .min_by_key(|(_, v)| rank(text(&v["state"]).as_str()))
}

/// "working 12m" / "waiting" / "idle" / "running" from the most active agent entry.
fn agent_text(svc: &Value) -> String {
    let Some((_, a)) = busiest_agent(svc) else {
        return String::new();
    };
    let state = text(&a["state"]);
    let since = a["since"].as_str().and_then(parse_rfc3339).map(|t| {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let d = now.saturating_sub(t);
        if d < 60 {
            format!(" {d}s")
        } else if d < 3600 {
            format!(" {}m", d / 60)
        } else {
            format!(" {}h{:02}", d / 3600, (d % 3600) / 60)
        }
    });
    format!(
        "{state}{}",
        if state == "working" {
            since.unwrap_or_default()
        } else {
            String::new()
        }
    )
}

/// Seconds since the epoch of an RFC 3339 UTC time (YYYY-MM-DDTHH:MM:SSZ); None otherwise.
fn parse_rfc3339(s: &str) -> Option<u64> {
    let s = s.trim().trim_end_matches('Z');
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let mut t = time
        .split(':')
        .map(|x| x.split('.').next().unwrap_or("0").parse::<i64>().ok());
    let (hh, mm, ss) = (t.next()??, t.next()??, t.next()??);
    // days from civil (Howard Hinnant)
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(
        (days * 86400 + hh * 3600 + mm * 60 + ss)
            .max(0)
            .unsigned_abs(),
    )
}

/// Runs a farmy command and streams its output into the pane; the screen stays.
fn act(app: &mut App, args: &[String], title: &str, stdin: Option<&str>) {
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "farmy".into());
    let (tx, rx) = channel::<Option<i32>>();
    let (ltx, lines_rx) = channel::<String>();
    let first = format!("$ farmy {}", shell_line(args));
    let args: Vec<String> = args.to_vec();
    let input = stdin.map(String::from);
    let folder = crate::folder::current().path.clone();
    std::thread::spawn(move || {
        let mut cmd = Command::new(&exe);
        cmd.args(&args)
            .env("FARMY_DIR", &folder)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd.stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        });
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the pane reading these may have been closed; then the lines have nowhere to go"
                )]
                let _ = ltx.send(format!("could not run farmy: {e}"));
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the pane reading these may have been closed; then the lines have nowhere to go"
                )]
                let _ = tx.send(Some(1));
                return;
            }
        };
        if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
            use std::io::Write;
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the command's exit code, shown in the pane, says whether it took its input"
            )]
            let _ = stdin.write_all(text.as_bytes());
        }
        let out = child.stdout.take();
        let err = child.stderr.take();
        let ltx2 = ltx.clone();
        let reader = std::thread::spawn(move || {
            if let Some(err) = err {
                for line in std::io::BufReader::new(err).lines().map_while(Result::ok) {
                    #[expect(
                        clippy::let_underscore_must_use,
                        reason = "the pane reading these may have been closed; then the lines have nowhere to go"
                    )]
                    let _ = ltx2.send(line);
                }
            }
        });
        if let Some(out) = out {
            for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "the pane reading these may have been closed; then the lines have nowhere to go"
                )]
                let _ = ltx.send(line);
            }
        }
        #[expect(
            clippy::let_underscore_must_use,
            reason = "join only waits for the thread to finish; it fails only after a panic, which aborts in release builds"
        )]
        let _ = reader.join();
        let code = child.wait().ok().and_then(|s| s.code());
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the pane reading these may have been closed; then the lines have nowhere to go"
        )]
        let _ = tx.send(code);
    });
    app.message = format!("{title}: running — Esc closes the pane when it is done");
    app.pane = Some(Pane {
        title: title.to_string(),
        lines: vec![first],
        scroll: 0,
        follow: true,
        done: None,
        rx,
        lines_rx,
    });
}

fn shell_line(args: &[String]) -> String {
    args.iter()
        .map(|a| shell_quote(a))
        .collect::<Vec<_>>()
        .join(" ")
}

/// A shell or the logs: the terminal is theirs until they exit, then the screen comes back.
fn take_over(
    terminal: &mut Terminal<ratatui::backend::CrosstermBackend<std::io::Stdout>>,
    app: &mut App,
    args: &[String],
    title: &str,
) {
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "farmy".into());
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a terminal mode switch around the hand-over; if it fails there is nothing better to do than go on"
    )]
    let _ = disable_raw_mode();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a terminal mode switch around the hand-over; if it fails there is nothing better to do than go on"
    )]
    let _ = std::io::stdout().execute(LeaveAlternateScreen);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the command had the terminal and showed its own outcome there"
    )]
    let _ = Command::new(&exe)
        .args(args)
        .env("FARMY_DIR", &crate::folder::current().path)
        .status();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a terminal mode switch around the hand-over; if it fails there is nothing better to do than go on"
    )]
    let _ = std::io::stdout().execute(EnterAlternateScreen);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a terminal mode switch around the hand-over; if it fails there is nothing better to do than go on"
    )]
    let _ = enable_raw_mode();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a terminal mode switch around the hand-over; if it fails there is nothing better to do than go on"
    )]
    let _ = terminal.clear();
    app.message = format!("{title}: back");
    app.refresh();
}

/// What the pane received since the last draw.
fn drain_pane(app: &mut App) {
    let Some(pane) = &mut app.pane else { return };
    while let Ok(line) = pane.lines_rx.try_recv() {
        pane.lines.push(line);
    }
    if pane.done.is_none()
        && let Ok(code) = pane.rx.try_recv()
    {
        pane.done = Some(code.unwrap_or(-1));
        pane.lines.push(match code {
            Some(0) => "[done]".to_string(),
            Some(c) => format!("[exit {c}]"),
            None => "[ended by a signal]".to_string(),
        });
        app.message = format!("{}: done — Esc closes the pane", pane.title);
    }
}

fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || "-_./:=@".contains(c))
    {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// `docker events` on containers, followed in a thread: each event marks the state dirty.
fn follow_events(dirty: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        let Ok(mut child) = Command::new("docker")
            .args([
                "events",
                "--filter",
                "type=container",
                "--format",
                "{{.Status}}",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .stdin(Stdio::null())
            .spawn()
        else {
            return;
        };
        if let Some(out) = child.stdout.take() {
            for line in std::io::BufReader::new(out).lines() {
                if line.is_err() {
                    break;
                }
                dirty.store(true, Ordering::Relaxed);
            }
        }
        #[expect(
            clippy::let_underscore_must_use,
            reason = "reaping the event follower; its exit status means nothing here"
        )]
        let _ = child.wait();
    });
}

pub(crate) fn run() -> R {
    enable_raw_mode()?;
    std::io::stdout().execute(EnterAlternateScreen)?;
    let backend = ratatui::backend::CrosstermBackend::new(std::io::stdout());
    let mut terminal = Terminal::new(backend)?;
    let mut app = App::load();
    let result = loop_ui(&mut terminal, &mut app);
    #[expect(
        clippy::let_underscore_must_use,
        reason = "restoring the terminal on the way out; the session's own result is what is returned"
    )]
    let _ = disable_raw_mode();
    #[expect(
        clippy::let_underscore_must_use,
        reason = "restoring the terminal on the way out; the session's own result is what is returned"
    )]
    let _ = std::io::stdout().execute(LeaveAlternateScreen);
    result
}

enum Prompt {
    Command(String),
    AddUrl(String),
    AddImage(String, String),
    Destroy(String, String),
}

fn loop_ui(
    terminal: &mut Terminal<ratatui::backend::CrosstermBackend<std::io::Stdout>>,
    app: &mut App,
) -> R {
    let mut prompt: Option<Prompt> = None;
    let refresh_after_done = AtomicBool::new(true);
    let dirty = Arc::new(AtomicBool::new(false));
    follow_events(dirty.clone());
    let mut last = Instant::now();
    loop {
        drain_pane(app);
        if app
            .pane
            .as_ref()
            .map(|p| p.done.is_some() && !p.lines.is_empty())
            .unwrap_or(false)
            && refresh_after_done.swap(false, Ordering::Relaxed)
        {
            app.refresh();
        }
        terminal.draw(|f| {
            let with_pane = app.pane.is_some();
            let handoffs = app.current().map(factory_lines).unwrap_or_default();
            let content_width = f.area().width.saturating_sub(2).max(1) as usize;
            let extra_height: usize = handoffs.iter().map(|line| line.width().div_ceil(content_width).max(1)).sum();
            let details_height = (u16::try_from(extra_height).unwrap_or(u16::MAX).saturating_add(8)).min(f.area().height.saturating_sub(11).max(4));
            let layout = if with_pane {
                Layout::vertical([Constraint::Length(3), Constraint::Min(5), Constraint::Percentage(45), Constraint::Length(3)]).split(f.area())
            } else {
                Layout::vertical([Constraint::Length(3), Constraint::Min(5), Constraint::Length(details_height), Constraint::Length(3)]).split(f.area())
            };
            let egress = match &app.egress {
                Value::Null => String::new(),
                e => format!("   egress: {}{}", text(&e["state"]), match text(&e["state"]).as_str() { "registered" => format!(" {} {}", text(&e["name"]), text(&e["address"])), "unregistered" => format!(" — register: {}", text(&e["registration_url"])), _ => String::new() }),
            };
            let title = Paragraph::new(Line::from(vec![Span::styled(" farmy ", Style::default().add_modifier(Modifier::BOLD)), Span::raw(format!("— {}   (as of {}){egress}", app.folder, local_time(&app.generated)))]))
                .block(Block::default().borders(Borders::ALL));
            f.render_widget(title, layout[0]);
            if app.services.is_empty() {
                let empty = Paragraph::new(commands::NO_SERVICES).block(Block::default().borders(Borders::ALL).title(" services "));
                f.render_widget(empty, layout[1]);
            } else {
                let table = service_table(&app.services);
                f.render_stateful_widget(table, layout[1], &mut app.table);
            }
            let mut lines: Vec<Line<'_>> = handoffs;
            if let Some(s) = app.current() {
                lines.push(Line::from(format!("egress: {}", egress_text(s))));
                if let Some(drift) = toolbox_drift(s) {
                    lines.push(Line::from(drift));
                }
                let containers: Vec<String> = s["containers"]
                    .as_array()
                    .map(|cs| {
                        cs.iter()
                            .map(|c| {
                                format!("{} {}{}", text(&c["name"]), text(&c["state"]), if c["health"].is_null() { String::new() } else { format!(" ({})", text(&c["health"])) })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                lines.push(Line::from(format!("containers: {}", if containers.is_empty() { "none".to_string() } else { containers.join(" · ") })));
                let ports: Vec<String> = s["ports"]
                    .as_array()
                    .map(|ps| {
                        ps.iter()
                            .map(|p| {
                                format!(
                                    "{}→{} {}{}{}",
                                    text(&p["host"]),
                                    text(&p["container"]),
                                    text(&p["url"]),
                                    if p["lan_url"].is_null() { String::new() } else { format!(" / {}", text(&p["lan_url"])) },
                                    match p["listening"] {
                                        Value::Bool(true) => " listening",
                                        Value::Bool(false) => " nothing listens",
                                        _ => "",
                                    }
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                lines.push(Line::from(format!("ports: {}", if ports.is_empty() { "none published".to_string() } else { ports.join(" · ") })));
                let cmds = s["commands"].as_array().map(|c| c.iter().map(text).collect::<Vec<_>>()).unwrap_or_default();
                lines.push(Line::from(if cmds.is_empty() { "commands: none in the definition".to_string() } else { format!("commands: {}", cmds.join(" ")) }));
                let agents: Vec<String> = s["agents"].as_object().map(|m| m.iter().map(|(k, v)| format!("{k} {} ({})", text(&v["state"]), text(&v["source"]))).collect()).unwrap_or_default();
                lines.push(Line::from(if s["agents"].is_null() { "agents: (not running)".to_string() } else if agents.is_empty() { "agents: none".to_string() } else { format!("agents: {}", agents.join(" · ")) }));
            }
            let keys = if app.keys.is_empty() { "keys: no routes resolved yet".to_string() } else { format!("keys: {}", app.keys.iter().map(|(k, v)| format!("{k} {v}")).collect::<Vec<_>>().join(" · ")) };
            lines.push(Line::from(keys));
            if let Some(pane) = &mut app.pane {
                let height = layout[2].height.saturating_sub(2) as usize;
                if pane.follow {
                    pane.scroll = pane.lines.len().saturating_sub(height);
                }
                let shown: Vec<Line<'_>> = pane.lines.iter().skip(pane.scroll).take(height).map(|l| Line::from(l.clone())).collect();
                let title = format!(" {} {} ", pane.title, if pane.done.is_some() { "(done — Esc closes)" } else { "(running)" });
                f.render_widget(Paragraph::new(shown).block(Block::default().borders(Borders::ALL).title(title)), layout[2]);
            } else {
                f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }).block(Block::default().borders(Borders::ALL).title(" selected service ")), layout[2]);
            }
            let bottom = match &prompt {
                Some(Prompt::Command(p)) => format!("command to run (a name from commands:, or words): {p}_"),
                Some(Prompt::AddUrl(p)) => format!("add — the repository's clone URL: {p}_"),
                Some(Prompt::AddImage(_, p)) => format!("add — the image (an official Debian image, e.g. ruby:3.4-slim): {p}_"),
                Some(Prompt::Destroy(name, p)) => format!("destroy {name} — its containers AND volumes (the checkout, databases)? type y: {p}_"),
                None => app.message.clone(),
            };
            f.render_widget(Paragraph::new(bottom).block(Block::default().borders(Borders::ALL)), layout[3]);
        })?;
        if dirty.swap(false, Ordering::Relaxed) || last.elapsed() > POLL {
            app.refresh();
            last = Instant::now();
        }
        if !event::poll(Duration::from_millis(if app.pane.is_some() {
            100
        } else {
            500
        }))? {
            continue;
        }
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        if let Some(pane) = &mut app.pane {
            match key.code {
                KeyCode::Esc | KeyCode::Char('q') if pane.done.is_some() => {
                    app.pane = None;
                    app.message = HELP.into();
                    refresh_after_done.store(true, Ordering::Relaxed);
                    app.refresh();
                }
                KeyCode::Up => {
                    pane.follow = false;
                    pane.scroll = pane.scroll.saturating_sub(1);
                }
                KeyCode::Down => {
                    pane.scroll += 1;
                    pane.follow = pane.scroll + 1 >= pane.lines.len();
                }
                KeyCode::PageUp => {
                    pane.follow = false;
                    pane.scroll = pane.scroll.saturating_sub(20);
                }
                KeyCode::PageDown => {
                    pane.scroll += 20;
                    pane.follow = pane.scroll + 1 >= pane.lines.len();
                }
                KeyCode::End => pane.follow = true,
                _ => {}
            }
            continue;
        }
        if let Some(p) = &mut prompt {
            let buffer: &mut String = match p {
                Prompt::Command(b)
                | Prompt::AddUrl(b)
                | Prompt::AddImage(_, b)
                | Prompt::Destroy(_, b) => b,
            };
            match key.code {
                KeyCode::Esc => prompt = None,
                KeyCode::Backspace => {
                    buffer.pop();
                }
                KeyCode::Char(c) => buffer.push(c),
                KeyCode::Enter => {
                    let taken = prompt
                        .take()
                        .expect("inside `if let Some(p) = &mut prompt`");
                    match taken {
                        Prompt::Command(line) => {
                            let words: Vec<String> =
                                line.split_whitespace().map(String::from).collect();
                            let name = app.current().map(|s| text(&s["name"]));
                            if let (Some(name), false) = (name, words.is_empty()) {
                                let mut args = vec!["run".to_string(), name.clone()];
                                args.extend(words.clone());
                                act(app, &args, &format!("{name}: {}", words.join(" ")), None);
                            }
                        }
                        Prompt::AddUrl(url) => {
                            if !url.trim().is_empty() {
                                prompt =
                                    Some(Prompt::AddImage(url.trim().to_string(), String::new()));
                            }
                        }
                        Prompt::AddImage(url, image) => {
                            if !image.trim().is_empty() {
                                act(
                                    app,
                                    &[
                                        "add".to_string(),
                                        url.clone(),
                                        "--image".to_string(),
                                        image.trim().to_string(),
                                    ],
                                    &format!("add {url}"),
                                    None,
                                );
                            }
                        }
                        Prompt::Destroy(name, answer) => {
                            if answer.trim().eq_ignore_ascii_case("y") {
                                act(
                                    app,
                                    &["destroy".to_string(), name.clone()],
                                    &format!("{name}: destroy"),
                                    Some("y\n"),
                                );
                            } else {
                                app.message = "nothing destroyed".into();
                            }
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        let name = app.current().map(|s| text(&s["name"]));
        match key.code {
            KeyCode::Char('q') => {
                // leave the terminal, keep the session: tmux detaches by command, never by a key of its own
                if std::env::var("TMUX").is_ok() {
                    #[expect(
                        clippy::let_underscore_must_use,
                        reason = "if tmux cannot detach, the session simply stays on screen"
                    )]
                    let _ = Command::new("tmux").args(["detach-client"]).status();
                    continue;
                }
                return Ok(());
            }
            KeyCode::Down | KeyCode::Char('j') => app.move_by(1),
            KeyCode::Up => app.move_by(-1),
            KeyCode::Char('R') => app.refresh(),
            KeyCode::Char('c') => prompt = Some(Prompt::Command(String::new())),
            KeyCode::Char('a') => prompt = Some(Prompt::AddUrl(String::new())),
            KeyCode::Char('k') => {
                let Some(name) = name else { continue };
                act(
                    app,
                    &["keys".to_string(), "reload".to_string(), name.clone()],
                    &format!("{name}: keys reload"),
                    None,
                );
            }
            KeyCode::Char('D') => {
                let Some(name) = name else { continue };
                prompt = Some(Prompt::Destroy(name, String::new()));
            }
            KeyCode::Char('e') | KeyCode::Char('l') => {
                let Some(name) = name else { continue };
                let cmd = if key.code == KeyCode::Char('e') {
                    "ssh"
                } else {
                    "logs"
                };
                take_over(
                    terminal,
                    app,
                    &[cmd.to_string(), name.clone()],
                    &format!("{name}: {cmd}"),
                );
            }
            KeyCode::Char(c) => {
                let Some(name) = name else { continue };
                let cmd = match c {
                    's' => "start",
                    'x' => "stop",
                    'r' => "restart",
                    _ => continue,
                };
                act(
                    app,
                    &[cmd.to_string(), name.clone()],
                    &format!("{name}: {cmd}"),
                    None,
                );
            }
            _ => {}
        }
    }
}

/// An RFC 3339 UTC time as the local clock shows it (TZ and tzdata, through date), else as it is.
fn local_time(utc: &str) -> String {
    let Some(secs) = parse_rfc3339(utc) else {
        return utc.to_string();
    };
    std::process::Command::new("date")
        .args(["-d", &format!("@{secs}"), "+%Y-%m-%d %H:%M:%S %Z"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| utc.to_string())
}

#[cfg(test)]
mod factory_tests {
    use super::*;
    use ratatui::backend::TestBackend;

    #[test]
    fn service_table_renders_audit_and_toolbox_drift_from_status_fields() {
        let services = vec![
            serde_json::json!({"name":"shop","state":"running","egress":{"restricted":true,"mode":"audit","denied":7},"toolbox_version":"0.0.9","toolbox_outdated":true}),
            serde_json::json!({"name":"notes","state":"running","egress":{"restricted":true,"mode":"strict","denied":11},"toolbox_version":crate::version::CURRENT,"toolbox_outdated":false}),
        ];
        let mut terminal = Terminal::new(TestBackend::new(300, 8)).unwrap();
        terminal
            .draw(|frame| frame.render_widget(service_table(&services), frame.area()))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let lines: Vec<String> = (0..8)
            .map(|y| (0..300).map(|x| buffer[(x, y)].symbol()).collect())
            .collect();
        assert!(lines.iter().any(|l| l.contains("shop")
            && l.contains("7 denied (audit)")
            && l.contains(&format!(
                "built by 0.0.9, now {}: farmy rebuild shop",
                crate::version::CURRENT
            ))));
        assert!(lines.iter().any(|l| l.contains("notes")
            && l.contains("11 denied (strict)")
            && !l.contains("built by")));
    }

    #[test]
    fn service_table_renders_each_services_nonzero_denial_count() {
        let services = vec![
            serde_json::json!({"name":"shop","state":"running","egress":{"restricted":true,"denied":37}}),
            serde_json::json!({"name":"notes","state":"stopped","egress":{"restricted":false,"denied":12}}),
        ];
        let mut terminal = Terminal::new(TestBackend::new(140, 8)).unwrap();
        terminal
            .draw(|frame| frame.render_widget(service_table(&services), frame.area()))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let lines: Vec<String> = (0..8)
            .map(|y| (0..140).map(|x| buffer[(x, y)].symbol()).collect())
            .collect();
        assert!(lines.iter().any(|l| l.contains("egress")));
        assert!(
            lines
                .iter()
                .any(|l| l.contains("shop") && l.contains("37 denied (restricted)"))
        );
        assert!(
            lines.iter().any(|l| l.contains("notes")
                && l.contains("12 denied")
                && !l.contains("restricted"))
        );
    }

    #[test]
    fn unknown_toolbox_provenance_renders_for_existing_images_only() {
        let services = vec![
            serde_json::json!({"name":"shop","state":"running","toolbox_version":null,"toolbox_outdated":true}),
            serde_json::json!({"name":"notes","state":"stopped","toolbox_version":null,"toolbox_outdated":true}),
            serde_json::json!({"name":"fresh","state":"stopped","toolbox_version":null,"toolbox_outdated":false}),
        ];
        let mut terminal = Terminal::new(TestBackend::new(240, 8)).unwrap();
        terminal
            .draw(|frame| frame.render_widget(service_table(&services), frame.area()))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let lines: Vec<String> = (0..8)
            .map(|y| (0..240).map(|x| buffer[(x, y)].symbol()).collect())
            .collect();
        for name in ["shop", "notes"] {
            assert!(
                lines.iter().any(
                    |l| l.contains(&format!("built by an unknown farmy: farmy rebuild {name}"))
                )
            );
        }
        assert!(
            lines
                .iter()
                .any(|l| l.contains("fresh") && !l.contains("built by"))
        );
    }

    #[test]
    fn pending_review_and_questions_render_before_newer_completed_runs() {
        let service = serde_json::json!({"runs": [
            {"id":"review","profile":"contracts","result":"awaiting_review","iteration":1,"max_iterations":3},
            {"id":"ask","profile":"implementation","from":"review","result":"question","question":"Which behavior is required?\nKeep the existing API?","iteration":1,"max_iterations":3},
            {"id":"done1","result":"green"}, {"id":"done2","result":"green"}, {"id":"done3","result":"green"}, {"id":"done4","result":"green"}
        ]});
        let backend = TestBackend::new(110, 14);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| {
                frame.render_widget(
                    Paragraph::new(factory_lines(&service)).wrap(Wrap { trim: false }),
                    frame.area(),
                )
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        let displayed = buffer
            .content
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(displayed.contains("Approval needed: farmy factory approve review"));
        assert!(displayed.contains("awaiting_review"));
        assert!(displayed.contains("Question: Which behavior is required?"));
        assert!(displayed.contains("Question: Keep the existing API?"));
        assert!(displayed.contains("[implementation] from review"));
        assert!(displayed.contains("farmy factory answer ask <text|file>"));
        assert!(displayed.find("review").unwrap() < displayed.find("done4").unwrap());
        assert_eq!(buffer[(0, 0)].fg, Color::Yellow);
        assert!(buffer[(0, 0)].modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn legacy_status_runs_render_as_default_without_a_question_or_approval() {
        let service = serde_json::json!({"runs":[{"id":"old","phase":"done","result":"green","iteration":2,"max_iterations":5}]});
        let lines = factory_lines(&service);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].to_string().contains("[default] — green 2/5"));
    }

    #[test]
    fn pipeline_step_child_and_immutable_review_link_render_in_the_terminal_buffer() {
        let service = serde_json::json!({
            "pipelines": [{"id":"p-example", "name":"build", "state":"awaiting_review",
                "step":1, "steps":2, "profile":"shape", "active_run":"draft-example"}],
            "runs": [{"id":"draft-example", "profile":"shape", "result":"awaiting_review",
                "iteration":1, "max_iterations":4, "gate_summary":"red (unverified)",
                "compare_url":"https://git.example.com/acme/shop/compare/base-sha...gated-sha"}]
        });
        let mut terminal = Terminal::new(TestBackend::new(150, 9)).unwrap();
        terminal
            .draw(|frame| {
                frame.render_widget(
                    Paragraph::new(factory_lines(&service)).wrap(Wrap { trim: false }),
                    frame.area(),
                )
            })
            .unwrap();
        let displayed = terminal
            .backend()
            .buffer()
            .content
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(displayed.contains(
            "pipeline p-example [build] — awaiting_review step 1/2 [shape] child draft-example"
        ));
        assert!(
            displayed.contains("https://git.example.com/acme/shop/compare/base-sha...gated-sha")
        );
        assert!(displayed.contains("Gate: red (unverified)"));
        assert!(displayed.contains("farmy factory approve draft-example"));
        assert_eq!(terminal.backend().buffer()[(0, 0)].fg, Color::Yellow);
    }
}
