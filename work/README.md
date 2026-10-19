# farmy — one set of containers per repository

`farmy` runs one set of containers per repository: an app container with the repository cloned
inside and the tools an agent or a developer needs, whatever runs next to it (Postgres, Redis,
Mailpit, in plain compose), and a small keys broker that holds the secrets so the app container
never does. A persistent session shows every service and lets you start, stop, open a shell or
run the service's own commands, from any terminal that can reach the machine.

> New here? Read [docs/getting-started.md](docs/getting-started.md). Then
> [docs/troubleshooting.md](docs/troubleshooting.md) when something goes wrong,
> [docs/architecture.md](docs/architecture.md) for images, containers and volumes,
> [docs/credentials.md](docs/credentials.md) for keys and secrets,
> [docs/farmy-mcp.md](docs/farmy-mcp.md) for what an agent knows inside a container,
> [docs/factory.md](docs/factory.md) for factory profiles, gates, reviews and questions,
> [docs/mesh-egress.md](docs/mesh-egress.md) for enforced egress and a private mesh,
> [docs/distribution.md](docs/distribution.md) for installation, releases and compatibility,
> [docs/editor-integration.md](docs/editor-integration.md) for editors, and
> [docs/worked-example.md](docs/worked-example.md) for a Mac with the Keychain, Infisical and a Headscale mesh.

## The premise

The host needs Docker and POSIX utilities. Pipe the latest GitHub release's `install` asset to
`sh`, or download it with `SHA256SUMS`, run `sha256sum --check SHA256SUMS`, then `sh ./install`;
either installs that release's `~/.local/bin/farmy` and prints the `PATH` line when the folder is
not on `PATH`. Public defaults come from `release.yml`; `FARMY_REGISTRY` and `FARMY_SOURCE`
override the registry and the matching mirror-tag source context. See the
[root README](../README.md#install) for asset links.

`farmy` with no arguments attaches to the persistent session: the TUI, kept alive by tmux so that
it survives your terminal (tmux itself never shows: no keys, no status bar). An action's output
streams into a pane of the screen; a shell or the logs take the terminal over and give it back.
`q` leaves, the session stays. Close the laptop, ssh in from another device, run `farmy` again,
and you are back where you were. `farmy update` installs the folder's exact `farmy:` pin, otherwise
the latest release; `--to VERSION` chooses explicitly. In a checkout, `init` rebuilds cached control
when its source inputs change, even at the same version. `FARMY_BUILD=1` skips the initial published
pull and also enables source caching for targetless `update`. See
[distribution](docs/distribution.md) for registry examples, source fallback and format checks.

## Layout

The farmy checkout (this repository) and your containers folder are two different places.

```
farmy/                        the checkout; nothing of yours lives here
  farmy                       the shim: builds the control image, runs commands in the control container
  Dockerfile                  the control image
  gate.Dockerfile             the filtering proxy's image (farmy-gate:local)
  egress-hosts.yml             named destination sets for app policies
  keys.Dockerfile             the keys broker's image      (farmy-keys:local)
  knowledge.Dockerfile        the knowledge container's image (farmy-knowledge:local)
  toolbox/                    the Dockerfile the app images are built with, and the entrypoint
  providers/                  secrets providers to copy or use as they are (env, infisical)
  farmy.example.yml           the usual farmy.yml, to copy from
  .env.example                the usual .env, to copy from (farmy init does it)
  crates/                     the Rust sources: farmy, farmy-keys, farmy-knowledge
  docs/                       what the links above point at
  bin/verify                  runs the acceptance suite from outside (bin/build compiles with cargo)

~/containers/                 your containers folder; farmy runs in it
  services/shop.yml           one definition per service: repository, image, ports, commands, sidecars
  services/shop.env           optional: settings for that service's app container only (readable inside; no secret)
  .env                        this machine's settings (the Git identity, LAN_HOST); no secret
  farmy.yml                   optional: the secrets provider, the routes, agents, the knowledge container
  toolbox/                    optional: a Dockerfile that replaces farmy's toolbox
  .work/                      farmy's state; nothing in it is promised, nothing in it is a secret
```

Put the shim on your PATH (`ln -s ~/farmy/farmy ~/bin/farmy`) or call it by path. Every command
reads and writes the folder you are in.

## Quickstart

```sh
git clone https://github.com/acme/farmy.git ~/farmy
mkdir ~/containers && cd ~/containers
~/farmy/farmy init                  # builds the control image, writes .env, lists the services (none yet)
~/farmy/farmy add https://github.com/acme/shop.git --image ruby:3.4-slim   # writes services/shop.yml
~/farmy/farmy start shop            # images, containers, the clone, the setup command
~/farmy/farmy                       # the session
```

`farmy init` writes `.env` with the Git identity your host's git is configured with (the shim passes
it in; without git on the host, farmy asks). That identity and an optional `LAN_HOST` are all
`.env` holds. For private repositories, add a git route for the host and a secrets provider: see
"Keys and secrets".

## Adding a service

In the containers folder:

1. `farmy add <url> --image <image>` writes `services/<name>.yml` with the repository and the image;
   the name is the last part of the URL (`--name` for another). Or write the file by hand.
2. Write its definition, `services/<name>.yml`. Three examples:

   A Rails app on a stock image, with Postgres and Redis next to it:
   ```yaml
   # services/shop.yml
   repo: https://github.com/acme/shop.git   # the clone URL as you paste it; required
   image: ruby:3.4-slim           # the toolbox is built on it: an official Debian image (see "Images")
   ports: ["3100:3000"]           # host:container; the hundred the host port is in (3100-3199) is the
                                  # service's block, ${FARMY_PORT_<n>} below is its n-th port
   env:
     DATABASE_URL: postgres://postgres:postgres@postgres:5432/shop_development
     REDIS_URL: redis://redis:6379/0
   commands:                      # run in the checkout as the dev user
     setup: bin/setup --skip-server   # at every start, once the clone and the healthy sidecars are there
                                  # (Rails' bin/setup starts the server unless --skip-server is passed)
     start: bin/rails server -b 0.0.0.0
     test: bin/rails test
   compose:                       # plain compose services next to the app, reached by their names
     postgres:
       image: postgres:18
       container_name: shop-pg
       environment:
         POSTGRES_PASSWORD: postgres
       ports: ["127.0.0.1:${FARMY_PORT_32}:5432"]   # 3132: the service's block starts at 3100
       volumes: [pgdata:/var/lib/postgresql]
       healthcheck:             # with one, the app container and its setup wait for it to be healthy
         test: ["CMD", "pg_isready", "-U", "postgres"]
         interval: 2s
         retries: 30
     redis:
       image: redis:7
       container_name: shop-redis
   volumes:
     pgdata:
       name: shop-pg-data
   ```
   A Vite front end that talks to shop and starts after it:
   ```yaml
   # services/notes.yml
   repo: https://codeberg.org/acme/notes.git
   image: node:22-bookworm-slim
   ports: ["3200:5173", "3201:24678"]
   start_after: [shop]            # farmy start notes starts shop first
   env:
     VITE_API_URL: ${url:shop}    # http://localhost:3100 (LAN_HOST instead of localhost when set)
     API_PORT: ${port:shop}       # 3100
   commands:
     setup: npm install
     start: npm run dev
   ```
   A CLI built from a stage of its own Dockerfile:
   ```yaml
   # services/toolkit.yml
   repo: https://github.com/acme/toolkit.git
   dockerfile: Dockerfile
   target: base                   # the stage to build: runtime and deps, not the one that COPYs the source
   build_files: [Gemfile, Gemfile.lock]   # what that stage COPYs; fetched with the Dockerfile
   branch: main                   # no ports: — a CLI publishes nothing
   ```
   A workbench: no repository of its own, an empty `/workspace` to clone into by hand (every clone
   goes through the keys broker or the agent socket like any other), and a cache kept across restarts:
   ```yaml
   # services/bench.yml
   repo: none
   image: debian:bookworm-slim
   mounts:
     cache: /home/dev/.cache        # on the volume bench-cache; kept by stop and restart, removed by destroy
   ```
3. `farmy start <name>`.

The keys of a definition: `repo` (a clone URL, or `none` for a workbench; required), `branch`,
`image` or `dockerfile` + `target` + `build_files` (one of the two is required), `ports`
(`host:container` pairs; without it nothing is published), `workdir` (the folder of the repository the app lives in), `mounts` (name → path:
folders of the app container kept on volumes `<name>-<mount>`), `start_after`, `env` (with
`${url:x}` and `${port:x}`), `commands`, and `compose`, `volumes`, `networks` passed to compose as
they are. farmy adds the `app` service (container `shop`, the checkout on the volume
`shop-src` at `/workspace`) and `keys` (container `shop-keys`); a fragment that defines a service of
either name is refused. Every container gets `init: true` unless the fragment sets `init` itself.

Ports: a service owns the hundred its host ports lie in (`3100:3000` → the block `3100-3199`); all
its host ports stay in that hundred, no two services share one, and `${FARMY_PORT_<n>}` in its
fragment is the block's n-th port. A definition without `ports:` publishes nothing. When another
definition refers to it with `${url:x}` or `${port:x}`, or its own fragment uses
`${FARMY_PORT_<n>}`, `farmy start` and `farmy status` give it the next free block from 3100 up,
write `ports: ["<port>:3000"]` into its definition and say so; edit the container port if the
app listens elsewhere.

`services/<name>.env`, when present, is environment for that app container only. The agent inside
can read it, like everything in the container: settings go there, secrets go through routes. The
full key list is in [FORMATS.md](FORMATS.md).

## Keys and secrets

No secret lives in `.env` or in any file farmy writes. Routes are defined in `farmy.yml` under
`keys:`: an upstream, how the secret is sent, which secret, and optionally the variable the app
gets. Without a secrets manager the shim asks for each route's secret on this machine (a prompt,
the Linux secret service, a command of yours, the macOS Keychain); with one, a provider (a program
farmy runs) yields them. farmy loads them into the running keys broker next to each app container
over a private socket, and the broker adds them on the way out.
The app container reaches `http://keys:9181/anthropic/...`; it never sees the key. Every route a
service may use is configured when its containers are made, whether or not the secret was there:
the broker answers 503 for an unloaded route until `farmy keys reload` loads it, and no container
is made anew for a secret. Copy the routes
you need from [farmy.example.yml](farmy.example.yml), which as shipped fits a GitHub token and an
Anthropic API key with no secrets manager; the full story, the sources on this machine and the
provider protocol are in [docs/credentials.md](docs/credentials.md).

A route may also be `auth: ssh`: the secret is an OpenSSH private key, the broker runs an SSH agent
with it and shares only the agent's socket with the app container, so git over SSH works there and
the key never leaves the broker. A git route applies to the repositories on its host (the host of
its `upstream`); there may be one per host. Without a git route for a host, only its public
repositories clone, and `start` says so by host; a git route whose secret is not loaded lets nothing
on its host clone (the broker answers 503 for it), and `start` names the route and its state.

An agent is data: an entry in farmy's catalogue (`agents.yml`: Claude Code, Codex, Gemini CLI,
OpenCode, Cursor, Copilot) or one of your own under `agents:` in `farmy.yml`, with the same fields
(how to install it, where its login lives, how to log in without a browser, a token variable, its
API variables, …). None is on unless `farmy init` was told or `agents:` in `farmy.yml` says so. Each
has a mode per service: `subscription` (the default; its own login, shared
across containers, or a token from the provider put into the container's environment, the one
documented exception to the rule above), `api-key` (through the broker, billed per token) or
`off`. Each service keeps the agents' transcripts on its own volume. `farmy agents` lists them;
see [docs/credentials.md](docs/credentials.md), "Agents inside the container".

## Egress

Set `egress.restrict: true` in `farmy.yml`, or `restrict: true` in one service definition, to
put apps on internal Docker networks with a filtering HTTP/CONNECT proxy as their only route
out. Apps may reach package registries, enabled agents' API hosts, configured git hosts and
your extra destinations. Factory agents always use an internal network and a policy limited
to their selected agent's API hosts. A service cannot opt out of a global restriction.
For interactive agents using WebFetch, `restrict: audit` permits destinations through the
gate and records each host/port once per container. The strongest global or definition setting
wins: strict, audit, unrestricted. Factory policy stays strict.

`farmy egress` manages allowances and event logs. `farmy egress allow HOST [--service NAME]`
saves an app allowance and reloads running gates
without recreating containers. `farmy egress log [SERVICE]` shows readable timestamp, service,
container, host:port and decision fields; `--json` emits NDJSON. Status and the session show
each service's mode and denial count, including retained factory denials. Audit observations
do not count as denials.

Filtering can use an existing HTTP proxy or a private mesh (Tailscale or Headscale) upstream.
Mesh configuration starts `farmy-egress` on the shared network and joins by auth key or a
registration URL; its persistent volume keeps registration across starts. Unrestricted
containers keep their direct internet. A filter-only egress map creates no mesh node.
See [docs/mesh-egress.md](docs/mesh-egress.md).

## Commands

```
farmy                         attach to the session (the TUI); also: farmy session. Without a terminal: the usage
farmy session --background    make sure the session runs, without attaching
farmy init                    prepare this folder: Docker, .env, the list of services (the shim: the control image)
farmy add <url> [--image X] [--name N]   write services/<name>.yml with repo: and image:
farmy start <name>...         start a service's containers (and what it start_after), then its setup command
farmy stop [<name>...]        stop containers; none named: everything, the knowledge container too
farmy restart <name>...       make the containers anew from the definition as it is now
farmy rebuild <name>...       the same, and build the images again from scratch
farmy destroy <name>...       remove containers and volumes; asks "y" first
farmy status [--json]         every service: name, state, port block, repository, addresses, notes;
                              --json: the same with containers, health, what listens, the agent's state
farmy url <name>              the service's addresses on the host, one per line
farmy run <name> <command>    a named command of the service, or the words as a command
farmy keys                    every route, its upstream, its state and who may use it
farmy keys reload [<name>...] obtain the secrets again and load the brokers
farmy toolbox list --json     the vendor tool catalogue with resolved versions and artifact pins
farmy toolbox bump [tool...]  verify releases and atomically update selected tools.lock entries
farmy dotfiles pull           fast-forward the shared clone and apply it to every running app
farmy factory pipeline start <service> <pipeline> --task <text|file> [--wait]
                              run profiles in order with pinned approvals and question handoffs
farmy factory show <id>       the run or pipeline result, gate evidence and comparison link
farmy factory login <name> <agent>   make the agent's own subscription login for factory runs (mode: login)
farmy agents                 the agent catalogue, enabled modes and login instructions
farmy lock                   forget held unlocking values
farmy logs <name>             follow the containers' logs
farmy ssh <name>              a shell in the app container, as the dev user
farmy egress allow <host> [--service name]   save and live-reload an app allowance
farmy egress log [name]        the latest 100 denied destinations
farmy update [--to VERSION]    install the folder pin or newest release (the host shim)
farmy help                    the usage
```

Exit codes: 0 done or nothing to do, 1 refused (something to fix first; the message names the
file, key or command), 2 a mistake in the command line. Waiting factory commands also use 2 for a
review or question pause. Refusals and warnings go to stderr.

In the session: the arrows (or `j`) move, `s` start, `x` stop, `r` restart, `D` destroy (asks),
`l` logs, `e` shell, `c` a command (a name from `commands:` or any words), `a` add a service (the
URL and the image are asked), `k` keys reload, `R` refresh, `q` leave (the session stays). An
action's output streams into the pane at the bottom: the arrows and PageUp/PageDown scroll it,
Esc closes it when the action is done. The screen is re-read after every action, when Docker
reports a container event, and every few seconds; without a pane open, the bottom shows the
selected service's containers with their health, its ports with whether something listens on
them (and the LAN address when `LAN_HOST` is set), and the agent's activity.

## Images

farmy's own containers (the control container, the keys broker, the knowledge container) are
Alpine because they run static binaries and small is all that matters. Your service runs on the
image you name, and there is no default. Use an official Debian-based image: `ruby:3.4-slim`,
`node:22-bookworm-slim`, `python:3.12-slim`. An Alpine service builds, but prebuilt tools and
native extensions may require glibc. Tool selections require an actual compatible vendor artifact;
shared editor data is partitioned by architecture, libc, and selected tool versions.

## Volumes

The rule: shared across containers → `farmy-shared`; project state → per-service volumes; binaries
→ the image. `farmy-shared` is one volume mounted in every app container at `/home/dev/.farmy-shared`,
a folder per tool inside it for what a tool keeps per user: the agents' logins (`~/.claude`,
`~/.codex`, … are links into it, from each entry's `login` paths). A persistent private
`<name>-home` volume holds each service's remaining home. Only names in `shared_data` (default
`[nvim]`) share `~/.local/share/<name>` and `~/.cache/<name>`, partitioned by platform and tool
versions. `shared_logins: false` exposes only the dotfiles and tool-data subdirectories.
Per-service: the checkout (`<name>-src`), the definition's `mounts:`, and the agents' state
(`<name>-agents`, with `~/.claude/projects` and the like links into it, from each entry's `state`
paths), so no service reads another's sessions. `destroy` removes a
service's volumes and never `farmy-shared`.

`dockerfile:` builds a stage of the repository's own Dockerfile instead. Use it only for a stage
written for development. The Dockerfile `rails new` generates (and most generated ones) is a
production image: `RAILS_ENV=production`, `BUNDLE_WITHOUT=development`, its own `rails` user; its
`base` stage gives you a container that refuses `Gemfile` edits. For a Rails app, `image:
ruby:3.4-slim` with Postgres in `compose:` is the development setup.

## Toolbox

The app container's image is the service's image (or the stage built from its Dockerfile) plus
farmy's toolbox: `toolbox/Dockerfile` is built with `BASE` (that image), `AGENTS` (the agents on
for the service, default `claude`) and `agents.tsv` in its context, one line per agent with its
install line for each base and what the entrypoint needs. Its `install.sh` uses the image's own
package manager, apt (the supported path) or apk (best effort): git, curl, bash, zsh, socat, a build
toolchain, the `dev` user (uid 1001, so the shared volumes have one owner), and each agent through
its `install` line, run as root. Once the agents are installed, the build runs each agent's `version`
line as dev, the user who runs them: a CLI dev cannot run (one under `/root`, say) fails the build,
naming the agent and what the command said. The catalogue installs every CLI outside any home
directory, owned by root and executable by all. The `entrypoint.sh` prepares the app and waits; farmy's shared Git helper
clones the repository, then farmy runs `setup` once every sidecar with a `healthcheck:` is
healthy (the app container depends on them with `condition: service_healthy`; the rest only have to
be started). Setup runs under `setup_timeout` from `farmy.yml`, thirty minutes by default: a setup
that does not end, such as a Rails `bin/setup` without `--skip-server`, is stopped and reported.

A `toolbox/` folder in your containers folder, with its own `Dockerfile`, replaces farmy's for
every service; `start` and `rebuild` say `custom toolbox: <path>/toolbox` when they build it. Keep the
`BASE` and `AGENTS` arguments and what farmy's `install.sh` provides (the `dev` user, `gosu` or `su-exec`,
git, curl). Farmy appends the managed tool/package layer unless `toolbox: {managed: false}` opts out,
and always, last, its own entrypoint: a custom toolbox cannot replace it, and a `toolbox/entrypoint.sh`
has no effect. Startup of your own goes into `toolbox/start.sh`, which farmy's entrypoint runs as dev at
every container start. See [toolbox and dotfiles](docs/toolbox.md).

Select pinned vendor tools independently from distro packages in `farmy.yml`; service lists add to them:

```yaml
tools: [neovim, ripgrep, fd, fzf, bat, lazygit, delta, jq]
packages: [imagemagick]
shell: zsh
shared_data: [nvim]
dotfiles:
  repo: https://git.example.com/dev/dotfiles.git
  # install: install.sh
```

`farmy toolbox list --json` shows resolved pins. `farmy toolbox bump [tool ...]` verifies releases and
atomically updates `tools.lock`; normal starts never rewrite it. `farmy dotfiles pull` fast-forwards the
shared read-only checkout and applies it to each running app, reporting partial failures by service.


## Status and the session

`farmy status` prints one line per service: name, `running` or `stopped`, the port block, the
repository, the addresses when running, and a note when the definition or `farmy.yml` changed
since the containers were made (`definition changed — run farmy restart shop`). `farmy status
--json` is what the session renders from: the same, plus every container of the service with its
health, each port with whether something listens on it inside, and each agent's activity. The
activity comes from the agent's hooks, which the entrypoint writes once from the entry's
`status_hooks` (`farmy-agent-status` writes `working`, `waiting` or `idle` to the service's own
volume); an agent without them is reported by its process.
The same snapshot is written to `.work/status/status.tsv` for the knowledge container, so an
agent inside a container can ask what is running.

The session is a tmux session named `farmy` inside the control container (its status bar and prefix
key are off: nothing of tmux is for the user), with the host's time zone (`TZ`, or what
`/etc/localtime` points at; the image has `tzdata`). A session made by another build of farmy is
replaced on the next `farmy`, so the TUI never runs stale (`farmy --version` and `farmy tui
--version` print the build). It survives your
terminal, your ssh connection and your laptop's lid; it does not survive the control container
being removed (the next command after an update may select a new one). Attaching needs no secret: the brokers are
running with what they were loaded with.

## Tests

`bin/verify` runs the acceptance suite from outside: `bin/build` compiles the four binaries with
cargo, and the tests run `bin/farmy` in a containers folder of their own against a fake `docker`
on the PATH. An integration file needs a real Docker: `JOBS=1 bin/verify -n /Integration/` on the
machine that has it.
