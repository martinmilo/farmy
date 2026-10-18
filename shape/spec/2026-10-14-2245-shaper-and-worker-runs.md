# 2026-10-14 22:45 — Shaper and worker runs

Recorded on `farmy-workbench`, for the shaper and the worker.

The generic form of a two-agent build: one agent may change the tests and never the code, the other the
reverse; neither can mark its own work done. farmy knows no folder names. Profiles describe each agent's
permissions and the independent gate that judges its work; a person approves work that requires review.

This extends the factory-loop and factory-gate records and the later factory corrections. Existing
isolation, commit export, credentials, network, ownership and cleanup rules continue to apply.

## 1. Profiles

`factory:` holds named profiles instead of one agent's block. Each profile has its own agent, login/mode,
`writes`, `protects`, `hidden`, `gate`, `max_iterations` and `iteration_timeout`. It can also set `review`.
Profile names are chosen by the user; `shape` and `work` have no built-in meaning.

The documentation uses these profile entries as its example (agent, login/mode, command selections and
limits omitted here):

```yaml
shape:
  writes: [test/]
  hidden: [src/]
  gate: red_first
work:
  writes: [src/]
  protects: [test/]
  gate: green
```

The paths are configuration, not conventions farmy recognises. As today, hidden paths are also protected;
changes outside `writes` are dropped before the gate, and changes under `protects` are reverted. The
agent's claim to be finished changes none of these rules.

A definition using today's single `factory:` block keeps working as one profile named `default`, with
the existing start command and green gate. Its existing limits and gate network configuration retain
their meaning. `--profile <name>` selects a named profile.

## 2. Gates

Commands are names from the service's `commands:`. The controller runs them independently of the agent,
against the exported commit, under the existing gate isolation rules.

| Gate | Pass condition |
|---|---|
| `green` | The test command exits 0, as today. |
| `red_first` | The check command exits 0, the test command exits non-zero, and this iteration's commit added or changed at least one file under the profile's `writes`. All three conditions are required. |
| A custom command name | That command exits 0. |

The check command is selected from `commands:`, for example the suite's load or syntax check. A broken
check is not a successful `red_first` gate. Neither is an already passing suite, an unchanged failing
suite, or a change that was dropped because it was outside `writes`. Deleting files alone does not meet
the requirement to add or change one.

Keep the gate output and command exit codes. The next worker receives the preceding run's failure output
in its prompt so it sees exactly what fails; the run's logs retain that evidence too. A command or gate
container that could not run is an execution failure, not evidence that a test failed as intended.

## 3. Chaining and review

```text
farmy factory start <name> --profile work --from <run id|branch> --task <file or text>
farmy factory approve <id>
```

`--from` starts from the preceding run's branch rather than the configured base. The selected profile's
permissions apply to the new run, with its starting commit as the protection baseline: a worker must
retain the tests the shaper added. The developer's checkout stays untouched, as it does today.

`review: true` is the default for `red_first`; other gates keep today's automatic completion unless
review is requested. When the gate passes for a profile requiring review, the run ends `awaiting_review`
and does not push. `approve` is the person's explicit approval: it marks the run green and pushes its
branch, subject to the existing rule that a workbench with no remote does not push. Nothing merges.

`--from` refuses a run still awaiting approval. Naming that same run's branch must not bypass review.
The TUI presents `awaiting_review` prominently as work needing a person's attention. A successful gate
and an approved run are distinct facts; an agent's words cannot stand in for either.

## 4. Questions and answers

The agent prompt says it may stop and ask by writing `.farmy/question.md`. This control file may be
written outside the profile's `writes`, is never committed (even when `writes` includes the whole
repository), and ends the run as `question`. Capture its text before the usual removal of uncommitted
files can discard it. `factory show` and the TUI show the question text.

```text
farmy factory answer <id> <text|file>
```

An answer starts the next run from the questioned run's branch, using the same profile and carrying the
answer in the prompt along with the task and question. This is a continuation, with a new run ID, not a
claim that the earlier run passed. It must not restart from the configured base or immediately stop on
the old question file. The earlier run remains available as the question and its history.

## 5. Stalled runs

If two consecutive iterations commit nothing and have identical gate output, end the run `stalled`
after the second iteration. Start no third iteration and spend none of the remaining iteration budget.
A commit or changed gate output breaks the sequence. A gate that passes still completes immediately
according to its review policy; stalling describes a run that has not passed.

The existing earlier termination rules still apply: asking a question stops for that question, and
`agent_failed`, timeout and a gate that cannot run retain their meanings. When the second empty,
identical iteration is also the iteration limit, report the more specific result `stalled`.

## Tests whose meaning changes

`test/farmy/factory_test.rb`, "an agent that prints tests pass with a red suite does not produce green":
its two iterations commit nothing and produce identical gate output. Its result becomes `stalled`
instead of `max_iterations`; the rule that the agent cannot declare success remains the point of the
test. The separate test for reaching `max_iterations` commits different changes each time and keeps its
existing meaning.

The test "with factory.gate.network: none the gate has no network and no sidecar joins" must retain its
meaning for the legacy definition. The new scalar gate selection must not silently discard that setting.

## Tests through the fake

Use the existing fake Docker and Git host: agents play file changes, while git and gate commands act on
real files in the fake's volumes. Assertions observe the public commands, prompts, exported files,
commits and pushes. The fake must not decide whether a profile passes or approve a run for farmy.

The owner's requested sequences are:

1. A shape run adds a failing test, passes its check, reaches `awaiting_review`, is approved, and becomes
   the source of a work run that passes green.
2. A work run asks a question, and an answer starts a continuation with the answer in its prompt.
3. Two empty iterations with identical gate output end `stalled` without a third iteration.
4. A shape agent's attempted change to `src/` is dropped.

## Scenario list

Each sentence below describes one acceptance test; the related tests together cover the requested
sequences.

- A legacy single factory block runs as the default profile and keeps its existing green gate.
- A selected named profile uses its own agent, login/mode, permissions and iteration limits.
- A shape run that adds a failing test and passes its check ends awaiting_review without pushing.
- Approving a run awaiting_review marks it green and pushes its branch.
- A work run started from the approved shape run inherits its tests and failure output, fixes the code, and ends green.
- Starting from an unapproved run is refused without starting an agent or publishing its branch.
- Starting from an unapproved run's branch is refused for the same missing approval.
- A red_first gate does not pass when the check command fails.
- A red_first gate does not pass when the test command exits zero.
- A red_first gate does not pass without a committed added or changed file under writes.
- A custom gate passes when its named command exits zero.
- A custom gate does not pass when its named command exits non-zero.
- A profile explicitly requiring review waits for approval even when its green gate passes.
- A profile explicitly disabling review completes when its red_first gate passes.
- An agent may ask a question outside writes, ending question with its text visible in show and absent from every commit.
- Answering a questioned run continues its branch with the answer in the prompt and can complete green.
- An answer read from a file reaches the continuing agent's prompt.
- Two empty iterations with identical failing gate output end stalled after the second, with no further agent invocation.
- A commit between empty iterations breaks the stalled sequence.
- Changed gate output between empty iterations breaks the stalled sequence.
- A shape agent's source edit is dropped before the gate and reaches no commit.
- A work agent's test edit is dropped while the approved shaper tests remain in the gate's commit.
- The two-profile build also works with user-chosen profile and directory names.
- The TUI makes a run awaiting_review prominent and shows the text of a run waiting on a question.

## Contracts to settle before the tests depend on them

1. The complete YAML spelling for profiles, login/mode, selection of the test and check commands, and
   where `base` and gate network options live. The legacy single block, including `gate.network`, stays
   accepted. Also settle the default selection when several named profiles exist and `--profile` is
   omitted; only the legacy `default` behavior is fixed here.
2. Whether an agent's permitted edits in the iteration that asks a question are committed before it
   stops, and the branch naming of the new run that `answer` starts. The continuation must retain the
   questioned branch's work, and the question file must never become a commit.
3. The treatment of a bare branch without recorded run approval, and of a source that has advanced since
   review. Naming a known unapproved run by branch is not an escape from approval.
4. How `prune` treats runs awaiting review or an answer: the existing policy removes finished runs'
   volumes, but these states still need their branches for approval or continuation.
5. The command exit codes for `awaiting_review`, `question` and `stalled`, the public status fields for
   profile and continuation, and the TUI presentation used for the review and question tests.

Once settled, put these shared contracts in `FORMATS.md` so the worker receives what a failure cannot
show. This record captures the agreed behavior and proposed test scenarios; it does not change existing
tests or the shared format contract yet.

## Left out

Automatic approval, merging, a hard-coded shaper/worker workflow, fixed repository folder names, and an
automatic pipeline that launches the next profile without the explicit chaining or answer command.
