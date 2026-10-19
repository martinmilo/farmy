# The factory run record: what each iteration ran, with what, and what it reported

The owner plans an experiment through the factory, one run at a time: Claude Code as shaper, Codex CLI as
worker, in three profiles. Comparing runs needs to know, per iteration, exactly what ran: the command and
environment, the image and CLI version, the agent's exit code, its timing, its prompt and what it reported
about its usage. Today a run keeps `state.json` (commits, gate verdicts, the profile and definition
snapshots) and per iteration `iteration-<i>.agent.log` (stdout and stderr joined) and
`iteration-<i>.test.log`. The command, environment, prompt, image, version and the agent's own exit code
are not kept, and a usage report printed on stdout (Claude's `--output-format json`, Codex's JSON events)
is mixed with stderr.

Decided (the owner, 2026-10-18), "the smallest change":

Per iteration, in `.work/<name>/runs/<id>/`, beside the files that are there today (`agent.log` stays
for `factory log`):
- `iteration-<i>.agent.json`: `iteration`, `command` (the `docker run` farmy ran for the agent, as a list
  of words starting `docker`, `run`), `env` (the agent container's environment as given), `image`
  (`farmy/<name>:dev`), `image_id` (that image's id when the agent ran, as `docker image inspect` gives it),
  `exit` (the agent's exit code, 124 when stopped at `iteration_timeout`), `started` and `ended` (RFC 3339,
  UTC), and `prompt`, `stdout`, `stderr` naming the three files below.
- In `command` and `env`, a secret's value is replaced by its name in angle brackets: token mode gives
  `CLAUDE_CODE_OAUTH_TOKEN=<CLAUDE_CODE_OAUTH_TOKEN>`. No secret's value is in any file of the run.
- `iteration-<i>.prompt.md`: the prompt the agent was given, exactly.
- `iteration-<i>.agent.stdout` and `iteration-<i>.agent.stderr`: what the agent printed, apart, exactly.
  The raw stdout is the usage report: farmy does not parse it (a parser per agent can come later).

Per run, in `state.json`, next to `profile_config`:
- `agent_config`: the agent entry the run used, resolved: the catalogue's entry with the `farmy.yml`
  overrides applied (or the entry of your own), with its `name`.
- `agent_version`: what the entry's `version` command printed (surrounding whitespace removed), or null
  when the entry has none or it failed. A failing version command never stops the run.

A new catalogue field, `version`: a shell line that prints the CLI's version (`claude --version`). Every
catalogue entry states it (null where the vendor documents none). It runs once per run, before the first
iteration, in the service image `farmy/<name>:dev`, in a container of its own: `docker run --rm`, name
`<name>-run-<id>-version`, label `farmy.role=version` with the run's other labels, user `dev`,
`--network none`, the line run by `sh -c`, no volume. It needs no network: the CLI is in the image.

Left out: parsing usage into numbers; recording the gate's command the same way (its log names each
command and exit code already); pinning the CLI version (the agent entry's `install` does that, see
the docs record that follows).

Open:
- In token mode the token reaches the agent container as `-e NAME=value` on the `docker run` command
  line, so it is visible in the host's process list while the container is made (and in the fake
  docker's call log). Moving it to stdin or an env file is a hardening record of its own.

A note on separation: the shaper had read work/'s factory code earlier in this session, answering the
owner's questions about the run record. The tests below observe only the run folder, the fake docker's
record of each `docker run`, and the catalogue file, as before.

## Scenarios (FactoryRunRecordTest, and one in AgentsTest)

1. Each iteration's agent record names the service image and its id, the agent's exit code, and when it
   started and ended.
2. The agent's stdout and stderr are kept apart, each exactly as it was printed, and the record names both
   files.
3. The prompt each iteration was given is saved beside its record, exactly.
4. The recorded command is the docker run farmy made for the agent, with the token's value replaced by its
   name, and the value is in no file of the run.
5. A run keeps the agent entry it used, with its farmy.yml overrides, next to its profile.
6. The CLI's version is asked once per run, in the service image, without a network, by the catalogue's
   version command, and the run keeps what it printed.
7. An agent of your own may give a version command; the run keeps what it printed.
8. An agent without a version command runs as before, and its run keeps no version.
9. A version command that fails does not stop the run, and the run keeps no version.
10. (AgentsTest) Every catalogue agent states its version command.
