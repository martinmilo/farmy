# A time limit on the version check

The run record (2026-10-18-2016) asks the CLI's version once per run, before the first iteration, in a
container of its own. Nothing limited how long that may take: a CLI that waits on `--version` (an update
prompt, a network check it cannot make without a network) held the run before its first iteration, forever.

Decided (the owner, 2026-10-19):

- The version container gets 30 s. When it has not ended by then, farmy stops it (it is gone afterwards),
  keeps `agent_version: "unknown"` in `state.json` and `agent_version_reason`, which says the command gave no
  answer within 30 s, and the run goes on to its first iteration.
- A version command that fails or prints nothing keeps `agent_version` null, as before; only the time limit
  gives `unknown`.

The fake docker plays a version command that never answers (`agent_version_hangs`): it runs silent until its
own `timeout N` ends it (exit 124), until it is stopped or removed (exit 137), or for 120 s.

Left out: a configurable limit; a reason for a failing version command.

## Scenario (FactoryRunRecordTest)

1. A version command that gives no answer within 30 s is given up: the run keeps agent_version unknown with
   the reason, and goes on.
