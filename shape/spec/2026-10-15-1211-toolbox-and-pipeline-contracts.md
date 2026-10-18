# Toolbox and pipeline contracts

The owner approved TS1–TS27 and PS1–PS43, accepted the proposed defaults, then supplied two reviews.
The second review takes precedence wherever it changes the first. Work continues on
`farmy-workbench`: acceptance tests first, then a separate worker that reads their failures and
`FORMATS.md`. The earlier records remain historical; this record resolves their open questions.

## Toolbox and dotfiles decisions

- Workspace `tools` and service additions select catalogue entries; omitted selection is empty.
  `tool_catalogue` supplies custom definitions using the shipped fields. Fields merge, but a version
  override invalidates inherited artifacts unless the override supplies the complete required set.
  The catalogue names neovim, ripgrep, fd, fzf, bat, lazygit, delta and jq; ripgrep is at least 15.2.
  Downloads are official static/prebuilt releases, SHA-256 checked, with explicit architecture/libc
  combinations. Missing compatible artifacts fail; there is no silent distro/source fallback.
- Global and service packages are additive distro package names. A custom toolbox can explicitly opt
  out of managed tools and packages with `toolbox: {managed: false}`; otherwise the managed layer applies.
- `farmy toolbox bump [tool ...]` defaults to the active workspace/service selection and writes
  `tools.lock` in the containers folder, leaving `farmy.yml` byte-identical. It resolves stable vendor
  releases and verifies every required architecture/libc artifact before one atomic replacement.
  One incomplete tool aborts the entire bump. Normal builds only read the lock. Its pins override
  shipped pins; status names a newer shipped pin and says `farmy toolbox bump` when the lock lags.
- The shared dotfiles clone tracks its initially selected remote default branch. Initialization and
  updates are serialized; incomplete clones are not published. Updates are fast-forward only and
  refuse local changes or a changed repository URL without a deliberate migration. Git authentication
  uses the existing token/SSH broker routes. Apps receive the clone read-only; only farmy's initialization
  and update operation write it. Failure names the operation and does not pretend startup succeeded.
- A repo-relative executable installer runs using its shebang, from the repository root as dev, after
  shared-data links and before service setup. Without it, dotted files and directories are linked/merged,
  excluding repository metadata. Existing files, including the image's `.bashrc`, `.zshrc`, `.profile`
  and other skel files, move to `~/.dotfiles-backup/<timestamp>/` before replacement; report the backup
  once. Correct existing links are unchanged and reported no further. Refuse only an unmergeable
  directory target. Never replace farmy's managed shared-data link with a whole-directory symlink.
- Record the revision actually applied per container. Pull updates the clone and tries every running
  app. An installer failure yields a partial result listing applied and failed containers, preserves
  each container's actual applied revision and makes no rollback claim.
- `shared_data: [nvim]` is the default. Only each named directory under `~/.local/share` and `~/.cache`
  is shared. Storage is keyed by platform, libc and the selected tool versions; architecture, libc or
  version changes cannot reuse incompatible data. All other home content is private per service.
  There is no automatic migration of existing `~/.local/share`. `shared_logins: false` exposes only
  necessary shared subdirectories and keeps login files private. Farmy serializes its own setup;
  interactive plugin-manager concurrency remains the plugin manager's responsibility.
- zsh is the default login shell; sh, bash and zsh are supported selections and installed in the image.
  `farmy ssh` invokes the chosen interactive login shell. Factory agents inherit image tools but retain
  isolated runtime homes and no shared dotfiles/data; gate homes remain scratch directories.

## Pipeline decisions

- Pipelines are service-level definitions referencing named profiles, with `handoff_limit: 3` and
  `review_answers: false` defaults. `factory.concurrency: 2` is reserved and accepted with legacy or
  named profiles. Runs above the service cap queue FIFO; a waiting review/question and the parent
  controller consume no execution slot. Claiming a slot is atomic across simultaneous starters.
- Pipeline IDs are distinct from run IDs. Assign and persist a child's ID before launching it.
  Resume reconciles that ID with existing containers and volumes, adopting or cleaning up its resources;
  it never launches a second copy. Approve/resume claim transitions atomically. Status reads do not
  launch work. Waiting commands exit 0 for green, 2 for paused review/question and 1 for failure.
- Successful review-required runs push immediately as drafts. Compare links name the original step
  base and exact gated commit, retain their base through revisions, support GitHub/GitLab/Forgejo/Gitea,
  and use the branch as fallback for unknown hosts or no remote. Explicit self-hosted forge/web URL
  configuration is supported; print those links even when only the reviewer's network can open them.
  Failed publication does not advance and is resumable against the same gated commit.
- Approval refuses branch drift before approval, then snapshots both the SHA and profile/gate
  configuration. Later branch movement or live configuration edits do not change the approved handoff.
  Known branch aliases cannot bypass approval; unrelated explicit manual sources resolve once to a SHA.
  Revise creates a new attempt ID on the same branch, preserves its task and feedback, and requires fresh
  review. Revision of an approved attempt atomically invalidates queued downstream work. Already-started
  downstream work prevents revision of that attempt. Repeated approvals do not start another child.
- A question shaper starts from the worker's captured question commit. Its new test must fail against
  that worker commit, with only permitted shaper changes applied. A forbidden edit is a reported
  permission violation and stops automatic continuation before filtering can conceal it. A nonempty
  text-only `.farmy/answer.md` continues the worker without review by default; `review_answers: true`
  holds it for human approval. Any permitted change instead requires the shape gate and human review.
  Question and answer files are captured outside writes and never committed. Empty text-only answers
  fail; a shaper's own question waits for a human rather than recursively dispatching another shaper.
- Count one handoff per new worker question sent to `on_question`; three are allowed, the fourth ends
  `handoff_limit` before dispatch. Answering, revising, retrying or resuming that handoff does not reset
  or increase its count. Without on_question, manual answers remain supported.
- red_first passes exactly when check exits 0, test exits nonzero, the commit adds or changes a file
  under writes, and `red_pattern` matches if configured. Optional `red_exit_codes` further restricts
  acceptable test exits. Execution failure is never a gate verdict. Without a pattern, status
  and show say `red (unverified)`, never `meaningful red`; no generic crash-detection heuristic replaces
  this explicit contract. Invalid/empty patterns or invalid exit lists are refused before execution.
- Every gate iteration gets fresh sidecars and data in a run-specific Compose project without published
  ports. Remove them after the gate or cancellation without touching another run or the live service.
  Preserve aliases, dependencies and health checks; wait for health. Reject privileged sidecars,
  Docker-socket mounts, host networking and external networks. Writable data gets run-owned volumes;
  only read-only configuration binds may be retained. network none starts no sidecars.
- A profile's optional `gate_setup` names a command, run in the gate container after sidecars are healthy
  and before check/test. Health timeout or setup failure is `test_failed_to_run`, never red.
- Notify on awaiting_review, question, green and terminal failures. Configuration chooses JSON, ntfy or
  Slack-compatible formatting. Persist secret references only, never resolved destination URLs or
  tokens. Errors never echo destination URLs, headers or receiver bodies. Payloads omit task text,
  questions, answers and logs by default. Use stable event IDs and bounded retries; delivery failures
  do not change the run verdict. Comparison links remain in the payload.
- Restrict inputs and public status use off/audit/enforce, retaining false/true aliases and accepting
  old persisted mode names. Preserve strongest-policy precedence and factory enforcement. Document HTTP
  and opaque CONNECT coverage, no independent route for other protocols and builds outside the gate.

## Approved scenario refinements

TS1 explicitly names the eight tools. TS9–10 test tools.lock, selectable bump targets, every required
architecture/libc combination and all-or-nothing updates. TS17–24 cover backups, read-only dotfiles,
per-container applied revisions and partial pull, named shared_data with tool-version separation,
private home content and no automatic migration.

PS15 covers preassigned children, reconciliation and atomic claims. PS18 covers profile/gate snapshots
and invalidating queued downstream work. PS20–23 cover text-answer review policy, forbidden-edit refusal,
the worker question commit as red_first reference and control-file cleanup. PS26–29 cover the exact
red_first predicate, optional exit-code narrowing and explicit unverified status without a pattern.

Additional approved scenarios:

- TS28: The image's default .zshrc and .bashrc are backed up and replaced by dotfiles links; another start changes and reports nothing.
- TS29: Toolbox bump writes tools.lock, leaves farmy.yml byte-identical and status reports a shipped pin newer than the lock.
- An app cannot modify its shared dotfiles clone.
- Simultaneous starts never exceed the service concurrency cap.
- PS44: gate_setup runs against fresh healthy sidecars before check/test, and failure ends test_failed_to_run.
- Notification credentials appear in no persisted state or error output.

PS43 remains the milestone: shape, draft push, revise, approve an immutable commit/configuration, work,
question, text answer, worker continuation and green. The fake must observe actual Git history, prompts,
sidecar state and HTTP requests; it must not implement the controller's decisions for the program.

## Public test boundaries and handoff

The catalogue listing, generated toolbox inputs/scripts, tools.lock, Compose inputs, public status and
run outputs are observable interfaces. The fake executes generated home/install scripts and ordinary
Git/test commands against mapped files; it does not manufacture dotfiles links or approval outcomes.
Its journal must support overlapping simulated containers without losing updates.

The shared contract in FORMATS.md fixes the remaining concrete spellings and exit codes. No further
scenario approval is needed for the behaviors approved above. The shaper commits records, contracts,
fixtures and tests; the worker then implements from failures without reading this record or tests.

## Existing tests whose meaning changes

`FactoryProfilesTest` now expects checked review-required shape/work runs to push a draft immediately,
approval to mark an already-published exact commit green, and unapproved-source refusal to retain that
draft. Its review/question waiting commands and their helper setups expect exit 2. The prune scenario
now retains a published draft for revision or approval. The shaper-forbidden-edit scenario still drops
ordinary out-of-scope edits; the stricter permission-violation rule applies to an answering shaper.

`FactoryEgressTest`'s explicit failing-test/any-glob scenario likewise expects review pause exit 2.
`FactoryTest`'s sidecar-reachability scenario now requires the gate's own sidecar copies and verifies
the developer's sidecar stays separate. `AuditEgressTest` and the egress-control status assertions now
name the canonical stronger mode enforce and the unrestricted mode off, preserving policy behavior.
