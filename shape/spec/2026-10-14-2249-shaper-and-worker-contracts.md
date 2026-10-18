# 2026-10-14 22:49 — Shaper and worker contracts

The owner confirmed the whole record: specification and scenarios, acceptance tests, then the worker's
implementation, committed separately on `farmy-workbench`. The scenario list in the shaper-and-worker-runs
record is accepted. This record resolves its open contracts so tests and implementation can proceed.

## Decisions

- Named profiles are entries directly under `factory:`. Each has `base`, `agent`, optional `mode`,
  `writes`, `protects`, `hidden`, `test`, optional `check`, `gate`, `review`, `max_iterations` and
  `iteration_timeout`. `mode` uses the existing `api-key` or `subscription` login; omitted retains today's
  selection. The agent catalogue supplies login details. `check` is required for `red_first` and names a
  command. A scalar `gate` selects its predicate; a mapping `{kind: green, network: none}` also selects
  the network policy. The old `{network: none}` means green with no network.
- A legacy block is `default`. Without `--profile`, select `default` if present, else the sole profile;
  several profiles without `default` require an explicit selection, with the available names in the
  refusal. All profiles' agents are installed in the service image; authentication is checked for the
  selected run. Unrecognised profile and command names are refused before creating a run.
- Starting from a run requires it to be green. Starting from a known run branch requires the same
  approval; an unrelated existing branch is allowed as an explicit source. Resolve a source to a commit
  before starting. Changes to a known run branch since its gate/approval are refused, rather than approved
  implicitly. The chosen source commit becomes the new run's protection baseline.
- Approval applies only to `awaiting_review`, checks that its branch still names the gated commit, and
  publishes that commit before reporting green. Approval of an already approved green run is idempotent.
  Other results cannot be approved. A remote-less workbench becomes green without a push, as before.
- On a question, first capture its text, then commit permitted changes under the normal protections,
  excluding `.farmy/question.md`; do not run a gate. An answer uses the original task and profile,
  question and answer, makes a new run branch from the questioned run's tip, and clears the old control
  file. The old run remains `question`. Text/file selection follows `--task`: an existing file in the
  containers folder supplies its contents, otherwise the argument is text. `answer` accepts `--wait`.
- `start --wait` and `answer --wait` exit 0 only for green, 1 for all other run results. Invalid requests
  exit 1 and name the reason. `approve` exits 0 after successful approval. `prune` retains the volumes
  of `awaiting_review` and `question` runs, because they still support a human action.
- Public run data adds `profile`, `question` (text or null) and `from` (the source run ID or branch, or
  null). `show` names the profile and source and prints the question. The TUI uses the result to highlight
  awaiting review and presents question text. Acceptance tests cover its `status --json` input, as for
  the rest of the TUI; the worker verifies the rendering in its own tests.
- Question instructions and the source run's gate evidence reach even a customised prompt. Logs keep
  complete gate output and exit codes; the first prompt of a chained run carries that source evidence.
- Stalling compares the complete output and exit codes of consecutive unsuccessful gates, not the
  truncated prompt excerpt. Two iterations with no commit and identical results stop at the second,
  even when it is also the limit. An earlier successful gate, question, timeout or agent failure wins.

## Scenario refinements

The accepted scenario list remains. The selected-profile test uses a different catalogue agent and an
explicit subscription mode even when an API route is also available. Its limit and timeout are distinct
from the shape profile's. The TUI scenario observes review and question data through `status --json`.
To test dropped source changes rather than only hidden mounts, the shape edit test permits the agent to
see the source but leaves it outside `writes`; a separate assertion checks the example's hidden source.

Additional refusal and lifecycle scenarios required by these contracts:

- An unknown profile is refused with its name and the available profiles, before any agent starts.
- Omitting a profile when several exist and none is default is refused with the available profiles.
- A named profile's missing check command is refused with its command name before any agent starts.
- A red_first gate does not pass when its only committed change deletes a file under writes.
- A worker can start from the approved shape branch as well as its run ID.
- A run that has not passed its gate cannot be approved.
- Pruning keeps the branches of runs awaiting review or an answer.
- Answering a question preserves permitted edits made before asking and never commits the question.

## Tests changed and left out

The existing declaration-of-success test changes its expected result from `max_iterations` to `stalled`,
as recorded previously. No other existing acceptance behavior is loosened. No new network access,
repository-specific path convention, automatic approval or merge is introduced.

The shared YAML, commands, result rules, prompt requirements and public status fields go in `FORMATS.md`.
