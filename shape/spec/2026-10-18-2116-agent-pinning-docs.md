# Docs: pinning an agent's model, effort and CLI version for factory runs

For the owner's experiment every run must use the same model, reasoning effort and CLI version. A factory
profile has no fields for them, and none are wanted: they belong to the agent, and the agent entry in
`farmy.yml` already overrides the catalogue field by field. What is missing is the guide. The run record
(2026-10-18-2016) shows afterwards what each run used (`agent_config`, `agent_version`).

Decided (the owner, 2026-10-18): `docs/factory.md` gets a section on pinning through the agent entry, with
a Codex example, and documents only flags that exist in the pinned CLI version.

Checked against Codex at rust-v0.163.0 (its source, 2026-10-18):
- no reasoning-effort flag on `codex exec` or the top-level command; effort is the config key
  `model_reasoning_effort`, set with Codex's global `-c key=value` (declared `global = true` on the top-level
  command, so it may stand after `exec`); known values none, minimal, low, medium (default), high, xhigh,
  max, ultra (which a model accepts depends on the model);
- the model: `-m/--model`;
- an exact version: the official installer takes `CODEX_RELEASE=<x.y.z>` (or `--release`), with
  `CODEX_INSTALL_DIR` and `CODEX_NON_INTERACTIVE`, verifies the download's checksum and that the installed
  binary reports that version;
- `codex exec --json` writes JSON events to stdout; `turn.completed` carries `usage` (input, cached input,
  output and reasoning tokens): with the run record, stdout is the usage report.

Claude Code (code.claude.com docs, 2026-10-18): the model with `--model`; effort with the variable
`CLAUDE_CODE_EFFORT_LEVEL` (low, medium, high, xhigh, max, auto), which overrides `--effort`; an exact version
with the native installer's version argument (`bash -s <version>`); the apt repository documents no version
pin. `--output-format json` puts the result with `usage` and `total_cost_usd` on stdout.

The guide says that overriding `headless`, `env` or `install` replaces that whole field, that a changed
`install` needs `farmy rebuild <service>`, that factory runs do not read the interactive login's user
configuration (no `farmy-shared`), and that a factory login volume (mode `login`) is the CLI's home folder,
so a configuration file there would apply: keep pins on the command line, which wins over the file.

## Scenarios (DocsTest)

1. The factory guide shows how to pin the model, the effort and the CLI version through the agent entry,
   with Codex's flags and Claude's effort variable, and points at the run record.
2. The factory guide names no Codex reasoning-effort flag, since Codex 0.163.0 has none.
3. The factory guide's Codex pin is a farmy.yml agent entry that farmy accepts as written.
