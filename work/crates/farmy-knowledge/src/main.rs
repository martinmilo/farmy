//! farmy-knowledge — the shared knowledge container: a read-only MCP server (streamable HTTP, JSON
//! answers) for the agents inside the app containers. It knows farmy's docs (README, docs/) and the
//! containers folder's definitions (services/) and the status file farmy writes, mounted
//! read-only under KB_DIR (/kb). No Docker, no commands: it tells the agent which farmy command to run.
#![forbid(unsafe_code)]
use std::path::{Path, PathBuf};

const INSTRUCTIONS: &str = "This server knows farmy: every service (one per repository) runs in its own containers, driven by \
the farmy command in the containers folder on the host. You (the agent) run INSIDE one of those containers. \
Use \"status\" for what is running and the addresses; \"search_docs\" / \"read_doc\" for how things work; \
\"service\" for one service's definition. You cannot run farmy or docker from here: tell the developer the \
exact command to run in the farmy session (e.g. \"farmy restart shop\"). The secrets are deliberately NOT in \
your container: they live in the keys broker next to it; never suggest copying one into a container.";

fn main() {
    let kb = PathBuf::from(std::env::var("KB_DIR").unwrap_or_else(|_| "/kb".into()));
    let port = std::env::var("PORT").unwrap_or_else(|_| "9190".into());
    let server = tiny_http::Server::http(format!("0.0.0.0:{port}")).unwrap_or_else(|e| {
        eprintln!("farmy-knowledge: cannot listen on :{port}: {e}");
        std::process::exit(1)
    });
    eprintln!(
        "farmy-knowledge: serving on :{port}/mcp (docs from {})",
        kb.display()
    );
    for mut request in server.incoming_requests() {
        let url = request.url().to_string();
        let response = match (request.method().as_str(), url.as_str()) {
            ("GET", "/-/health") => tiny_http::Response::from_string("ok\n").with_status_code(200),
            ("POST", "/mcp") => {
                let mut body = String::new();
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "a body that fails to read is incomplete JSON, which rpc refuses"
                )]
                let _ = request.as_reader().read_to_string(&mut body);
                match rpc(&kb, &body) {
                    Some(json) => tiny_http::Response::from_string(json)
                        .with_status_code(200)
                        .with_header(
                            tiny_http::Header::from_bytes("Content-Type", "application/json")
                                .expect("a fixed, valid header"),
                        ),
                    None => tiny_http::Response::from_string("").with_status_code(202),
                }
            }
            ("GET", "/mcp") => {
                tiny_http::Response::from_string("farmy-knowledge: POST JSON-RPC to /mcp\n")
                    .with_status_code(405)
            }
            _ => tiny_http::Response::from_string("not found\n").with_status_code(404),
        };
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the client may have hung up; there is no one left to answer"
        )]
        let _ = request.respond(response);
    }
}

/// One JSON-RPC message in, one out (None for a notification).
fn rpc(kb: &Path, body: &str) -> Option<String> {
    let msg: serde_json::Value = serde_json::from_str(body).ok()?;
    let id = msg.get("id").cloned();
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = msg.get("params").cloned().unwrap_or(serde_json::json!({}));
    let result = match method {
        "initialize" => serde_json::json!({
            "protocolVersion": params.get("protocolVersion").and_then(|v| v.as_str()).unwrap_or("2025-03-26"),
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "farmy", "title": "farmy knowledge", "version": env!("CARGO_PKG_VERSION") },
            "instructions": INSTRUCTIONS
        }),
        "ping" => serde_json::json!({}),
        "tools/list" => serde_json::json!({ "tools": tools() }),
        "tools/call" => {
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or(serde_json::json!({}));
            let text = call(kb, name, &args);
            serde_json::json!({ "content": [{ "type": "text", "text": text }], "isError": false })
        }
        m if m.starts_with("notifications/") => return None,
        other => {
            let err = serde_json::json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": format!("method not found: {other}") } });
            return Some(err.to_string());
        }
    };
    id.map(|id| serde_json::json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string())
}

fn tools() -> serde_json::Value {
    let s = |name: &str, desc: &str, props: serde_json::Value, required: Vec<&str>| serde_json::json!({ "name": name, "description": desc, "inputSchema": { "type": "object", "properties": props, "required": required } });
    serde_json::json!([
        s(
            "status",
            "What is running right now: every farmy service, its state, its addresses on the host, its containers, and recent problems. Includes how old the snapshot is.",
            serde_json::json!({}),
            vec![]
        ),
        s(
            "service",
            "One service: its definition (services/<name>.yml, its ports: included) and current status.",
            serde_json::json!({ "name": { "type": "string" } }),
            vec!["name"]
        ),
        s(
            "list_docs",
            "List farmy's documentation and the definitions (README, docs/*.md, services/*.yml).",
            serde_json::json!({}),
            vec![]
        ),
        s(
            "read_doc",
            "Read one document by the name list_docs shows (e.g. docs/credentials.md).",
            serde_json::json!({ "name": { "type": "string" } }),
            vec!["name"]
        ),
        s(
            "search_docs",
            "Case-insensitive search across all farmy docs and definitions; returns file:line matches.",
            serde_json::json!({ "query": { "type": "string" } }),
            vec!["query"]
        ),
    ])
}

fn docs(kb: &Path) -> Vec<(String, PathBuf)> {
    let mut out = vec![];
    {
        let name = "README.md";
        let p = kb.join(name);
        if p.is_file() {
            out.push((name.to_string(), p));
        }
    }
    for dir in ["docs", "services"] {
        if let Ok(rd) = std::fs::read_dir(kb.join(dir)) {
            let mut entries: Vec<_> = rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.is_file())
                .collect();
            entries.sort();
            for p in entries {
                out.push((
                    format!(
                        "{dir}/{}",
                        p.file_name().unwrap_or_default().to_string_lossy()
                    ),
                    p,
                ));
            }
        }
    }
    out
}

fn status_text(kb: &Path) -> String {
    let Ok(text) = std::fs::read_to_string(kb.join("status/status.tsv")) else {
        return "No status yet — run `farmy status` (or `farmy start`) in the farmy session on the host, then ask again.".into();
    };
    let mut out = String::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f.first().copied() {
            Some("generated") => out.push_str(&format!(
                "farmy status as of {} (UTC). Refresh: `farmy status` on the host.\n\n",
                f.get(1).unwrap_or(&"")
            )),
            Some("service") => out.push_str(&format!(
                "- {}: {}{}{}\n",
                f.get(1).unwrap_or(&""),
                f.get(2).unwrap_or(&""),
                f.get(3)
                    .filter(|u| !u.is_empty())
                    .map(|u| format!(" — {u}"))
                    .unwrap_or_default(),
                f.get(4)
                    .filter(|c| !c.is_empty())
                    .map(|c| format!(" — containers: {c}"))
                    .unwrap_or_default()
            )),
            Some("problem") => out.push_str(&format!(
                "    problem ({}): {}\n",
                f.get(1).unwrap_or(&""),
                f.get(2).unwrap_or(&"")
            )),
            _ => {}
        }
    }
    out
}

fn call(kb: &Path, name: &str, args: &serde_json::Value) -> String {
    let arg = |k: &str| {
        args.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    match name {
        "status" => status_text(kb),
        "list_docs" => docs(kb)
            .iter()
            .map(|(n, p)| {
                format!(
                    "{n}  — {}",
                    std::fs::read_to_string(p)
                        .ok()
                        .and_then(|t| t
                            .lines()
                            .next()
                            .map(|l| l.trim_start_matches('#').trim().to_string()))
                        .unwrap_or_default()
                )
            })
            .collect::<Vec<_>>()
            .join("\n"),
        "read_doc" => {
            let n = arg("name");
            docs(kb)
                .iter()
                .find(|(d, _)| *d == n)
                .map(|(_, p)| std::fs::read_to_string(p).unwrap_or_default())
                .unwrap_or_else(|| format!("no document named {n}; list_docs shows the names"))
        }
        "search_docs" => {
            let q = arg("query").to_lowercase();
            let mut hits = vec![];
            for (n, p) in docs(kb) {
                for (i, line) in std::fs::read_to_string(&p)
                    .unwrap_or_default()
                    .lines()
                    .enumerate()
                {
                    if line.to_lowercase().contains(&q) {
                        hits.push(format!("{n}:{}: {}", i + 1, line.trim()));
                    }
                }
            }
            if hits.is_empty() {
                format!("nothing matches {q:?}")
            } else {
                hits.join("\n")
            }
        }
        "service" => {
            let n = arg("name");
            let def = std::fs::read_to_string(kb.join("services").join(format!("{n}.yml")))
                .unwrap_or_else(|_| format!("no definition services/{n}.yml"));
            let status = status_text(kb)
                .lines()
                .find(|l| l.starts_with(&format!("- {n}:")))
                .unwrap_or("not in the status snapshot")
                .to_string();
            format!("# services/{n}.yml\n{def}\n# status\n{status}")
        }
        other => format!("unknown tool {other}"),
    }
}
