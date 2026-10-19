# Install guards: a limit on the build's version check, no piped downloads, the guide's pins

Three loose ends of 2026-10-19-1430, closed before the owner's Mini round (the owner, 2026-10-19):

- **A 30 s limit on the build's as-dev version check.** Each agent's version line runs under `timeout 30`; one
  that does not answer fails the build, naming the agent and the limit, instead of hanging it.
- **Download, then run.** No catalogue install line pipes a download into a shell. With `curl … | sh` a failed
  download runs an empty script and the step passes; the failure then shows only at the as-dev check, as a
  missing CLI. The owner allowed `set -o pipefail` or download-then-run; download-then-run is the one that
  works everywhere: install lines run under `sh`, which on Debian bookworm is dash, without `pipefail`.
- **The guide keeps the rules.** `docs/factory.md`'s pinning examples installed Claude Code as dev into
  `/home/dev/.local` and Codex through `curl … | sh` without `CODEX_HOME` (so under `/root`, the Mini's fault
  again). Every install line in the guide's code blocks keeps the catalogue's rules: as root, outside any
  home, download then run.

Also, for running the real-Docker tests on a Docker-only host: the suite's per-command watchdog (60 s) can be
raised with `TEST_COMMAND_TIMEOUT`, since a cold real build (the control image, agent installs) takes longer.

Left out: a limit on install lines themselves; agents of your own (their install lines are the user's).

## Scenarios

AgentCliAsDevTest:
1. farmy's toolbox build gives each agent's as-dev version check 30 s, so a version command that never answers
   fails the build instead of hanging it.
2. No catalogue install line pipes a download into a shell: each downloads to a file and runs it, so a failed
   download fails the install step.
3. Every install line the factory guide shows, the Claude pin included, runs as root outside any home and
   downloads before it runs.

AgentCliIntegrationTest (real Docker):
4. A toolbox build whose agent's version command never answers fails after 30 s, naming the agent and the limit.
5. An agent whose install download fails fails the build at the install step, naming the agent and the
   download's error.
