# 2026-10-13 10:00 — Workbench services, mounts, the reload lifecycle, and the Debian rule

Four reviews of the test list (the compressed inventory of every acceptance test) came back at once.
This record takes what holds, corrects what the reviewers could not see, and sets the contract for
the pieces that were missing before the first run on a real machine. The factory loop (runs, gates,
mission control) is deliberately not in it: that record comes after the first run.

## What the reviewers got right

- **Reload and "missing" contradicted each other.** A route whose secret the provider did not have
  got no `expose`/`placeholder` variable in the app container, yet `farmy keys reload` promised to
  load the broker without touching the containers. A running app could never learn the broker's
  address. Decided: **every granted route is configured in the app container at start, whatever
  the secret's state.** The broker answers 503 until it is loaded; `keys reload` loads it; a load
  without a secret unloads it (503 again). The container is never recreated for a secret.
- **Bare `farmy`.** The shim attaches to the session on a terminal; the binary with no arguments
  prints the usage. Without a terminal the shim must not try to attach: it prints the usage too.
  The usage lists every command, `keys`, `keys reload`, `logs`, `ssh` and `session` included.
- **`init` on a host without git.** The host needs Docker only, so `git config` may not exist, and
  the control container never sees the host's git configuration. Decided: the identity comes from
  `GIT_USER_NAME` / `GIT_USER_EMAIL` in `farmy init`'s environment first (the shim passes the host's
  git configuration that way when the host has git), then the global git configuration, then a
  question on a terminal, else a warning and the key left for the owner.
- **A service without a repository.** A workbench: `repo: none` gives an empty `/workspace`
  volume and no clone; the developer clones what they want inside, and those clones go through the
  broker or the agent socket like any other. No `FORGE_OWNER` needed.
- **Mounts on the app container.** What is installed outside `/workspace` (gem and npm caches,
  `~/.cache`) vanished at `restart`. Decided: `mounts:` in the definition, name → path, each on a
  volume `<service>-<mount>`; kept by `stop` and `restart`, removed by `destroy`. Named volumes
  only; the entrypoint makes them the dev user's.
- **Alpine.** Scoped to farmy's own three images (control, keys, knowledge), which run static Rust
  binaries. A service runs on the image it names; the docs recommend the official Debian `-slim`
  images; Alpine services are accepted and only their build is checked. The apt path of the toolbox
  is the supported one, apk is best effort.
- **`services/<name>.env` wording.** It is agent-readable like everything in the container, so it is
  for settings, not secrets; the example in the test is no longer a master key.
- **The secret guarantee is mode-specific** and already says so (FORMATS.md, Claude in a container).
  Noted for the factory record: api-key mode is the default there, subscription an explicit opt-in.
- **The count.** The inventory said 103 tests; the per-file numbers sum to 100 (3 of them the
  integration tests). 100 is right.

## What they could not see

- **Setup after rebuild.** Two reviewers believed `setup` runs only after the clone. It runs at every
  `start`, `restart` and `rebuild` of the containers once the clone is there, from the host. Nothing
  changes.
- **`localhost` from inside a container.** `${url:hub}` is one URL for the browser and the container:
  the entrypoint forwards each referenced host port to `host.docker.internal`, and the compose file
  adds `extra_hosts: host.docker.internal:host-gateway` for Linux engines. What stands: no real
  request was ever made; the integration tests get one.
- **The knowledge container** serves five read-only tools over MCP (status, service, list_docs,
  read_doc, search_docs). It was pinned only as "starts". It gets its own test file against the
  binary, like the broker.

## What nobody saw

A definition with neither `image:` nor `dockerfile:` quietly built the repository's own
`Dockerfile`, which for a Rails app is the production image (`RAILS_ENV=production`,
`BUNDLE_WITHOUT=development`, a `rails` user). Decided: **one of `image:` or `dockerfile:` is
required**, refused by both names when absent; the docs warn about generated production
Dockerfiles and recommend `image: ruby:3.4-slim` for development.

## Left out, on purpose

- The factory loop and mission-control state: after the first run.
- A test of the shim through the fake docker: the shim builds the control image from the work folder,
  which the fake would hash whole; it stays under the integration tests, which gain "bare `farmy`
  without a terminal prints the usage".
- A real SSH clone against an SSH server: the first-run script, step 3.
- Egress control.

## Tests altered

- `help_test.rb`: the usage lists `keys`, `keys reload`, `logs`, `ssh`, `session` as well.
- `start_test.rb`, "a services/<name>.env file reaches that app container": the example is a setting
  (`RAILS_MAX_THREADS=5`), not a master key.
- `keys_test.rb`: "a route whose secret the provider does not have" now expects the route to be
  configured in the app and unloaded in the broker; "a provider that fails" expects the same; "keys
  reload" works on a service in api-key mode and expects the base URL before and after.
- `integration_test.rb`: the Debian build is the required one, the Alpine build optional; a real
  request between two services; bare `farmy` without a terminal.

## Scenario list

help_test.rb
- farmy with no arguments prints the usage with every command (now: keys, session, logs, ssh too)

init_test.rb
- init takes the identity from GIT_USER_NAME and GIT_USER_EMAIL in its environment when the host has no git configuration

defining_services_test.rb
- a definition with neither image nor dockerfile is refused by both names
- repo: none starts a workbench: an empty workspace volume, no clone, no FORGE_OWNER needed
- status shows a workbench's repository as none

mounts_test.rb
- a mount keeps a folder of the app container on a volume named after the service and the mount
- stop and restart keep a mount's volume, destroy removes it

keys_test.rb
- a route whose secret the provider does not have is configured in the app, unloaded in the broker, and keys says missing
- a provider that fails switches its routes to provider failed, says so without its output, and start goes on
- keys reload loads a missing secret into the running broker and the app keeps pointing at the route

broker_test.rb
- a load without a secret unloads it and the route answers 503 again

knowledge_test.rb
- the knowledge server lists its five read-only tools
- status reads the snapshot farmy wrote and tells the agent to refresh it with farmy status
- search_docs answers with file and line

integration_test.rb
- the toolbox builds on a Debian slim image (required), on Alpine (optional)
- a request from one service reaches another through ${url:x}
- bare farmy without a terminal prints the usage
