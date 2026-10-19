# The factory

A factory profile runs an agent against a separate gate. After every iteration farmy commits the
permitted changes, restores protected paths, and checks the committed tree in a separate container.
The gate can require passing tests, a checked failing test, or a custom command. A passing review run
publishes a draft branch, then waits for approval of its exact commit. Nothing is merged.

## Opting in

In the service's definition, give each profile a name and its own rules:

```yaml
commands:
  test: sh checks/behavior.sh
  check: sh -n checks/behavior.sh
  release: bin/check-release
factory:
  concurrency: 2
  contracts:
    base: main
    agent: claude
    mode: api-key
    writes: [checks/]
    hidden: [implementation/]
    test: test
    check: check
    gate:
      kind: red_first
      red_pattern: 'Expected .*'
      red_exit_codes: [1]
  implementation:
    base: main
    agent: claude
    mode: api-key
    writes: [implementation/]
    protects: [checks/]
    test: test
    gate: green
    max_iterations: 5
    iteration_timeout: 30m
pipelines:
  build:
    steps: [contracts, implementation]
    on_question: contracts
    handoff_limit: 3
    review_answers: false
```

Names and paths are yours to choose. Select one with `--profile`; if omitted, farmy selects `default`
when present, otherwise the only profile. Several profiles without `default` require an explicit choice.
The earlier single `factory:` block with `base`, `agent`, `test` and the other options remains valid as
profile `default`.

`writes` defaults to the whole repository. `protects` restores those paths to the starting commit before
each gate; `hidden` also covers its folders in the agent's container. Every profile's agent is included
in the service image; run `farmy restart <name>` after adding an agent.

`mode: api-key` uses the selected agent's API route through a broker of the run's own.
`mode: subscription` uses that agent's `token_env` from the provider, even when an API route exists.
`mode: login` uses the agent's factory login (below). Omitted mode prefers the API route, then the
agent's token; it never picks `login`. A profile never borrows another agent's credentials.
The selected profile's authentication is checked when the factory run starts.

The gate choices are:

- `green` (the default): `test` exits 0.
- `red_first`: `check` exits 0, `test` exits non-zero, and this iteration committed an added or changed
  file under `writes`. A deletion alone does not qualify. A container or command that could not run
  never counts as a passing red-first gate. Optional `red_pattern` matches the complete test stdout and
  stderr using Rust regex syntax; optional `red_exit_codes` restricts acceptable nonzero exits. Patterns
  and exit codes are validated before launch. Without a pattern, status calls it `red (unverified)`.
  The log names each command and its exit code.
- A command name, such as `release`: that command exits 0; the ordinary test's result does not decide.

`review` defaults to true for `red_first` and false for the other gates. Set it explicitly to override.
A gate mapping also accepts `kind` and `network`, for example `gate: {kind: red_first, network: none}`.
The older `gate: {network: none}` keeps its green gate.
An optional profile `gate_setup` names a command to run in the gate before check/test. Setup failure,
sidecar startup failure or a health timeout ends `test_failed_to_run`, never an accepted red result.

Every catalogue agent with an unattended mode has a `headless` field: the command and whether the
prompt goes on stdin or as an argument (Claude Code `claude -p --dangerously-skip-permissions`, Codex
`codex exec … -`, OpenCode `opencode run --auto`, Cursor `agent -p --force --trust`, Copilot `copilot
--allow-all-tools --no-ask-user -p`; Gemini CLI documents none). The flags that let them act without
asking are the vendors' own for runs inside a container, which is where the agent runs. An agent of your
own gives `headless` in `farmy.yml`.

## Factory logins

A factory login is a subscription login of the agent's own, made for its unattended factory runs. It is
never the interactive login in `farmy-shared` that you use in the app container: a run cannot touch that
one, and logging out there does not stop the factory. It lives on the volume `farmy-factory-login-<agent>`,
one per agent on this Docker, whatever the service.

An agent declares one with `factory_login: {path, create}`: the folder under `$HOME` where its CLI keeps
the login, and the line that makes it without a browser. In the catalogue only Codex has one
(`{path: .codex, create: codex login --device-auth}`; enable device-code login in ChatGPT's security
settings first). An agent of your own can give it in `farmy.yml`.

```sh
farmy start shop                    # the service's image must be built and carry the agent
farmy factory login shop codex      # prints a code and a link; confirm it in a browser anywhere
```

The command runs `create` in the service's image as the dev user, with the volume at `/home/dev/<path>`
and the same way out as the factory's git containers. A failed login on a new volume removes the volume
again, so an existing volume means a login was made. Running it again logs in again into the same
volume. Then select it in a profile:

```yaml
factory:
  work:
    agent: codex
    mode: login
    # …
```

In `mode: login` the agent's container mounts the volume, writable (the CLI refreshes its tokens there),
and gets no token, no API variables and no broker. `farmy factory start` refuses login mode for an agent
without `factory_login`, and before the login has been made.

One agent iteration at a time per factory login: two runs whose agent uses the same login take turns for
the agent's step, and the waiting run shows the phase `login_wait`. Only that step waits; other runs'
clones, commits and gates go on, and the wait does not count against `iteration_timeout`. With
`concurrency` above 1 runs are still admitted and share their slots as before, but their agent iterations
on one login run one after another, so a second run on the same login mostly waits. The turn is a lock
held by the run's controller while its agent container runs; a controller that dies lets go of it.

A turn passes on only once the agent container holding it is gone: if `docker run` returns while the
container still exists, the controller removes it first. Login-mode agent containers carry the label
`farmy.factory-login=<agent>`. A controller that was killed mid-turn leaves its agent container running,
so before taking its turn the next run on that login removes such orphans (`docker rm -f`): running agent
containers of the same login whose run belongs to this containers folder and whose controller is gone.
Each goes together with its run's egress gate (`<service>-run-<id>-egress-gate`) when that is still there.
`farmy factory show` lists each as `stopped orphaned agent container <name> (run <id>)`, followed by
`and its egress gate <gate>` when the gate was removed with it; in `state.json` each entry of
`orphans_stopped` is `{"container", "run", "gate"}`, with `gate` null when there was none. A gate that
cannot be removed is only warned about: the agent container alone decides the turn. Containers of
another login, of a live run or of another containers folder are left alone.

A removal that fails is tried again: four tries in all, 2, 3 and 5 seconds apart (10 seconds). One that
works on a later try is listed like the others and the run goes on. When the orphan is still there after
the last try, the run does not start its agent, since two agents would then share one login: it lets go
of the turn, ends with the result `login_blocked`, and `farmy factory show` prints
`could not remove orphaned agent container <name> (run <id>): <Docker's error>`. Remove that container
yourself (or restart Docker) and start the run again.

`farmy destroy` keeps factory logins. To remove one: `docker volume rm farmy-factory-login-<agent>`.

## Pinning the agent: model, effort and CLI version

Left alone, a factory run gets whatever model, reasoning effort and CLI version the agent defaults to
when the image is built, and those defaults change. To pin them, put the agent's entry in `farmy.yml`.
An entry named after a catalogue agent overrides the catalogue entry field by field and keeps the rest
(FORMATS, "Agents"). A profile has no fields for this, by design: they belong to the agent, so every
profile and every service that uses it runs the same pinned agent.

**Codex** (0.163.0) takes the model as `-m`/`--model`. Reasoning effort has no flag. It is the config
key `model_reasoning_effort`, set with Codex's global config flag `-c key=value`, which may stand after
`exec`. The known values are `none`, `minimal`, `low`, `medium` (the default), `high`, `xhigh`, `max`
and `ultra`, and the model decides which of them it accepts. The official installer installs an exact
release with `CODEX_RELEASE=<x.y.z>` (or `--release <x.y.z>`). It verifies the download's checksum and
checks that the installed binary reports that version. It puts the package under `CODEX_HOME` (by default
`.codex` in the home of the user who runs it, root's in an image build, where dev cannot reach it), so the
line sets `CODEX_HOME=/usr/local/lib/codex` for the install alone, as the catalogue does, and makes that
folder root's and readable by all; `CODEX_INSTALL_DIR` puts the `codex` link in `/usr/local/bin`. Like every
install line, it downloads the installer to a file and then runs it, so a failed download fails the build
with curl's own message instead of running an empty script.

```yaml
agents:
  codex:
    install: curl -fsSL -o /tmp/codex-install.sh https://chatgpt.com/codex/install.sh && CODEX_HOME=/usr/local/lib/codex CODEX_INSTALL_DIR=/usr/local/bin CODEX_RELEASE=0.163.0 CODEX_NON_INTERACTIVE=1 sh /tmp/codex-install.sh && rm -f /tmp/codex-install.sh && chown -R root:root /usr/local/lib/codex && chmod -R a+rX /usr/local/lib/codex
    headless: {command: codex exec -m gpt-6-astra -c model_reasoning_effort=high --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --json -, prompt: stdin}
```

With `--json`, `codex exec` writes JSON events to stdout. Its `turn.completed` event carries `usage`
(`input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`), so each
iteration's `iteration-<i>.agent.stdout` is that iteration's usage report.

**Claude Code** takes the model as `--model`. An alias such as `opus` moves to the latest model, so a
full model name is the pin. Effort is the variable `CLAUDE_CODE_EFFORT_LEVEL` (`low`, `medium`,
`high`, `xhigh`, `max`, `auto`), which wins over the command-line effort setting. Put it in the entry's
`env:`, which the agent's container gets. For an exact version, use the native installer, which takes
the version as its argument. It installs per user: the CLI goes to `.local/share/claude/versions/<version>`
in the home of the user who runs it, with a launcher link in `.local/bin` there. The line below therefore
runs it as root (as every install line runs) with a home of its own, `HOME=/usr/local/lib/claude-code`,
makes that folder root's and readable by all (`chown -R root:root`, `chmod -R a+rX`) and links
`/usr/local/bin/claude` to the installed binary, so dev can run it and no login volume is mounted over it.
It downloads the installer to a file and then runs it, so a failed download fails the build. The apt
repository that the catalogue uses documents no version pin.
`DISABLE_UPDATES=1` stops the installed version from updating itself. `--output-format json` puts the
result, with `usage` and `total_cost_usd`, on stdout.

```yaml
agents:
  claude:
    install: curl -fsSL -o /tmp/claude-install.sh https://claude.ai/install.sh && HOME=/usr/local/lib/claude-code bash /tmp/claude-install.sh 2.1.211 && rm -f /tmp/claude-install.sh && chown -R root:root /usr/local/lib/claude-code && chmod -R a+rX /usr/local/lib/claude-code && ln -sf "$(readlink -f /usr/local/lib/claude-code/.local/bin/claude)" /usr/local/bin/claude   # choose your own exact version
    headless: {command: claude -p --dangerously-skip-permissions --model claude-opus-5-5 --output-format json, prompt: argument}
    env: {CLAUDE_CODE_EFFORT_LEVEL: high, DISABLE_UPDATES: '1'}
```

Points to watch:

- Overriding `headless`, `env` or `install` replaces the whole field. Repeat what you want to keep, such
  as the flags that let the agent act without asking and the prompt mode (`stdin` for Codex, `argument`
  for Claude Code).
- A changed `install` takes effect only once the image is built again: `farmy rebuild <service>`.
- Factory runs never read the interactive login's user configuration, because `farmy-shared` is not in
  the agent's container. In `mode: login`, though, the factory login volume *is* the CLI's home folder
  (`~/.codex` for Codex), so a `config.toml` there would apply to every run on that login. Keep pins on
  the command line, which wins over the file.
- The run record shows what each run actually used (see [A run](#a-run)). `agent_config` in the run's
  `state.json` is the entry with your overrides applied, and `agent_version` is what its `version`
  command printed.

## A run

```sh
farmy start shop                                   # a run needs the service running
farmy factory start shop --profile contracts --task task.md # or --task "the text"; prints the run's id
farmy factory list                                 # every run: id, service, result or phase, iteration
farmy factory show 20261015-091500-3f2a            # the branch, each iteration's commit and verdict, the last test output
farmy factory log 20261015-091500-3f2a 2           # iteration 2's agent output and test output
farmy factory approve 20261015-091500-3f2a          # review its changes and gate log first
farmy factory revise 20261015-091500-3f2a feedback.md --wait
farmy factory start shop --profile implementation --from 20261015-091500-3f2a --task task.md
farmy factory answer 20261015-091500-3f2a "Use the existing API." --wait
farmy factory cancel 20261015-091500-3f2a
farmy factory prune --older-than 7d               # the volumes of runs that ended a week ago or more
```

`--wait` runs the loop in the foreground and exits 0 for green, 2 for review/question pauses and 1 for
failure. Without it the controller
runs in the background of the control container. The session highlights runs needing approval and
shows questions, their profiles, and continuation commands.

What happens:

1. **The run volume.** A short-lived git container clones the service's checkout into `shop-run-<id>`
   (locally, no network), fetches the remote, and checks out `base` as the branch `farmy/shop/<id>`. Your
   own checkout is not touched.
2. **The agent** runs in a new container per iteration with the run volume at `/workspace`. Its `.git` is
   covered (no history, nothing to plant for the git container), the `hidden` folders too; it has no SSH
   agent, no git route, no shared login, no knowledge MCP. The prompt is the task, the iteration and the
   last 200 lines of the previous test output; `factory/prompt.md` in the containers folder replaces
   farmy's template (`{{TASK}}`, `{{ITERATION}}`, `{{TEST_OUTPUT}}`). For `red_first`, the default
   prompt requires every failing check to make the test fail, including `set -e` or equivalent
   shell handling; a later successful command must never hide an earlier failure.
3. **The commit**, in a git container: what changed under `protects` goes back to the run's base, what
   changed under `writes` is committed as `farmy: iteration <i>`, everything else is dropped, so the
   gate tests exactly the commit.
4. **The gate**: a new test container exports the commit into a scratch area and runs the test command
   there, so the suite may write into its tree (Rails' `log/` and `tmp/`) and nothing of it lasts; what is
   not committed is not there. Each iteration creates isolated copies of the service's sidecars with
   their usual names (`postgres`, for example), fresh writable volumes, no published ports and an
   internal network. Developer databases and earlier iterations are untouched. Read-only configuration
   mounts remain available. Privileged sidecars, Docker socket mounts, host networking and external
   networks are refused before the agent starts. Farmy waits for healthchecks, up to
   `gate.health_timeout` (default `30s`), then runs any `gate_setup` and the gate commands. Gate HOME is
   scratch and has no broker, shared home or internet access. `gate: {network: none}` omits sidecars.
   A passing gate pushes `farmy/shop/<id>` and ends `awaiting_review` when review is required;
   otherwise it ends green.
   An unsuccessful gate supplies its output to the next iteration.

A run ends `green`, `awaiting_review`, `question`, `stalled`, `max_iterations`, `timeout` (the agent ran past `iteration_timeout` and the gate was
red), `agent_failed` (the agent exited non-zero having changed nothing), `login_blocked` (an orphaned agent
container of its factory login could not be removed, so its agent never started), `test_failed_to_run` (Docker
could not start the test container), `cancelled`, or `interrupted` (the control container restarted, or
the controller died, while it ran). Everything about a run is in `.work/shop/runs/<id>/`.

That folder holds the run record. For each iteration it has `iteration-<i>.agent.json`, which records
the `docker run` farmy ran, word for word, the agent's environment (every secret replaced by its name), the
image id, the exit code and the times. No secret is on that command line: the token in token mode goes
as `-e NAME` alone, its value only in the environment of that one `docker` process. Next to it are
`iteration-<i>.prompt.md` and the agent's own output, byte for byte, in `iteration-<i>.agent.stdout` and
`iteration-<i>.agent.stderr`. stdout is where an agent's usage report lands. For the whole run,
`state.json` holds `agent_config`, the agent entry as resolved (the catalogue with the `farmy.yml`
overrides applied), and `agent_version`. That is what the entry's `version` command printed, asked once
before the first iteration, or null when the entry has none or the command printed nothing. A command
that fails keeps `agent_version: "unknown"` with `agent_version_reason`, its exit code and the last line
it wrote to stderr (`exited 126: sh: 1: codex: Permission denied`), so a CLI that is missing or that dev
may not execute shows in the record; the run goes on. The version container gets 30 s. When it has not ended by then, farmy removes it, keeps
`agent_version: "unknown"` with `agent_version_reason: "no answer within 30 s"`, and the run goes on to
its first iteration. `agent_version_reason` is absent when the version was given or there is none.

## Review, chaining and questions

`awaiting_review` identifies the published draft and its gated commit. Inspect its comparison link and
gate output, then run `farmy factory approve <id>`. Approval verifies that both local and published
branches still name that commit and records immutable commit, profile and gate snapshots. A workbench
without a remote keeps local review. Repeated approval is harmless. A failed draft push ends
`publish_failed`; `farmy factory resume <id>` retries the same commit without another agent or gate.
Draft publication creates a Git branch, not a forge pull request.

`start --from <id|known branch>` uses the stored approved commit even after the branch advances. A known
unapproved branch cannot bypass review. An unrelated branch can be named explicitly and resolves once
to a source SHA. The new profile's protected paths use this starting commit,
so the approved contract stays intact, and its first prompt includes the previous gate's complete
output and exit codes. Both earlier and developer checkouts are left untouched.

An agent can write `.farmy/question.md` even when it is outside `writes`. Farmy captures the question,
commits the other permitted changes, and stops as `question`, without a gate or push. The question file
is never committed. `show` and the session display the question. Continue with
`farmy factory answer <id> <text|file> [--wait]`: an existing file is read as the answer; otherwise the
argument is literal text. This makes a new run and branch from the questioned commit with the original
task and profile, the question and answer in its prompt, and the old control file removed. The earlier
run remains history. Question instructions and handoff evidence are supplied even with a custom prompt.

`farmy factory revise <id> <text|file> [--wait]` creates a new attempt on the same branch using the
original task/profile and the feedback. It retains the original comparison base and supersedes the
old attempt. The replacement needs fresh approval. An approved attempt can be revised only before
downstream work starts; any queued continuation is atomically invalidated.

GitHub, GitLab, Forgejo and Gitea comparison links use the original base and exact gated SHA. Public
GitHub/GitLab hosts are recognized automatically. Set service `forge: forgejo` (or another supported
kind) and optionally `repo_web_url: https://git.example.com/acme/shop` for a private forge. Unknown
hosts retain the branch as the review fallback; farmy makes no discovery request.

## Pipelines

```sh
farmy factory pipeline start shop build --task task.md --wait
farmy factory pipeline list shop
farmy factory pipeline show p-20261015-091500-3f2a
farmy factory pipeline resume p-20261015-091500-3f2a --wait
farmy factory pipeline cancel p-20261015-091500-3f2a
```

Pipelines run their configured profiles in order and pause for each required approval. Configuration
is captured at launch. Status and the session show the pipeline, current step, child, result and
comparison link. Each child's ID is stored before launch; resume adopts a live child or cleans up an
interrupted attempt before restarting that identity. Repeated resumes do not duplicate work. Status
only observes. Cancellation removes that pipeline's active and queued resources while preserving
history and other runs.

The service's positive `factory.concurrency` limit defaults to 2. Direct runs, pipeline children and
question handoffs share it, with excess runs queued in arrival order. Review/question pauses and parent
controllers consume no execution slot. Each gate iteration cleans up its own sidecars and data.

With `on_question`, a worker question dispatches the named profile from the worker's captured commit.
If the asking profile is already `on_question`, the pipeline pauses for a human `factory answer`
without dispatching to itself or consuming a handoff. The answer resumes that same step and profile.
The answerer may write `.farmy/answer.md`, which is captured and excluded from all commits. Forbidden
edits end `permission_violation` before cleanup can conceal them. Run and pipeline show, plus failure
notifications, name the actual forbidden paths and report whether the edits were dropped. A hidden
write blocked by a read-only mount is not reported as a changed file. A nonempty answer without permitted
changes ends `answered` and resumes the original worker with its task, question and answer. Set
`review_answers: true` to require approval of text-only answers. Empty answers end `answer_missing`.
Any permitted changes require the ordinary gate, draft and approval, with red-first checked against
the worker's question commit. After approval, the worker continues from the approved answer commit.
An answerer asking another question waits for a human.

Each new worker question consumes a persisted handoff. The default limit is 3; the fourth ends
`handoff_limit` before launching another answerer. Replies, revisions and resumes retain that budget.
Without `on_question`, use the manual answer command.

Two consecutive unsuccessful gates with identical complete output and command exit codes stop as
`stalled` when neither iteration committed a change. A commit or changed output breaks this sequence;
stalling takes precedence over the iteration limit on that second attempt.

## Unattended

A run asks nobody for anything: the values the host gave at `farmy start` are held by the control
container (credentials.md, "Held"), so a run started from a script, a cron job or the session gets the
agent's key without a prompt. `farmy lock` takes that away again. When the control container holds
nothing (made anew, restarted, after `farmy lock`), `farmy factory start` obtains the values the way
`farmy start` does: the command in `FARMY_UNLOCK_COMMAND`, the Keychain or the secret service under
`FARMY_SECRET_PREFIX`, and a prompt only for what none of them has.

Git in a run goes the way the service's git goes: through its broker for a token route, through its SSH
agent for an SSH route, and through the mesh (or an existing proxy) when there is one, the push included.

Run volumes are kept for `show`, `log` and a look inside; `farmy factory show` prints each one's size, and
`farmy factory prune` removes the volumes of finished runs (their state and logs stay). Runs awaiting
review or an answer keep their volumes so they can continue; `farmy destroy shop`
removes them all, with the service's own volumes.

Dependencies kept inside the tree and ignored by Git (`node_modules`, for example) are not in the
gate's export. Use the image or `gate_setup` to supply what the check needs.

## Notifications

Workspace `notify` accepts `format: json|slack|ntfy`, exactly one of `url` or `url_secret`, and an optional
`token_secret`. Secret fields name provider references; resolved endpoints and bearer tokens remain
in memory. Events cover review, question, green and failed transitions and include run/pipeline identity,
profile, step, result, branch, commit and comparison link. Task, question, answer, agent and test text
are excluded. Slack and ntfy receive readable summaries.

Delivery uses three bounded attempts with one event ID. Failure is reported and retained by `show`
without changing the run's result. Diagnostics exclude endpoint values, tokens and receiver bodies.

## Outbound access

In both API-key and token modes, the agent starts on the run's internal network. A separate
filtering proxy permits only the selected agent's catalogue `api_hosts`; it has the outward
attachment, including access to a configured mesh or HTTP proxy. The agent has no temporary
outward network and cannot bypass filtering by ignoring its proxy variables. API-key mode also
keeps the fixed route through its credential broker. App registry, git and extra host allowances
do not apply to the agent, and `farmy egress allow` cannot widen a running factory policy.

The test container remains isolated from these proxies. Every terminal run outcome removes
the run's filtering resources and retains its denials for `farmy egress log [SERVICE]` and the
service's status count. See [egress filtering](mesh-egress.md).
