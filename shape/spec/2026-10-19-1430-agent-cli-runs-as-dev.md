# Every agent's CLI runs as dev, checked when the toolbox builds

Found on the owner's Mac mini, 2026-10-19, blocking 0.1.1: in a built app image `/usr/local/bin/codex` was a
symlink to `/root/.codex/packages/standalone/current/bin/codex`. As dev (uid 1001) `codex` said
`Permission denied` (root's home is closed to others), so `farmy factory login <service> codex` failed and
codex was unusable as dev in every app container. The factory login's volume at `~/.codex` could also hide an
install living under `.codex`.

A read-only work-side helper read the catalogue and the vendors' installers (2026-10-19):

- codex: `curl … install.sh | CODEX_INSTALL_DIR=/usr/local/bin … sh`. The installer keeps its package in
  `${CODEX_HOME:-$HOME/.codex}` and `CODEX_INSTALL_DIR` only places the symlink: run as root, under `/root`.
- cursor: `su dev -c 'curl https://cursor.com/install … | bash'`: the CLI lives under
  `/home/dev/.local/share/cursor-agent`, linked from `~/.local/bin`. It runs, but it is the same pattern (a
  CLI in a home directory).
- claude (apt/apk package), gemini, opencode, copilot (npm global): outside every home, root-owned.
- The toolbox ran nothing as dev after installing, and agents.tsv carried no version command.
- The run record's version check runs as dev; a failing command was thrown away with its stderr, so the
  Mac's run would have kept `agent_version: null` with no reason, the same as an agent without a version
  command.

Decided (the owner, 2026-10-19), before 0.1.1:

- The catalogue installs every agent's CLI outside any home directory (`/root`, `/home/…`), owned by root and
  executable by all; no catalogue install line runs as dev or names a home directory. Codex's moves to a
  release binary under `/usr/local` (the owner suggested pinning it through `CODEX_RELEASE`; how is the
  worker's choice, a test does not pin it). Cursor's moves out of dev's home.
- agents.tsv gains a column, `version`, after `process`: the agent's version line, empty when it has none.
- farmy's toolbox, once the agents are installed, runs each agent's version line as dev; one that fails
  fails the build, naming the agent and what the command said. An install like the Mac's then fails the build
  instead of the run.
- A version command that fails keeps `agent_version: "unknown"` in the run record, with
  `agent_version_reason` giving its exit code and the last line of its stderr. This supersedes the rule of
  2026-10-18-2016 / 2026-10-19-0940 that a failing command leaves null; one that succeeds and prints nothing
  still leaves null. The run goes on either way.

Changed: FactoryRunRecordTest "a version command that fails …" now expects `unknown` with the reason.

Real Docker: the build check and the per-agent checks are integration tests, skipped here (no real Docker);
the owner rebuilds and retries the login on the Mini. Left out: pinning the other agents; stopping a run
whose CLI cannot run; a custom toolbox's own checks.

## Scenarios

AgentCliAsDevTest:
1. agents.tsv gives each agent its version line in a column after process.
2. farmy's toolbox build runs a step as dev after installing the agents, where each agent's version line is
   tried as the user who will run it.
3. No catalogue agent's install line runs as dev or names a home directory.

FactoryRunRecordTest:
4. A version command that fails does not stop the run; the run keeps agent_version unknown and a reason with
   its exit code and what it said on stderr (changed).
5. A CLI that dev may not execute is recorded as agent_version unknown with the reason, Permission denied and
   its exit code.

AgentCliIntegrationTest (real Docker):
6. In a real Debian app image each catalogue agent's CLI answers its version line as dev and lives outside
   every home directory (one test per agent).
7. A toolbox build whose agent CLI dev cannot execute (codex installed under /root, linked from
   /usr/local/bin) fails, naming the agent and Permission denied.
