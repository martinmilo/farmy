#![forbid(unsafe_code)]
use farmy_gate::{HostRule, Mode, Policy, authority, http_proxy};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream, ToSocketAddrs};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;

type State = Arc<Mutex<Memory>>;
struct Memory {
    policy: Policy,
    log: VecDeque<Value>,
    counts: BTreeMap<String, u64>,
    observed: BTreeSet<(String, String, u16)>,
}

fn socket() -> String {
    std::env::var("FARMY_GATE_SOCKET").unwrap_or_else(|_| "/run/farmy-gate/control.sock".into())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("farmy-gate: {e}");
        std::process::exit(1);
    }
}
#[expect(
    clippy::print_stdout,
    reason = "`farmy-gate log` and `status` print their answer for farmy to read"
)]
fn run() -> Result<(), String> {
    let command = std::env::args().nth(1).unwrap_or_default();
    if command == "serve" {
        return serve();
    }
    if !["load", "log", "status"].contains(&command.as_str()) {
        return Err("usage: farmy-gate serve|load|log|status".into());
    }
    let mut request = json!({"op":command});
    if command == "load" {
        let mut data = String::new();
        io::stdin()
            .take(1024 * 1024 + 1)
            .read_to_string(&mut data)
            .map_err(|e| e.to_string())?;
        if data.len() > 1024 * 1024 {
            return Err("policy too large".into());
        }
        let policy: Policy =
            serde_json::from_str(&data).map_err(|e| format!("invalid policy: {e}"))?;
        policy.validate()?;
        request["policy"] =
            serde_json::to_value(policy).expect("a Policy always serialises to JSON");
    }
    let mut stream = UnixStream::connect(socket()).map_err(|e| e.to_string())?;
    stream
        .write_all(request.to_string().as_bytes())
        .map_err(|e| e.to_string())?;
    stream
        .shutdown(Shutdown::Write)
        .map_err(|e| e.to_string())?;
    let mut data = String::new();
    stream
        .read_to_string(&mut data)
        .map_err(|e| e.to_string())?;
    let response: Value = serde_json::from_str(&data).map_err(|e| e.to_string())?;
    if let Some(e) = response["error"].as_str() {
        return Err(e.into());
    }
    match command.as_str() {
        "log" => {
            for row in response["log"].as_array().into_iter().flatten() {
                println!("{row}");
            }
        }
        "status" => println!("{}", response["status"]),
        _ => {}
    }
    Ok(())
}
fn serve() -> Result<(), String> {
    let path = socket();
    if let Some(parent) = std::path::Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a stale socket from an earlier run may be there; the bind below reports a real problem"
    )]
    let _ = std::fs::remove_file(&path);
    let control = UnixListener::bind(&path).map_err(|e| e.to_string())?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    let port = std::env::var("FARMY_GATE_PORT")
        .unwrap_or_else(|_| "9182".into())
        .parse::<u16>()
        .map_err(|_| "invalid FARMY_GATE_PORT")?;
    let listener = TcpListener::bind(("0.0.0.0", port)).map_err(|e| e.to_string())?;
    let state = Arc::new(Mutex::new(Memory {
        policy: Policy {
            version: 1,
            upstream: None,
            clients: BTreeMap::new(),
        },
        log: VecDeque::new(),
        counts: BTreeMap::new(),
        observed: BTreeSet::new(),
    }));
    let control_state = state.clone();
    std::thread::spawn(move || {
        for stream in control.incoming().flatten() {
            let state = control_state.clone();
            std::thread::spawn(move || {
                #[expect(
                    clippy::let_underscore_must_use,
                    reason = "a failed control exchange ends only that client's connection; the gate keeps serving"
                )]
                let _ = control_request(stream, state);
            });
        }
    });
    for stream in listener.incoming().flatten() {
        let state = state.clone();
        std::thread::spawn(move || {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "a failed request ends only that client's connection; the gate keeps serving"
            )]
            let _ = http_request(stream, state);
        });
    }
    Ok(())
}
fn control_request(mut stream: UnixStream, state: State) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut input = String::new();
    Read::by_ref(&mut stream)
        .take(1024 * 1024 + 1)
        .read_to_string(&mut input)?;
    let result = (|| -> Result<Value, String> {
        if input.len() > 1024 * 1024 {
            return Err("policy too large".into());
        }
        let request: Value = serde_json::from_str(&input).map_err(|e| e.to_string())?;
        match request["op"].as_str() {
            Some("load") => {
                let policy: Policy = serde_json::from_value(request["policy"].clone())
                    .map_err(|e| format!("invalid policy: {e}"))?;
                policy.validate()?;
                state.lock().expect("the gate state lock is poisoned only after a panic, which aborts in release builds").policy = policy;
                Ok(json!({"ok":true}))
            }
            Some("log") => Ok(
                json!({"log":state.lock().expect("the gate state lock is poisoned only after a panic, which aborts in release builds").log}),
            ),
            Some("status") => Ok(
                json!({"status":{"version":1,"denied":state.lock().expect("the gate state lock is poisoned only after a panic, which aborts in release builds").counts}}),
            ),
            _ => Err("unknown control operation".into()),
        }
    })();
    stream.write_all(
        result
            .unwrap_or_else(|e| json!({"error":e}))
            .to_string()
            .as_bytes(),
    )
}
fn headers(stream: &mut TcpStream) -> io::Result<String> {
    let mut data = Vec::new();
    while data.len() <= 65536 {
        let mut byte = [0];
        stream.read_exact(&mut byte)?;
        data.push(byte[0]);
        if data.ends_with(b"\r\n\r\n") {
            return String::from_utf8(data)
                .map_err(|_| io::Error::other("invalid HTTP header encoding"));
        }
    }
    Err(io::Error::other("headers too large"))
}
fn reply(stream: &mut TcpStream, code: u16, reason: &str) -> io::Result<()> {
    let title = match code {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        _ => "Bad Gateway",
    };
    let body = format!("{reason}\n");
    write!(
        stream,
        "HTTP/1.1 {code} {title}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}
struct Request {
    method: String,
    target: String,
    host: String,
    port: u16,
    path: String,
    fields: Vec<(String, String)>,
    length: u64,
    chunked: bool,
}
fn parse_request(text: &str) -> Result<Request, String> {
    let mut lines = text.split("\r\n");
    let words: Vec<_> = lines.next().unwrap_or("").split_whitespace().collect();
    if words.len() != 3 || !["HTTP/1.0", "HTTP/1.1"].contains(&words[2]) {
        return Err("invalid HTTP request".into());
    }
    let (method, target) = (words[0], words[1]);
    if !method
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&c))
    {
        return Err("invalid HTTP method".into());
    }
    let (host, port, path) = if method == "CONNECT" {
        let (host, port) = authority(target, true)?;
        (
            host,
            port.expect("authority with require_port always has a port"),
            String::new(),
        )
    } else {
        let uri = target
            .strip_prefix("http://")
            .ok_or("HTTP proxy requires an absolute http:// URI")?;
        let split = uri.find(['/', '?', '#']).unwrap_or(uri.len());
        if uri[split..].contains('#') {
            return Err("URL fragments are invalid in proxy requests".into());
        }
        let (host, port) = authority(&uri[..split], false)?;
        let path = if split == uri.len() {
            "/".into()
        } else if uri[split..].starts_with('?') {
            format!("/{}", &uri[split..])
        } else {
            uri[split..].into()
        };
        (host, port.unwrap_or(80), path)
    };
    let mut fields = vec![];
    let mut seen_host = false;
    let mut length = None;
    let mut chunked = false;
    for line in lines.filter(|l| !l.is_empty()) {
        let (name, value) = line.split_once(':').ok_or("invalid HTTP header")?;
        if name.is_empty() || !name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') {
            return Err("invalid HTTP header name".into());
        }
        let value = value.trim();
        if value.chars().any(|c| c.is_control() && c != '\t') {
            return Err("invalid HTTP header value".into());
        }
        if name.eq_ignore_ascii_case("host") {
            if seen_host {
                return Err("duplicate Host header".into());
            }
            seen_host = true;
            let (h, p) = authority(value, false)?;
            if h != host || p.unwrap_or(if method == "CONNECT" { port } else { 80 }) != port {
                return Err("Host header conflicts with request authority".into());
            }
        }
        if name.eq_ignore_ascii_case("content-length") {
            if length.is_some() || value.is_empty() || !value.bytes().all(|c| c.is_ascii_digit()) {
                return Err("invalid Content-Length".into());
            }
            length = Some(value.parse::<u64>().map_err(|_| "invalid Content-Length")?);
        }
        if name.eq_ignore_ascii_case("transfer-encoding") {
            if chunked || !value.eq_ignore_ascii_case("chunked") {
                return Err("unsupported Transfer-Encoding".into());
            }
            chunked = true;
        }
        if name.eq_ignore_ascii_case("connection")
            && value.split(',').any(|v| {
                ["host", "content-length", "transfer-encoding"]
                    .iter()
                    .any(|h| v.trim().eq_ignore_ascii_case(h))
            })
        {
            return Err("Connection cannot remove request framing or authority".into());
        }
        fields.push((name.to_string(), value.to_string()));
    }
    if chunked && length.is_some() {
        return Err("ambiguous request body".into());
    }
    Ok(Request {
        method: method.into(),
        target: target.into(),
        host,
        port,
        path,
        fields,
        length: length.unwrap_or(0),
        chunked,
    })
}
fn connect(host: &str, port: u16) -> io::Result<TcpStream> {
    let mut last = io::Error::other("host has no addresses");
    for address in (host, port).to_socket_addrs()? {
        match TcpStream::connect_timeout(&address, Duration::from_secs(10)) {
            Ok(s) => return Ok(s),
            Err(e) => last = e,
        }
    }
    Err(last)
}
fn host_port(host: &str, port: u16) -> String {
    if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}
#[expect(
    clippy::print_stdout,
    reason = "each request's record is a log line on stdout, which docker keeps as the gate's log"
)]
fn http_request(mut client: TcpStream, state: State) -> io::Result<()> {
    client.set_read_timeout(Some(Duration::from_secs(30)))?;
    let text = match headers(&mut client) {
        Ok(s) => s,
        Err(_) => return reply(&mut client, 400, "invalid HTTP headers"),
    };
    if text
        .lines()
        .next()
        .map(|l| l == "GET /-/health HTTP/1.1" || l == "GET /-/health HTTP/1.0")
        .unwrap_or(false)
    {
        return reply(&mut client, 200, "ok");
    }
    let request = match parse_request(&text) {
        Ok(r) => r,
        Err(e) => return reply(&mut client, 400, &e),
    };
    let peer = client.peer_addr()?.ip();
    let policy = state
        .lock()
        .expect(
            "the gate state lock is poisoned only after a panic, which aborts in release builds",
        )
        .policy
        .clone();
    let known = policy.clients.iter().find(|(name, c)| {
        if let Some(ips) = &c.addresses {
            ips.iter().any(|ip| ip.parse::<IpAddr>().ok() == Some(peer))
        } else {
            (name.as_str(), 0)
                .to_socket_addrs()
                .map(|mut ips| ips.any(|ip| ip.ip() == peer))
                .unwrap_or(false)
        }
    });
    let audit = known.map(|(_, c)| c.mode == Mode::Audit).unwrap_or(false);
    let allowed = audit
        || known
            .map(|(_, c)| {
                c.allow.iter().any(|a| {
                    HostRule::parse(a)
                        .map(|a| a.permits(&request.host, request.port))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);
    let (name, service) = known
        .map(|(n, c)| (n.as_str(), c.service.as_str()))
        .unwrap_or(("unknown", "unknown"));
    let mut memory = state.lock().expect(
        "the gate state lock is poisoned only after a panic, which aborts in release builds",
    );
    let observe = audit
        && memory
            .observed
            .insert((name.into(), request.host.clone(), request.port));
    if !allowed || observe {
        let timestamp = farmy_gate::utc_timestamp(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        );
        let mut record = json!({"event":if allowed {"allowed"}else{"denied"},"host":request.host,"port":request.port,"container":name,"service":service,"timestamp":timestamp});
        if audit {
            record["mode"] = json!("audit");
        }
        if !allowed {
            *memory.counts.entry(name.into()).or_default() += 1;
        }
        memory.log.push_back(record.clone());
        if memory.log.len() > 100 {
            memory.log.pop_front();
        }
        println!("{record}");
        #[expect(
            clippy::let_underscore_must_use,
            reason = "a log line; a stdout that cannot flush must not stop the gate"
        )]
        let _ = io::stdout().flush();
    }
    drop(memory);
    if !allowed {
        return reply(
            &mut client,
            403,
            &format!("egress denied: {}:{}", request.host, request.port),
        );
    }
    let destination = policy
        .upstream
        .as_deref()
        .map(http_proxy)
        .transpose()
        .map_err(io::Error::other)?;
    let (host, port) = destination
        .clone()
        .unwrap_or((request.host.clone(), request.port));
    let mut upstream = match connect(&host, port) {
        Ok(s) => s,
        Err(_) => return reply(&mut client, 502, "upstream connection failed"),
    };
    upstream.set_read_timeout(Some(Duration::from_secs(30)))?;
    if request.method == "CONNECT" {
        if destination.is_some() {
            let target = host_port(&request.host, request.port);
            write!(
                upstream,
                "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n"
            )?;
            let response = match headers(&mut upstream) {
                Ok(s) => s,
                Err(_) => return reply(&mut client, 502, "upstream CONNECT failed"),
            };
            if response
                .lines()
                .next()
                .and_then(|l| l.split_whitespace().nth(1))
                != Some("200")
            {
                return reply(&mut client, 502, "upstream CONNECT refused");
            }
        }
        client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")?;
        client.set_read_timeout(None)?;
        upstream.set_read_timeout(None)?;
        let mut to_up = client.try_clone()?;
        let mut up_copy = upstream.try_clone()?;
        let thread = std::thread::spawn(move || {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the tunnel ends when either side closes; how it ended changes nothing"
            )]
            let _ = io::copy(&mut to_up, &mut up_copy);
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the peer may already be gone; shutting down a closed socket fails harmlessly"
            )]
            let _ = up_copy.shutdown(Shutdown::Write);
        });
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the tunnel ends when either side closes; how it ended changes nothing"
        )]
        let _ = io::copy(&mut upstream, &mut client);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "the peer may already be gone; shutting down a closed socket fails harmlessly"
        )]
        let _ = client.shutdown(Shutdown::Write);
        #[expect(
            clippy::let_underscore_must_use,
            reason = "join only waits for the thread to finish; it fails only after a panic, which aborts in release builds"
        )]
        let _ = thread.join();
        return Ok(());
    }
    let target = if destination.is_some() {
        request.target.as_str()
    } else {
        request.path.as_str()
    };
    let send = (|| -> io::Result<()> {
        write!(
            upstream,
            "{} {target} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n",
            request.method,
            host_port(&request.host, request.port)
        )?;
        let connection_headers: Vec<String> = request
            .fields
            .iter()
            .filter(|(k, _)| k.eq_ignore_ascii_case("connection"))
            .flat_map(|(_, v)| v.split(',').map(|s| s.trim().to_ascii_lowercase()))
            .collect();
        for (name, value) in &request.fields {
            if [
                "host",
                "connection",
                "proxy-connection",
                "proxy-authorization",
                "keep-alive",
                "upgrade",
                "expect",
            ]
            .iter()
            .any(|k| name.eq_ignore_ascii_case(k))
                || connection_headers
                    .iter()
                    .any(|n| name.eq_ignore_ascii_case(n))
            {
                continue;
            }
            write!(upstream, "{name}: {value}\r\n")?;
        }
        upstream.write_all(b"\r\n")?;
        if request.fields.iter().any(|(k, v)| {
            k.eq_ignore_ascii_case("expect") && v.eq_ignore_ascii_case("100-continue")
        }) {
            client.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
        }
        if request.chunked {
            copy_chunks(&mut client, &mut upstream)?;
        } else {
            let n = io::copy(
                &mut Read::by_ref(&mut client).take(request.length),
                &mut upstream,
            )?;
            if n != request.length {
                return Err(io::Error::other("incomplete body"));
            }
        }
        Ok(())
    })();
    if send.is_err() {
        return reply(&mut client, 502, "request forwarding failed");
    }
    let response = match headers(&mut upstream) {
        Ok(s) => s,
        Err(_) => return reply(&mut client, 502, "upstream response failed"),
    };
    let words: Vec<_> = response
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .collect();
    if words.len() < 2
        || !["HTTP/1.0", "HTTP/1.1"].contains(&words[0])
        || words[1].len() != 3
        || !words[1].bytes().all(|b| b.is_ascii_digit())
    {
        return reply(&mut client, 502, "invalid upstream response");
    }
    client.write_all(response.as_bytes())?;
    #[expect(
        clippy::let_underscore_must_use,
        reason = "the tunnel ends when either side closes; how it ended changes nothing"
    )]
    let _ = io::copy(&mut upstream, &mut client);
    Ok(())
}
fn copy_chunks(client: &mut TcpStream, upstream: &mut TcpStream) -> io::Result<()> {
    loop {
        let mut line = Vec::new();
        while !line.ends_with(b"\r\n") {
            let mut b = [0];
            client.read_exact(&mut b)?;
            line.push(b[0]);
            if line.len() > 4096 {
                return Err(io::Error::other("chunk header too large"));
            }
        }
        let text = std::str::from_utf8(&line).map_err(io::Error::other)?;
        let size = u64::from_str_radix(text.trim().split(';').next().unwrap_or(""), 16)
            .map_err(io::Error::other)?;
        upstream.write_all(&line)?;
        if size == 0 {
            // discard trailers: only the body is forwarded
            loop {
                let mut line = Vec::new();
                while !line.ends_with(b"\r\n") {
                    let mut b = [0];
                    client.read_exact(&mut b)?;
                    line.push(b[0]);
                    if line.len() > 8192 {
                        return Err(io::Error::other("trailer too large"));
                    }
                }
                if line == b"\r\n" {
                    break;
                }
            }
            upstream.write_all(b"\r\n")?;
            return Ok(());
        }
        if io::copy(&mut Read::by_ref(client).take(size), upstream)? != size {
            return Err(io::Error::other("incomplete chunk"));
        }
        let mut end = [0; 2];
        client.read_exact(&mut end)?;
        if &end != b"\r\n" {
            return Err(io::Error::other("invalid chunk"));
        }
        upstream.write_all(&end)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use farmy_gate::Client;

    fn memory(allow: Vec<String>) -> State {
        let clients = BTreeMap::from([(
            "shop".into(),
            Client {
                mode: Mode::Strict,
                service: "shop".into(),
                addresses: Some(vec!["127.0.0.1".into()]),
                allow,
            },
        )]);
        Arc::new(Mutex::new(Memory {
            policy: Policy {
                version: 1,
                upstream: None,
                clients,
            },
            log: VecDeque::new(),
            counts: BTreeMap::new(),
            observed: BTreeSet::new(),
        }))
    }
    fn through_gate(state: State) -> (TcpStream, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let worker = std::thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            http_request(socket, state).unwrap();
        });
        (client, worker)
    }
    fn control(state: State, request: Value) -> Value {
        let (mut client, server) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || control_request(server, state).unwrap());
        client.write_all(request.to_string().as_bytes()).unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let mut result = String::new();
        client.read_to_string(&mut result).unwrap();
        worker.join().unwrap();
        serde_json::from_str(&result).unwrap()
    }

    #[test]
    fn ambiguous_framing_and_conflicting_authorities_fail_before_forwarding() {
        for fields in [
            "Host: attacker.example\r\n",
            "Host: allowed.example\r\nHost: allowed.example\r\n",
            "Content-Length: 3\r\nContent-Length: 3\r\n",
            "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n",
            "Transfer-Encoding: gzip, chunked\r\n",
            "Content-Length: 3\r\nConnection: Content-Length\r\n",
            "Connection: Host\r\n",
        ] {
            assert!(
                parse_request(&format!(
                    "POST http://allowed.example/ HTTP/1.1\r\n{fields}\r\n"
                ))
                .is_err(),
                "{fields}"
            );
        }
    }

    #[test]
    fn unknown_peer_cannot_select_a_policy_with_headers_and_logs_are_redacted() {
        let state = memory(vec!["example.com".into()]);
        state
            .lock()
            .unwrap()
            .policy
            .clients
            .get_mut("shop")
            .unwrap()
            .addresses = Some(vec!["127.0.0.2".into()]);
        let (mut client, worker) = through_gate(state.clone());
        client.write_all(b"GET http://example.com/private?token=secret HTTP/1.1\r\nHost: example.com\r\nX-Farmy-Container: shop\r\nX-Forwarded-For: 127.0.0.2\r\nAuthorization: Bearer secret\r\n\r\n").unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        worker.join().unwrap();
        assert!(response.starts_with("HTTP/1.1 403"));
        let memory = state.lock().unwrap();
        let row = &memory.log[0];
        assert_eq!(row["container"], "unknown");
        assert_eq!(row["service"], "unknown");
        assert_eq!(row["host"], "example.com");
        assert!(!row.to_string().contains("secret"));
        assert!(!row.to_string().contains("private"));
        assert_eq!(memory.counts["unknown"], 1);
    }

    #[test]
    fn chunked_post_preserves_body_without_forwarding_a_pipelined_second_request() {
        let origin = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = origin.local_addr().unwrap();
        let receiver = std::thread::spawn(move || {
            let (mut stream, _) = origin.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let request = headers(&mut stream).unwrap();
            let mut body = [0; 15];
            stream.read_exact(&mut body).unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .unwrap();
            stream.shutdown(Shutdown::Write).unwrap();
            let mut rest = Vec::new();
            stream.read_to_end(&mut rest).unwrap();
            (request, body, rest)
        });
        let state = memory(vec![address.to_string()]);
        let (mut client, worker) = through_gate(state);
        let request = format!(
            "POST http://{address}/submit HTTP/1.1\r\nHost: {address}\r\nTransfer-Encoding: chunked\r\nProxy-Authorization: secret\r\n\r\n5\r\nhello\r\n0\r\nX-Trailer: discarded\r\n\r\nGET http://attacker.example/ HTTP/1.1\r\n\r\n"
        );
        client.write_all(request.as_bytes()).unwrap();
        let mut response = String::new();
        let result = client.read_to_string(&mut response);
        assert!(result.is_ok() || result.unwrap_err().kind() == io::ErrorKind::ConnectionReset);
        worker.join().unwrap();
        let (request, body, rest) = receiver.join().unwrap();
        assert!(request.starts_with("POST /submit HTTP/1.1\r\n"));
        assert!(!request.contains("secret"));
        assert_eq!(&body, b"5\r\nhello\r\n0\r\n\r\n");
        assert!(rest.is_empty());
        assert!(response.ends_with("ok"));
    }

    #[test]
    fn connect_preserves_bytes_sent_immediately_after_headers() {
        let origin = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = origin.local_addr().unwrap();
        let receiver = std::thread::spawn(move || {
            let (mut stream, _) = origin.accept().unwrap();
            let mut bytes = [0; 5];
            stream.read_exact(&mut bytes).unwrap();
            assert_eq!(&bytes, b"\0\xffabc");
            stream.write_all(&bytes).unwrap();
        });
        let (mut client, worker) = through_gate(memory(vec![address.to_string()]));
        let mut request =
            format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\n").into_bytes();
        request.extend(b"\0\xffabc");
        client.write_all(&request).unwrap();
        assert!(headers(&mut client).unwrap().starts_with("HTTP/1.1 200"));
        let mut reply = [0; 5];
        client.read_exact(&mut reply).unwrap();
        assert_eq!(&reply, b"\0\xffabc");
        client.shutdown(Shutdown::Write).unwrap();
        worker.join().unwrap();
        receiver.join().unwrap();
    }

    #[test]
    fn an_upstream_that_closes_without_an_http_response_returns_502() {
        let origin = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = origin.local_addr().unwrap();
        let receiver = std::thread::spawn(move || {
            let (mut stream, _) = origin.accept().unwrap();
            headers(&mut stream).unwrap();
        });
        let (mut client, worker) = through_gate(memory(vec![address.to_string()]));
        write!(client, "GET http://{address}/ HTTP/1.1\r\n\r\n").unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 502"));
        worker.join().unwrap();
        receiver.join().unwrap();
    }

    #[test]
    fn invalid_reload_preserves_policy_and_valid_reload_preserves_observations() {
        let state = memory(vec!["example.com:443".into()]);
        {
            let mut memory = state.lock().unwrap();
            memory.counts.insert("shop".into(), 9);
            memory
                .log
                .push_back(json!({"event":"denied","host":"blocked.example"}));
        }
        let invalid = json!({"op":"load","policy":{"version":1,"clients":{"shop":{"service":"shop","addresses":["127.0.0.1/8"],"allow":["other.example"]}}}});
        assert!(control(state.clone(), invalid)["error"].is_string());
        assert_eq!(
            state.lock().unwrap().policy.clients["shop"].allow,
            ["example.com:443"]
        );
        let valid = json!({"op":"load","policy":{"version":1,"clients":{}}});
        assert_eq!(control(state.clone(), valid)["ok"], true);
        let status = control(state.clone(), json!({"op":"status"}));
        assert_eq!(status["status"]["denied"]["shop"], 9);
        assert_eq!(
            control(state, json!({"op":"log"}))["log"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn audit_observations_survive_reload_and_unknown_peers_stay_denied() {
        let upstream = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = upstream.local_addr().unwrap();
        let receiver = std::thread::spawn(move || {
            for _ in 0..4 {
                let (mut stream, _) = upstream.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                headers(&mut stream).unwrap();
                stream
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                    )
                    .unwrap();
            }
        });
        let state = memory(vec![]);
        let policy = json!({"version":1,"upstream":format!("http://{address}"),"clients":{"shop":{"service":"shop","addresses":["127.0.0.1"],"allow":[],"mode":"audit"}}});
        assert_eq!(
            control(state.clone(), json!({"op":"load","policy":policy}))["ok"],
            true
        );
        for authority in [
            "EXAMPLE.COM.:80",
            "example.com:80",
            "example.com:443",
            "example.com:443",
        ] {
            assert_eq!(
                control(state.clone(), json!({"op":"load","policy":policy}))["ok"],
                true
            );
            let (mut client, worker) = through_gate(state.clone());
            write!(client, "GET http://{authority}/secret?token=hidden HTTP/1.1\r\nAuthorization: hidden\r\n\r\n").unwrap();
            let mut response = String::new();
            client.read_to_string(&mut response).unwrap();
            worker.join().unwrap();
            assert!(response.starts_with("HTTP/1.1 200"));
        }
        receiver.join().unwrap();
        {
            let mut memory = state.lock().unwrap();
            assert_eq!(memory.log.len(), 2);
            assert!(memory.counts.is_empty());
            assert!(memory.log.iter().all(|event| event["event"] == "allowed"
                && event["mode"] == "audit"
                && event["host"] == "example.com"));
            assert!(
                memory
                    .log
                    .iter()
                    .all(|event| !event.to_string().contains("hidden")
                        && !event.to_string().contains("secret"))
            );
            memory.policy.clients.get_mut("shop").unwrap().addresses =
                Some(vec!["127.0.0.2".into()]);
        }
        let (mut client, worker) = through_gate(state.clone());
        client
            .write_all(b"GET http://example.com/ HTTP/1.1\r\nX-Farmy-Container: shop\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        worker.join().unwrap();
        assert!(response.starts_with("HTTP/1.1 403"));
        assert_eq!(state.lock().unwrap().counts["unknown"], 1);
    }
}
