# 2026-10-13 18:00 — Mission control

The TUI exists and runs on the Mini. These are the first things missing from it. The acceptance
tests pin the data, not the drawing: `farmy status --json` is what the TUI renders from, and
every test here reads that.

## Decided

1. **Refresh.** The TUI re-reads the state after every action; between actions it follows
   `docker events` for the farmy containers, with a poll every few seconds as a fallback. `R`
   stays. (Not under the suite: the TUI is not.)
2. **Sidecars.** For the selected service, every container of its compose project with its state
   and health, in the bottom pane. In the JSON: `containers: [{name, service, state, health}]`,
   `health` being `healthy`, `unhealthy`, `starting` or null for a container without a healthcheck.
3. **App running.** For each `ports:` pair, whether something listens on the container port:
   farmy reads `/proc/net/tcp` and `/proc/net/tcp6` through `docker exec` (no tool needed in the
   image). In the JSON: `ports: [{host, container, url, lan_url, listening}]`; `lan_url` is set
   when `LAN_HOST` is; `listening` is true, false, or null when the service is not running.
4. **Agent activity.** A column from a status file on the service's own Claude volume,
   `/home/dev/.farmy-service/claude/agent.status`, written by Claude Code hooks (SessionStart,
   UserPromptSubmit, Stop, Notification) the entrypoint registers once, next to the MCP
   registration: `working` (with how long), `waiting` (for input), `idle`. Without the file,
   `docker top` is the fallback: a `claude` or `codex` process means `running`, else `idle`. In
   the JSON: `agent: {state, since, source}` with `source` `hooks` or `process`, or null when the
   service is not running.
5. **Key bar.** `a` add (asks for the URL and the image), `k` keys reload. `TZ` from the host
   reaches the control container, so the tmux clock is local: the shim passes `TZ` when set, else
   the zone `/etc/localtime` points at.

## The status file

`agent.status` is one line: `<working|waiting|idle>\t<RFC 3339 time it began>`. The hooks
overwrite it; SessionStart and Stop write `idle`, UserPromptSubmit `working`, Notification
`waiting`. It lives on the service's volume because an agent's state is project state.

## `farmy status --json`

```json
{"generated": "2026-10-13T18:00:00Z", "lan_host": "mini.local",
 "services": [{"name": "shop", "state": "running", "block": "3100-3199",
   "repo": "https://github.com/acme/shop.git", "note": null, "commands": ["setup", "start", "test"],
   "ports": [{"host": 3100, "container": 3000, "url": "http://localhost:3100", "lan_url": "http://mini.local:3100", "listening": true}],
   "containers": [{"name": "shop", "service": "app", "state": "running", "health": null},
                  {"name": "shop-pg", "service": "postgres", "state": "running", "health": "healthy"}],
   "agent": {"state": "working", "since": "2026-10-13T17:58:10Z", "source": "hooks"}}]}
```

`block`, `repo` and `note` are what `status` prints; `commands` the names under `commands:`.

## The fake docker

Three things it learns, all state a test sets: a container's health from its compose
`healthcheck:` (healthy, by default); what a test says is listening in a container
(`listening "shop", 3000`), answered to a read of `/proc/net/tcp`; files a test puts on a volume
(`volume_file "shop-claude", "agent.status", "…"`), answered to a `cat` of their path; and the
processes a test says run in a container (`process_in "shop", "claude"`), answered by `docker
top`.

## Scenario list

status_json_test.rb
- status --json lists every service with its state, block, repository and commands
- status --json lists every container of a service with its state and its health when it has a healthcheck
- status --json says for each ports pair whether something listens on the container port
- status --json gives the LAN address of each port when LAN_HOST is set
- status --json shows the agent's state from the status file the hooks write
- status --json falls back to the processes in the container when there is no status file
- status --json shows null for ports and agent of a service that is not running

shim_test.rb
- the control container gets the host's TZ

help_test.rb
- the usage says that status --json exists
