# No secret's value on a command line

The run record (2026-10-18-2016) left this open: in token mode the agent's token reached its container as
`-e NAME=value` on the `docker run` command line, visible in the host's process list while the container
was made. The record only replaced the value in its own files.

Decided (the owner, 2026-10-19), for 0.1.1:

- During a factory run, no secret's value farmy resolved (a `token_env` value, a route's key, the mesh
  auth key) is in the argv of any process farmy starts: every `docker` call (`run`, `create`, `exec`,
  `compose`), and the commands those containers run.
- A value a container needs is passed as `-e NAME` without a value (Docker reads it from the environment
  farmy gives the `docker` process) or through `--env-file <file>`. Such a file is farmy's own, mode 0600,
  and is deleted as soon as the container has started, before the container's command ends. The worker
  chooses between the two ways.
- The container still gets the value: the agent in token mode has its token in its environment.
- The run record's `command` is then exactly the words farmy gave Docker, and it holds no value to
  replace. `env` still gives a secret as `<NAME>`. No value is in `state.json` or any file of the run, and
  no env file is left behind.

Tests observe this in three places: the fake docker's call log (every `docker` call farmy made, from the
moment the run starts), the process list sampled while the run goes (every process on the machine, by
`ps`), and the `--env-file` files the fake docker was given (their mode when read, and whether they still
exist while the agent runs).

The existing scenario 4 of the run record ("…with the token's value replaced by its name…") changes
meaning: the recorded command is now the docker call itself, word for word, and never holds the token's
value.

Also recorded here (the owner, 2026-10-19): code questions while shaping go to a read-only work-side
helper, not to the shaper reading `../work` (now in AGENTS.md).

Left out: secrets outside a factory run (`farmy start`'s broker loading, app containers); `docker inspect`
showing a container's environment (Docker keeps it, by design).

Found while checking, not decided: in token mode `.work/<name>/compose.yml`, which `farmy start` writes for
the app container, holds the token's value in plain text. That is outside a run; brought to the owner.

## Scenarios (SecretsOffCommandLinesTest; one changed in FactoryRunRecordTest)

1. In token mode, no process farmy starts during a run has the token's value on its command line, and the
   agent still gets the token in its environment.
2. In api-key mode with mesh egress, no process farmy starts during a run has the route's key or the mesh
   auth key on its command line.
3. An env file farmy gives Docker is readable by its owner only and is gone while the agent still runs.
4. (changed, FactoryRunRecordTest) The recorded command is exactly the docker run farmy made for the agent:
   it never holds the token's value, and the record's environment gives the token as its name.
