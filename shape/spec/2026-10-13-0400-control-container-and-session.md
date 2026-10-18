# 2026-10-13 04:00 — farmy in a control container, services as compose, a persistent session

The owner, after the farmy.yml piece: "I'm not sure if this is what I want. The whole premise should
be -> I pull repo on my machine (or someone pulls it in their laptop). There's no need to install any
dev tools besides having Docker. Then all the tools are installed on the Docker containers if
needed, nothing locally. User would set up container definitions on their own. Once this is
running, great thing would be to have tmux or whatever session that would monitor all running
containers in TUI with options to stop container, shut it down, restart it, start the
application, start the tests, etc. This would have to be preservable ... reopened or even
connected to from different device." And on the pieces: rename the credentials helper; the proxy
must not need two steps; sidecars are "lot of manual plumbing"; pins mean maintenance; the
toolbox is coupled to Debian "which we don't want in generic repo".

This record supersedes `2026-10-13-0200-farmy-yml-configuration.md` where they differ. It keeps
the shaper/worker layout, the port blocks, the clone inside the container, the token isolation,
and the test kit with its fake docker.

## What was decided

- **The host needs Docker and nothing else.** farmy itself runs in a **control container**
  (`farmy`), built from the repository, holding the farmy binary, the docker CLI with compose,
  git and tmux, with the Docker socket and the containers folder mounted (the folder at the same
  path as on the host, so that paths in generated compose files hold for the daemon). The
  repository ships a POSIX `sh` shim, `farmy`, that builds the control image when missing and
  runs commands in that container; it is the only thing that runs on the host. The control
  container runs no agent and no app: it is the one place the socket belongs.
- **farmy is written in Rust**, as a single binary, shelling out to `docker` and `docker compose`
  (so the test kit's fake docker still observes it). The two helpers, the keys proxy and the
  knowledge MCP, are rewritten in Rust as well, so the repository has one language. The acceptance tests run that binary
  directly (`bin/build` compiles it to `bin/farmy`); the shim and the control image are not
  under the suite and stay trivial.
- **A persistent session.** `farmy` with no arguments (or `farmy session`) attaches to a tmux
  session in the control container, created when absent: one window with the **TUI**, and a
  window per thing the user starts from it. The TUI lists every service with its state, ports
  and repository, and offers per service: start, stop, restart, rebuild, destroy, logs, a shell,
  and the service's own commands (`setup`, `start`, `test`, ...), each run in its own tmux window
  so that output and processes survive the terminal. Detach and the session stays; reattach from
  any terminal that can run the shim, including over ssh from another device. The TUI's state
  logic is unit-tested by the worker; the acceptance suite covers the commands it calls.
- **A service is a compose fragment plus a few farmy keys.** `services/<name>.yml` holds `repo`,
  `branch`, `image` or `dockerfile`/`target`/`build_files`, `ports`, `env`, `workdir`,
  `start_after`, **`commands`** (named commands run in the checkout: `setup` runs after the clone,
  the rest on demand: `farmy run hub test`, the TUI), and **`compose`**: verbatim compose
  services (and `volumes`, `networks`) that run next to the app and are reached by their names.
  No sidecar schema: Postgres is `compose.postgres: {image: postgres:18, ...}` in the user's own
  words, and `${FARMY_PORT_<n>}` in a fragment is the n-th port of the service's block, for
  publishing a database on the host. farmy adds the `app` container (`<name>`) and the keys
  helper (`<name>-keys`); everything else in the compose file is the user's. The database
  conveniences (`create_databases_from`, `schema_sql`, `seed_dump`) go: they are a `setup` command.
- **Keys: OPEN.** the owner, on the first draft of this record: "The keys shouldn't be defined, there
  should be only some example somewhere. But basically I'd not put the keys in the .env, for me
  they live in a keychain or in Infisical. The only key I'd define is key for unlocking infisical
  but even this one could be hidden and not in the .env potentially. So there needs to be another
  mechanism to define them." Settled so far: farmy ships no catalogue of keys; routes are the
  user's, in `farmy.yml` under `keys:`, with an example file to copy from; `.env` holds farmy's
  settings only, never a key. Being decided in a separate conversation: where the secrets come
  from (a secrets manager such as Infisical, the macOS Keychain, a command that prints them) and
  how the one unlocking secret reaches the control container. Until then the helper keeps its name
  `keys` (`<name>-keys`) and its contract (`FARMY_ROUTES`, `FARMY_ROUTE_<NAME>`), and no keys test
  is written.
- **The toolbox is a Dockerfile, not a pin list.** farmy's `toolbox/Dockerfile` builds on the
  service's image (`ARG BASE`), installs the basics with the image's own package manager (apt or
  apk, detected), creates the `dev` user, installs the agent CLIs named in `agents:` through their
  official installers, and sets the entrypoint that clones. A `toolbox/` folder in the containers
  folder replaces farmy's. Any image works, Alpine included; no `devbase`, no `pins.tsv`.
- **`farmy.yml` shrinks** to `keys:` (the routes), the secrets source (open, above), `agents:`
  (default `[claude]`) and `knowledge:` (the shared knowledge container, default on). Everything else lives in the
  service's definition.
- **The command line stays** where it still means the same: `init` (Docker, `.env`, the list of
  services), `start`, `stop`, `restart`, `rebuild`, `destroy`, `status`, `url`, `run`, `ssh`,
  `logs`, `keys`, `session`, `help`; exit codes 0/1/2 as before. `run <svc> <name>` runs the named
  command of the service, or the words as a command when no command has that name.

## Left out

- A web terminal in the control container (reachable from a phone without ssh): a later piece.
- Running the control container's TUI through the acceptance suite.
- The knowledge MCP's content; it stays as it is, switchable off.

## Still open

- The secrets mechanism (above), and with it the keys tests of the scenario list.

- Whether the shim should also offer `farmy update` (pull the repository, rebuild the control
  image).
- The four roles per repository and the harness, as before.

## Scenario list

The existing tests keep their meaning except where a decision above changes it; those are
rewritten and listed here with the new ones. Files under `test/farmy/`.

Changed in existing files
- `config_test.rb` keeps only "an unknown key in farmy.yml is refused by name".
- `services/<name>.dev.yml` becomes `services/<name>.yml` everywhere (fixtures, messages).
- `hub-creds` becomes `hub-keys`; `FORGE_TOKEN` reaches only the keys helper (credentials_test.rb
  → keys_test.rb).
- The Postgres and Redis of `hub` come from its `compose:` fragment, which names its containers
  `hub-pg` and `hub-redis` and its volume `hub-pg-data`, so the names in the start, stop and
  destroy tests hold.
- The three database tests (create_databases_from, schema_sql, seed_dump) and the sidecar,
  app-defaults and toolbox tests of the farmy.yml piece are removed.

compose_test.rb
- the compose services a definition lists run next to the app and are reached by their names
- the volumes and networks a definition declares are passed on as they are
- ${FARMY_PORT_<n>} in a fragment is the n-th port of the service's block
- a fragment that defines a service named app or keys is refused

commands_test.rb
- the setup command runs in the checkout after the clone, as the dev user
- a service with a workdir runs its commands there
- run with a command name runs that command of the service
- run with words that are no command name runs them as they are
- a definition without commands starts with no setup

keys_test.rb (not written: waits for the secrets decision)
- a known key set in .env reaches only the keys helper, routed to its upstream
- the app container gets the variable a known key exposes, pointing at the route
- keys lists every key set in .env and where it goes
- a key farmy does not know is given to no container and keys says so
- a known key that is not in .env is no route
- an upstream added in farmy.yml under keys is routed like a known one
- FORGE_TOKEN is the git route to FORGE_URL

toolbox_test.rb
- the app image is built from the service's image with farmy's toolbox Dockerfile
- a toolbox folder in the containers folder is built instead of farmy's
- an Alpine image is accepted
- with Claude not among the agents the app container gets no Claude settings
- with the knowledge container switched off nothing shared starts
