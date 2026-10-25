// ── on-demand verify (FORMATS.md, "On-demand verify") ─────────────────────────────────────────────
//
// With a profile's `verify`, the agent's container has `farmy-verify` on its PATH: farmy-verify.sh, written
// into the run's folder and bind-mounted read-only, with two folders beside it, also bind-mounted:
// `.work/<name>/runs/<id>/verify/requests/` (writable there: farmy-verify leaves its call) and
// `…/verify/responses/` (read-only there: the answer). Only the containers folder is bind-mounted, as
// everywhere (FORMATS.md, "Volumes"); the agent gets no farmy binary, no Docker socket, no broker and no
// network for it. While the agent runs, a thread of the run's controller takes the calls and answers them
// one at a time: a snapshot commit made in a git container, then a verify container made as the gate's
// test container, whose output is written into the call's answer as it comes.
//
// Three limits (FORMATS.md, "On-demand verify", "Limits") keep what the agent can make farmy hold small:
// a waiting call is only a directory entry, moved unread into farmy's own queue folder (`take`), and one
// more than VERIFY_QUEUE_LIMIT is refused at once; the verify container's output is held before its
// command starts up to VERIFY_PREPARE_OUTPUT_CAP, then streamed through, never held, up to
// VERIFY_OUTPUT_CAP (`Stream`). Each ends the call as one that could not run, exit 125.

/// The most a verify's command may print, its stdout and stderr together. The first byte beyond it stops
/// the verify; nothing beyond is passed on or kept.
const VERIFY_OUTPUT_CAP: u64 = 4 * 1024 * 1024;
/// The most calls of a run that wait for their turn, the running one not counted. A call that would be
/// one more is refused at once.
const VERIFY_QUEUE_LIMIT: usize = 4;
/// The most the verify container may print before its command starts (its preparation), its stdout and
/// stderr together. The first byte beyond it ends the verify before the command runs.
const VERIFY_PREPARE_OUTPUT_CAP: usize = 64 * 1024;

fn output_exceeded() -> String {
    format!(
        "the output exceeded {} MiB, so the verify was stopped",
        VERIFY_OUTPUT_CAP >> 20
    )
}
fn queue_full() -> String {
    format!("the verify queue is full ({VERIFY_QUEUE_LIMIT} calls are waiting)")
}
fn prepare_exceeded() -> String {
    format!(
        "the verify container printed more than {} KiB before the command started",
        VERIFY_PREPARE_OUTPUT_CAP >> 10
    )
}

const VERIFY_PROGRAM: &str = include_str!("farmy-verify.sh");
const VERIFY_PROGRAM_AT: &str = "/usr/local/bin/farmy-verify";
const VERIFY_REQUESTS_AT: &str = "/run/farmy-verify/requests";
const VERIFY_RESPONSES_AT: &str = "/run/farmy-verify/responses";
/// The reason of a verify stopped by the end of the agent's container, and of a call it left waiting.
const VERIFY_ENDED: &str = "stopped: the agent's container ended";
/// The reason of a verify whose farmy-verify was interrupted: no one waits for its answer any more.
const VERIFY_INTERRUPTED: &str = "stopped: farmy-verify was interrupted";
/// How long the verify of an interrupted farmy-verify goes on: an ending container interrupts its calls
/// too, and when it ends within this time, its end is what they are recorded as.
const VERIFY_INTERRUPT_GRACE: std::time::Duration = std::time::Duration::from_secs(5);
/// The largest call farmy reads: its words, each ended by a NUL byte.
const VERIFY_CALL_LIMIT: u64 = 1 << 20;
const VERIFY_POLL: std::time::Duration = std::time::Duration::from_millis(50);

/// `state.json`'s `verifies`: how many verifies an iteration's agent asked for.
#[derive(Serialize, Deserialize, Clone, Default, PartialEq, Eq, Debug)]
pub(crate) struct VerifyCount {
    pub iteration: u32,
    pub count: u32,
}

/// Best effort: what a verify leaves behind is harmless, and the next iteration clears the folders anyway.
fn best_effort<T>(_: std::io::Result<T>) {}

/// Removes a folder's entry itself, a folder with what it holds, never what a link of the agent's points at.
fn remove_entry(path: &Path) {
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir()) {
        best_effort(std::fs::remove_dir_all(path));
    } else {
        best_effort(std::fs::remove_file(path));
    }
}

/// A run's verify folders, relative to the containers folder.
struct Channel {
    root: PathBuf,
}

impl Channel {
    fn of(service: &str, id: &str) -> Self {
        Self {
            root: run_dir(service, id).join("verify"),
        }
    }
    fn requests(&self) -> PathBuf {
        self.root.join("requests")
    }
    fn responses(&self) -> PathBuf {
        self.root.join("responses")
    }
    /// The calls taken and waiting for their turn: farmy's own, never mounted. Each is the agent's call
    /// file itself, moved here unread as `<n>-<id>.call` (`n` the order taken); the one whose turn it is
    /// becomes `<n>-<id>.turn`, so that it no longer counts as waiting.
    fn queue(&self) -> PathBuf {
        self.root.join("queue")
    }
    fn program(&self) -> PathBuf {
        self.root.join("farmy-verify")
    }
    /// The verify command's line, for the record of a call that never ran when the controller is gone.
    fn command(&self) -> PathBuf {
        self.root.join("command")
    }
    /// The record of the verify running now, and what its command printed so far.
    fn running(&self) -> PathBuf {
        self.root.join("running.json")
    }
    fn running_output(&self) -> PathBuf {
        self.root.join("running.out")
    }

    /// Ready and empty for an iteration's agent: the program, the requests folder writable by the agent's
    /// user (uid 1001, whoever owns the containers folder), the responses folder written by farmy alone.
    fn prepare(&self, command: &str) -> std::io::Result<()> {
        use std::os::unix::fs::PermissionsExt;
        self.clear();
        for (dir, mode) in [
            (self.requests(), 0o777),
            (self.responses(), 0o755),
            (self.queue(), 0o700),
        ] {
            std::fs::create_dir_all(&dir)?;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode))?;
        }
        if std::fs::read_to_string(self.program()).ok().as_deref() != Some(VERIFY_PROGRAM) {
            let new = self.root.join(".farmy-verify.new");
            std::fs::write(&new, VERIFY_PROGRAM)?;
            std::fs::set_permissions(&new, std::fs::Permissions::from_mode(0o755))?;
            std::fs::rename(&new, self.program())?;
        }
        std::fs::write(self.command(), command)?;
        Ok(())
    }

    /// How many calls wait for their turn: the queue's `.call` entries, counted by name, none of them read.
    fn waiting(&self) -> usize {
        std::fs::read_dir(self.queue())
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".call"))
            .count()
    }

    /// Takes the calls farmy-verify left, oldest first, without reading them: each is renamed out of the
    /// agent's folder into the queue, so that farmy-verify knows it was taken even while another verify
    /// runs, and the agent can no longer change it. A call that would be one more than
    /// VERIFY_QUEUE_LIMIT waiting is refused at once. However many files the agent leaves, one pass holds
    /// no more than the names of the calls there is room for, and one more.
    fn take(&self, taken: &std::cell::Cell<u64>) {
        let Ok(entries) = std::fs::read_dir(self.requests()) else {
            return;
        };
        let room = VERIFY_QUEUE_LIMIT.saturating_sub(self.waiting());
        let mut found: Vec<(Option<std::time::SystemTime>, String)> = Vec::with_capacity(room + 1);
        for entry in entries.flatten() {
            let file = entry.file_name().to_string_lossy().to_string();
            let Some(id) = file.strip_suffix(".call") else {
                continue;
            };
            // DirEntry's metadata does not follow a link
            let meta = entry.metadata();
            if !call_id_ok(id) || !meta.as_ref().is_ok_and(std::fs::Metadata::is_file) {
                remove_entry(&entry.path());
                continue;
            }
            found.push((meta.and_then(|m| m.modified()).ok(), id.to_string()));
            if found.len() > room {
                // keep the oldest: the newest of them is the one too many
                found.sort();
                if let Some((_, newest)) = found.pop() {
                    self.refuse(&newest, &queue_full());
                }
            }
        }
        found.sort();
        for (_, id) in found {
            let n = taken.get() + 1;
            taken.set(n);
            let call = self.requests().join(format!("{id}.call"));
            match std::fs::rename(&call, self.queue().join(format!("{n:08}-{id}.call"))) {
                Ok(()) => {}
                // farmy-verify gave up on it
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => self.refuse(&id, &format!("the call could not be taken: {e}")),
            }
        }
    }

    /// A call that never waits: gone from the agent's folder and answered at once. It is not a verify:
    /// no number, no record, not in the count.
    fn refuse(&self, id: &str, why: &str) {
        best_effort(std::fs::remove_file(
            self.requests().join(format!("{id}.call")),
        ));
        let answer = Answer::open(self, id);
        answer.say(&format!("farmy-verify: could not run: {why}\n"));
        answer.finish(125);
    }

    /// The call whose turn it is: the oldest waiting, renamed `.turn`, and only now read.
    fn next(&self) -> Option<Call> {
        let oldest = std::fs::read_dir(self.queue())
            .ok()?
            .flatten()
            .filter_map(|e| {
                e.file_name()
                    .to_string_lossy()
                    .strip_suffix(".call")
                    .map(String::from)
            })
            .min()?;
        let queued = self.queue().join(format!("{oldest}.turn"));
        if std::fs::rename(self.queue().join(format!("{oldest}.call")), &queued).is_err() {
            remove_entry(&self.queue().join(format!("{oldest}.call")));
            return None;
        }
        let id = oldest.split_once('-').map_or(oldest.as_str(), |(_, id)| id);
        Some(Call {
            id: id.to_string(),
            args: read_call(&queued),
            queued,
            interrupted_since: Default::default(),
        })
    }

    /// The queue's calls, the one whose turn it was first, then the waiting ones in the order taken.
    fn queued(&self) -> Vec<PathBuf> {
        let mut queued: Vec<PathBuf> = std::fs::read_dir(self.queue())
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "call" || x == "turn"))
            .collect();
        queued.sort();
        queued
    }

    /// Removes the answers farmy-verify has read to the end (it leaves `<id>.done`).
    fn forget_answered(&self) {
        let Ok(entries) = std::fs::read_dir(self.requests()) else {
            return;
        };
        for entry in entries.flatten() {
            let file = entry.file_name().to_string_lossy().to_string();
            let Some(id) = file.strip_suffix(".done") else {
                continue;
            };
            if call_id_ok(id) {
                for suffix in ["out", "err", "exit"] {
                    best_effort(std::fs::remove_file(
                        self.responses().join(format!("{id}.{suffix}")),
                    ));
                }
                best_effort(std::fs::remove_file(
                    self.requests().join(format!("{id}.cancel")),
                ));
            }
            remove_entry(&entry.path());
        }
    }

    /// Every call, answer and running record gone; the folders, the program and the command stay.
    fn clear(&self) {
        for dir in [self.requests(), self.responses(), self.queue()] {
            for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                remove_entry(&entry.path());
            }
        }
        best_effort(std::fs::remove_file(self.running()));
        best_effort(std::fs::remove_file(self.running_output()));
    }

    /// The `-v` and `-e` words that give the agent's container farmy-verify and the run's folders.
    fn agent_args(&self) -> (Vec<String>, Vec<(String, String)>) {
        // the daemon resolves a bind's source on the host, where the containers folder has the same path
        let root = std::env::current_dir().unwrap_or_default().join(&self.root);
        let mounts = vec![
            "-v".into(),
            format!(
                "{}:{VERIFY_PROGRAM_AT}:ro",
                root.join("farmy-verify").display()
            ),
            "-v".into(),
            format!("{}:{VERIFY_REQUESTS_AT}", root.join("requests").display()),
            "-v".into(),
            format!("{}:{VERIFY_RESPONSES_AT}:ro", root.join("responses").display()),
        ];
        let env = vec![
            (
                "FARMY_VERIFY_REQUESTS".to_string(),
                VERIFY_REQUESTS_AT.to_string(),
            ),
            (
                "FARMY_VERIFY_RESPONSES".to_string(),
                VERIFY_RESPONSES_AT.to_string(),
            ),
        ];
        (mounts, env)
    }
}

/// A call's id as farmy-verify makes it (`<time>-<pid>`), safe as part of a file name.
fn call_id_ok(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 80
        && !id.starts_with('.')
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// A call's words: the file as farmy-verify wrote it, each word ended by a NUL byte. Opened without
/// following a link and without blocking on a pipe, and only a regular file of a sane size: the folder is
/// the agent's to write.
fn read_call(path: &Path) -> Result<Vec<String>, String> {
    use rustix::fs::{Mode, OFlags};
    use std::io::Read;
    let fd = rustix::fs::open(
        path,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|e| format!("the call could not be read: {e}"))?;
    let file = std::fs::File::from(fd);
    let meta = file
        .metadata()
        .map_err(|e| format!("the call could not be read: {e}"))?;
    if !meta.is_file() || meta.len() > VERIFY_CALL_LIMIT {
        return Err("the call is not a file farmy-verify wrote".into());
    }
    let mut bytes = vec![];
    file.take(VERIFY_CALL_LIMIT)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("the call could not be read: {e}"))?;
    let mut words: Vec<String> = String::from_utf8_lossy(&bytes)
        .split('\0')
        .map(String::from)
        .collect();
    // every word ends with a NUL: what follows the last one is empty
    words.pop();
    Ok(words)
}

/// A word for `sh`: as it is when the shell would read it so, else in single quotes.
fn shell_word(word: &str) -> String {
    if !word.is_empty()
        && word
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"@%+=:,./_-".contains(&b))
    {
        word.to_string()
    } else {
        sh_quote(word)
    }
}

/// The verify command's line with the agent's words appended, each one word for the shell.
fn verify_line(command: &str, args: &[String]) -> String {
    let mut line = command.to_string();
    for a in args {
        line.push(' ');
        line.push_str(&shell_word(a));
    }
    line
}

/// What farmy-verify adds on stderr after the command's own output for the exits that do not say
/// whether the suite failed.
fn verify_exit_meaning(code: i32) -> Option<&'static str> {
    match code {
        124 => Some("it timed out"),
        125 => Some("it could not be run"),
        126 => Some("a program it runs could not be executed"),
        127 => Some("a program it runs was not found"),
        _ => None,
    }
}

/// The prompt's part on farmy-verify, supplied whatever the template says.
fn verify_instructions(command: &str) -> String {
    format!(
        "\nYou may run `farmy-verify [args…]` as often as you like. It runs `{command}` (each of your args appended as a word of its own) on a snapshot of your tree as the iteration commit would make it: hidden folders included, though you cannot read them, and protected paths as the run started them. It prints the command's output as it comes and exits with the command's exit code. Its result decides nothing: only the gate does, the separate run of the tests after you finish.\n"
    )
}

/// The git container's script that makes a verify's snapshot, as `commit_script` makes the iteration's
/// commit, in an index of its own: the run branch, its index and the agent's files stay as they are.
/// Prints `snapshot <commit>`.
fn snapshot_script(writes: Option<&[String]>, protects: &[String]) -> String {
    let mut script = String::from(
        "set -e\ncd /workspace\nindex=\"$(git rev-parse --absolute-git-dir)/farmy-verify.index\"\nrm -f \"$index\"\ntrap 'rm -f \"$index\"' EXIT\nexport GIT_INDEX_FILE=\"$index\"\ngit read-tree HEAD\n",
    );
    match writes {
        Some(w) => {
            for path in w {
                let q = sh_quote(&clean_path(path));
                script.push_str(&format!(
                    "if [ -e {q} ] || [ -n \"$(git ls-files -- {q})\" ]; then git add -A -- {q}; fi\n"
                ));
            }
        }
        None => script.push_str("git add -A -- .\n"),
    }
    for path in protects {
        let q = sh_quote(&clean_path(path));
        script.push_str(&format!(
            "git rm -r -q -f --cached --ignore-unmatch -- {q}\ngit ls-tree -r \"$FARMY_BASE_SHA\" -- {q} | git update-index --index-info\n"
        ));
    }
    script.push_str("git rm -q -f --cached --ignore-unmatch -- .farmy/question.md .farmy/answer.md\ntree=$(git write-tree)\ncommit=$(git commit-tree \"$tree\" -p HEAD -m \"farmy: verify $FARMY_ITERATION.$FARMY_VERIFY\")\necho \"snapshot $commit\"\n");
    script
}

/// The commit `snapshot_script` printed, from the git container's exit code and output. It is taken
/// only as a full commit id; anything else is a snapshot that failed, and its reason never repeats
/// what was printed, which is not to be trusted.
fn snapshot_commit(code: i32, out: &str, err: &str) -> Result<String, String> {
    match marker(out, "snapshot") {
        Some(c) if code == 0 && commit_id_ok(&c) => Ok(c),
        Some(c) if !commit_id_ok(&c) => Err("git printed no commit id".into()),
        _ => Err(commands::git_cause(&format!("{out}\n{err}"))),
    }
}

/// A full commit id: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits and nothing else.
fn commit_id_ok(id: &str) -> bool {
    matches!(id.len(), 40 | 64) && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The verify container's script: the snapshot exported into the scratch area, then the profile's
/// gate_setup and the command. A line `<marker> run` on stdout says the command starts now; before it,
/// `<marker> prepare|setup <exit>` and the last lines of the error say why it never did.
fn verify_script(workdir: Option<String>) -> String {
    let into = match workdir {
        Some(w) => format!("/scratch/tree/{}", w.trim_start_matches('/')),
        None => "/scratch/tree".to_string(),
    };
    format!(
        "m=$FARMY_VERIFY_MARKER\nfail() {{ printf '%s %s %s\\n' \"$m\" \"$1\" \"$2\"; if [ -s /scratch/.farmy-error ]; then tail -n 5 /scratch/.farmy-error; fi; exit 125; }}\nmkdir -p /scratch/tree /scratch/home /scratch/tmp || fail prepare $?\ngit -C /workspace archive \"$FARMY_VERIFY_COMMIT\" 2>/scratch/.farmy-error | tar -x -C /scratch/tree 2>>/scratch/.farmy-error || fail prepare $?\ncd {} 2>/scratch/.farmy-error || fail prepare $?\nexport HOME=/scratch/home TMPDIR=/scratch/tmp\nif [ -n \"${{FARMY_VERIFY_SETUP:-}}\" ]; then sh -c \"$FARMY_VERIFY_SETUP\" </dev/null >/scratch/.farmy-setup 2>&1 || fail setup $?; fi\nprintf '%s run\\n' \"$m\"\nexec sh -c \"$FARMY_VERIFY_COMMAND\"\n",
        sh_quote(&into)
    )
}

/// A verify's record, `iteration-<i>.verify-<k>.log`; kept as `running.json` while it runs, so that a
/// controller that is killed (cancel) leaves enough to write it.
#[derive(Serialize, Deserialize, Default, Clone)]
struct VerifyRecord {
    iteration: u32,
    k: u32,
    args: Vec<String>,
    command: String,
    commit: Option<String>,
    started: String,
    ended: Option<String>,
    exit: Option<i32>,
    reason: Option<String>,
}

impl VerifyRecord {
    fn save_running(&self, channel: &Channel) {
        let new = channel.root.join(".running.json.new");
        if std::fs::write(&new, serde_json::to_string(self).unwrap_or_default()).is_ok() {
            best_effort(std::fs::rename(&new, channel.running()));
        }
    }

    /// The record's header lines and the blank line after them. No value spans a line: `args` is a JSON
    /// array and `command` and `reason` JSON strings, every control character in them escaped.
    fn header(&self) -> String {
        let mut text = format!(
            "args: {}\ncommand: {}\ncommit: {}\nstarted: {}\nended: {}\nexit: {}\n",
            json_line(&self.args),
            json_line(&self.command),
            self.commit.as_deref().unwrap_or("-"),
            self.started,
            self.ended.clone().unwrap_or_else(now),
            self.exit.unwrap_or(137),
        );
        if let Some(reason) = &self.reason {
            text.push_str(&format!("reason: {}\n", json_line(reason)));
        }
        text.push('\n');
        text
    }

    /// The record, written into the run's folder: its header, then the file `output` holds (what the
    /// verify printed, never more than the limits let through), copied as it is, not read into memory.
    fn write(&self, dir: &Path, output: Option<&Path>) {
        let path = dir.join(format!("iteration-{}.verify-{}.log", self.iteration, self.k));
        let Ok(mut file) = std::fs::File::create(path) else {
            return;
        };
        best_effort(file.write_all(self.header().as_bytes()));
        if let Some(Ok(source)) = output.map(std::fs::File::open) {
            let most = VERIFY_PREPARE_OUTPUT_CAP as u64 + VERIFY_OUTPUT_CAP;
            best_effort(std::io::copy(
                &mut std::io::Read::take(source, most),
                &mut file,
            ));
        }
    }
}

/// A value as compact JSON on one line: as serde_json writes it, which escapes `"`, `\` and the
/// characters below U+0020, with DEL, the C1 controls and the line and paragraph separators escaped too.
/// They can stand only inside a string there, so escaping them leaves the same value.
fn json_line(value: &impl Serialize) -> String {
    let json = serde_json::to_string(value).unwrap_or_else(|_| "null".into());
    let mut line = String::with_capacity(json.len());
    for c in json.chars() {
        if matches!(c, '\u{7f}'..='\u{9f}' | '\u{2028}' | '\u{2029}') {
            line.push_str(&format!("\\u{:04x}", u32::from(c)));
        } else {
            line.push(c);
        }
    }
    line
}

/// The call whose turn it is: its words, read when its turn came, and its file in the queue.
struct Call {
    id: String,
    args: Result<Vec<String>, String>,
    queued: PathBuf,
    interrupted_since: std::cell::Cell<Option<std::time::Instant>>,
}

/// How a verify ended.
enum Outcome {
    /// the command ran and exited with this code
    Exited(i32),
    /// it never ran the command, for this reason
    CouldNotRun(String),
    /// farmy stopped it, for this reason
    Stopped(&'static str),
}

/// The answer farmy-verify passes on: `<id>.out` and `<id>.err` as the command prints, `<id>.exit` last.
struct Answer {
    out: Option<std::fs::File>,
    err: Option<std::fs::File>,
    exit: PathBuf,
    /// whether what `err` holds so far ends inside a line
    err_open: std::sync::atomic::AtomicBool,
}

impl Answer {
    fn open(channel: &Channel, id: &str) -> Self {
        let create = |suffix: &str| {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(channel.responses().join(format!("{id}.{suffix}")))
                .ok()
        };
        Self {
            out: create("out"),
            err: create("err"),
            exit: channel.responses().join(format!("{id}.exit")),
            err_open: Default::default(),
        }
    }
    fn write_out(&self, bytes: &[u8]) {
        if let Some(mut out) = self.out.as_ref() {
            best_effort(out.write_all(bytes));
        }
    }
    fn write_err(&self, bytes: &[u8]) {
        let Some(last) = bytes.last() else {
            return;
        };
        if let Some(mut err) = self.err.as_ref() {
            best_effort(err.write_all(bytes));
        }
        self.err_open
            .store(*last != b'\n', std::sync::atomic::Ordering::SeqCst);
    }
    /// farmy-verify's own line on stderr, on a line of its own.
    fn say(&self, line: &str) {
        if self.err_open.load(std::sync::atomic::Ordering::SeqCst) {
            self.write_err(b"\n");
        }
        self.write_err(line.as_bytes());
    }
    /// The exit code, written beside and renamed: farmy-verify reads it only once everything else is there.
    fn finish(&self, code: i32) {
        let new = self.exit.with_extension("exit.new");
        if std::fs::write(&new, format!("{code}\n")).is_ok() {
            best_effort(std::fs::rename(&new, &self.exit));
        }
    }
}

/// The verify container's output on its way. Until its script says on a line of its own that the command
/// starts (`run`), what comes is held, VERIFY_PREPARE_OUTPUT_CAP at most: passed on once the command
/// starts, or read to say why it never did. From then on the command's output goes to the answer and the
/// record as it comes, never held, VERIFY_OUTPUT_CAP at most. Passing either limit sets `over`: nothing
/// more is passed on or kept, what was held is dropped, and the controller stops the verify.
struct Stream<'s> {
    /// the line that says the command starts now
    run: Vec<u8>,
    answer: &'s Answer,
    log: Option<std::fs::File>,
    state: std::sync::Mutex<StreamState>,
}

#[derive(Default)]
struct StreamState {
    started: bool,
    /// why a limit ended the verify, once one has
    over: Option<String>,
    /// stdout and stderr before the command started, held
    head: Vec<u8>,
    early_err: Vec<u8>,
    /// the current line of stdout before the command started while it may still be `run`: not held yet
    line: Vec<u8>,
    /// whether the current line of stdout before the command started is already not `run`
    off_run: bool,
    /// how much of the command's output was passed on
    passed: u64,
}

impl StreamState {
    /// Holds what came before the command started, stdout or stderr; false when it would pass
    /// VERIFY_PREPARE_OUTPUT_CAP, which ends the verify and drops what was held.
    fn hold(&mut self, err: bool, bytes: &[u8]) -> bool {
        if self.head.len() + self.early_err.len() + bytes.len() > VERIFY_PREPARE_OUTPUT_CAP {
            self.head = vec![];
            self.early_err = vec![];
            self.line = vec![];
            self.over = Some(prepare_exceeded());
            return false;
        }
        if err {
            self.early_err.extend_from_slice(bytes);
        } else {
            self.head.extend_from_slice(bytes);
        }
        true
    }
}

impl Stream<'_> {
    fn lock(&self) -> std::sync::MutexGuard<'_, StreamState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    /// Passes bytes on to the answer and the record, in the order they came (the lock is held).
    fn pass(&self, err: bool, bytes: &[u8]) {
        if err {
            self.answer.write_err(bytes);
        } else {
            self.answer.write_out(bytes);
        }
        if let Some(mut log) = self.log.as_ref() {
            best_effort(log.write_all(bytes));
        }
    }
    /// The command's own output: passed on up to VERIFY_OUTPUT_CAP; a byte beyond it ends the verify.
    fn command_output(&self, st: &mut StreamState, err: bool, bytes: &[u8]) {
        let room = VERIFY_OUTPUT_CAP.saturating_sub(st.passed);
        let n = bytes.len().min(usize::try_from(room).unwrap_or(usize::MAX));
        self.pass(err, &bytes[..n]);
        st.passed += n as u64;
        if n < bytes.len() {
            st.over = Some(output_exceeded());
        }
    }
    /// The command starts: what was held is passed on, stderr first, as before.
    fn start(&self, st: &mut StreamState) {
        st.started = true;
        st.line = vec![];
        let (err, out) = (
            std::mem::take(&mut st.early_err),
            std::mem::take(&mut st.head),
        );
        self.pass(true, &err);
        self.pass(false, &out);
    }
    fn stdout(&self, bytes: &[u8]) {
        let mut st = self.lock();
        if st.over.is_some() {
            return;
        }
        if st.started {
            self.command_output(&mut st, false, bytes);
            return;
        }
        // before the command: byte by byte, looking for `run` at the start of a line
        for (i, &b) in bytes.iter().enumerate() {
            if !st.off_run && self.run.get(st.line.len()) == Some(&b) {
                st.line.push(b);
                if st.line.len() == self.run.len() {
                    self.start(&mut st);
                    self.command_output(&mut st, false, &bytes[i + 1..]);
                    return;
                }
                continue;
            }
            // not `run`: the line so far, and this byte, are output held
            let line = std::mem::take(&mut st.line);
            if !st.hold(false, &line) || !st.hold(false, &[b]) {
                return;
            }
            st.off_run = b != b'\n';
        }
    }
    fn stderr(&self, bytes: &[u8]) {
        let mut st = self.lock();
        if st.over.is_some() {
            return;
        }
        if st.started {
            self.command_output(&mut st, true, bytes);
        } else {
            st.hold(true, bytes);
        }
    }
    /// Why a limit ended the verify, once one has.
    fn over(&self) -> Option<String> {
        self.lock().over.clone()
    }
}

/// Reads a pipe to its end, handing each chunk on as it comes.
fn pump(pipe: Option<impl std::io::Read>, sink: impl Fn(&[u8])) {
    let Some(mut pipe) = pipe else {
        return;
    };
    let mut buf = [0u8; 16 * 1024];
    loop {
        match pipe.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => sink(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
}

/// The last line of `text` that says something.
fn last_said(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty())
        .map(String::from)
}

/// The thread that serves an iteration's farmy-verify calls while its agent runs.
struct Verifier<'v, 'a> {
    run: &'v Run<'a>,
    iteration: u32,
    base: &'v str,
    command: &'v str,
    channel: &'v Channel,
    /// set once the agent's container has ended: the verify running is stopped, the calls waiting never run
    ended: &'v std::sync::atomic::AtomicBool,
    /// how many calls were taken into the queue: the next one's place in it
    taken: std::cell::Cell<u64>,
    network_made: std::cell::Cell<bool>,
}

impl<'v, 'a> Verifier<'v, 'a> {
    fn new(
        run: &'v Run<'a>,
        iteration: u32,
        base: &'v str,
        command: &'v str,
        channel: &'v Channel,
        ended: &'v std::sync::atomic::AtomicBool,
    ) -> Self {
        Self {
            run,
            iteration,
            base,
            command,
            channel,
            ended,
            taken: Default::default(),
            network_made: Default::default(),
        }
    }

    fn dir(&self) -> PathBuf {
        run_dir(&self.run.p.name, &self.run.id)
    }
    fn project(&self) -> String {
        format!("{}-run-{}-verify", self.run.p.name, self.run.id)
    }
    fn compose_file(&self) -> PathBuf {
        self.dir().join("verify-compose.yml")
    }
    fn agent_ended(&self) -> bool {
        self.ended.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Serves calls until the agent's container has ended; returns how many there were.
    fn serve(&self) -> u32 {
        let mut k = 0;
        loop {
            self.take();
            self.forget_answered();
            if self.agent_ended() {
                break;
            }
            let Some(call) = self.channel.next() else {
                std::thread::sleep(VERIFY_POLL);
                continue;
            };
            k += 1;
            match self.turn(&call) {
                Some(VERIFY_ENDED) => {
                    self.unrun(k, &call, VERIFY_ENDED);
                    break;
                }
                Some(reason) => self.unrun(k, &call, reason),
                None => self.answer(k, &call),
            }
        }
        self.take();
        // the calls still waiting never run: each read in what would have been its turn
        while let Some(call) = self.channel.next() {
            k += 1;
            self.unrun(k, &call, VERIFY_ENDED);
        }
        self.channel.clear();
        k
    }

    fn take(&self) {
        self.channel.take(&self.taken);
    }
    fn forget_answered(&self) {
        self.channel.forget_answered();
    }

    /// Whether a call whose turn it is runs (None) or is stopped first, and why.
    fn turn(&self, call: &Call) -> Option<&'static str> {
        loop {
            if self.agent_ended() {
                return Some(VERIFY_ENDED);
            }
            if !self.cancelled(call) {
                return None;
            }
            if let Some(reason) = self.stop_reason(call) {
                return Some(reason);
            }
            std::thread::sleep(VERIFY_POLL);
            self.take();
            self.forget_answered();
        }
    }

    /// Whether farmy-verify said it was interrupted (`<id>.cancel`).
    fn cancelled(&self, call: &Call) -> bool {
        std::fs::symlink_metadata(self.channel.requests().join(format!("{}.cancel", call.id)))
            .is_ok()
    }

    /// Why the verify of `call` must stop now, if it must.
    fn stop_reason(&self, call: &Call) -> Option<&'static str> {
        if self.agent_ended() {
            return Some(VERIFY_ENDED);
        }
        if !self.cancelled(call) {
            return None;
        }
        let since = call
            .interrupted_since
            .get()
            .unwrap_or_else(std::time::Instant::now);
        call.interrupted_since.set(Some(since));
        (since.elapsed() >= VERIFY_INTERRUPT_GRACE).then_some(VERIFY_INTERRUPTED)
    }

    /// A call that never ran, recorded with the reason it was stopped before its turn.
    fn unrun(&self, k: u32, call: &Call, reason: &str) {
        remove_entry(&call.queued);
        let args = call.args.clone().unwrap_or_default();
        let at = now();
        VerifyRecord {
            iteration: self.iteration,
            k,
            command: verify_line(self.command, &args),
            args,
            commit: None,
            started: at.clone(),
            ended: Some(at),
            exit: Some(137),
            reason: Some(reason.into()),
        }
        .write(&self.dir(), None);
        Answer::open(self.channel, &call.id).finish(137);
    }

    /// Runs a call's verify and answers it: the output as it comes, then the exit code; then its record.
    fn answer(&self, k: u32, call: &Call) {
        remove_entry(&call.queued);
        let args = call.args.clone().unwrap_or_default();
        let mut record = VerifyRecord {
            iteration: self.iteration,
            k,
            command: verify_line(self.command, &args),
            args,
            started: now(),
            ..Default::default()
        };
        best_effort(std::fs::remove_file(self.channel.running_output()));
        record.save_running(self.channel);
        let answer = Answer::open(self.channel, &call.id);
        let (exit, reason) = match self.attempt(k, call, &mut record, &answer) {
            Outcome::Exited(code) => match verify_exit_meaning(code) {
                Some(meaning) => {
                    let said = format!("the command exited {code}: {meaning}");
                    answer.say(&format!("farmy-verify: {said}\n"));
                    (code, Some(said))
                }
                None => (code, None),
            },
            Outcome::CouldNotRun(why) => {
                answer.say(&format!("farmy-verify: could not run: {why}\n"));
                (125, Some(format!("could not run: {why}")))
            }
            Outcome::Stopped(why) => (137, Some(why.to_string())),
        };
        answer.finish(exit);
        record.ended = Some(now());
        record.exit = Some(exit);
        record.reason = reason;
        record.write(&self.dir(), Some(&self.channel.running_output()));
        best_effort(std::fs::remove_file(self.channel.running()));
        best_effort(std::fs::remove_file(self.channel.running_output()));
    }

    /// The snapshot, the verify's network and sidecars, the verify container, and what came of it.
    fn attempt(&self, k: u32, call: &Call, record: &mut VerifyRecord, answer: &Answer) -> Outcome {
        let args = match &call.args {
            Ok(args) => args,
            Err(why) => return Outcome::CouldNotRun(why.clone()),
        };
        if let Some(why) = self.stop_reason(call) {
            return Outcome::Stopped(why);
        }
        let commit = match self.snapshot(k) {
            Ok(commit) => commit,
            Err(why) => return Outcome::CouldNotRun(format!("the snapshot failed: {why}")),
        };
        record.commit = Some(commit.clone());
        record.save_running(self.channel);
        if let Some(why) = self.stop_reason(call) {
            return Outcome::Stopped(why);
        }
        let outcome = match self.open(call) {
            Ok(network) => self.contain(k, call, &commit, &network, args, answer),
            Err(outcome) => outcome,
        };
        self.close();
        outcome
    }

    /// The snapshot commit, made as the iteration commit would be, in a git container.
    fn snapshot(&self, k: u32) -> Result<String, String> {
        let p = self.run.p;
        let iteration = self.iteration.to_string();
        let verify = k.to_string();
        let (code, out, err) = self.run.git(
            &snapshot_script(p.writes.as_deref(), &p.protects),
            false,
            &[
                ("FARMY_BASE_SHA", self.base),
                ("FARMY_ITERATION", &iteration),
                ("FARMY_VERIFY", &verify),
            ],
        );
        append(&self.dir().join("git.log"), &err);
        snapshot_commit(code, &out, &err)
    }

    /// The verify's network: `none` with the gate's network none; else one with no way out, the
    /// project's own, with fresh copies of the sidecars on it, healthy.
    fn open(&self, call: &Call) -> Result<String, Outcome> {
        let p = self.run.p;
        if p.gate_isolated {
            return Ok("none".into());
        }
        let project = self.project();
        let sidecars = self
            .run
            .sidecar_project(&project, "verify-sidecar")
            .map_err(|e| Outcome::CouldNotRun(format!("the sidecars could not be made: {e}")))?;
        let Some(sidecars) = sidecars else {
            let label = format!("farmy.run={}", self.run.id);
            if !docker::quiet(&["network", "create", "--label", &label, "--internal", &project]) {
                return Err(Outcome::CouldNotRun(
                    "the verify's network could not be created".into(),
                ));
            }
            self.network_made.set(true);
            return Ok(project);
        };
        if let Err(e) = std::fs::write(self.compose_file(), &sidecars.file) {
            return Err(Outcome::CouldNotRun(format!(
                "the sidecars could not be made: {e}"
            )));
        }
        if !docker::compose(&project, Some(&self.compose_file()), &["up", "-d"], false) {
            // compose may have waited for a dependency's health itself: name one that is not healthy
            let unhealthy = sidecars.checked.iter().find(|service| {
                docker::out(&[
                    "inspect",
                    "--format",
                    "{{.State.Health.Status}}",
                    &format!("{project}-{service}"),
                ])
                .map(|h| h.trim() == "unhealthy")
                .unwrap_or(false)
            });
            return Err(Outcome::CouldNotRun(match unhealthy {
                Some(service) => format!("sidecar {service} is not healthy"),
                None => "the sidecars could not be started".into(),
            }));
        }
        let abort = || {
            self.take();
            self.forget_answered();
            self.stop_reason(call).is_some()
        };
        match wait_healthy(&project, &sidecars.checked, p.health_timeout, &abort) {
            Ok(()) => Ok(project),
            Err(Health::Unhealthy(service) | Health::Timeout(service)) => Err(
                Outcome::CouldNotRun(format!("sidecar {service} is not healthy")),
            ),
            Err(Health::Aborted) => Err(Outcome::Stopped(
                self.stop_reason(call).unwrap_or(VERIFY_ENDED),
            )),
        }
    }

    /// The verify's sidecars and network gone.
    fn close(&self) {
        let file = self.compose_file();
        if file.is_file() {
            let _ = docker::compose(
                &self.project(),
                Some(&file),
                &["down", "-v", "--remove-orphans"],
                false,
            );
            best_effort(std::fs::remove_file(&file));
        }
        if self.network_made.replace(false) {
            let _ = docker::ok(&["network", "rm", &self.project()]);
        }
    }

    /// The verify container, made as the gate's test container: its output passed on as it comes.
    fn contain(
        &self,
        k: u32,
        call: &Call,
        commit: &str,
        network: &str,
        args: &[String],
        answer: &Answer,
    ) -> Outcome {
        let p = self.run.p;
        let name = format!("{}-run-{}-verify-{}-{k}", p.name, self.run.id, self.iteration);
        let marker = format!("farmy-verify-{}-{}-{k}", self.run.id, self.iteration);
        let mut words: Vec<String> = vec!["run".into(), "--rm".into(), "--name".into(), name.clone()];
        words.extend(self.run.labels("verify", Some(self.iteration)));
        words.extend(["--label".into(), format!("farmy.verify={k}")]);
        words.extend([
            "-u".into(),
            "dev".into(),
            "--network".into(),
            network.into(),
        ]);
        words.extend(["-v".into(), format!("{}:/workspace:ro", self.run.volume())]);
        for (m, at) in &p.def.mounts {
            words.extend(["-v".into(), format!("{}-{m}:{at}:ro", p.name)]);
        }
        words.extend(["--tmpfs".into(), "/scratch:exec".into()]);
        let mut env = vec![
            ("FARMY_VERIFY_MARKER", marker.clone()),
            ("FARMY_VERIFY_COMMIT", commit.to_string()),
            ("FARMY_VERIFY_COMMAND", verify_line(self.command, args)),
        ];
        if let Some((_, setup)) = &p.setup {
            env.push(("FARMY_VERIFY_SETUP", setup.clone()));
        }
        for (key, value) in env {
            words.extend(["-e".into(), format!("{key}={value}")]);
        }
        words.extend([
            "-w".into(),
            "/workspace".into(),
            "--entrypoint".into(),
            "sh".into(),
            self.run.image(),
            "-c".into(),
            verify_script(p.def.workdir_clean()),
        ]);
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.channel.running_output())
            .ok();
        let stream = Stream {
            run: format!("{marker} run\n").into_bytes(),
            answer,
            log,
            state: Default::default(),
        };
        let mut child = match Command::new("docker")
            .args(&words)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(e) => return Outcome::CouldNotRun(format!("docker could not be run: {e}")),
        };
        let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
        let (code, stopped) = std::thread::scope(|s| {
            s.spawn(|| pump(stdout, |b| stream.stdout(b)));
            s.spawn(|| pump(stderr, |b| stream.stderr(b)));
            let mut stopped: Option<(Outcome, std::time::Instant)> = None;
            let mut removed = None::<std::time::Instant>;
            let status = loop {
                match child.try_wait() {
                    Ok(Some(status)) => break status.code(),
                    Ok(None) => {}
                    Err(_) => break None,
                }
                self.take();
                self.forget_answered();
                if stopped.is_none() {
                    // the end of the agent's container or an interrupt, or a limit the output passed
                    stopped = self
                        .stop_reason(call)
                        .map(Outcome::Stopped)
                        .or_else(|| stream.over().map(Outcome::CouldNotRun))
                        .map(|outcome| (outcome, std::time::Instant::now()));
                }
                if let Some((_, since)) = &stopped {
                    // the client returns once the container has ended; a container not made yet is
                    // removed as soon as it is, and a client that never returns is given up on
                    if removed.is_none_or(|at| at.elapsed() >= std::time::Duration::from_secs(1)) {
                        let _ = docker::ok(&["rm", "-f", &name]);
                        removed = Some(std::time::Instant::now());
                    }
                    if since.elapsed() >= std::time::Duration::from_secs(30) {
                        best_effort(child.kill());
                    }
                }
                std::thread::sleep(VERIFY_POLL);
            };
            (status, stopped.map(|(outcome, _)| outcome))
        });
        if let Some(outcome) = stopped {
            return outcome;
        }
        let st = stream.lock();
        // a limit passed with the last of the output, the container ended before it was seen
        if let Some(why) = &st.over {
            return Outcome::CouldNotRun(why.clone());
        }
        let code = code.unwrap_or(137);
        if st.started {
            return Outcome::Exited(code);
        }
        // the command never started: the script said why on a line of its own, or Docker did (read where
        // it is held, not copied)
        let head = String::from_utf8_lossy(&st.head);
        let mut lines = head.lines();
        let prefix = format!("{marker} ");
        let said = lines
            .by_ref()
            .find_map(|l| l.strip_prefix(prefix.as_str()))
            .map(|rest| rest.split_whitespace().collect::<Vec<_>>());
        let detail = lines
            .map(str::trim)
            .rfind(|l| !l.is_empty())
            .map(String::from);
        match said.as_deref() {
            Some(["setup", exit]) => Outcome::CouldNotRun(format!(
                "gate_setup {} failed: exit {exit}",
                p.setup.as_ref().map(|(n, _)| n.as_str()).unwrap_or("")
            )),
            Some(["prepare", exit]) => Outcome::CouldNotRun(format!(
                "the snapshot could not be exported in the verify container: {}",
                detail.unwrap_or_else(|| format!("exit {exit}"))
            )),
            _ => Outcome::CouldNotRun(format!(
                "Docker could not run the verify container: {}",
                last_said(&String::from_utf8_lossy(&st.early_err))
                    .unwrap_or_else(|| format!("exit {code}"))
            )),
        }
    }
}

/// A run whose controller is gone (cancelled, or interrupted) during its agent: the verify that ran and
/// the calls that waited are recorded as stopped by the end of the agent's container, and the iteration's
/// count is kept. The verify's containers, sidecars and network go with the run's (`cleanup_abandoned`).
fn finish_abandoned_verifies(st: &mut State) {
    let channel = Channel::of(&st.service, &st.id);
    if !channel.root.is_dir() {
        return;
    }
    let dir = run_dir(&st.service, &st.id);
    let i = st.iteration;
    let prefix = format!("iteration-{i}.verify-");
    let mut count = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            e.file_name()
                .to_string_lossy()
                .strip_prefix(&prefix)?
                .strip_suffix(".log")?
                .parse::<u32>()
                .ok()
        })
        .max()
        .unwrap_or(0);
    if let Some(mut record) = std::fs::read_to_string(channel.running())
        .ok()
        .and_then(|t| serde_json::from_str::<VerifyRecord>(&t).ok())
        .filter(|r| r.iteration == i)
    {
        record.ended = Some(now());
        record.exit = Some(137);
        record.reason = Some(VERIFY_ENDED.into());
        record.write(&dir, Some(&channel.running_output()));
        count = count.max(record.k);
    }
    // the calls left in the queue never ran: each read now, one at a time
    let command = std::fs::read_to_string(channel.command()).unwrap_or_default();
    for path in channel.queued() {
        let args = read_call(&path).unwrap_or_default();
        count += 1;
        let at = now();
        VerifyRecord {
            iteration: i,
            k: count,
            command: verify_line(&command, &args),
            args,
            commit: None,
            started: at.clone(),
            ended: Some(at),
            exit: Some(137),
            reason: Some(VERIFY_ENDED.into()),
        }
        .write(&dir, None);
    }
    channel.clear();
    if st.phase == "agent" && !st.verifies.iter().any(|v| v.iteration == i) {
        st.verifies.push(VerifyCount { iteration: i, count });
    }
}

/// The verify's sidecars and network of a run whose controller is gone.
fn close_abandoned_verify(service: &str, id: &str) {
    let project = format!("{service}-run-{id}-verify");
    let file = run_dir(service, id).join("verify-compose.yml");
    if file.is_file() {
        let _ = docker::compose(
            &project,
            Some(&file),
            &["down", "-v", "--remove-orphans"],
            false,
        );
        best_effort(std::fs::remove_file(&file));
    }
    if docker::ok(&["network", "inspect", &project]) {
        let _ = docker::ok(&["network", "rm", &project]);
    }
}

#[cfg(test)]
mod verify_tests {
    use super::*;

    fn scratch(what: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("farmy-verify-{what}-{}", new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn git(repo: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .args(args)
            .current_dir(repo)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().into()
    }

    fn write(repo: &Path, path: &str, content: &str) {
        let path = repo.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn a_snapshot_is_the_iteration_commit_to_be_and_leaves_the_branch_index_and_tree_alone() {
        let repo = scratch("snapshot");
        git(&repo, &["init", "-q"]);
        git(&repo, &["config", "user.name", "Example Developer"]);
        git(&repo, &["config", "user.email", "dev@example.com"]);
        write(&repo, "src/app.txt", "broken\n");
        write(&repo, "src/old.txt", "old\n");
        write(&repo, "test/check.sh", "the run's test\n");
        write(&repo, "notes.txt", "notes\n");
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-qm", "base"]);
        let base = git(&repo, &["rev-parse", "HEAD"]);
        write(&repo, "src/app.txt", "almost\n");
        git(&repo, &["commit", "-qam", "farmy: iteration 1"]);
        let head = git(&repo, &["rev-parse", "HEAD"]);
        // the agent's tree now
        write(&repo, "src/app.txt", "fixed\n");
        write(&repo, "src/new.txt", "new\n");
        std::fs::remove_file(repo.join("src/old.txt")).unwrap();
        write(&repo, "test/check.sh", "echo all good\n");
        write(&repo, "test/extra.sh", "planted\n");
        write(&repo, "notes.txt", "outside writes\n");
        write(&repo, ".farmy/question.md", "A question?\n");
        let status = git(&repo, &["status", "--porcelain"]);
        let script = snapshot_script(Some(&["src/".into()]), &["test/".into()])
            .replace("/workspace", repo.to_str().unwrap());
        let output = Command::new("sh")
            .args(["-c", &script])
            .current_dir(&repo)
            .env("FARMY_BASE_SHA", &base)
            .env("FARMY_ITERATION", "2")
            .env("FARMY_VERIFY", "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let commit = marker(&String::from_utf8_lossy(&output.stdout), "snapshot").unwrap();
        let show = |path: &str| git(&repo, &["show", &format!("{commit}:{path}")]);
        assert_eq!(show("src/app.txt"), "fixed");
        assert_eq!(show("src/new.txt"), "new");
        assert_eq!(show("test/check.sh"), "the run's test");
        assert_eq!(show("notes.txt"), "notes");
        assert_eq!(
            git(&repo, &["ls-tree", "-r", "--name-only", &commit]),
            "notes.txt\nsrc/app.txt\nsrc/new.txt\ntest/check.sh"
        );
        assert_eq!(git(&repo, &["rev-parse", &format!("{commit}^")]), head);
        // nothing the agent sees has changed: the branch, its index, its files
        assert_eq!(git(&repo, &["rev-parse", "HEAD"]), head);
        assert_eq!(git(&repo, &["status", "--porcelain"]), status);
        assert_eq!(
            std::fs::read_to_string(repo.join("test/check.sh")).unwrap(),
            "echo all good\n"
        );
        assert!(repo.join("test/extra.sh").exists() && repo.join(".farmy/question.md").exists());
        assert!(!repo.join(".git/farmy-verify.index").exists());
        assert_eq!(
            git(&repo, &["branch", "--contains", &commit]),
            "",
            "the snapshot is on no branch"
        );
        std::fs::remove_dir_all(&repo).unwrap();
    }

    #[test]
    fn unrestricted_writes_snapshot_everything_but_the_protected_and_the_control_files() {
        let repo = scratch("snapshot-all");
        git(&repo, &["init", "-q"]);
        git(&repo, &["config", "user.name", "Example Developer"]);
        git(&repo, &["config", "user.email", "dev@example.com"]);
        write(&repo, "app.txt", "broken\n");
        write(&repo, "test/check.sh", "the run's test\n");
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-qm", "base"]);
        let base = git(&repo, &["rev-parse", "HEAD"]);
        write(&repo, "app.txt", "fixed\n");
        write(&repo, "test/check.sh", "echo all good\n");
        write(&repo, ".farmy/answer.md", "An answer.\n");
        let script =
            snapshot_script(None, &["test".into()]).replace("/workspace", repo.to_str().unwrap());
        let output = Command::new("sh")
            .args(["-c", &script])
            .current_dir(&repo)
            .env("FARMY_BASE_SHA", &base)
            .env("FARMY_ITERATION", "1")
            .env("FARMY_VERIFY", "1")
            .output()
            .unwrap();
        assert!(output.status.success());
        let commit = marker(&String::from_utf8_lossy(&output.stdout), "snapshot").unwrap();
        assert_eq!(git(&repo, &["show", &format!("{commit}:app.txt")]), "fixed");
        assert_eq!(
            git(&repo, &["show", &format!("{commit}:test/check.sh")]),
            "the run's test"
        );
        assert_eq!(
            git(&repo, &["ls-tree", "-r", "--name-only", &commit]),
            "app.txt\ntest/check.sh"
        );
        std::fs::remove_dir_all(&repo).unwrap();
    }

    #[test]
    fn each_of_the_agent_s_words_is_one_word_of_the_command_line() {
        let words = ["--name", "only login", "", "it's", "a/b.c=d"].map(String::from);
        assert_eq!(
            verify_line("sh test/check.sh", &words),
            "sh test/check.sh --name 'only login' '' 'it'\\''s' a/b.c=d"
        );
        assert_eq!(verify_line("sh test/check.sh", &[]), "sh test/check.sh");
    }

    #[test]
    fn a_call_is_its_nul_ended_words_and_only_a_regular_file_is_read() {
        let dir = scratch("call");
        let call = dir.join("1-2.call");
        std::fs::write(&call, b"--name\0only login\0\0").unwrap();
        assert_eq!(read_call(&call).unwrap(), ["--name", "only login", ""]);
        std::fs::write(&call, b"").unwrap();
        assert!(read_call(&call).unwrap().is_empty());
        let link = dir.join("3-4.call");
        std::os::unix::fs::symlink(&call, &link).unwrap();
        assert!(read_call(&link).is_err(), "a link is never followed");
        assert!(call_id_ok("20261021091403-4242"));
        assert!(!call_id_ok("../state") && !call_id_ok(".hidden") && !call_id_ok(""));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_snapshot_is_only_a_full_lowercase_hex_id_and_anything_else_failed_unrepeated() {
        let sha1 = "0123456789abcdef0123456789abcdef01234567";
        let sha256 = format!("{sha1}89abcdef0123456789abcdef");
        for id in [sha1, &sha256] {
            assert!(commit_id_ok(id), "{id}");
            assert_eq!(
                snapshot_commit(0, &format!("snapshot {id}\n"), ""),
                Ok(id.to_string())
            );
        }
        let rejected = [
            sha1[..39].to_string(),
            format!("{sha1}8"),
            sha256[..63].to_string(),
            format!("{sha256}0"),
            sha1.to_uppercase(),
            format!("{}g", &sha1[..39]),
            format!("{}\x1b{}", &sha1[..20], &sha1[21..]),
            format!("{}\r{}", &sha1[..20], &sha1[21..]),
            format!("{} {}", &sha1[..20], &sha1[21..]),
            format!("{}é{}", &sha1[..20], &sha1[22..]),
            format!("{sha1} and more"),
            String::new(),
        ];
        for id in &rejected {
            assert!(!commit_id_ok(id), "{id:?}");
            assert_eq!(
                snapshot_commit(0, &format!("snapshot {id}\n"), ""),
                Err("git printed no commit id".to_string()),
                "{id:?}"
            );
        }
        assert!(snapshot_commit(128, &format!("snapshot {sha1}\n"), "").is_err());
    }

    #[test]
    fn farmy_verify_leaves_its_call_and_passes_the_answer_on_stream_by_stream() {
        let dir = scratch("program");
        let (requests, responses) = (dir.join("requests"), dir.join("responses"));
        std::fs::create_dir_all(&requests).unwrap();
        std::fs::create_dir_all(&responses).unwrap();
        let program = dir.join("farmy-verify");
        std::fs::write(&program, VERIFY_PROGRAM).unwrap();
        let child = Command::new("sh")
            .arg(&program)
            .args(["--name", "only login"])
            .env("FARMY_VERIFY_REQUESTS", &requests)
            .env("FARMY_VERIFY_RESPONSES", &responses)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // the controller's side, by hand
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let id = loop {
            let found = std::fs::read_dir(&requests)
                .unwrap()
                .flatten()
                .find_map(|e| {
                    e.file_name()
                        .to_string_lossy()
                        .strip_suffix(".call")
                        .map(String::from)
                });
            if let Some(id) = found {
                break id;
            }
            assert!(std::time::Instant::now() < deadline, "no call came");
            std::thread::sleep(std::time::Duration::from_millis(20));
        };
        let call = requests.join(format!("{id}.call"));
        assert_eq!(read_call(&call).unwrap(), ["--name", "only login"]);
        std::fs::remove_file(&call).unwrap();
        let answer = Answer::open(
            &Channel {
                root: dir.clone(),
            },
            &id,
        );
        let mut out = answer.out.as_ref().unwrap();
        out.write_all(b"first line\n").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        out.write_all(b"second line\n").unwrap();
        answer.say("farmy-verify: the command exited 3\n");
        answer.finish(3);
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(3));
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "first line\nsecond line\n"
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stderr),
            "farmy-verify: the command exited 3\n"
        );
        assert!(
            requests.join(format!("{id}.done")).exists(),
            "it says when it has read everything"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn channel(what: &str) -> Channel {
        let channel = Channel {
            root: scratch(what),
        };
        channel.prepare("sh test/check.sh").unwrap();
        channel
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn file_len(path: &Path) -> u64 {
        std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
    }

    #[test]
    fn no_header_value_of_a_record_spans_a_line_whatever_the_arguments_hold() {
        let args = [
            "x\nexit: 0\n\nforged output",
            "bell\u{7} cr\r esc\u{1b}[2J",
            "del\u{7f} nel\u{85} ls\u{2028} ps\u{2029}",
            "quote\" backslash\\",
        ]
        .map(String::from)
        .to_vec();
        let record = VerifyRecord {
            iteration: 1,
            k: 1,
            command: verify_line("sh test/check.sh", &args),
            args: args.clone(),
            commit: Some("3f2c9a7d0e5b41c8a6f1d2e3b4c5a6978d0e1f23".into()),
            started: "2026-10-21T09:14:03Z".into(),
            ended: Some("2026-10-21T09:14:07Z".into()),
            exit: Some(125),
            reason: Some("could not run: the call\nexit: 0".into()),
        };
        let header = record.header();
        let lines: Vec<&str> = header.split('\n').collect();
        assert_eq!(lines.len(), 9, "seven lines, a blank one: {header:?}");
        let keys: Vec<&str> = lines[..7]
            .iter()
            .map(|l| l.split_once(": ").unwrap().0)
            .collect();
        assert_eq!(
            keys,
            ["args", "command", "commit", "started", "ended", "exit", "reason"]
        );
        for line in &lines {
            assert!(
                !line.chars().any(|c| c.is_control() || "\u{2028}\u{2029}".contains(c)),
                "{line:?}"
            );
        }
        let value = |key: &str| {
            let line = lines.iter().find(|l| l.starts_with(&format!("{key}: "))).unwrap();
            serde_json::from_str::<serde_json::Value>(&line[key.len() + 2..]).unwrap()
        };
        assert_eq!(value("args"), serde_json::json!(args));
        assert_eq!(value("command"), serde_json::json!(record.command));
        assert_eq!(value("reason"), serde_json::json!(record.reason));
        assert_eq!(
            lines[0],
            concat!(
                r#"args: ["x\nexit: 0\n\nforged output","bell\u0007 cr\r esc\u001b[2J","#,
                "\"del\\u007f nel\\u0085 ls\\u2028 ps\\u2029\",",
                r#""quote\" backslash\\"]"#
            )
        );
    }

    #[test]
    fn a_record_copies_its_output_from_the_file_after_the_header() {
        let dir = scratch("record");
        let output = dir.join("running.out");
        std::fs::write(&output, b"first\nsecond\n").unwrap();
        let record = VerifyRecord {
            iteration: 2,
            k: 3,
            command: "sh test/check.sh".into(),
            started: "2026-10-21T09:14:03Z".into(),
            ended: Some("2026-10-21T09:14:07Z".into()),
            exit: Some(3),
            ..Default::default()
        };
        record.write(&dir, Some(&output));
        assert_eq!(
            std::fs::read_to_string(dir.join("iteration-2.verify-3.log")).unwrap(),
            "args: []\ncommand: \"sh test/check.sh\"\ncommit: -\nstarted: 2026-10-21T09:14:03Z\nended: 2026-10-21T09:14:07Z\nexit: 3\n\nfirst\nsecond\n"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A stream as `contain` makes it, its answer and record in `channel`.
    fn stream<'s>(channel: &Channel, answer: &'s Answer) -> Stream<'s> {
        Stream {
            run: b"farmy-verify-1-1-1 run\n".to_vec(),
            answer,
            log: std::fs::File::create(channel.running_output()).ok(),
            state: Default::default(),
        }
    }

    #[test]
    fn the_command_s_first_4_mib_pass_on_as_they_come_and_the_first_byte_beyond_ends_the_verify() {
        let channel = channel("output-cap");
        let answer = Answer::open(&channel, "1-1");
        let stream = stream(&channel, &answer);
        stream.stdout(b"farmy-verify-1-1-1 run\n");
        let chunk = vec![b'o'; 16 * 1024];
        let mut printed = 0u64;
        while printed < VERIFY_OUTPUT_CAP {
            if printed.is_multiple_of(64 * 1024) {
                stream.stderr(&chunk);
            } else {
                stream.stdout(&chunk);
            }
            printed += chunk.len() as u64;
        }
        assert_eq!(printed, VERIFY_OUTPUT_CAP);
        assert_eq!(stream.over(), None, "exactly 4 MiB is not stopped");
        stream.stdout(b"xy");
        assert_eq!(stream.over(), Some(output_exceeded()));
        stream.stderr(b"more");
        let (out, err) = (
            channel.responses().join("1-1.out"),
            channel.responses().join("1-1.err"),
        );
        assert_eq!(file_len(&out) + file_len(&err), VERIFY_OUTPUT_CAP);
        assert_eq!(file_len(&channel.running_output()), VERIFY_OUTPUT_CAP);
        assert!(!std::fs::read(&out).unwrap().contains(&b'x'));
        // farmy-verify's line stands on a line of its own
        answer.say("farmy-verify: could not run: why\n");
        assert!(
            std::fs::read(&err)
                .unwrap()
                .ends_with(b"o\nfarmy-verify: could not run: why\n")
        );
        std::fs::remove_dir_all(&channel.root).unwrap();
    }

    #[test]
    fn a_limit_passed_inside_a_read_lets_through_only_what_fits() {
        let channel = channel("output-cap-chunk");
        let answer = Answer::open(&channel, "1-1");
        let stream = stream(&channel, &answer);
        let mut first = b"farmy-verify-1-1-1 run\n".to_vec();
        first.extend(vec![b'o'; usize::try_from(VERIFY_OUTPUT_CAP).unwrap() - 3]);
        stream.stdout(&first);
        assert_eq!(stream.over(), None);
        stream.stderr(b"abcdef");
        assert_eq!(stream.over(), Some(output_exceeded()));
        assert_eq!(
            std::fs::read(channel.responses().join("1-1.err")).unwrap(),
            b"abc"
        );
        assert_eq!(file_len(&channel.running_output()), VERIFY_OUTPUT_CAP);
        std::fs::remove_dir_all(&channel.root).unwrap();
    }

    #[test]
    fn up_to_64_kib_before_the_command_is_held_and_passed_on_when_it_starts() {
        let channel = channel("prepare-held");
        let answer = Answer::open(&channel, "1-1");
        let stream = stream(&channel, &answer);
        let half = VERIFY_PREPARE_OUTPUT_CAP / 2;
        let mut out = b"farmy-verify-1-1-1 ru".to_vec();
        out.extend(vec![b'.'; half - out.len() - 1]);
        out.push(b'\n');
        stream.stdout(&out);
        stream.stderr(&vec![b'e'; half]);
        assert_eq!(stream.over(), None, "exactly 64 KiB is held");
        // the line that says the command starts, split across reads, is not counted
        stream.stdout(b"farmy-verify-1-1");
        stream.stdout(b"-1 run\nthe command\n");
        assert_eq!(stream.over(), None);
        assert!(stream.lock().started);
        assert_eq!(
            std::fs::read(channel.responses().join("1-1.out")).unwrap(),
            [out.as_slice(), b"the command\n"].concat()
        );
        assert_eq!(
            file_len(&channel.responses().join("1-1.err")),
            half as u64
        );
        std::fs::remove_dir_all(&channel.root).unwrap();
    }

    #[test]
    fn a_byte_beyond_64_kib_before_the_command_ends_the_verify_and_nothing_of_it_is_kept() {
        let channel = channel("prepare-cap");
        let answer = Answer::open(&channel, "1-1");
        let stream = stream(&channel, &answer);
        let line = b"printed before the command\n";
        let mut held = 0;
        while held + line.len() <= VERIFY_PREPARE_OUTPUT_CAP {
            stream.stdout(line);
            held += line.len();
        }
        stream.stderr(&vec![b'e'; VERIFY_PREPARE_OUTPUT_CAP - held]);
        assert_eq!(stream.over(), None);
        stream.stderr(b"!");
        assert_eq!(stream.over(), Some(prepare_exceeded()));
        stream.stdout(b"farmy-verify-1-1-1 run\nthe command\n");
        let st = stream.lock();
        assert!(!st.started, "the command never starts");
        assert!(st.head.is_empty() && st.early_err.is_empty() && st.line.is_empty());
        drop(st);
        assert_eq!(file_len(&channel.responses().join("1-1.out")), 0);
        assert_eq!(file_len(&channel.responses().join("1-1.err")), 0);
        assert_eq!(file_len(&channel.running_output()), 0);
        std::fs::remove_dir_all(&channel.root).unwrap();
    }

    #[test]
    fn a_call_beyond_four_waiting_is_refused_at_once_and_a_waiting_call_is_only_moved_never_read() {
        use std::os::unix::fs::MetadataExt;
        let channel = channel("queue");
        let taken = std::cell::Cell::new(0);
        let call = |id: &str, words: &[u8], age: u64| {
            let path = channel.requests().join(format!("{id}.call"));
            std::fs::write(&path, words).unwrap();
            let when = std::time::SystemTime::now() - std::time::Duration::from_secs(age);
            std::fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(when)
                .unwrap();
            std::fs::metadata(&path).unwrap().ino()
        };
        let first = call("20261021091401-11", b"1\0", 60);
        for (i, id) in ["20261021091402-12", "20261021091403-13", "20261021091404-14"]
            .iter()
            .enumerate()
        {
            call(id, b"0\0", 50 - i as u64);
        }
        call("20261021091406-16", b"0\0", 10);
        call("20261021091405-15", b"0\0", 20);
        channel.take(&taken);
        // the four oldest wait, the agent's own files, moved; the newest is refused
        assert_eq!(channel.waiting(), 4);
        assert!(names(&channel.requests()).is_empty(), "nothing left behind");
        assert_eq!(
            names(&channel.queue()),
            [
                "00000001-20261021091401-11.call",
                "00000002-20261021091402-12.call",
                "00000003-20261021091403-13.call",
                "00000004-20261021091404-14.call",
            ]
        );
        assert_eq!(
            std::fs::metadata(channel.queue().join("00000001-20261021091401-11.call"))
                .unwrap()
                .ino(),
            first
        );
        let refused = channel.responses().join("20261021091405-15");
        assert_eq!(
            std::fs::read_to_string(refused.with_extension("exit")).unwrap(),
            "125\n"
        );
        assert_eq!(
            std::fs::read_to_string(refused.with_extension("err")).unwrap(),
            "farmy-verify: could not run: the verify queue is full (4 calls are waiting)\n"
        );
        // the newest of those taken at once is the one too many
        assert!(channel.responses().join("20261021091406-16.exit").exists());
        // the oldest's turn: read now, no longer waiting, and the next call finds room for one
        let next = channel.next().unwrap();
        assert_eq!(next.id, "20261021091401-11");
        assert_eq!(next.args.unwrap(), ["1"]);
        assert_eq!(channel.waiting(), 3);
        call("20261021091407-17", b"0\0", 0);
        call("20261021091408-18", b"0\0", 0);
        channel.take(&taken);
        assert_eq!(channel.waiting(), 4);
        assert!(names(&channel.requests()).is_empty());
        // farmy-verify read a refusal to the end: its answer goes, and so does what it left
        std::fs::write(channel.requests().join("20261021091405-15.done"), b"").unwrap();
        channel.forget_answered();
        assert!(names(&channel.requests()).is_empty());
        assert!(!refused.with_extension("err").exists());
        // the waiting calls in order, the turn's first
        let queued: Vec<String> = channel
            .queued()
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(queued[0], "00000001-20261021091401-11.turn");
        assert_eq!(queued.len(), 5);
        std::fs::remove_dir_all(&channel.root).unwrap();
    }

    #[test]
    fn farmy_verify_without_its_folders_says_it_could_not_run() {
        let output = Command::new("sh")
            .args(["-c", VERIFY_PROGRAM, "farmy-verify"])
            .env_remove("FARMY_VERIFY_REQUESTS")
            .env_remove("FARMY_VERIFY_RESPONSES")
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(125));
        assert!(String::from_utf8_lossy(&output.stderr).starts_with("farmy-verify: could not run:"));
    }
}
