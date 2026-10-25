# Formats and contracts

What the worker must know about the files farmy reads and writes and the names it gives things,
when a failing test alone cannot show it. The spec records in `spec/` explain why; this file says
what. Examples use an imaginary containers folder with the services `shop` (a Rails app on github.com),
`notes` (a Vite front end on codeberg.org) and `toolkit` (a Ruby CLI built from its own Dockerfile).

## How farmy runs

The host needs Docker and nothing else. The repository ships a POSIX `sh` shim, `farmy`, that
pulls a versioned control image by default (see Distribution below) and runs commands inside the control container:
the farmy binary, the docker CLI with compose and buildx, git, tmux and the Infisical CLI (for
`providers/infisical`), with the Docker socket mounted (the one `docker context inspect` names as the
current endpoint: on a Linux host a `unix://` endpoint's path, rootless Docker's included, mounted at
`/var/run/docker.sock` inside; on macOS always `/var/run/docker.sock`, the socket of the VM the daemon
runs in; an endpoint that is not a local socket, `tcp://` or `ssh://`, is refused, saying farmy needs a
local Docker) and
the containers folder mounted at the same path as on the host. The control container is named
`farmy` and stays up: its main process is never the farmy binary, which is a command-line tool and
exits; farmy runs in it through `docker exec`. Every farmy binary carries a build hash of its
sources: `farmy --version` prints `farmy <version> (<hash>)` and `farmy tui --version` the same. The image carries the label `farmy.hash`, a content
hash of the control image's build inputs; explicit local builds rebuild when those inputs
change. `farmy update` follows the distribution contract below. `farmy` with no arguments on a
terminal attaches to the persistent session: a tmux session that holds the TUI, so that it
survives a closed terminal; tmux is never something the user operates. No tmux key is shown or
needed: an action's output streams into a pane inside the TUI, a shell or the logs take the
screen over and return, `q` leaves the terminal and keeps the session, the tmux status bar is
hidden. `farmy session` starts the session anew when the running TUI's build hash differs from
its own. Without a terminal (stdin or stdout is not a tty) a bare `farmy` prints the usage instead,
as `farmy help` does. When the host has git, the shim passes `git config --global user.name` / `user.email`
to `farmy init` as `GIT_USER_NAME` / `GIT_USER_EMAIL` in its environment; the control container
never sees the host's git configuration. Docker's CLI hints (`DOCKER_CLI_HINTS=false`) are off in
the shim's own docker calls and in the control container's environment. The shim passes the host's
`TZ` into the control container (when unset, the zone `/etc/localtime` points at), so the
session's clock is local.

The acceptance tests run the binary itself: `bin/build` in the work folder compiles it to
`bin/farmy`, and the tests run that in a containers folder of their own, with the fake docker on
the PATH. The shim runs under the suite for the seam between it and the control image (`init`
leaves the control container up), with the fake docker and, in the integration tests, the real
one. The TUI is not under the suite.

## The folder farmy runs in

```
.env                      farmy's settings for this machine (never committed; no secret in it)
farmy.yml                 optional: custom key routes, agents, the knowledge container
services/<name>.yml       one definition per service; a service is defined when this file exists
services/<name>.env       optional: environment for that service's app container
toolbox/                  optional: a Dockerfile that replaces farmy's toolbox
.work/                    farmy's own state; nothing in it is promised
```

Everything farmy creates or rewrites in this folder (`.env`, `services/<name>.yml` from `add` and from
the port write-back, everything under `.work/`) belongs to the owner of the folder: its uid and gid as
the control container sees them, whatever user farmy runs as. Docker Desktop and OrbStack map file
ownership to the host user by themselves; Docker Engine on Linux does not, so a file the control
container's root writes would be root's on the host.

A `ports.yml` in the folder (the format before this one) is refused by name, pointing at `ports:`
in the definitions.

## `.env`

`KEY=value` lines. Keys farmy reads; any other key is ignored:

| Key | Meaning |
|---|---|
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | the Git identity inside every app container; required by every command that starts a container |
| `LAN_HOST` | the name other machines reach this host by; `url` and `status` show it instead of `localhost` when set |
| `FARMY_UNLOCK_COMMAND` | read by the shim: the command that yields an unlocking value ("Unlocking"); the environment wins |
| `FARMY_SECRET_PREFIX` | read by the shim: the prefix of the unlocking values' names in the Keychain and the secret service ("Unlocking"); the environment wins |

`farmy init` writes `.env` when it is missing, with the Git identity taken from the first of:
`GIT_USER_NAME` / `GIT_USER_EMAIL` in its own environment (the shim puts the host's git
configuration there), the global git configuration where it runs (`git config --global
user.name` / `user.email`), a question on a terminal; else it warns and leaves the key for the
owner to set. It never changes an existing `.env`. Of `.env`, only the Git identity reaches an
app container; nothing else of it reaches any container, and no key lives in it (see "Keys").

## `services/<name>.yml`

```yaml
repo: https://github.com/acme/shop.git   # the clone URL, as it is pasted (https://, ssh://, git@host:path, file://);
                               # required. `none`: a workbench — an empty /workspace, no clone
branch: main                   # the branch cloned and, for a Dockerfile build, read. Default: the repository's default
image: ruby:3.4-slim           # the image the app container is built on (an official Debian image, see "The toolbox"), or:
dockerfile: Dockerfile         # build it from this Dockerfile in the repository (a stage written for development:
                               # a generated Rails/Node Dockerfile is a production image and is the wrong base)...
target: base                   # ...this stage of it (optional)...
build_files: [Gemfile, Gemfile.lock]   # ...with these files from the repository in the build context (optional)
ports: ["3100:3000"]           # host:container pairs, as compose writes them; the first is the app's address.
                               # Optional: without it nothing is published. The hundred the host ports lie in
                               # (3100-3199) is the service's block: all its host ports lie in it, no other
                               # service shares it, and ${FARMY_PORT_<n>} in the fragment is its n-th port
workdir: backend               # the folder of the repository the app lives in; commands run there. Default: the root
shared_logins: false           # the agents' logins on this service's own volume, not on farmy-shared. Default true
factory:                       # the factory loop for this service ("The factory")
  agent: claude
  test: test
mounts:                        # folders of the app container kept on volumes of their own, <name>-<mount>:
  bundle: /usr/local/bundle    # here shop-bundle at /usr/local/bundle. Kept by stop and restart, removed by destroy
start_after: [shop]             # services started first whenever this one is started
env:                           # environment of the app container
  DATABASE_URL: postgres://postgres:postgres@postgres:5432/shop_development
  VITE_API_URL: ${url:shop}     # ${url:<service>}: that service's first address on the host
  API_PORT: ${port:shop}        # ${port:<service>}: that service's first host port
agents: {claude: api-key}      # a mode per agent for this service: subscription | api-key | off; default: the agent's mode in farmy.yml
restrict: true                # opt this app into enforced egress (global egress.restrict also applies)
egress: {allow: [docs.example.com]} # extra app destinations; see "Enforced egress"
commands:                      # named commands, run in the checkout (or workdir) as the dev user
  setup: bin/setup --skip-server   # `setup` runs at every start, once the clone is there and the fragment's
                               # checked services are healthy; Rails' bin/setup starts the server without --skip-server
  start: bin/rails server -b 0.0.0.0    # the rest on demand: farmy run shop start, or the session's TUI
  test: bin/rails test
compose:                       # verbatim compose services that run next to the app, reached by their names
  postgres:
    image: postgres:18
    container_name: shop-pg     # your choice; without it compose names it shop-postgres-1
    environment:
      POSTGRES_PASSWORD: postgres
    ports: ["127.0.0.1:${FARMY_PORT_32}:5432"]   # ${FARMY_PORT_<n>}: the n-th port of the service's block (3132)
    volumes: [pgdata:/var/lib/postgresql]
    healthcheck:               # with one, the app container (and so setup) waits for it to be healthy
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
  redis:
    image: redis:7
volumes:                       # verbatim, as compose takes them
  pgdata:
    name: shop-pg-data
networks: {}                   # verbatim
```

`compose`, `volumes` and `networks` are passed to compose as they are, with `${FARMY_PORT_<n>}`
replaced. farmy adds its own two services, `app` and `keys`, so a fragment that defines a service
of either name is refused. Every container farmy starts, the fragment's included, runs with an
init process: `init: true` is added to a fragment service that does not set `init`.

The app container depends on every service of the fragment: one with a `healthcheck:` must be
healthy before the app container is started (`depends_on` with `condition: service_healthy`), one
without is only started first (`service_started`). The `setup` command therefore runs once the
clone is there and every checked service is healthy. It runs under a time limit, `setup_timeout`
in `farmy.yml` (default `30m`): a setup that runs past it is stopped and reported as not finished
within the limit; `start` exits 1 and the containers stay up, as after a failed setup.

One of `image:` or `dockerfile:` is required; a definition with neither is refused naming both.
`repo:` is required: a definition without it is refused naming `repo:`, and a `repo:` that is not a
clone URL (`acme/shop`) is refused as such, naming it.

**Ports.** A `ports:` pair `3100:3000` is published as `127.0.0.1:3100:3000`: the host itself only.
With `LAN_HOST` in `.env` it is published on every interface, so that other machines reach it.
`status` says which (see `farmy status --json`). The fragment's own `ports:` are passed as written.
A service without `ports:` publishes nothing: no address, `farmy url` prints nothing,
`status` shows `-` for its block. When another definition refers to it with `${url:<name>}` or
`${port:<name>}`, or its own fragment uses `${FARMY_PORT_<n>}`, farmy gives it the next free
block from `3100-3199` upward, writes `ports: ["<first port of the block>:3000"]` into its
definition and says so on stderr, naming the file and that 3000 is the container port it assumed;
this happens at `start` and `status` before anything else is done with the definition. Two
services whose host ports lie in the same block are refused naming the block and both services; a
service whose host ports lie in two blocks is refused naming the file and the port outside.
`mounts:` are named volumes only, mounted in the app container at the given absolute path and
owned by the dev user; a mount named `src` is refused (`/workspace` is `<name>-src` already).

`services/<name>.env` has `KEY=value` lines; every key reaches that service's app container and
no other. Like everything in that container it is readable by the agent inside: it is for
settings, not for secrets (those go through routes).

## Keys and secrets

A **route** is a destination the app containers reach through the service's keys helper (the
broker, `<name>-keys`) at `http://keys:9181/<route>/<path>`; the broker forwards to the route's
upstream with the secret added. Routes are defined in `farmy.yml` under `keys:`; farmy ships
`farmy.example.yml` with the usual ones. A route's secret is obtained from the **provider** at
`start`, `restart` and `farmy keys reload`, and loaded into the running broker; no secret is ever
in `.env`, in a container's configuration, in a generated file or under `.work/`.

```yaml
# secrets:                       # optional. Without a provider the routes' secrets are obtained on the host like
#   provider: [providers/env]    # unlocking values (below). A provider: the program and its arguments, run as given
#   unlock: [GITHUB_TOKEN]       # (no shell); a relative path: the containers folder first, then farmy's own folder.
#                                # unlock: values the provider needs; the shim obtains them (Unlocking, below) and
#                                # gives them to farmy on stdin. Another provider: [providers/infisical, --projectId,
#                                # <id>, --env, dev] with unlock: [INFISICAL_TOKEN]
keys:
  github:                        # a route is named after what it reaches; there may be several git hosts
    secret: GITHUB_TOKEN           # the name asked from the provider, or on the host without one
    upstream: https://github.com   # a git route applies to the repositories on this host
    auth: basic                    # basic (user:) | bearer | header (header:)
    # encoding: base64             # the provider's value is base64: farmy decodes it before loading the broker
    user: x-access-token
    git: true                      # the app container's git is rewritten to this route
  # git:                         # the same host over SSH instead: the secret is the private key, the broker
  #   secret: GIT_SSH_KEY        # runs an SSH agent with it, the app container gets SSH_AUTH_SOCK and never the key
  #   upstream: ssh://git@github.com   # the host, and the user (git when there is none)
  #   auth: ssh
  #   git: true
  # codeberg:                    # a second git route: another host, its own secret
  #   secret: CODEBERG_TOKEN
  #   upstream: https://codeberg.org
  #   auth: basic
  #   user: x-access-token
  #   git: true
  anthropic:
    secret: ANTHROPIC_API_KEY
    upstream: https://api.anthropic.com
    auth: header
    header: x-api-key
    expose: ANTHROPIC_BASE_URL     # the app gets ANTHROPIC_BASE_URL=http://keys:9181/anthropic
    placeholder: ANTHROPIC_API_KEY # the app gets ANTHROPIC_API_KEY=via-farmy-keys, which the broker swaps for the real one
    # services: [shop]             # the services that may use it; absent: every service
```

**Without a provider** (no `secrets.provider`), the secrets the routes name are obtained on the host
like unlocking values (the command, the Keychain, the secret service, a prompt; "Unlocking" below) and
farmy loads them into the brokers as they come. A route whose secret was not given reads `locked`.
`providers/env` with the names under `unlock:` does the same explicitly. An agent's `token_env` secret
is asked only from a provider, so that the prompt never asks for something optional at every start.

A definition may list `keys: [github, anthropic]` to say which routes it uses; a route it names
without being granted is refused. Without `keys:` in the definition, every route granted to the
service is available.

**Every granted route is configured at start, whatever its secret's state.** The broker gets the
route, the app container gets the route's `expose` and `placeholder` variables (subject to the
Claude mode, below) and, for the git route, its git rewrite, whether or not the provider had the
secret. A route without its secret answers 503 from the broker until `farmy keys reload` loads
it; no container is made anew for a secret. A load that omits a secret unloads it.

**Git routes and hosts.** A route with `git: true` applies to the repositories whose clone URL has
the host of its `upstream`; there may be several. Every granted git route with an http(s)
upstream is rewritten in the app container's git: the container gets `DEV_GIT_ROUTES`, space-
separated `<upstream>=http://keys:9181/<route>/` pairs, and the entrypoint turns each into a
`url.<route URL>.insteadOf <upstream>/`. The host match decides the rest: a repository on a host
without a git route that has a secret is warned about by host name ("only public repositories
clone"; the same warning, naming the host, when there is no git route at all), the transport
(below), and the check after the clone that git reaches the host through the broker.

A git route whose secret is not loaded forwards without credentials (its broker spec ends in `public`),
so the public repositories on its host clone; the warning at start says only public repositories clone
from that host until its secret (named) is given, then `farmy keys reload`.

**The provider protocol.** farmy runs the provider with the unlocking values in its environment
(under their names) and this on stdin:

```json
{"version": 1, "secrets": ["GIT_TOKEN", "ANTHROPIC_API_KEY"]}
```

The provider answers on stdout, then exits 0:

```json
{"version": 1, "secrets": {"GIT_TOKEN": "ghp_…"}, "missing": ["ANTHROPIC_API_KEY"]}
```

or `{"version": 1, "error": "not logged in"}`. Neither stdout nor stderr is shown or logged; the
operator runs the provider by hand to see why it failed. The error form, exit non-zero, an answer
that is not this, more than 30 seconds or more than 1 MB: the provider failed, and the message
names the provider, not its output.

farmy ships two providers in its own `providers/` folder: `env` answers from its environment
(the unlocking values, and whatever was exported before farmy ran), `infisical` asks the Infisical
CLI for each name (`infisical secrets get <NAME> --plain <the arguments after it in farmy.yml>`),
with `INFISICAL_TOKEN` from `unlock:` in the CLI's environment, the CLI's stderr passed through as
the provider's own; a name the CLI does not have is
`missing`, a CLI that is not installed is the error form. farmy asks only for the
secrets its granted routes need, never for everything.

**Universal auth** is the Infisical provider's other way in: `--client-id-from <unlock name>
--client-secret-from <unlock name>` among its arguments (`provider: [providers/infisical,
--client-id-from, INFISICAL_CLIENT_ID, --client-secret-from, INFISICAL_CLIENT_SECRET, --projectId,
<id>, --env, dev]`, both names under `unlock:`). The provider first runs `infisical login
--method=universal-auth --plain`, the id and the secret in the CLI's environment as
`INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` and `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET` and never on a
command line, and the token it prints is `INFISICAL_TOKEN` for every `secrets get`. The two `-from`
pairs are not among the arguments of the gets; `--domain <url>`, when given, stays among them and is
given to the login as well (`infisical login --method=universal-auth --plain --domain <url>`). A login
Infisical rejects is the error form.

**Unlocking.** farmy never stores a secret on disk. The values named under `secrets.unlock` reach
farmy on its standard input, one line each, `NAME:base64=<the value, base64>` as the shim writes
them (so that a multi-line value, an SSH key, arrives byte for byte) or `NAME=value`: before the shim hands a command that loads the
brokers or runs the provider (`start`, `restart`, `rebuild`, `keys reload`, `keys --why`, and `factory start`) to the control container, it asks the control
container for the names (`farmy unlock-names` prints the names under `secrets.unlock`, then, when
`farmy.yml` has no `secrets.provider`, the secret of every route under `keys:`; once each, in file
order, one per line; `farmy unlock-names --missing` prints only those the holder below does not have, and
that is what the shim asks) and obtains each from one source, and the sources are equivalent:

- the command in `FARMY_UNLOCK_COMMAND`, when it is set: a shell line, run in the containers
  folder with the name as `$1` (`FARMY_UNLOCK_COMMAND='pass show "farmy/$1"'`), never by string
  concatenation; a line that does not mention `$1` gets the name appended as its last argument. It
  prints the value; a non-zero exit, or nothing printed, is "not there";
- else the macOS Keychain, when `security` is on the PATH: `security find-generic-password -s
  <prefix><NAME> -w`, that one form only. Exit
  36 ("User interaction is not allowed": the keychain is locked) makes the shim run `security
  unlock-keychain` once, on the terminal, and look again;
- else the Linux secret service, when `secret-tool` is on the PATH: `secret-tool lookup farmy
  <prefix><NAME>`, that one form only. A collection
  cannot be unlocked from a shell: when the tool fails with a message on stderr (a locked collection,
  no D-Bus session on a headless host), the message is shown once, the secret service is asked nothing
  more for this command, and every value is asked for instead;
- a name the source does not have is asked for with a hidden prompt on the terminal. Without a
  terminal it is left out, named on stderr, and the command goes on (farmy reports the routes as
  `locked`).

**The holder.** The values farmy receives on stdin (the unlocking values, and without a provider the
routes' secrets) are held for the life of the control container by a holder process in it, in memory
only. farmy starts it (`farmy hold`, detached, its standard streams closed) the first time values arrive
and hands them over; every later command that runs the provider or loads a broker (`start`, `restart`,
`rebuild`, `keys reload`, `keys --why`, `factory start`) uses the held values, the ones on its stdin winning and being
held from then on. The holder listens on the Unix socket `FARMY_HOLD_SOCKET` (default
`/run/farmy/hold.sock`; farmy creates its folder), mode 0600, answering one JSON request per connection
(`{"op": "put", "values": {…}}`, `{"op": "get"}` → `{"values": {…}}`, `{"op": "clear"}`), and exits when
its socket file is gone. `farmy lock` clears it and ends it, printing that the values are forgotten and the
next load asks the host again; a restart of the control container ends it too. Nothing it holds is in a
file, a docker command line, a container's configuration or any output. Anyone who can `docker exec` into
the control container can ask it: the operator.

`<prefix>` is `FARMY_SECRET_PREFIX` from the environment, else from `.env` in the containers
folder, default `farmy/`. The values are passed to the provider's
process environment and nowhere else. The guide, `docs/credentials.md`, states the rule first and
the two stores as two bullets under it, and shows how to add an entry: on macOS
`security add-generic-password -a "$USER" -s farmy/GIT_TOKEN -w -T /usr/bin/security` (the `-T`
lets `security` read it back without a dialog), on Linux
`secret-tool store --label='farmy GIT_TOKEN' farmy farmy/GIT_TOKEN`.

**An SSH route** (`auth: ssh`, `upstream: ssh://[user@]host`): the broker keeps the key in an SSH
agent inside its container and shares the agent's socket with the app container on the volume
`<name>-keys-agent`, mounted at `/run/farmy-keys` in both; the app container gets
`SSH_AUTH_SOCK=/run/farmy-keys/agent.sock`. A repository on that host whose `repo:` is an
`https://` URL is cloned over SSH, `ssh://<user or git>@<host>[:<port>]/<path>`, the user and the
port the upstream names (the port only when it names one): the pasted URL stays, the route decides
the transport. It has no `DEV_GIT_ROUTES` entry; instead the app container gets
`DEV_GIT_SSH_ROUTES`, space-separated `https://<host>/=ssh://<user>@<host>[:<port>]/` pairs, one per
granted SSH git route, and the entrypoint turns each into `url.<ssh URL>.insteadOf <https URL>`,
so later fetches and pushes by the https URL go over SSH on the route's port. An `ssh://` or
`git@host:path` URL is taken as it is.

**Loading the broker.** farmy starts `<name>-keys` with its routes and no secret, then runs
`docker exec -i <name>-keys farmy-keys load` with this on stdin:

```json
{"version": 1, "secrets": {"GIT_TOKEN": "ghp_…", "GIT_TOKEN_ACME": "…"}}
```

`farmy-keys load` hands it to the broker over `/run/farmy-keys.sock` inside the container. The
port 9181 has no endpoint that loads or changes anything.

**What the broker holds.** `farmy-keys loaded` prints the names of the secrets it holds, one per
line (an SSH route's key only once its agent took it). A load whose SSH key the agent refuses is
answered with an error (`farmy-keys load` exits 1) naming why; when the value is not a key but
decodes from base64 to one starting `-----BEGIN`, the error says it looks base64-encoded and
names `encoding: base64`.

**The broker's contract** (`bin/farmy-keys`, so that it can run elsewhere): `farmy-keys serve`
starts with or without routes (none: only `/-/health` answers), as the user it runs as (uid 1001
in its container, on a read-only root with `/run` and `/tmp` as writable tmpfs mounts, mode
1777), and listens on the socket it is given; when it cannot, it says so naming the socket's
directory, its owner and mode, and exits 1. It reads `FARMY_ROUTES` (route names, space-separated) and `FARMY_ROUTE_<NAME>` holding
`<upstream> <auth> <user or header name or -> <secret name>`, optionally followed by `public`, listens on `FARMY_PORT` (default
9181) and on the Unix socket `FARMY_SOCKET` (default `/run/farmy-keys.sock`) for `load`. For a route
whose spec says `- ssh - <secret name>` it runs an SSH agent at `FARMY_AGENT_SOCKET` (default
`/run/farmy-keys/agent.sock`) and gives it the loaded key, replacing an earlier one.
`/<route>/<path>` → `<upstream>/<path>` with the secret added (basic: the user and the secret;
bearer: `Authorization: Bearer`; header: the named header); the client's own `Authorization`
and the named header are dropped. A `Location` the upstream answers with, on its own origin, is
rewritten to the route. A route not loaded answers 503 naming the route, unless its spec ends in
`public` (farmy writes it for every route with `git: true`): then the request is forwarded without
credentials (the client's own `Authorization` still dropped) until the secret is loaded. A path outside
the routes answers 404. `/-/health` answers 200. `farmy-keys load` reads the JSON on stdin and
sends it to the socket; a bad payload exits 1.

**`farmy keys`** prints one line per route: `<route>  →  <upstream>  <state>`, the state being
`loaded` (a running broker of a service it is granted to holds its secret, asked with `farmy-keys
loaded`), `not loaded (farmy keys reload)` (farmy loaded it, and no running broker holds it now:
the keys container was made anew or restarted), `missing` (the provider has no such secret),
`locked` (an unlocking value was not given), `provider failed`, `rejected (encoding: base64 on the
route, and the secret does not decode)`, `rejected (it looks base64-encoded: encoding: base64 on
the route)` (an SSH route's value that is not a key but decodes to one; it is not loaded), or `not
resolved yet` (nothing has been started); and the services it is granted to. There is no `off`:
without a provider a secret not given is `locked`. Every start, restart and rebuild loads each broker right
after its service's containers are up, before launching the service clone through the shared Git
container launcher, so it uses a loaded agent; a keys container made anew is loaded the same way. The shipped providers escape every control character in their JSON answer.
`farmy keys reload [<name>…]` resolves and loads again, into the running brokers; the containers
are not touched.

## The knowledge container

`farmy-knowledge` (image `farmy-knowledge:local`, binary `bin/farmy-knowledge`) is a read-only MCP
server for the agents inside the app containers, on the network `farmy` at
`http://farmy-knowledge:9190/mcp`
(streamable HTTP: JSON-RPC by POST, one answer per request, 202 for a notification). It reads
`KB_DIR` (default `/kb`): farmy's `README.md` and `docs/` are in the image (`knowledge.Dockerfile`
copies them, so the image is built again when they change); the containers folder's `services/`
and `.work/status` (holding `status.tsv`, the snapshot `status` and `start` write) are mounted
there read-only. It listens on `PORT` (default 9190); `GET /-/health` answers 200. It has no
Docker socket and runs no command. Its tools:

| Tool | Answers |
|---|---|
| `status` | the snapshot: one line per service with state, addresses and containers, its age, and the command to refresh it (`farmy status`); without a snapshot, says so and names the command |
| `service` (`name`) | the definition and the status line of one service |
| `list_docs` | README, `docs/*.md`, `services/*.yml`, each with its first line |
| `read_doc` (`name`) | one of them, by the name `list_docs` shows |
| `search_docs` (`query`) | case-insensitive matches as `file:line: text` |

`status.tsv` is tab-separated lines: `generated <UTC time>`, `service <name> <state> <addresses> <containers>`,
`problem <name> <text>`.
## Agents

An agent is data. farmy ships a catalogue, `agents.yml` in its own folder (`claude`, `codex`,
`gemini`, `opencode`, `cursor`, `copilot`), each entry preceded by a comment citing the vendor's
page every field was checked against; a field the vendor does not document is `null`, never a
guess. `farmy.yml` `agents:` is a map of name → fields: a catalogue name with `{}` (or null) takes
the catalogue's entry, a catalogue name with some fields overrides those fields and keeps the
rest, any other name is an agent of your own with the same fields. A list (`agents: [claude,
codex]`) means those catalogue entries unchanged; `agents: []` none. Default: none, no agent is on.
A definition's `agents: {<name>: <mode>}` turns a catalogue agent on for that service with that mode,
whether or not `farmy.yml` names it. `farmy init` asks on a terminal which agents to install (catalogue
names, space-separated; empty for none) and writes `agents:` into `farmy.yml` (creating the file, or adding
the key; one that has `agents:` is not asked about); without a terminal it turns none on, writes nothing,
and says that `agents:` in `farmy.yml` turns one on. `farmy add` ends with the agents the image will carry,
`agents: claude (api-key), codex (subscription)`, or `agents: none (agents: in farmy.yml turns one on)`.
Claude is one catalogue entry and a special case nowhere.

```yaml
agents:
  claude:
    mode: api-key                 # the default mode for every service: subscription | api-key | off
  mytool:
    install: npm install -g mytool@2.4.0   # a shell line run as root while the toolbox builds, the same on an apt and an apk base,
                                  # or {apt: <line>, apk: <line>} when they differ (null for a base the vendor does not support);
                                  # null: nothing to install. /home/dev/.local/bin is on the dev user's PATH, for per-user installers run as `su dev -c …`
    login: .mytool                # a path under $HOME (or a list of them) holding the login; linked into farmy-shared/<name>/;
                                  # a folder when it ends in / or its last part has no extension, else a file (.claude.json)
                                  # so that one login serves every container; null: the agent keeps no login
    state: [projects]             # paths under the first login path that are per service (transcripts, sessions):
                                  # kept on <service>-agents under <name>/, linked from the login path. Default: none
    headless_login: mytool login --device   # the command to log in without a browser; farmy agents prints it
    token_env: MYTOOL_TOKEN       # optional: the provider's secret of that name goes into the app's environment under that name
    api_hosts: [api.mytool.example:443] # destinations for this agent; replaces the catalogue list when overridden
    env: {MYTOOL_STORE: file}     # optional: plain variables the agent needs in the app container (no secret)
    api:                          # optional: how the agent talks to its API, for api-key mode
      key: MYTOOL_API_KEY         #   the variable it reads its key from
      base_url: MYTOOL_BASE_URL   #   the variable it reads its API base URL from
      upstream: https://api.mytool.example   # the route with this upstream serves it
    mcp_add: mytool mcp add farmy "$FARMY_MCP_URL"   # optional: run once per login by the entrypoint, FARMY_MCP_URL being the knowledge MCP's address
    status_hooks:                 # optional: the agent's lifecycle hooks, written by the entrypoint when the file has none
      file: .mytool/settings.json #   under $HOME; the shape is {"hooks": {"<Event>": [{"hooks": [{"type": "command", "command": "farmy-agent-status <state>"}]}]}}
      events: {SessionStart: idle, UserPromptSubmit: working, Stop: idle, Notification: waiting}   # event → state
    process: mytool               # optional: the process `docker top` shows while it runs. Default: the name
    headless: {command: mytool run --yes, prompt: argument}   # optional: an unattended one-shot run, for the factory: the command
                                  # without the prompt, and the prompt on stdin or as the last argument. null: none
    version: mytool --version     # optional: a shell line that prints the CLI's version; a factory run asks it once and keeps
                                  # what it printed (Factory, "The run record"). null: none. Every catalogue entry states it
    factory_login: {path: .mytool, create: mytool login --device}   # optional: a subscription login of its own for factory runs
                                  # (Factory, "Factory logins"): the folder under $HOME where the CLI keeps its login (relative,
                                  # no ..), and the shell line that makes it without a browser. Absent: the agent has none
```

An unknown field is refused by name, as is a `claude:` key at the top of `farmy.yml` (the message
points at `agents`). A definition's `agents: {<name>: <mode>}` sets the mode of an agent for that
service. The modes, per agent and per service:

- **`subscription`** (default): the agent's login paths are linked into `farmy-shared`, so one
  login serves every container; when `token_env` is set and the provider has a secret of that
  name, it is put into the app container's environment under that name. This is the one
  documented exception to the rule that no secret is in a container's configuration; the agent
  can read it. The value is in no file farmy writes (record 2026-10-19-1035): `.work/<name>/compose.yml`
  names the variable only (`environment: [NAME]` or `NAME: ${NAME}`), and farmy gives the value in the
  environment of the `docker compose` process at every compose up that makes or recreates the app container
  (from the provider, or the held unlocking values), so it survives `farmy restart` without values given again
  and a `farmy start` that reuses the existing compose file. The agent's `api` variables (`key`, `base_url`) reach the container from no route.
- **`api-key`**: no token; the route whose `upstream` is the agent's `api.upstream` gives the
  container `<api.base_url>=http://keys:9181/<route>` and `<api.key>=via-farmy-keys`, which the
  broker swaps for the real key. An agent in this mode without such a route is refused at
  `start`, naming the agent and the upstream.
- **`off`**: not installed in that service's image, nothing linked, none of its variables.

**What the toolbox and the entrypoint get.** The app image's build context holds `agents.tsv`,
one line per agent that is on for the service (whatever its mode but `off`), the columns `name`,
`install_apt`, `install_apk` (the one line in both when `install` is a string), `login` (paths
joined by `:`, a folder with a trailing `/`, a file without), `state` (joined by `,`), `mcp_add`, `hooks_file`, `hooks_events` (`Event=state,…`),
`process`, `version` (the version line), separated by tabs, an empty column for null; the build argument `AGENTS` lists the same
names, space-separated. The image keeps the file, the toolbox runs the install line of its base as
root (an agent whose line for that base is empty is skipped, with a note in the build output). Once the agents
are installed, farmy's toolbox runs each agent's `version` line as dev (record 2026-10-19-1430), each given 30 s
(`timeout 30`, record 2026-10-19-1540); one that fails or does not answer in time fails the build, naming the
agent and what the command said (or the 30 s limit), so an install dev cannot run (a CLI under
`/root`) fails the build instead of the run. The catalogue installs every CLI outside any home directory
(`/root`, `/home/…`), as root, owned by root and executable by all: no catalogue install line runs as dev or
names a home directory, and none lives under a path a login volume is mounted on. No catalogue install line pipes a
download into a shell (`curl … | sh`): it downloads to a file and runs that (`curl -fsSL -o <file> <url> && sh
<file>`), so a failed download fails the install step with curl's own message (Debian's `sh`, dash, has no
`pipefail`). The install lines `docs/factory.md` shows (pinning Claude Code or Codex) keep the same rules. The app container gets `FARMY_AGENTS` (the same names) and
the entrypoint, for each: links every login path to `$FARMY_LOGIN_DIR/<name>/<basename>`
(`FARMY_LOGIN_DIR` is `/home/dev/.farmy-shared`; `/home/dev/.farmy-service/logins` for a service with
`shared_logins: false`, which does not mount `farmy-shared` at all: its logins are its own),
links each `state` path to `/home/dev/.farmy-service/<name>/<path>`, runs `mcp_add` once per
login (with `FARMY_MCP_URL`), and writes the hooks into `hooks_file` when it has none. The
hooks run `farmy-agent-status <state>`, which writes `/home/dev/.farmy-service/<name>/agent.status`.

`farmy agents` lists the catalogue's entries and yours, one line each: `<name>  <on|off>  <mode>
<headless_login or ->` (on: in `agents:` and not `off` in every definition; the mode from
`farmy.yml`).

## `farmy.yml`

Optional. Six keys (`secrets`, `keys`, `agents`, `egress`, `knowledge`, `setup_timeout`); an unknown
key is refused by name. `secrets` and `keys` are described above, `agents` just above, `egress` below.

```yaml
agents: {claude: {}}           # the agents on in every service, and overrides; see "Agents". Default: none
egress:                        # upstream proxy/mesh settings and optional filtering ("Enforced egress")
  # proxy: proxy.example.com:3128   #   or an existing HTTP proxy instead of a node: no Tailscale, the same variables
  authkey: TS_AUTHKEY          #   an unlocking value named under secrets.unlock; absent: registration by URL
  join_timeout: 10m            #   how long start waits for the node to register. Default 10m
  tailscale:
    login_server: https://headscale.example.com   # a control server of your own; omitted: Tailscale's
knowledge: true                # the shared knowledge container (the MCP). Default true
setup_timeout: 30m             # how long a service's setup command may run: a number with s, m or h. Default 30m
```

## Mesh egress

With mesh egress configured in `farmy.yml` (not an external proxy or restriction-only map), farmy
keeps one container **`farmy-egress`** on the `farmy` network,
never published, running `tailscaled` in userspace-networking mode (no TUN device, no `NET_ADMIN`)
with a SOCKS5 and an HTTP CONNECT proxy on port 1055 for the farmy network; its state is the
volume `farmy-egress` at `/var/lib/tailscale`. It is a proxy only: no internal network, no exit
node, no subnet router; unrestricted app containers keep their direct internet. `egress.tailscale.login_server`
is given to the node (`--login-server=<url>`); omitted, the node uses Tailscale's own.

The container has the device `/dev/net/tun` and the capability `NET_ADMIN`, and `tailscaled` runs
with a TUN interface (kernel mode); every login passes `--accept-dns=true`, so tailscaled manages the
container's resolver and the proxies resolve names on the mesh, extra records and split DNS included.
When the daemon refuses the device or the capability (compose up fails, or the node does not come
up), farmy makes the node again in userspace mode (`--tun=userspace-networking`) and says at start
and in status that only names under the tailnet's suffix resolve through the proxy.

The container's main process is `tailscaled` (the proxies on 1055), with one
`tailscale up` (and `--login-server=<url>` written into the command itself) run once beside it when no auth key is configured; the
container does not exit when that call ends or fails, and nothing runs `up` or `login` again,
since every call makes a new node key. With an auth key, farmy's one `tailscale up --auth-key`
(the key on the exec's stdin) is the only login call. A node registered before needs none: its
state on the volume brings it back `Running` after a container restart, without a word.

**Every container farmy starts** (`<name>-keys`, `farmy-knowledge`, the app container, the
fragment's services) and the provider process get, in both cases (`HTTP_PROXY` and `http_proxy`):

```
HTTP_PROXY=http://farmy-egress:1055
HTTPS_PROXY=http://farmy-egress:1055
ALL_PROXY=socks5h://farmy-egress:1055
NO_PROXY=localhost,127.0.0.1,host.docker.internal,<service>,keys,<the fragment's services in order>,farmy,farmy-egress,farmy-knowledge
```

farmy's own fetch of a Dockerfile (a `dockerfile:` definition) runs git with the same variables, and
over SSH with a `ProxyCommand` of `nc -X 5 -x <proxy> %h %p`; the control image has `netcat-openbsd`.
`FARMY_EGRESS_PROXY=<host:port>`, in farmy's environment, replaces `farmy-egress:1055` in every one
of these variables: a proxy of your own, or a test's. The control container is on the `farmy`
network (the shim creates the network when it is missing, starts the control container on it and
attaches one from an older farmy with `docker network connect`), so the provider resolves
`farmy-egress`; the app container is on it always, and with `egress:` the fragment's services too.

**An existing proxy.** `egress: {proxy: <host:port>}` runs no node: every container farmy starts and the
provider get `HTTP_PROXY` and `HTTPS_PROXY` (both cases) as `http://<host:port>` and the `NO_PROXY`
above, and no `ALL_PROXY` (a corporate proxy speaks HTTP). git over SSH goes through it by HTTP CONNECT:
the entrypoint's `ProxyCommand` is `nc -X connect -x <host:port> %h %p` when `ALL_PROXY` is absent and
`HTTPS_PROXY` is set, and farmy's own Dockerfile fetch does the same. `proxy` together with `authkey` or
`tailscale` is refused, naming both. Status: `egress  proxy  <host:port>`; the JSON's `egress` is
`{"state": "proxy", "name": null, "address": null, "registration_url": null, "proxy": "<host:port>",
"mode": "proxy", "note": null}`.

The broker honours them for its upstreams (an `http://` upstream in absolute form through
`HTTP_PROXY`, an `https://` one by CONNECT through `HTTPS_PROXY`, `NO_PROXY` respected). The
toolbox installs `netcat-openbsd` and `openssh-client`; with `ALL_PROXY` set, the entrypoint sets `core.sshCommand`
to `ssh -o StrictHostKeyChecking=accept-new -o ProxyCommand='nc -X 5 -x farmy-egress:1055 %h %p'`.
Without `egress:` none of this is set and no egress container exists.

**Joining.** `egress.authkey` names an unlocking value: it must be listed under
`secrets.unlock` (else refused, naming the key and `unlock`), the shim obtains it like the others,
and it reaches the node through the stdin of a `docker exec -i` in `farmy-egress`: in no file,
no docker command line, no environment of a container. The order at `start`, `restart`,
`rebuild` and `keys reload`: unlocking values → the egress node up and joined → the provider →
the brokers. With the key the node joins by itself. Without, farmy starts the container, reads
the registration URL from `docker logs farmy-egress` (stdout and stderr both; the URL stands
alone on its own line, indented, under `To authenticate, visit:`), reading the log again and again
through the whole wait, prints it once with the instruction to register the node on the control
server, and waits up to `egress.join_timeout` (default 10m) for `tailscale status --json` in the
container to say `BackendState` `Running`. While it waits it keeps one live line, `egress: waiting
for registration · <elapsed> of <limit> · <url>` (`2m10s of 10m`; rewritten in place on a terminal,
printed anew every so often without one).
On timeout start goes on; a service whose clone then fails says the mesh is unregistered. A
node registered before (its state on the volume) joins at the next start without a word.

**A terminal.** farmy treats its output as a terminal when its stdout is one or when
`FARMY_TTY=1` is in its environment: the shim passes that when its own stdout is a terminal,
since with unlocking values on stdin `docker exec` cannot have `-t`.

**Phases.** `start` prints a line `== <phase>` as it enters each: `== egress` (with `egress:`),
`== secrets`, then for each service `== images: <name>`, `== containers: <name>`, `== clone:
<name>`. A build's output stays under its phase: on a terminal collapsed to its last line, shown in
full when the build fails; without a terminal as it comes.

**Status.** `farmy status --json` gets a top-level `egress`: null without `egress:`, else
`{"state": "registered" | "unregistered" | "stopped", "name": <the mesh name, DNSName without the
trailing dot>, "address": <the first mesh IP>, "registration_url": <the URL, when unregistered>,
"proxy": "farmy-egress:1055", "mode": "kernel" | "userspace", "note": <in userspace mode: only names under the
tailnet's suffix resolve through the proxy; else null>}`, name and address null when not registered. `status` prints a first
line `egress  <state>  <name> <address>  <kernel|userspace> mode` (the URL instead of name and
address when unregistered); the TUI shows it, and its "as of" in the local time zone (`TZ`).
`stop` with no name stops `farmy-egress` too; `destroy` never removes its volume.

## The factory

A service opts in with named profiles under `factory:` in its definition. Names and paths are chosen
by the user; farmy assigns no meaning to `shape`, `work`, `test/` or `src/`:

```yaml
factory:
  shape:
    base: main
    agent: claude
    mode: api-key
    writes: [test/]
    hidden: [src/]
    test: test
    check: check
    gate: red_first
    # review: true is the default for red_first
    max_iterations: 5
    iteration_timeout: 30m
  work:
    base: main
    agent: claude
    mode: api-key
    writes: [src/]
    protects: [test/]
    test: test
    gate: green
```

Each profile accepts `base`, `agent`, `mode`, `writes`, `protects`, `hidden`, `test`, `check`, `gate`,
`review`, `max_iterations`, `iteration_timeout`, and `verify` (a command the agent may run on demand: "On-demand
verify", below). `mode` is `api-key`, `subscription` or `login`: it selects the
existing catalogue agent's authentication (the subscription token/login or API route), never a different
agent's credentials. `login` uses the agent's factory login ("Factory logins"). Omitted mode retains the existing API-route-else-token selection; it never picks `login`. The catalogue
supplies the login details; runs keep their existing credential isolation. Every profile's agent is
installed in the service image, while authentication is validated for the selected run.

`--profile <name>` selects a profile. Without it, use `default` if present, otherwise the sole profile;
with several and no `default`, refuse naming `--profile` and the available profiles. An unknown profile
is refused with its name and the available profiles before any run starts.

Today's single block below remains accepted as the profile `default`, with no changes required:

```yaml
factory:
  base: main              # the branch runs start from (required)
  agent: claude           # an agent of the catalogue or of farmy.yml with a headless field (required); in api-key mode
                          # when a route has its api.upstream, else with its token_env; it is put into the service's image
  writes: [src/]          # paths the agent may change. Default: the whole repository
  protects: [test/]       # paths whose changes by the agent are reverted before every gate. Default: none
  hidden: []              # folders covered in the agent's container (always protected too). Default: none
  test: test              # a name under commands:, run from the repository root (required)
  verify: test            # optional: a name under commands: the agent may run whenever it likes with farmy-verify
  max_iterations: 5       # default 5
  iteration_timeout: 30m  # default 30m; s, m or h
  gate:
    network: none         # the gate without the service's sidecars, no network at all. Default: the sidecars (below)
```

**Gate selection.** A scalar `gate` is `green` (the default), `red_first`, or a command name under
`commands:`. A mapping accepts `kind` (the same values, default `green`) and `network` (the existing
network setting), for example `gate: {kind: red_first, network: none}`. Thus the legacy
`gate: {network: none}` still means green with no gate network.

- `green`: the named `test` command exits 0.
- `red_first`: the named `check` command exits 0, the `test` command exits non-zero, and that iteration
  committed at least one added or changed file under `writes`. All three are required; a deletion alone
  does not qualify. `check` is required and names a command under `commands:` (such as a syntax/load check).
- A custom command name: that command exits 0, irrespective of the ordinary test's result.

Keep each command's output and exit code in the gate log; the red-first gate log distinguishes the check
and the test. A container or command that could not run is an execution failure, not a passing red-first
gate. The gate runs against the committed export with the existing network and credential isolation.
`review` is boolean, default true for `red_first`, false otherwise; an explicit value overrides the default.

`farmy factory start` refuses, naming what to fix: a definition without `factory:`; `test` not under
`commands:`; an agent unknown, without `headless`, or with neither a route to its `api.upstream` nor a
`token_env` (naming `api` and `token_env`); a service that is not running (naming `farmy start <name>`).
`farmy start` reads `factory:` but does not check it beyond its keys. When the run's first clone fails, `factory
start` refuses quoting the first line of git's output that names a cause (as for the clone marker), keeps git's
whole output in `.work/<name>/runs/<id>/git.log` (that folder holds no state: it is no run) and names the file.

**A run** has the id `<yyyymmdd>-<hhmmss>-<4 hex digits>` (UTC) and:

| Thing | Name |
|---|---|
| run volume | `<name>-run-<id>` (kept after the run) |
| run networks, and the run's broker (alias `keys`) | `<name>-run-<id>` (internal in every mode), `<name>-run-<id>-keys`; filtering proxy topology is described in "Enforced egress". Only what a run made is removed at its end, without a word about anything absent |
| containers (`docker run --rm`, entrypoint `sh` or the command's own) | `<name>-run-<id>-git-<n>`, `<name>-run-<id>-agent-<i>`, `<name>-run-<id>-test-<i>`, `<name>-run-<id>-version`, `<name>-run-<id>-verify-<i>-<k>` |
| labels on each | `farmy.run=<id>`, `farmy.service=<name>`, `farmy.role=git\|agent\|test\|version\|verify`, `farmy.iteration=<i>`; a login-mode agent also `farmy.factory-login=<agent>`; a verify also `farmy.verify=<k>` |
| branch | `farmy/<name>/<id>` |
| folder | `.work/<name>/runs/<id>/`: `state.json`, `iteration-<i>.agent.log`, `iteration-<i>.test.log`, and the run record: `iteration-<i>.agent.json`, `iteration-<i>.prompt.md`, `iteration-<i>.agent.stdout`, `iteration-<i>.agent.stderr`, `iteration-<i>.verify-<k>.log` |

**The run record.** Per iteration, beside `iteration-<i>.agent.log` (stdout and stderr joined, for
`factory log`):

- `iteration-<i>.agent.json`, a JSON object: `iteration` (number); `command`, the `docker run` farmy ran for
  the agent as a list of words starting `"docker", "run"`; `env`, the agent container's environment as given
  (name → value); `image`, `farmy/<name>:dev`; `image_id`, that image's id when the agent ran, as `docker image
  inspect` gives it (`sha256:…`); `exit`, the agent's exit code (124 when stopped at `iteration_timeout`);
  `started` and `ended`, RFC 3339 in UTC (`2026-10-18T20:16:05Z`); `prompt`, `stdout`, `stderr`, the names of the
  three files below. `command` is word for word what farmy gave Docker, which holds no secret's value (see
  "No secret on a command line" below); in `env` the value of every secret farmy resolved is replaced by its
  name in angle brackets (`"CLAUDE_CODE_OAUTH_TOKEN": "<CLAUDE_CODE_OAUTH_TOKEN>"`); no secret's value is in
  any file of the run.
- `iteration-<i>.prompt.md`: the prompt the agent was given, byte for byte.
- `iteration-<i>.agent.stdout` and `iteration-<i>.agent.stderr`: what the agent printed on each, byte for
  byte. farmy does not parse them; stdout is where an agent's usage report lands (Claude's `--output-format
  json` result, Codex's JSON events).

Per run, in `state.json`, next to `profile_config`: `agent_config`, the agent entry the run used, resolved
(the catalogue's entry with the `farmy.yml` overrides applied, or the entry of your own), as a map of its
fields plus `name`; and `agent_version`, what the entry's `version` command printed with surrounding
whitespace removed, or null when the entry has no `version` or the command printed nothing. The version is asked
once per run, before the first iteration: `docker run --rm --name <name>-run-<id>-version`, the run's labels
with `farmy.role=version`, `-u dev`, `--network none`, no volume, the image `farmy/<name>:dev`, the line run as
`sh -c <version>`. A version command that exits 0 and prints nothing leaves `agent_version` null. One that
fails (record 2026-10-19-1430) keeps `agent_version: "unknown"` and `agent_version_reason`: its exit code and
the last line it wrote to stderr (`exited 126: sh: 1: codex: Permission denied`), so a CLI that is missing or
that dev may not execute shows in the record. Either way the run goes on. The version container gets 30 s (record 2026-10-19-0940): when it has not ended by then farmy stops
it (it is gone afterwards), keeps `agent_version: "unknown"` and `agent_version_reason`, a sentence saying the
command gave no answer within 30 s (`no answer within 30 s`), and the run goes on to its first iteration.
`agent_version_reason` is absent when the version was given or there is none.

**No secret on a command line** (record 2026-10-19-0840). While a run goes, no secret value farmy resolved
(a `token_env` value, a route's key, the mesh auth key) is in the argv of any process farmy starts: every
`docker` call (`run`, `create`, `exec`, `compose`) and the commands its containers run. A container that
needs a value gets it as `-e NAME` without a value (Docker takes it from the environment farmy gives the
`docker` process) or from `--env-file <file>`: a file farmy writes with mode 0600 and deletes as soon as the
container has started, before the container's command ends.

Factory-scoped container observations require a nonempty `farmy.run` label. A shared
Git helper for service clone, build-file fetch or dotfiles may also have `farmy.role=git`
without belonging to a factory run.

- **Git containers** (the service's image `farmy/<name>:dev`), every one as the checkout's owner, the dev user
  (`-u dev`, uid 1001), never root; the run volume, once created, is made the dev user's by a root container whose
  only command is `chown 1001:1001 /workspace`; no `safe.directory` exception anywhere. Each is made with `docker create
  --rm` on the service's network, joined to `farmy` with `docker network connect` (where `farmy-egress` resolves), and run
  with `docker start -a`; the agent's container and the gate are never on `farmy`. The run volume at `/workspace`; the
  checkout `<name>-src` at `/src`, read-only, for the first clone; the service's compose network, its git
  routes as `git -c url.<route>.insteadOf=<upstream>/`, and with an SSH route `<name>-keys-agent` at
  `/run/farmy-keys` and `SSH_AUTH_SOCK=/run/farmy-keys/agent.sock`. git runs with `-c core.hooksPath=/dev/null
  -c core.fsmonitor=false`, the proxy variables, and with an SSH route `core.sshCommand` = `ssh -o
  StrictHostKeyChecking=accept-new` plus `-o ProxyCommand='nc -X 5 -x <proxy> %h %p'` with the mesh, `-o
  ProxyCommand='nc -X connect -x <host:port> %h %p'` with `egress: {proxy: …}`. The first one clones `/src` into `/workspace`, sets `origin` to the clone URL farmy
  uses for the service, fetches, checks out `origin/<base>` as `farmy/<name>/<id>`; a checkout without an
  `origin` checks out its local `base` and the run neither fetches nor pushes.
- **Agent containers**: `docker run --rm -i`, user `dev`, the run volume at `/workspace`, `--tmpfs
  /workspace/.git:ro` and one `--tmpfs /workspace/<folder>:ro` per `hidden` folder, the definition's
  `mounts:`; the run's internal network `<name>-run-<id>` in every mode (never `farmy`, never the
  service's network), with its broker in api-key mode and HTTP proxy variables pointing at a
  filtering gate limited to this agent's `api_hosts` ("Enforced egress");
  the environment: in api-key mode `<api.base_url>=http://keys:9181/<route>`
  and `<api.key>=via-farmy-keys`, in token mode `<token_env>=<the secret>`, in login mode none of these and the
  agent's factory login volume at `/home/dev/<path>` ("Factory logins"), the agent's `env:`,
  `FARMY_LOGIN_DIR=/home/dev/.farmy-service/logins`; nothing else of farmy's (no `SSH_AUTH_SOCK`, no
  `DEV_GIT_ROUTES`, no `FARMY_MCP_URL`, no `farmy-shared`, no `<name>-keys-agent`). The command is
  `timeout <iteration_timeout in seconds> <headless.command>`, the prompt on stdin (`headless.prompt: stdin`)
  or appended as one word (`argument`).
- **Test containers**: a new one per gate, the run volume at `/workspace:ro`, the definition's `mounts:`
  read-only, `--tmpfs /scratch:exec`; the command exports the commit into `/scratch/tree` (`git -C /workspace
  archive HEAD | tar -x -C /scratch/tree`), goes there (or to the definition's `workdir` inside it) and runs
  the test command with `HOME` and `TMPDIR` under `/scratch`: the suite may write into its tree, and nothing
  of that outlives the container. Its exit code is the verdict.
- **The gate's network**: by default the internal network `<name>-run-<id>-gate` (`docker network create
  --internal`), made at the run's start; the service's fragment containers join it under their compose
  service names (`docker network connect --alias <service> <network> <container>`) and leave it at the
  run's end, when it is removed (cancel included). The app container, `<name>-keys` and the agent's container
  never join it; the gate gets no proxy variables. A sidecar that is not running is left out. With
  `factory.gate.network: none` in a legacy block, or `gate: {kind: <gate>, network: none}` in a profile:
  `--network none` and no network made.

**An iteration**: the agent; then in a git container: `git checkout <base commit> -- <protects and hidden>`,
`git clean -fdx -- <protects and hidden>`, `git add -A -- <writes>` (or `git add -A`), `git commit -m "farmy:
iteration <i>"` when anything is staged, `git reset --hard` and `git clean -fd`; then the gate. Always exclude
`.farmy/question.md` from staging. The protection baseline is the chosen starting commit, including
the preceding run's tests when chaining. A passing gate ends `awaiting_review` without a push when review
is required; otherwise it ends green and pushes `farmy/<name>/<id>` to `origin` in a git container.
Nothing else is pushed, nothing merged. After two consecutive unsuccessful gates whose full output and
exit codes are identical and whose iterations both committed nothing, end `stalled` without another
iteration. A commit or changed output breaks the sequence; `stalled` wins over the limit on that second
iteration. Earlier success, question, agent failure and timeout still terminate as their own results.

**Chaining and approval.** `start --from <run id|branch>` resolves that source's tip instead of the base,
then makes the new run's branch from that commit. A source run must be green; naming its branch must
not bypass approval. An unrelated branch is allowed explicitly. A known run branch that has advanced
since its gate or approval is refused. The preceding gate's complete output and command exit codes are
supplied in the new run's first prompt. The source checkout and the developer's checkout stay untouched.
`approve <id>` accepts `awaiting_review` only, verifies the branch still names the gated commit, pushes
that branch and marks it green after publishing succeeds. Repeating a completed approval is idempotent.
Other non-green results cannot be approved. A workbench without a remote marks green without pushing.

**Questions.** The agent prompt says it may stop and ask by writing `.farmy/question.md`, even outside
`writes`. Capture the text before cleanup, commit any other permitted changes with the usual protection,
never commit the question file, and end `question` without running a gate or pushing. `show` and the TUI
show the text. `answer <id> <text|file>` accepts a questioned run only, reads an existing file in the
containers folder or uses the argument as literal text, and starts a new run ID and branch from the
questioned run's tip, with its original task and profile and the question and answer in the prompt.
Remove the old control file so the continuation does not ask the same question automatically. Preserve
the old run as history. `answer --wait` has the same behavior as `start --wait`.

**The prompt**: `factory/prompt.md` in the containers folder, else `factory-prompt.md` in farmy's folder,
with `{{TASK}}` (the task's text), `{{ITERATION}}` (`<i> of <max>`) and `{{TEST_OUTPUT}}` replaced: for the
first iteration a sentence that no test has run yet, after that `The tests ended with exit <n>; the last
lines of their output:` and the last 200 lines of the previous gate. Question instructions, and any
source gate evidence or answered question, are supplied even when a custom prompt omits a placeholder.

**States.** `state.json`: `{"id", "service", "task", "base", "branch", "phase", "iteration",
"max_iterations", "result", "started", "ended", "profile", "from", "question", "commits": [{"iteration", "sha"}], "verdicts":
[{"iteration", "exit"}], "pid"}`; times RFC 3339 UTC; `phase` `cloning` | `login_wait` | `agent` | `commit` | `gate` |
`pushing` | `done`; `result` null until the end, then `green` | `max_iterations` | `timeout` |
`agent_failed` | `test_failed_to_run` | `cancelled` | `interrupted` | `awaiting_review` | `question` |
`stalled` | `login_blocked`. `profile` is the selected name (`default` for old runs/definitions); `from` is the source run ID
or branch, or null; `question` is the captured text or null. Awaiting review and question both have phase
`done`; they do not become interrupted when the controller exits.
A command that reads runs marks a run whose phase is not `done` and whose controller (`pid`, a process
whose command line holds `factory run <id>`) is gone `interrupted`, phase `done`.

**Commands.**

```
farmy factory start <name> --task <file or text> [--profile <name>] [--from <id|branch>] [--wait]
                                                         start a run; prints its id. --wait: run it here,
                                                            print the result, exit 0 for green, 1 otherwise
farmy factory list [<name>]     one line per run: <id>  <service>  <result or phase>  <i>/<max>  <branch>
farmy factory show <id>         the run's state as lines, the branch, the result (agent_failed with the first cause line of
                                the agent's log: API Error, Error:, error:, ENOTFOUND, ECONNREFUSED, 401, 403, rate limit; else
                                its last line), the last gate's output (`(no output)` when it printed nothing), and
                                `volume  <name>-run-<id>  <size>` (du -sh in a container labelled farmy.role=measure)
                                or `volume  <name>-run-<id>  removed (farmy factory prune)`
farmy factory log <id> [<i>]    an iteration's agent log and test log (default: the last iteration)
farmy factory cancel <id>       stop the run's controller and containers; the run reads cancelled
farmy factory approve <id>      approve awaiting_review, publish its branch, report green; exit 0 on success
farmy factory answer <id> <text|file> [--wait]   continue a question on a new run with the answer in its prompt
farmy factory prune [--older-than <n>d|h|m]   remove the run volumes of finished runs (all, or those ended longer
                                ago); prints each; the runs' folders stay. awaiting_review and question volumes stay
farmy factory run <id>          the controller itself (started detached, in a session of its own, by start)
farmy factory login <name> <agent>   make <agent>'s factory login with <name>'s image ("Factory logins")
```

**Factory logins.** An agent entry's `factory_login: {path, create}` lets its factory runs use a subscription
login of their own, never the interactive login in `farmy-shared`. `farmy factory login <name> <agent>`:

- refuses an agent without `factory_login` (naming `factory_login`), a `path` that is absolute or holds `..`
  (naming `factory_login`), a service whose image `farmy/<name>:dev` is not built (naming `farmy start <name>`),
  and an agent that service's image does not carry (naming the agent); it starts no container then;
- creates the volume `farmy-factory-login-<agent>` when missing (one per agent, on this Docker, whatever the
  service) and makes it the dev user's with a root container whose only command is `chown 1001:1001
  /home/dev/<path>`;
- runs `create` like the factory's git containers: `docker create --rm -i` (and `-t` on a terminal),
  name `<name>-factory-login-<agent>`, labels `farmy.role=login`, `farmy.service=<name>`, `farmy.agent=<agent>`,
  `-u dev`, the service's network `<name>_default` with the git containers' proxy variables, the volume at
  `/home/dev/<path>`, `--entrypoint sh farmy/<name>:dev -c <create>`; joined to `farmy` with `docker network
  connect`; run with `docker start -a -i`, its output passed through;
- on success exits 0; when `create` fails, says so naming the line and `exit <code>`, exits 1, and removes the
  volume if this call created it (so an existing volume means a login was made).

A second `farmy factory login` logs in again into the same volume. `farmy destroy` never removes a
`farmy-factory-login-*` volume.

In `mode: login` the agent container ("Agent containers" below) also mounts `farmy-factory-login-<agent>` at
`/home/dev/<path>`, writable, and gets neither `token_env` nor the `api` variables nor a broker. `factory
start` refuses login mode for an agent without `factory_login` (naming the agent and `factory_login`) and when
`farmy-factory-login-<agent>` does not exist (naming `farmy factory login <name> <agent>`), before any run
container starts.

One agent iteration at a time per factory login: before starting an agent container in login mode, a run
waits until no other agent container of the same factory login runs (from this containers folder); meanwhile
its phase is `login_wait` (`factory list`, `show`, `status --json`). Only the agent's turn waits: other
runs' clones, commits and gates go on, and the wait does not count against `iteration_timeout`. With
`concurrency` above 1, runs are admitted and share slots as before; agent iterations on one login run one
after another.

A login turn ends only when the agent container holding it is gone (record 2026-10-19-0907): if the
controller's `docker run` returns or fails while that container still exists, it removes the container
before the turn passes on. Login-mode agent containers carry the label `farmy.factory-login=<agent>`. Before
granting a turn the controller stops orphans: running containers labelled `farmy.role=agent` and
`farmy.factory-login=<agent>` whose run is one of this containers folder's (`.work/<service>/runs/<id>/`
exists) and whose controller is gone (its `controller.lock` not held). It removes each with `docker rm -f
<container>` before its own agent starts, together with that run's egress gate `<service>-run-<id>-egress-gate`
when it is there (record 2026-10-19-1210), keeps `orphans_stopped` in its own `state.json` (a list of
`{"container": <name>, "run": <id>, "gate": <the gate's name, or null>}`, empty or absent when none), and
`factory show` prints `stopped orphaned agent container <name> (run <id>)` naming the gate on that line. Containers of another factory login, of a live run, or
of another containers folder are left alone. A removal that fails is tried again, at least 3 tries over about 10 s (record 2026-10-19-1145); when
the orphan is still there the run does not start its agent and ends with the result `login_blocked`, and
`factory show` names the container and Docker's error.

`farmy status --json`: every service has `runs`, a list (oldest first) of `{"id", "phase", "iteration",
"max_iterations", "result", "branch", "started", "ended", "profile", "from", "question"}`.
`show` also names the profile and source and prints any question. The TUI highlights awaiting_review as
needing approval and displays question text, using these public status fields. Invalid start, approve or
answer requests exit 1 and name the reason. Waiting commands exit 0 only for green, 1 for every other result.

## The toolbox

The app container's image is built from the service's image (`image:`, or the stage built from
its Dockerfile) with the toolbox Dockerfile: farmy's `toolbox/` folder, or the `toolbox/` folder
in the containers folder when there is one. It is built with the build arguments `BASE` (the
image it builds on; `ARG BASE=debian:bookworm-slim` in the Dockerfile so that BuildKit does not
warn, farmy always passes it) and `AGENTS` (space-separated, the agents on for the service), and a context
holding the toolbox folder's files and `agents.tsv` (see "Agents"). farmy's own toolbox uses the
image's package manager, creates the `dev` user (uid 1001) and installs each agent with its
`install` line.

**The Debian rule.** farmy's own three images (control, keys, knowledge) are Alpine: they run
static binaries and small is all that matters. A service runs on the image it names, and the
docs recommend the official Debian `-slim` images (`ruby:3.4-slim`, `node:22-bookworm-slim`,
`python:3.12-slim`): the toolbox's apt path is the supported one. An Alpine service is accepted
and its toolbox build is checked; beyond that (prebuilt tools, native extensions, what is shared
on `farmy-shared`) nothing is promised, and nothing in farmy defaults a service to Alpine.

## Names

| Thing | Name |
|---|---|
| compose project of a service | `<name>` |
| app container | `<name>` |
| keys helper (the broker) | `<name>-keys` |
| the fragment's services | as compose names them (`<name>-<service>-1`), or `container_name` |
| volume holding the checkout | `<name>-src` |
| a mount of the definition | `<name>-<mount>` |
| volume holding the agents' per-service state (transcripts, sessions, the status file) | `<name>-agents`, at `/home/dev/.farmy-service`, a folder per agent; none when no agent is on |
| the one volume shared across every app container | `farmy-shared`, at `/home/dev/.farmy-shared` |
| the shared knowledge container | `farmy-knowledge` |
| the mesh egress node, and its state volume | `farmy-egress` (at `/var/lib/tailscale`) |
| the shared network, and the control container the shim starts | `farmy` |
| images | `farmy/<name>:base` (the Dockerfile stage), `farmy/<name>:dev` (with the toolbox), `farmy-keys:local`, `farmy-knowledge:local`, `farmy:local` (the control container) |

## Volumes

The rule: **shared across containers → `farmy-shared`; project state → per-service volumes;
binaries → the image.** `farmy-shared` is one external volume farmy creates, mounted in every app
container at `/home/dev/.farmy-shared`, agents on or off; inside it a folder per tool (`claude/`,
`codex/`, `vscode/`, `cursor/`, …) for what a tool keeps per user: logins, editor extensions.
The entrypoint links each agent's `login` paths into it (`~/.claude` → `.farmy-shared/claude/.claude`,
`~/.claude.json` → `.farmy-shared/claude/.claude.json`), an editor server's `extensions` →
`.farmy-shared/<editor>/linux-<arch>/extensions`, and makes the volume the dev user's. There is
no `dev-tooling` volume any more. Per-service state stays on the service's own volumes:
`<name>-src`, `<name>-agents` (each agent's `state` paths: `~/.claude/projects` is a link to
`/home/dev/.farmy-service/claude/projects`), the definition's `mounts:`. `destroy` removes a
service's volumes and never `farmy-shared`. A factory run will not mount `farmy-shared` (the
factory record).

**Bind mounts.** The daemon resolves a bind source on the host, and of the control container's
file system only the containers folder is there (mounted at its host path). So nothing farmy
generates bind-mounts a path outside the containers folder: farmy's own files reach a container
through its image or a volume.

Before the containers come up (made anew or started again) farmy removes `/workspace/.farmy-clone`
from the checkout's volume when that volume exists (a first start leaves the volume to compose, which labels it) (`rm -f` in a `docker run --rm` of the app image), so the marker it reads
is the new attempt's. The service clone operation writes `/workspace/.farmy-clone` when it is done cloning: `ok`, or `failed` followed
by git's last twenty lines. The reason farmy names is the first line that names a cause
(`detected dubious ownership`, `getaddrinfo`, `Name or service not known`, `Could not resolve hostname`, `Error connecting to agent`, `Permission denied`, `Host key verification failed`, `Could not
resolve host`, `Connection refused`, `Connection timed out`, `No route to host`, `SOCKS`,
`Repository not found`, `not found`, `unable to access`), and nothing of git's closing advice;
with none of them, the last two lines; `Authentication failed`, `could not read Username`,
`returned error: 401` and `returned error: 403` are causes too. When the repository goes through a
git route, farmy adds what it knows of that route: whose secret is not loaded, its state (`locked`,
`missing`, `provider failed`, `rejected …`) and `farmy keys reload`; whose secret is loaded and the
cause is an authentication one, that the host refused the route's secret, naming the route and the
secret's name. The shared Git launcher clones with `GIT_TERMINAL_PROMPT=0`, so git never waits for a user
name. It retries a clone that failed for a reason that may pass (a proxy or a connection right after
a recreate, `returned error: 503` while the broker is not loaded yet) up to four times over about
thirty seconds before it writes `failed`; a refused key, a refused token or a missing repository is
not retried. `start` waits for the file and reads it: `failed` ends start
with exit 1, naming the service and the reason (the container stays up for `farmy ssh`).

The checkout lives on `<name>-src`, mounted at `/workspace`, never in a container's writable
layer: `stop` keeps it, `destroy` removes it with every volume the compose file declares. The
app container gets the clone URL as `REPO` and the branch as `BRANCH`, and clones at its first
start. A workbench (`repo: none`) gets no `REPO` and nothing is cloned.

## Commands, exit codes, where messages go

```
farmy                         attach to the session (the TUI); also: farmy session. Without a terminal: the usage
farmy init                    prepare this folder: Docker, .env, the list of services (the shim: the control image, built when missing or stale)
farmy add <url> [--image <image>] [--name <name>]   write services/<name>.yml with repo: and image:; the name from the URL
farmy start <name>...         start a service's containers (and what it start_after), then its setup command;
                              ends with the addresses, or `<name>: no ports published`
farmy stop [<name>...]        stop containers; none named: everything, the shared container too
farmy restart <name>...       make the containers anew from the definition as it is now
farmy rebuild <name>...       the same, and build the images again from scratch
farmy destroy <name>...       remove containers and volumes; asks "y" on stdin first. Besides compose's down -v,
                              it removes <name>-src, <name>-agents, <name>-keys-agent, <name>-<mount> and <name>-run-*
                              itself, whoever made them
farmy status [--json]         every service: name, state, port block, repository, notes; --json: what the TUI renders from
farmy url <name>              the service's addresses on the host, one per line
farmy run <name> <command>    a named command of the service, or the words as a command (with GIT_PAGER=cat and
                              PAGER=cat in its environment: nothing pages)
farmy keys                    every route, its upstream, its state and who may use it
farmy keys reload [<name>...]  obtain the secrets again and load the brokers
farmy keys --why              run the provider once and print how it ended and its stderr, every secret and
                              unlocking value replaced by [redacted]; loads nothing
farmy lock                    forget the values the control container holds; the next load asks the host again
farmy factory start|list|show|log|cancel|approve|answer|prune   the factory loop ("The factory")
farmy agents                  every agent of the catalogue and of farmy.yml: name, on or off, mode, how to log in
farmy logs | ssh              pass-through to the containers; not covered by tests
farmy update                  the shim: build the control image again when its inputs changed
farmy help                    the usage
farmy --version               farmy <version> (<build hash>); farmy tui --version prints the same
```

The usage (`farmy help`, and the binary with no arguments) lists every command above, `add`,
`session`, `keys`, `keys reload`, `agents`, `logs`, `ssh` and `update` included.

`farmy add` needs neither Docker nor `.env`. The URL must be a clone URL (`https://`, `ssh://`,
`git@host:path`, `file://`), else a mistake in the command line naming it and nothing written. The
name is the last part of the URL without `.git`, or `--name`. On a terminal a missing `--image` is asked for; without a terminal it is a mistake in
the command line, named by `--image`, and nothing is written. A definition that exists already is
refused by file name and left as it is. On success it prints `farmy start <name>`.

| Exit | When |
|---|---|
| 0 | done, or nothing to do (a service already running, a declined destroy) |
| 1 | refused: Docker not running, `.env` missing or incomplete, a `ports.yml` in the folder, a definition without `repo:` or with a `repo:` that is no clone URL, a definition with neither `image` nor `dockerfile`, two services in one port block or one service in two, a fragment naming `app` or `keys`, a mount named `src`, a definition naming a route it is not granted, a repository or build that cannot be reached (named by its clone URL), a container that must be running and is not, a setup command that failed or did not finish within `setup_timeout`, `add` for a definition that exists |
| 2 | a mistake in the command line: unknown command, unknown service, missing argument |

The usage goes to stdout. Every refusal and warning goes to stderr and names what to check: the
file (`.env`, `services/<name>.yml`, `farmy.yml`), the key, the repository, or the
command to run (`farmy init`, `farmy start <name>`). When no service is defined, the message says
so and points at the README section "Adding a service"; `status` then exits 0 with the same
pointer.

## `farmy status --json`

What the session's TUI renders from, so that the tests pin the data and not the drawing:

```json
{"generated": "2026-10-13T18:00:00Z", "lan_host": "mini.local", "bind": "0.0.0.0",
 "egress": {"state": "registered", "name": "mini.tail1234.ts.net", "address": "100.101.102.103", "registration_url": null, "proxy": "farmy-egress:1055"},
 "services": [{"name": "shop", "state": "running", "block": "3100-3199",
   "repo": "https://github.com/acme/shop.git", "note": null, "commands": ["setup", "start", "test"],
   "ports": [{"host": 3100, "container": 3000, "url": "http://localhost:3100", "lan_url": "http://mini.local:3100", "listening": true}],
   "containers": [{"name": "shop", "service": "app", "state": "running", "health": null},
                  {"name": "shop-pg", "service": "postgres", "state": "running", "health": "healthy"}],
   "agents": {"claude": {"state": "working", "since": "2026-10-13T17:58:10Z", "source": "hooks"},
              "codex": {"state": "idle", "since": null, "source": "process"}}}]}
```

- `egress`: see "Mesh egress"; null without `egress:`.
- `lan_host` is `LAN_HOST` or null; `block`, `repo` and `note` are what `status` prints (`block`
  null without ports, `note` null without one); `commands` the names under `commands:`.
- `ports`: one entry per `ports:` pair; `url` is the localhost address, `lan_url` the one with
  `LAN_HOST` (null without); `listening` is whether something listens on the container port, read
  from `/proc/net/tcp` and `/proc/net/tcp6` inside the app container through `docker exec` (a
  line with `:<port in hex> ` in state `0A`), null when the service is not running.
- `containers`: every container of the compose project, with the compose service it came from
  (`app`, `keys`, the fragment's), its state, and its health (`healthy`, `unhealthy`, `starting`)
  or null without a healthcheck.
- `agents`: null when the service is not running. Else one entry per agent on for the service.
  From the file `/home/dev/.farmy-service/<agent>/agent.status` on the service's agents volume
  (one line: `<working|waiting|idle>\t<RFC 3339 time it began>`, written by the agent's status
  hooks): `{"state", "since", "source": "hooks"}`. Without the file, `docker top`: the agent's
  `process` running means `running`, else `idle`, with `since` null and `source` `process`. The
  TUI shows the most active one.

`bind` is the host address published ports listen on: `127.0.0.1`, or `0.0.0.0` with `LAN_HOST`.
`status` prints, after the egress line, `ports  127.0.0.1 only (LAN_HOST in .env opens them to the
network)` or `ports  every interface (LAN_HOST=<name>)`, then one line per defined service: `<name>  <state>  <port block>  <repository>`,
state being `running` or `stopped`, the block `3100-3199` or `-` for a service without ports,
the repository being the clone URL or `none` for a workbench, followed by a note when the definition changed since the service was started
(`definition changed — run farmy restart <name>`).

## Docker in the tests

The tests find `docker` on the PATH, as the program does; what they put there is a fake that
records every call and keeps what it was asked for. Nothing inside the program is replaced.
The fake understands the Docker CLI as it is commonly used, and the tests observe through it:

- **Containers** with their state (running, exited), image, published ports, environment
  (`environment:` and `env_file:` of the compose file, resolved), `init`, named volumes,
  networks, labels and the compose service they came from. They come from `docker compose
  up`/`down`/`stop`/`start`/`restart`/`rm`/`ps`/`exec`/`run`/`build`/`config` with `-p` and
  `-f`, and from `docker run`/`create`/`start`/`stop`/`restart`/`rm`/`ps`/`inspect`/`exec`/
  `logs`/`port`/`stats`. `container_name:`, `depends_on:` and top-level `volumes:`/`networks:`
  with `name:` are honoured (a `condition: service_healthy` on a service without a `healthcheck`
  fails `up`, and `down -v` leaves an `external: true` volume alone, as the real compose does); `${VAR}` and `$VAR` in a compose file are interpolated from a `.env`
  next to the file and the process environment, `$$` is a literal `$`, and an unset variable without a
  default becomes blank with compose's warning on stderr (`The "VAR" variable is not set. Defaulting to a
  blank string.`). A compose file farmy writes holds no variable for compose to fill: a value goes into the
  file, a `$` meant for a shell in the container is written `$$`.
- **Images** from `docker build` (`-t`, `-f`, `--target`, `--label`, `--build-arg`, a context
  folder or `-`), with the Dockerfile's text, the files in the context (and their hashes), its
  `LABEL`s and its `ENTRYPOINT`/`CMD` (a container's process is composed from them and the
  `docker run` line, as Docker does), and the text of small `.tsv`/`.txt`/`.yml`/`.json`/`.sh`
  files in the context; readable back with `docker image inspect`, `docker images`, `docker inspect`.
- **Volumes and networks**: `create`, `ls`, `inspect`, `rm`.
- **Commands run in a container** with `docker exec` or `docker compose exec`, with their user
  (`-u`), folder (`-w`) and, for `exec -i`, what they received on stdin: the container must exist
  and be running. They print nothing and exit 0, whatever they are, with two exceptions that let a
  slow command be played: `sleep <seconds>` takes that long, and `timeout <seconds> …` ends what it
  wraps at that limit with exit 124, as the real commands do. The program cannot rely on their
  output, only on their exit code.
- What a command in a container may learn, all of it state a test set: a read of `/proc/net/tcp`
  for a port in hex exits 0 when the test said something listens on that port in the container
  (`listening`), else 1; `cat <path>` of a file on a volume mounted there prints what the test put
  on the volume (`volume_file`), else fails as `cat` does, except `/workspace/.farmy-clone` in an app
  container that has a `REPO`, which answers `ok` as the entrypoint leaves it after a clone that worked; `farmy unlock-names` in the control
  container prints the names under `secrets.unlock` of the `farmy.yml` in its working folder and,
  without `secrets.provider`, the secret of every route under `keys:`, once each, one per line, as the
  real farmy does (the one output the shim relies on); `docker logs <container>`
  prints what the test set (`container_log`: on stderr unless told otherwise, and only from the
  n+1st read on with `after: n`); in a container with the volume `farmy-egress`,
  `tailscale status --json` answers `Running` with the node's name and address when the volume
  holds a registered node (`mesh_registered`, or a command run there that was given an auth key:
  `--auth-key` among its words or `tskey-` on its stdin registers one), else `NeedsLogin`. A compose service with a `healthcheck:`
  is `healthy` (`docker inspect`: `State.Health.Status`). `docker top` lists the container's main
  process and what the test said runs there (`process_in`).
- A network made with `--internal`, and `none`, have no way out; others, and the bridge, do. An `agent` container reaches
  its model through its broker (`keys` resolvable, the broker reaching out) or straight out (a resolvable proxy, else a
  network with a way out); else it prints `API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)`
  and exits 1, writing nothing.
- `docker network connect` and `disconnect` add and remove a container's network. A container resolves only the names
  on the networks it is attached to (container names, compose services, aliases; a dotted name is the host's DNS); a
  `git` container that fetches or pushes through a proxy, ProxyCommand host or broker route it cannot resolve fails as
  git does (`nc: getaddrinfo for host … Name or service not known`). `docker create` then `docker start -a` runs a
  factory container on the networks it has by then. Compose's `down -v` removes only volumes with its project's label.
- `docker exec -e` is kept on the exec; `docker build` without `-q` prints a few BuildKit-style lines
  on stderr.
- `farmy-keys loaded` run in a keys container prints the names of the last load into it since it
  last started (a restart or a new container has lost what was loaded before).
- A container keeps its `devices:` and `cap_add:` (`--device`, `--cap-add`); a device the test said
  the daemon refuses (`docker_refuses_device`) fails `compose up` with Docker's message. `rm -f
  <path>` run in a container or a `docker run` removes the file from a volume mounted there. The
  clone marker of an app container is `ok` unless the test said its clone fails (`clone_fails`), or
  the app has `SSH_AUTH_SOCK` (an SSH route) and its keys container was not loaded since it last
  started: then `failed` with `Permission denied (publickey)`; or its repository goes through a token
  route (`DEV_GIT_ROUTES` rewrites its host), the test said the repository is private
  (`private_repository`) and its keys container was not loaded with that route's secret since it last
  started: then `failed` with git's `could not read Username for '<host>': terminal prompts disabled`.
- **The factory.** A volume also has a real folder (in the fake's journal). A `docker run` labelled
  `farmy.role=git` or `test` runs its command for real, on the host, in those folders: every mount target
  that stands as a path in a word of the command, the environment or `-w` is replaced by the volume's folder;
  a `:ro` mount is made read-only for the run; a `--tmpfs` is a fresh folder; `timeout <s>` ends the command
  at that limit with exit 124; Docker's own exit code is the command's. A `docker run` labelled `agent` plays
  what the test said (`agent_plays`, one per agent run of the service, in order): it writes the files given
  under `/workspace` (none under a `--tmpfs` target, none into a read-only mount), prints the words, idles,
  and exits with the code given (124 when the idle time passes a `timeout <s>` in its command); `says` goes to
  stdout, `stderr` to stderr. A `docker run` labelled `version` prints what the test said the service's CLI
  version is (`agent_version_prints`; `1.0.0` when it said nothing) and exits 0, or, when the test said the
  version command fails (`agent_version_fails`), prints `sh: 1: <first word>: not found` on stderr and exits 127, or, when dev may not execute it
  (`agent_version_denied`), prints `sh: 1: <first word>: Permission denied` and exits 126.
  When it never answers (`agent_version_hangs`), it is listed as running and prints nothing until its own
  `timeout N` ends it (exit 124), until it is stopped or removed (exit 137), or for 120 s (exit 0).
  A `docker run` labelled `login` writes `auth.json` into a mounted `farmy-factory-login-*` volume, prints
  `Successfully logged in` and exits 0, or, when the test said the login fails (`login_fails`), prints
  `Error: the device code expired before it was confirmed` on stderr and exits 1. `fail_role`
  makes Docker refuse a role's containers with exit 125. Volumes have an owner (see the factory-ownership record):
  root for one made by `docker volume create` or a `docker run`, the dev user (1001) for an app container's checkout,
  the uid of a root `chown <uid> <target>`; a `git` container whose user is not a mounted volume's owner fails as git
  does (`detected dubious ownership …` with a repository there, `could not create work tree dir … Permission denied`
  without), exit 128. Compose warns about an existing volume without its project's label that is not `external`. Any other role (`measure`) runs for real like git and
  test. A factory agent container is listed as running (`docker ps`) while it plays; when its client is killed
  it stays running, as with Docker; `docker stop`, `kill` or `rm -f` ends its play (exit 137); when it ends,
  `--rm` removes it. A test can make `docker rm` of a container fail a number of times, or always
  (`rm_fails`), with `Error response from daemon: cannot remove container "/<name>": could not kill:
  permission denied`. `docker network connect` and `disconnect` change a container's networks, and every join is kept with
  its `--alias` names (`network_joins`); every network made is kept with whether it is `--internal`. Every `docker run` is kept with its name, labels,
  mounts (`ro`), tmpfs, environment, user, networks, process and what it got on stdin (`-i`). The environment
  is made as Docker makes it when the container is made (`docker run`, or `docker create` for a later `start`):
  each `--env-file` (`NAME=value` lines; a bare `NAME`, like `-e NAME` without a value, takes the `docker`
  process's own value), then `-e`; every env file read is kept with its path and mode (`env_files`). An app
  container whose `REPO` is a `file://` URL gets a real clone in its checkout volume's folder when it is made.
  Every `docker run` also keeps when it started and ended.
- **An agent's steps** (record 2026-10-21-1332). An agent play may have `steps`, done in order after its writes
  and before its idle time: `run: <line>` runs the line for real on the host with `/bin/sh -c`, as the agent's
  container would. Every mount target of that container that stands as a path in the line, or in a value of its
  environment, is replaced by its folder: a volume's folder, a bind's source, and for each `--tmpfs` a fresh empty
  folder that lasts as long as the container (so a covered path reads empty). The environment is the container's,
  as Docker made it, mapped, and nothing else; HOME is a fresh folder unless it lies on a mount; PATH is the
  container's `PATH` (Debian's default when it sets none), mapped, behind a folder that holds every file bound or
  mounted into a folder on that PATH, so a program put there is found by its name. It runs in the container's
  `-w` (else `/workspace`). The image adds no file: a program only the image carries is not there. A program the
  line starts gets no other mapping (a path written inside its own files is the host's), resolves no container
  name, and uses the test machine's own tools. So a program meant for the agent's container finds what it needs
  through its arguments, its environment or its own location, on something mounted into the container.
  `background: true` starts the line and goes on; the agent waits for every such line before it ends. `writes:`
  writes files as the play's writes do; `find: <text>` notes every file the container can see that holds the text
  (a file under a covered path is not seen); `list_writable: true` notes every entry (file, folder, link, FIFO) the
  container can see under a mount it can write (a volume or bind not read-only, a tmpfs not `ro`; what lies under
  a read-only mount is not seen), so a test can compare two moments; `sleep: <s>` waits. Each line's stdout and
  stderr (apart, each chunk with the time it came), its exit code, start and end are kept; a line that printed
  more than 256 KiB keeps its output in files instead. The agent's `timeout <s>` covers its steps: at
  the limit every line still running is killed and the agent exits 124; `docker stop`, `kill` or `rm -f` of the
  agent's container kills them too (137).
- A `docker run` labelled `verify` runs for real like `test`. It is listed as running while its command runs;
  `docker stop`, `kill` or `rm -f` of it ends its command (exit 137) and, as with Docker, returns once it has ended.
  When the test said so (`verify_sidecars_unhealthy`), the containers of every compose project
  `<service>-run-<id>-verify` are `unhealthy` (`docker inspect`'s `State.Health.Status`, and `compose up --wait`
  fails with `dependency failed to start: container is unhealthy`); the gate's sidecars stay healthy. When the
  test said so (`verify_containers_print_first <bytes>`, record 2026-10-21-1700), every verify container first
  prints that many bytes of `printed before the command` lines, 4 KiB at a time alternately on stdout and stderr,
  as output that comes before a verify's command starts would; only then does it run its process. Stopped (or no
  longer read) meanwhile, it ends there (137) and its process never runs.
- `docker context inspect` names `FAKE_DOCKER_CONTEXT_HOST` as the current endpoint (default
  `unix:///var/run/docker.sock`); `--format '{{.Endpoints.docker.Host}}'` prints it alone.
- `farmy unlock-names --missing` in the control container prints the names `farmy unlock-names` would,
  less those a `farmy` command run there received on stdin since the container last started and since
  the last `farmy lock` run there: the holder, as the real farmy keeps it.
- Next to the fake docker is a fake `infisical` (with `HTTPS_PROXY` and `--domain` it first goes
  to the domain through the proxy by CONNECT, as the Go CLI does, and fails when the proxy does
  not answer 200): `secrets get <NAME> --plain …` answers from
  `FAKE_INFISICAL_SECRETS` (`NAME=value;NAME2=value2`), a name not in there fails as the real CLI
  does; `login --method=universal-auth --plain …` prints the token of the identity whose client id and
  secret (`--client-id`/`--client-secret`, or `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` and
  `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET` in its environment) are in `FAKE_INFISICAL_IDENTITIES`
  (`id:secret=token;…`) and fails for any other pair. Every call logs its arguments, `INFISICAL_TOKEN`
  and, for a login, the identity it was given to `FAKE_INFISICAL_LOG`.
- The stores are fakes too, one per test on the PATH ahead of everything, and only the one the test
  chose: `security` plays the macOS Keychain (`find-generic-password [-s service] [-a account] -w`
  prints the password of the matching item, exit 44 for none, exit 36 "User interaction is not
  allowed" while locked until `unlock-keychain` ran, which the fake accepts without a password;
  `add-generic-password` adds one), `secret-tool` the secret service (`lookup attr value …` prints
  the secret of the item holding every pair, without a newline; exit 1 and nothing for none; exit 1
  and a message naming the locked collection while locked; exit 1 and `Cannot autolaunch D-Bus without
  X11 $DISPLAY` when it cannot be reached; `store --label=… attr value …` adds one
  from stdin). Both log every call. The shim therefore finds a store by `command -v`, not by the
  operating system.
- `docker info` and `docker version` answer; when "Docker is not running" every call fails
  with `Cannot connect to the Docker daemon ...` and exit 1, as the real client does.
- `--format` takes Go templates of the form `{{.Field}}`, `{{.A.B}}`, `{{index .Labels "k"}}`,
  `{{range .X}}…{{end}}` (with `$k, $v :=`), `{{if eq .A "b"}}…{{end}}`,
  `{{.Label "k"}}`, `{{json .}}`, `table ...`, or `json`. `--filter name=`, `label=`,
  `status=`, `reference=` work. Anything else is accepted silently and shows up in the
  failure message as "unhandled by the fake".

Git is the real one. The git host in a test is a folder of bare repositories, reached through
`file://` clone URLs written into `repo:`. The host's Git identity comes from the global Git
configuration, which the tests point at a file of their own with `GIT_CONFIG_GLOBAL`.

## Enforced egress

This contract supersedes advisory proxy and factory `-out` rules **for restricted containers**.
Factory agents are always restricted, in every mode. Apps are restricted when workspace
`egress.restrict` OR definition `restrict` is true; false in a definition cannot undo global true.
Unrestricted apps, control, credential brokers and the mesh node retain their earlier behavior.
The factory test gate remains isolated from all proxies, with only its allowed sidecars.

```yaml
# farmy.yml
egress:
  restrict: true
  allow: [docs.example.com, 'downloads.example.com:8443']
  services:
    shop:
      allow: [private-packages.example.com]
  # proxy: http://proxy.example.com:3128  # optional upstream instead of mesh
  # authkey: TS_AUTHKEY                  # optional existing mesh configuration
```

The definition accepts `restrict: true|false` and `egress: {allow: [...]}`. Allow lists
union global, workspace service and definition additions. Workspace `egress.services` entries
only accept `allow`. Existing config fields continue to work. An egress map containing only
`restrict`, `allow`, `services` configures filtering, **not** a mesh. The old empty `egress: {}`
still requests mesh, as do authkey/tailscale/join_timeout; `proxy` selects the external proxy.
`FARMY_EGRESS_PROXY` continues to override the upstream, never the filtering gate seen by an app.

An allow entry is a DNS hostname or IP literal, optionally `:port` (brackets for IPv6), or a
leading `*.` DNS suffix optionally with a port. Port range is 1..65535; absent port means any.
Matching ignores DNS case and one final dot. `*.example.com` matches one or more complete labels
before example.com, never example.com or badexample.com. All other wildcard forms, URLs,
userinfo, paths, empty hosts and invalid ports are rejected before modifying config or starting
containers. Destinations are matched on the requested host, not a DNS suffix guessed from an IP.
HTTP absolute URI authority governs routing; an incompatible Host header is rejected with 400.
CONNECT requires an explicit host and port. Denied requests return HTTP 403 with a reason naming
the host, before DNS or upstream connection. TLS is copied as opaque bytes after CONNECT 200.

The shipped data file `egress-hosts.yml` has one named set `registries`, a YAML sequence:
`deb.debian.org`, `security.debian.org`, `dl-cdn.alpinelinux.org`, `rubygems.org`,
`index.rubygems.org`, `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`,
`proxy.golang.org`, `crates.io`, `index.crates.io`, `static.crates.io`.
`@registries` in an app allow list expands this set; unknown set names are rejected.
App policy includes this set by default, the `api_hosts` of agents enabled for this service,
each configured `git: true` route's upstream host, and the additions above. A non-default port
in a git route is retained; a route without an explicit port contributes its host.

Catalogue `api_hosts` is a sequence, merged like other agent fields: an override replaces the
list, absence on a custom entry means empty. Factory policy contains **only** the selected
agent's `api_hosts`, irrespective of app policy, global extras or `egress allow`. API-key mode
still has its fixed credential-broker route; no arbitrary forwarding through that broker.
Each shipped entry cites its destination evidence in comments. Verified 2026-10-15 defaults:

| Agent | `api_hosts` (each entry uses `:443`) | Evidence |
|---|---|---|
| claude | api.anthropic.com, claude.ai, platform.claude.com | https://code.claude.com/docs/en/network-config |
| codex | api.openai.com, chatgpt.com, auth.openai.com | https://learn.chatgpt.com/docs/config-file/config-sample ; https://learn.chatgpt.com/docs/app-server ; https://developers.openai.com/api/docs/guides/ip-allowlist |
| gemini | generativelanguage.googleapis.com, cloudcode-pa.googleapis.com, oauth2.googleapis.com, accounts.google.com, www.googleapis.com | https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts ; https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts ; https://developers.google.com/identity/protocols/oauth2/native-app ; https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta |
| opencode | opencode.ai | https://opencode.ai/v2/docs/console/models/ (hosted provider only; override for other providers) |
| cursor | api2.cursor.sh, api5.cursor.sh, *.api5.cursor.sh, authenticate.cursor.sh, authenticator.cursor.sh, prod.authentication.cursor.sh, authentication.cursor.sh | https://cursor.com/docs/enterprise/network-configuration |
| copilot | github.com, api.github.com, *.githubcopilot.com, copilot-proxy.githubusercontent.com, origin-tracker.githubusercontent.com | https://docs.github.com/en/copilot/reference/copilot-allowlist-reference |

### Topology and live policy

Restricted containers join only networks marked internal by Docker, never default bridge,
host networking or outward `farmy`. There is no temporary outward startup attachment. Their
HTTP_PROXY/HTTPS_PROXY and lower-case counterparts point to a reachable filtering gate; any
ALL_PROXY also points to that gate using HTTP, never directly to the mesh/upstream. NO_PROXY
may include local peers, never external hosts or `*`. Ignoring these variables gives no route
out. SSH git uses HTTP CONNECT through the gate when it needs outbound SSH.

Filtering proxies carry Docker label `farmy.role=egress-gate` and connect to the client's
internal network plus an outward network. They may be per service, per run, or shared with
distinct peer policies; an agent must not be able to acquire an app policy. They can reach
`farmy-egress` on `farmy` when mesh is configured; restricted clients cannot reach it directly.
An upstream HTTP proxy is used for both absolute-form HTTP and CONNECT requests. Upstream
failure returns 502, never a direct-connection retry. Filter-only config connects directly.
Run-specific proxies/networks are cleaned up at all terminal outcomes and their denial logs
are retained for `egress log`/status. No old per-run `-out` network is created for agent access;
the broker and filtering proxy can use existing outward `farmy`.

`farmy egress allow HOST [--service NAME]` validates and normalizes the entry, writes it once
under `egress.allow` or `egress.services.NAME.allow`, preserves other config, and reloads all
affected running app gates. It does not start/restart/recreate a container, change restriction,
or widen factory policy. An unknown service or invalid entry exits 1 without changing files.
The next request uses the new policy. An existing permitted CONNECT tunnel may finish.

`farmy egress log [SERVICE] [--json]` displays the most recent 100 egress events, oldest first,
selecting only that service when supplied. Readable lines are the default; --json is NDJSON.
Every denial names host, numeric port, container and service; never log credentials, URL paths,
headers or TLS content. Service entries in `status --json` gain `egress` with
`{"restricted":true|false,"denied":<integer>,"mode":"strict"|"audit"|"unrestricted"}`; counts combine current app gate history and
retained run denials, without counting a run twice. The TUI shows this count on each service.
Live gate counts start at zero when that process starts and survive reload. Retained run counts
last as long as the run record. The existing top-level `egress` mesh/proxy object is unchanged.

### Filtering proxy executable contract

`bin/farmy-gate` is built by `bin/build` and available in the gate image; it may wrap a broker
mode. `serve` reads FARMY_GATE_PORT (default 9182) and FARMY_GATE_SOCKET (default
`/run/farmy-gate/control.sock`), starts with deny-all, and offers `GET /-/health` on the HTTP
listener returning 200. `load` reads JSON from stdin and sends it over that Unix socket:

```json
{"version":1,"upstream":null,"clients":{"shop":{"service":"shop","addresses":["172.18.0.2"],"allow":["registry.npmjs.org","api.example.com:443"]}}}
```

Keys of `clients` are real container names. `addresses` is a list of exact peer IPs from Docker
inspect; when omitted, the gate resolves the container name on its shared Docker network and
matches the connection's peer IP to those addresses. No address wildcard or HTTP identity
header. Unknown clients are denied as container/service `unknown`. `upstream` is null or an HTTP
proxy URL. A valid load atomically replaces policy and exits 0 only after application. Invalid
input exits 1 with a reason and leaves prior policy intact. Control socket never mounts in a
restricted container and no HTTP endpoint can reload. Policy is trusted control-plane data.

`log` via the Unix socket returns the latest 100 events as JSON lines. `status` returns
`{"version":1,"denied":{"shop":2}}`. Each denial is also emitted on stdout immediately:
`{"event":"denied","host":"example.com","port":443,"container":"shop","service":"shop"}`.
Events include an RFC3339 UTC timestamp. A `load` preserves log and counts. The real-proxy
tests use loopback peers and real HTTP/TCP upstreams; they never load program source.

The fake Docker models `farmy-gate load|log|status` and curl through the supplied policy, using
the actual container's network membership and identity. An internal network has no direct
external route. The fake records proxy hops and denies unlisted destinations with the same
JSON log. Agent plays can request URLs to prove policy independently of their model request.

### Red-first prompt reliability

A red_first profile's default prompt says a test must fail if **any** check fails. It explicitly
mentions `set -e` (or equivalent shell handling) and warns against swallowed assertions. An
earlier failing command followed by a successful command cannot constitute a passing test.

## Distribution

The program distribution's `VERSION` is the single version source, initially `0.1.0`.
The binary, TUI, installed shim and farmy-owned images use it. Stable versions are exact
`MAJOR.MINOR.PATCH` integers without leading zeros, v prefix, suffixes or ranges. Every
farmy-owned image (control, keys, knowledge, gate, service toolbox and other farmy builds)
carries `farmy.version` and nonempty `farmy.hash` labels. Vendor base/sidecar images are
not relabeled. Control images also carry `farmy.format`, highest readable format, initially 1.

`bin/release VERSION` validates VERSION against the version source and requires
FARMY_REGISTRY before any push. Docker buildx builds and pushes `linux/amd64,linux/arm64`
images named `<registry>/farmy-{control,keys,knowledge,gate}:<version>`, also tagged
`:latest`. The registry may include an owner/path and port. No registry is hard-coded.
Release does not edit VERSION or user files. A failed build/push returns nonzero and
does not claim success. CI configuration is an example, never required to run release.
Docs show GitHub `ghcr.io/acme` and Forgejo `forgejo.example.com/acme`, based on their
official container registry guides. No real release publication is authorized by tests.

For checking the real build without publishing, `bin/release VERSION --image ROLE
--output ARCHIVE` exports just that farmy image as an OCI archive for both supported
platforms, with the same labels/build inputs, without --push or a required registry.
ROLE is control, keys, knowledge or gate; unknown roles fail before build. The optional
real-build integration exercises gate and checks both platform descriptors in its OCI
archive. It skips only when real Docker or a builder supporting both targets is absent.

The control image contains the standalone executable POSIX shim at
`/usr/local/lib/farmy/farmy`, retrievable with Docker create/cp/remove without executing
a platform-specific binary. `bin/install [--to VERSION] [--dir DIR]` defaults to
`$HOME/.local/bin`; it requires Docker and installs only `DIR/farmy`. No version means, for the
checkout's `bin/install`, pull control `:latest` and read its `farmy.version`, then use the exact tag; the installer a
release attaches (rendered by `bin/render-release`) carries its own version and installs that release, even when a
newer one is `latest`. `--to` wins in both. It ends with `installed farmy <version> at <DIR>/farmy` on stdout and, when
`DIR` is not on `PATH`, a line holding `export PATH="<DIR>:$PATH"` with `DIR` written out; nothing about `PATH` when it is. Installation
retains FARMY_REGISTRY and optional FARMY_SOURCE defaults in the shim; environment overrides
win. It must not replace an existing shim until pull/extraction succeed. POSIX utilities
are available, but host Git, curl, jq, Python, Ruby, Rust and a checkout are not required.

The shim pulls `<registry>/farmy-control:<its-version>` by default and reports pulling or
building. FARMY_BUILD=1 skips that pull and builds locally. A failed pull reports failure
and tries a build. A checkout supplies local context; standalone fallback uses FARMY_SOURCE,
a URL Docker accepts as remote build context (for example a Git URL with ref/subdirectory).
Missing source gives an actionable refusal naming FARMY_SOURCE. A local build needs no
configured registry. Local development caching retains its content-hash behavior.

`farmy update [--to VERSION]` runs on the host through the shim. It selects --to first,
then an exact current-folder pin, else the latest control image's version label. It pulls
all four exact images before atomically replacing the installed shim, preserving selected
registry/source defaults. Any pull/extraction failure leaves the existing shim and running
containers unchanged. Updating does not rewrite farmy.yml. Versions and formats are checked
without requiring a host YAML library. Quoted and unquoted ordinary top-level scalar pins
and formats, with comments, are supported; invalid/ambiguous values fail with a reason.

`farmy.yml` may contain `farmy: 0.1.0`. Ordinary commands refuse a different shim/binary
version before changing containers and name `farmy update --to <pin>`. `update` and
`--version` remain usable during mismatch. Ranges are refused. A shim finding a running
control image newer than itself warns with both versions and `farmy update` before its
normal control selection/recreation. Installed copies must work outside the source tree.

`status` for an older toolbox version includes exactly the useful phrase
`built by <old>, now <current>: farmy rebuild <service>`. JSON service entries gain
`toolbox_version` (string or null) and `toolbox_outdated` (boolean). Current or newer
toolboxes are not marked older. The TUI uses these fields to show the same drift.

Both service definitions and farmy.yml may contain positive-integer `format: 1`; absence
means 1. A greater format is refused before changing containers. Latest control image
metadata (`farmy.format`, `farmy.version`) may name a capable reader in that refusal.
Otherwise say the required version is unknown and give `farmy update`. Name the file and
requested format in either case. Never assume a future release supports an unknown format,
or execute an unsupported file through the newly discovered binary automatically.

### Audit egress and readable logs

App policy uses the strongest of global `egress.restrict`, definition `restrict` and
definition `egress.restrict`: true (strict) > audit > false (unrestricted). An omitted
value is false. Both strict and audit keep clients on internal networks using the gate.
Factory agents always use strict selected-agent api_hosts, ignoring all app audit settings.
Docs recommend strict factory runs and audit for interactive apps using agents' WebFetch.

Gate policy clients accept `mode: "strict"|"audit"`; absent means strict. Audit recognizes
the peer as before, permits every host through the same configured upstream, and records
each normalized host/port pair once per container for the gate process lifetime. Include
allowlisted hosts too. Reload preserves observations; another port or container is distinct.
Unknown clients are still denied. Counts in `status.denied` count only denied events.

Denials keep `event: "denied"`; audit observations use `event: "allowed", mode: "audit"`.
Both include `timestamp` as RFC3339 UTC, host, numeric port, service and container, never
path/query/credentials/headers/body. CLI default output has one whitespace-separated line
per event: timestamp, service, container, host:port, decision (allowed/denied). IPv6 uses
brackets. Old records lacking timestamp render `-`. Empty readable output says no egress
events; empty --json output is empty. --json is NDJSON, preserving the machine-readable
fields for service-filtered and retained factory events. Restriction in service status is
true for strict and audit, false for unrestricted; mode names are strict/audit/unrestricted.

## Toolbox and dotfiles contracts (2026-10-15 review)

This section supersedes older toolbox/shared-home rules where they conflict. Catalogue tools are
official pinned static/prebuilt downloads, not distro packages. Shipped `tools.yml` contains neovim,
ripgrep (>=15.2), fd, fzf, bat, lazygit, delta and jq. Each has verified Linux amd64 and arm64 assets
for the base/libc families it supports. A missing compatible artifact is an actionable refusal.

Workspace configuration adds:

```yaml
tools: [neovim, ripgrep]             # absent: []; service tools add to this deduplicated selection
packages: [imagemagick]             # service packages add to this list; distro names, not catalogue names
toolbox: {managed: true}            # false opts a custom toolbox out of managed tools AND packages
shell: zsh                         # default zsh; sh, bash, zsh accepted, installed in the image
shared_data: [nvim]                 # default [nvim]; [] shares none; single directory names only
dotfiles:
  repo: https://git.example.com/dev/dotfiles.git
  install: install.sh               # optional repository-relative executable, using its shebang
tool_catalogue:
  formatter:
    version: 2.4.0
    releases:
      kind: github
      repo: example/formatter
      api: https://api.github.com   # optional API base; custom mirrors/local release services supported
      assets:
        linux-amd64-glibc: formatter-{version}-linux-amd64.tar.gz
        linux-arm64-glibc: formatter-{version}-linux-arm64.tar.gz
    artifacts:
      linux-amd64-glibc: {url: https://releases.example.com/formatter-2.4.0-linux-amd64.tar.gz, sha256: '<64 hex digits>', format: tar.gz}
      linux-arm64-glibc: {url: https://releases.example.com/formatter-2.4.0-linux-arm64.tar.gz, sha256: '<64 hex digits>', format: tar.gz}
    install:
      apt: 'tar -xzf "$ARCHIVE" -C "$DESTDIR/usr/local/bin" formatter'
```

The catalogue has the same fields as custom entries. `artifacts` keys are `linux-<amd64|arm64>-<glibc|musl>`;
formats are raw, tar.gz, tar.xz or zip. Optional `min_libc` records an artifact's actual minimum runtime.
Install recipes are per supported base family (`apt`, `apk`), running as root after SHA-256 verification,
with `ARCHIVE` naming the verified file and `DESTDIR` the root prefix (default `/`). No recipe may
silently substitute a distro release for its selected catalogue tool. Unknown names/fields and
incomplete pins fail with the configuration/tool/platform identified before installation.

Workspace catalogue overrides merge fields with shipped entries. A version change discards inherited
artifacts; the override must supply a complete set for its required architecture/libc matrix. URL and
checksum changes are a pair. Required combinations are the entry's declared release assets (or complete
artifact matrix for a manually pinned entry); an active Alpine selection requires a musl artifact.
Keep unsupported families explicit rather than pretending every vendor ships every variant.

`farmy toolbox list --json` returns a JSON object mapping available tool names to their resolved entries,
including inactive tools. Normal builds resolve selection and pins once and put `tools.yml`,
`packages.txt` (one distro package name per line), executable `tools-install.sh` and `farmy-home.sh` in
the toolbox build context. The generated Dockerfile carries each selected pinned URL and SHA-256 for
each architecture, and calls the installer so checksum verification is executed, not just documented.
The installer accepts normal customization inputs `TARGETARCH=amd64|arm64`,
`FARMY_BASE_FAMILY=apt|apk`, and `DESTDIR`; otherwise it detects the actual image platform/base.
This is also the interface for a managed custom toolbox. Existing `BASE`/`AGENTS` behavior continues.

`farmy toolbox bump [tool ...]` defaults to the union of active selections across service definitions.
Explicit names select only those tools. Read stable GitHub release data through the configured API,
resolve every required asset, download and calculate SHA-256, and verify published checksum metadata
where supplied. Asset templates substitute `{version}`. A missing resolver, artifact, download or
verification failure aborts the entire requested update before replacing the lock. Custom manually
pinned entries remain installable without release metadata but cannot be bumped without a resolver.
One successful bump atomically writes containers-folder `tools.lock`:

```yaml
version: 1
tools:
  formatter:                       # full resolved entry, with version, artifacts and install/release fields
    version: 2.5.0
    # ... all required pinned artifacts and their checksums ...
```

The lock overrides shipped pins, retains unrelated locked entries and never rewrites `farmy.yml`.
An explicit custom version definition remains subject to the complete-artifact rule even when a lock
exists; a stale lock cannot repair an invalid override by silently inheriting another version's files.
Normal start/rebuild never writes the lock. Status reports when a shipped pin is newer than a locked
pin, naming both versions and exactly `farmy toolbox bump` as the remedy.

**Dotfiles lifecycle.** Initialize one clone at `farmy-shared/dotfiles` on the remote's default branch,
using existing git route/broker authentication. Concurrent initialization/update is serialized, initial
clone publication is atomic and updates are fast-forward only. Refuse dirty clones or an unexpected
configured repository change. Only farmy's initialization/update operation mounts that clone writable;
apps see it read-only. Private HTTPS and SSH clones follow the same credential rules as app clones.

The real startup/pull path executes `farmy-home.sh` as dev with HOME set to the service's home, after
shared-data links and before service setup. It accepts `FARMY_DOTFILES_DIR` (default
`$HOME/.farmy-shared/dotfiles`), optional `FARMY_DOTFILES_INSTALL`, `FARMY_SHARED_DATA` (space-separated
directory names, default nvim), and `FARMY_TOOL_VERSIONS` (stable canonical key of selected tool versions).
The explicit installer runs from the repository root using its shebang. Without it, link dotted files
and recursively merge dotted directories into home; exclude `.git`, `.gitignore`, `.gitattributes`,
`.gitmodules` and forge metadata `.github`, `.gitlab`, `.gitlab-ci.yml`, `.forgejo`, `.gitea`, but include
user configuration such as `.gitconfig`. Protect managed shared-data links during directory merges.

Any file/symlink needing replacement is moved with its relative path into
`~/.dotfiles-backup/<timestamp>/` before linking. Image/skel files (.bashrc, .zshrc, .profile, others) are
ordinary backup candidates, never refusal reasons. Report one backup directory per application with
changes. Already-correct links produce no backup or repeat report. Refuse an unmergeable directory
target; do not silently destroy it. The timestamp is an opaque unique directory component, not output
whose exact clock value tests depend on.

`farmy dotfiles pull` updates the clone and attempts each running app, including default-link refresh
when no installer is configured. Report which containers applied the new revision and which failed;
any failure exits 1 and reports `partial`, with no rollback claim. The clone remains updated. Per-service
`status --json` exposes `dotfiles: {revision:<actually applied SHA|null>,state:applied|failed|unconfigured}`;
`wanted_revision` may additionally show the current clone SHA. Only successful completion records a new
applied revision. Start failure likewise reports the installer cause rather than claiming ready.

**Named tool data.** Share only `<name>` under `~/.local/share` AND `~/.cache` for each `shared_data`
entry. `nvim` is the default; names cannot escape those directories. Shared storage under
`farmy-shared/tool-data/<linux-arch-libc>/<tool-version-key>/{share,cache}/<name>` distinguishes actual
image architecture/libc and the full sorted selected tool-version set. The key may be a stable digest
of that set; it must change when a selected version changes. Every other home path is private per
service. Do not automatically migrate an existing local/share tree: refuse an existing nonempty
selected directory with a migration explanation instead of moving personal data. An empty target or
correct link can be initialized idempotently. A service's private home survives ordinary restarts.

Expose only necessary shared subdirectories when `shared_logins: false`; never make another service's
login files accessible to obtain tool data. Shared clone/data survive service destroy. Factory agents
use image binaries but no shared runtime homes/dotfiles; gates retain scratch HOME. `farmy ssh` uses
dev's selected interactive login shell, rather than hard-coding an independent shell command.

## Pipelines and review contracts (2026-10-15 review)

This section supersedes the earlier no-push-before-approval, branch-head chaining, shared-live-sidecar,
red_first presentation and waiting-exit-code rules. Other permission, Git ownership and network
isolation rules remain in force.

```yaml
factory:
  concurrency: 2                  # reserved positive integer, service scoped, also valid with a legacy block
  shape:
    base: main
    agent: claude
    writes: [test/]
    hidden: [src/]
    check: check
    test: test
    gate_setup: schema            # optional command from commands; runs before check/test
    gate:
      kind: red_first
      red_pattern: 'Expected .* fixed' # optional nonempty regex over complete combined stdout/stderr
      red_exit_codes: [1]         # optional nonempty list of nonzero test exit codes
      health_timeout: 30s         # sidecar readiness limit; default 30s
  work:
    base: main
    agent: claude
    writes: [src/]
    protects: [test/]
    test: test
    gate: green
pipelines:
  build:
    steps: [shape, work]
    on_question: shape
    handoff_limit: 3
    review_answers: false
forge: forgejo                    # optional github|gitlab|forgejo|gitea for self-hosted hosts
repo_web_url: https://git.example.com/acme/shop # optional web base for this repository
```

All referenced profiles and commands are validated before launching a run. `concurrency` is reserved,
not a profile name. red_pattern/red_exit_codes live in the gate mapping; scalar gates remain valid.
Patterns use Rust regex syntax, are checked before execution, and match full captured test stdout and
stderr, not a truncated prompt excerpt. A red_first passes iff check exits 0, test exits nonzero,
the iteration adds/changes at least one committed file under writes (deletion alone is insufficient),
and its optional pattern matches and optional exit-code list contains the test exit. No pattern means
the public gate summary is exactly `red (unverified)`; never call it meaningful red. Container launch,
health/setup failure and other execution failures are not ordinary test exits.

`farmy factory pipeline start <service> <pipeline> --task <text|file> [--wait]` creates an ID
`p-YYYYMMDD-HHMMSS-<4 hex>` and runs configured steps in order. Nested `pipeline list [service]`,
`show <id>`, `cancel <id>` and `resume <id> [--wait]` manage it; regular status/factory views also show
its current step and child identity. A detached request returns exit 0 and its ID. Every waiting factory
command now exits 0 for green, 2 for review/question pause, 1 for failure, including standalone
start/answer/revise and pipeline start/resume. Approval itself exits 0 after recording approval.
The detached controller is identifiable as `farmy factory pipeline run <pipeline-id>`; recovery tests
interrupt that controller process while leaving its already-launched child containers and volumes.

Public service JSON adds `pipelines`, each with `id`, `name`, `state`, `step` (one-based), `steps`
(count), `profile`, `active_run` (child ID|null), `handoffs`, `handoff_limit`. Run JSON gains
`pipeline_id`, `pipeline_name`, `pipeline_step` (null for standalone), `source_commit`, `gated_commit`,
`approved_commit`, `approved_profile`, `approved_gate`, `approval_valid`, `red_reference_commit`,
`compare_url`, `gate_summary`, `revision_of`
as applicable. `show` exposes the same decisions, question/answer and review evidence; TUI consumes
public status and the worker verifies its actual rendering.
`active_run` retains the current or final child's identity while queued, running, paused or terminal;
it is null only before a child has been assigned, rather than erasing the last child on completion.

**Durability and concurrency.** Reserve a child's ID in durable pipeline state before launch.
Claim pipeline transitions, approval and service execution slots atomically across processes. Count
only executing runs against `factory.concurrency` (default 2); queue excess runs FIFO. Waiting review,
question and parent controllers consume no slot. Direct runs, pipeline steps and question handoffs
share the cap. Resume reconciles the preassigned child with its containers and volumes: adopt a live
child or clean up an interrupted attempt before continuing that identity. It never launches a second
copy. Repeated approve/resume is idempotent; status does not perform launches. Cancellation stops active
and queued children and their owned resources. Prune retains resources needed by live/review/question
pipelines and preserves history after disposable resources are removed.

**Drafts and approvals.** A passed review-required run pushes its branch immediately and ends
awaiting_review. A failed push ends publish_failed without advancing; explicit resume retries that
gated commit, without rerunning its agent. Workbenches without remotes retain local review. A draft is
a published branch and state, not a forge pull-request creation. Compare the step's original base SHA
with its exact gated SHA, retaining the base across revisions. Normalize HTTPS/SSH clone URLs, escape
path/ref components, support GitHub/GitLab/Forgejo/Gitea, and use a branch fallback for unknown hosts.
Recognize public github.com/gitlab.com; explicit forge/repo_web_url config handles other hosts. Print
self-hosted links even if only the reviewer can reach them. No forge discovery request is required.

Approve verifies that the local and published branch still name the gated SHA, then atomically stores
that SHA AND the run's profile/gate configuration snapshot. After approval `--from <id|known branch>`
and pipeline continuation use the stored commit/configuration even if the branch or live definition
changes. The next profile still supplies its own write boundaries; the approved predecessor's tests,
gate evidence and provenance are immutable. Unrelated explicit manual branches remain accepted but
resolve once to a source SHA. A known unapproved branch can never bypass review.

`farmy factory revise <id> <text|file> [--wait]` creates a new attempt ID on the same branch, with the
original task and feedback. The earlier attempt is superseded; old evidence remains history. The latest
awaiting_review attempt can be revised. An approved attempt may be revised only before downstream work
has begun; atomically invalidate queued downstream work when that happens. Its replacement needs fresh
approval, and the obsolete queued child must never run. A completed approval cannot be reused for the
revision. The current profile's original snapshot governs revision, not a subsequently edited profile.
`approval_valid` is false on an approved attempt superseded by revision; its historical SHA and snapshots
remain available. approved_profile is the profile object and approved_gate its normalized gate object.

**Questions.** With on_question, dispatch that profile from the worker's captured question commit and
use the question as its task. Capture `.farmy/answer.md` outside writes; like question.md, exclude it
from all commits and clear control files before continuation. Detect answering-shaper forbidden edits
before cleanup would discard them: report permission_violation and stop automatic continuation. The
answering shaper's red_first reference is the worker question commit, with permitted test changes
applied there; a new test must actually fail against that work, never against some earlier base.
Expose that reference SHA as `red_reference_commit` on the answer run.

If no permitted changes remain and answer text is nonempty, end answered and resume the worker from
its question commit with original task/question/answer. With review_answers true, hold this text answer
in awaiting_review until approval; an answer-only run is the explicit exception to red_first's changed
file requirement. Any permitted change, even alongside answer text, requires the ordinary shape gate,
draft and human approval. After approval continue the worker from the approved shaper SHA, preserving
work present at the question. Empty text-only answers end answer_missing. A further shaper question
waits for a human. Without on_question retain manual factory answer.

Persist handoffs before dispatch; each new worker question consumes one, allowing three by default.
The fourth ends handoff_limit before launching a shaper. Replies/revisions/retries/resumes of that
handoff do not consume another or reset the budget. A new worker question does.

**Gate sidecars.** Each gate iteration creates fresh sidecars and writable data volumes in a Compose
project `<service>-run-<id>-gate` with internal networks and no published ports. Preserve service names
as aliases, dependencies and health checks. Replace fixed container names with project-owned names;
never join the developer's sidecars or another run's network. Writable data uses fresh run volumes;
read-only configuration binds may be retained. Refuse privileged sidecars, Docker-socket mounts,
host networking and external networks before starting them. Gate network none starts no sidecars.
Wait for all configured health checks up to gate.health_timeout (default 30s); unhealthy/timeout means
test_failed_to_run. Then, in the gate container and exported tree, execute optional gate_setup, then
check/test. Setup failure also ends test_failed_to_run and cannot satisfy red_first. Remove gate
sidecars/data after the iteration or cancellation, preserving live-service and other-run resources.

**Notifications.** Workspace `notify` accepts `format` (json default, ntfy, slack), one of `url` or
`url_secret`, and optional `token_secret`. The latter names refer to the existing provider/holder.
Resolved endpoint URLs and bearer tokens exist only in memory; persisted run/pipeline/outbox state
retains references, never resolved values. Even literal public URL configuration is referenced rather
than copied into generated state. Errors never contain destination URLs, headers or receiver bodies.

JSON events contain `event_id`, `event`, `service`, `pipeline_id`, `run_id`, `profile`, `step`, `result`,
`branch`, `commit`, `compare_url`, `timestamp`. Standalone pipeline_id/step are null. Events are
awaiting_review, question, green, or failed (with the specific terminal result, e.g. max_iterations,
publish_failed, handoff_limit). Intentional cancellation is not failed. No task text, questions, answers
or logs are included by default. Slack sends readable text JSON, ntfy readable text; each includes the
same identity, outcome and compare URL or branch fallback. Review events follow successful draft push.
Use a stable event ID across three total delivery attempts, with a ten-second per-attempt timeout and
bounded short backoff. Delivery failure remains visible in show without altering the gate/run verdict.
At-least-once delivery can duplicate an event; callers can deduplicate by event_id.

**Egress names.** Global and service restrict accept off, audit, enforce, false (=off), true (=enforce).
The strongest setting wins: enforce > audit > off. Public status emits canonical mode names, retaining
restricted=true for audit/enforce. Readers accept old persisted strict/unrestricted aliases. Factory
agents remain enforced. Existing proxy policy wire compatibility may retain strict as an internal
alias. Document HTTP and opaque CONNECT handling, no independent outward route for other protocols
in audit/enforce, and image builds outside the runtime gate.

### Mini regressions: Git ownership, local control cache and unknown image provenance

Managed Git defaults belong to system scope (/etc/gitconfig or a farmy-owned file named by
GIT_CONFIG_SYSTEM), not ~/.gitconfig. A personal config may be a read-only dotfiles link;
entrypoint setup and restart leave that link and its repository bytes unchanged. Personal
identity and ordinary preferences override defaults. Managed insteadOf routes and SSH transport
remain effective even against conflicting or longer-prefix personal URL rewrites and a personal
core.sshCommand. Verify the effective Git behavior, not merely the presence of configuration keys.

Normal init in a local checkout compares the complete control build-input digest even when
FARMY_BUILD is unset and the release version has not changed. A changed digest rebuilds the
control image and replaces the stale container; unchanged inputs reuse both. The digest covers
Docker recipes, applicable ignore rules, all copied files and recursive directories, directory
membership, file contents, executable modes, file types and symlink targets. Build outputs are not
source inputs. Hash failure cannot silently produce a cache hit. Binary and image build hashes must
reflect their complete build inputs, not only Rust source or an old compiled executable.

An existing unlabeled app image is actionable drift. Text status and the TUI say
`built by an unknown farmy: farmy rebuild <service>`; status JSON gives toolbox_version: null and
toolbox_outdated: true. This applies to stopped as well as running apps. A service that has never
had an image retains null version with outdated false. Labeled older/current/newer rules stay.

### Pipeline self-question routing and permission diagnostics

Compare the asking run's profile to on_question for every child, including ordinary pipeline
steps. Equality pauses the pipeline in question for a human `factory answer`; no answering
child starts and no handoff is consumed. A human answer resumes that same profile/step with
its existing gate and review contract. Other profiles still dispatch to on_question.

Before dropping forbidden changes, retain their actual repository-relative paths. Run show,
pipeline show and JSON/ntfy/Slack failure notifications identify all changed paths outside writes
or under protects/hidden and say the changes were dropped. File contents and private prompts,
questions, answers and logs remain excluded from notification payloads by default.

A write prevented by a read-only hidden mount is not an actual changed path and must not be
invented in the dropped-change report. If the inspected checkout does contain a hidden-path
change, detect it before restoring hidden/protected files and report that actual change.

The follow-up show command printed for a paused or terminal pipeline accepts the pipeline ID:
`farmy factory pipeline show <id>`, or a `factory show` supporting both run and pipeline IDs.

## Public release snapshots and GitHub mirror (publishing)

This supersedes the old missing-registry refusal, optional-source refusal, example-only CI,
and Forgejo contribution-intake defaults. Development stays in the private source repository.
The public Forgejo repository has release-only history and pushes a code mirror to GitHub.
Forgejo is reachable through a mesh, not internet contribution intake. GitHub issues are enabled;
GitHub pull requests are proposals. Maintainers apply accepted changes in the source repository,
ship them in the next release, and credit contributors in the release notes. GitHub PRs are not
merged into the mirrored branch. No live publication is part of acceptance verification.

### Release configuration and defaults

`work/release.yml` is the one declarative public configuration source. Its schema uses these
example values; the owner may explicitly supply public values to replace them:

```yaml
owner: your-owner
github_url: https://github.com/your-owner/farmy
public_remote: public
maintainer_name: farmy maintainers
maintainer_email: maintainers@example.com
issues_url: https://github.com/your-owner/farmy/issues
contributions_url: https://github.com/your-owner/farmy/pulls
contribution_text: >-
  GitHub pull requests are proposals. Maintainers apply accepted changes in the source
  repository for the next release and credit contributors in the release notes.
```

The owner fills those public values in. Never infer a real owner, URL or maintainer identity
from the private checkout, remotes, ambient Git settings or environment. `public_remote` names
one Git remote in the source repository; its URL/credentials remain private Git configuration.
The owner has now supplied the public owner and maintainer explicitly; keep their values
in this configuration, with the supplied noreply account-number placeholder until replaced
by the owner. Do not duplicate the public name in tests, records or ordinary prose.
Compiled binary, shim, installer and release defaults derive from this file at build time;
generated copies of values are permitted, independently maintained constants are not.
Default registry is `ghcr.io/<owner>/farmy`; explicit FARMY_REGISTRY wins. Image names remain
`farmy-control`, `farmy-keys`, `farmy-knowledge`, `farmy-gate`, followed by version/latest tags.
Default standalone Docker source is `<github_url>.git#v<version>:work`; explicit FARMY_SOURCE
wins. An update advances a generated source default to the installed version's tag and retains
an explicit source override. The retained public `work/` folder is the Docker build context.
README links the GitHub release `install` asset and documents verifying `SHA256SUMS` with SHA-256.

### Export and publication

Root `bin/publish <version>` operates on the Git repository containing its working directory
(repository root or work/), not necessarily the script's own checkout. It reads that repository's
committed `work/release.yml`, `work/VERSION` and `work/public-files.txt`. Stable version grammar
and exact VERSION matching remain. Refuse dirty tracked input. Export committed content/modes.

`work/public-files.txt` is the reviewed allowlist. Each nonblank, noncomment line is an exact
repository-relative file or a directory prefix ending `/`; `#` starts a comment line. Include
the release configuration/manifest, all runtime build inputs, public docs/licence/workflows,
root publishing/scanner executables, `shape/test/`, `shape/spec/`, and shared shape contracts.
Retain `work/` and `shape/`; include `shape/FORMATS.md` for the `work/FORMATS.md` symlink.
Exclude private configuration, `.git`, local state, compiled products/target and internal notes.
Preserve executable modes and safe internal symlinks; refuse dangling/escaping symlinks or a
link whose resolved target is excluded. A public checkout must build from its documented context.

The exported README and CONTRIBUTING render configured issues_url, contributions_url and
contribution_text. In the exported README, versioned installer and checksum links of the configured repository
(`<github_url>/releases/download/v<x.y.z>/{install,SHA256SUMS}`) name the published version; links to the
latest release (`<github_url>/releases/latest/download/…`) stay exactly as written (record 2026-10-19-1006). Public `work/releases/<version>.md` holds maintained release notes and
explicit contributor credit. Export those notes; publication does not copy private commit
messages to infer credits, and the release workflow uses the public notes file.

Create a separate public repository containing only public history and exported files, without
private refs, object alternates or development objects. First release: one parentless public
commit. Later release: one new commit with exactly the fetched public main tip as sole parent.
Use configured maintainer identity for author, committer and annotated-tag tagger, neutral
version messages and release timestamps. No private source SHA/message/remote/note/signature
is copied into public metadata. Required LICENSE attribution keeps its existing narrow exception.

Publication requires PRIVATE_TERMS_FILE to name a readable, nonempty denylist kept outside the
repository; no default exists, and bin/publish and bin/scan-private refuse to run when it is unset or
names no file. Run both root `bin/scan-private` and `bin/scan-history` on the candidate before
any push; either scanner's failure refuses publication. Check complete public bytes, names and
symlink targets, including binary bytes, and all reachable historical commits/tags, metadata
and unchanged/removed content. A clean latest tree cannot excuse a historical hit. The ordinary
suite's absent-denylist skip remains unchanged; publication has the stricter fail-closed rule.

Push precisely public main and annotated v<version> in one atomic operation with the fetched
old main tip as an explicit precondition. An expected-tip lease is permitted only alongside
the verified sole-parent relation; no history replacement is permitted. Refuse unsupported
atomic push, remote races, unexpected public history (including an untagged tip), older versions
and conflicting existing versions. An identical already-published tree/config/identity succeeds
as an explicit no-op without moving refs. A failed push is retryable without duplicate release
history. Preserve private refs/index/working files and unrelated remotes throughout. Success
reports public Forgejo publication separately from GitHub synchronization and CI, which remain
pending/unverified. Do not claim images or GitHub assets have published from local push success.

### Native workflow and proposal notice

Root `.github/workflows/release.yml` is the actual workflow, triggered by push tags `v*`.
Build all four image roles natively for linux/amd64 on ubuntu-24.04 and linux/arm64 on
ubuntu-24.04-arm. Each build pushes its digest to GHCR using GITHUB_TOKEN and exports a distinct
role/architecture digest artifact. Every required native build must succeed before manifest
publication. Merge both platform digests per role into `<version>` and `latest` manifests.
All manifests must succeed before publishing the GitHub release and assets `install` and
`SHA256SUMS`; checksum the exact attached installer bytes. Use the public version's maintained
release notes, including contributor credits. No failure bypass or claim of cross-image atomicity.
Build/merge permissions: contents read, packages write. Asset publication: contents write.
Document external Forgejo mirror setup for main/tags with a GitHub credential capable of
updating workflow files and triggering tag CI; keep that credential out of public artifacts.

Root `.github/workflows/mirror-pr.yml` is optional, disabled unless repository variable
FARMY_PR_NOTICE equals `true`. Its opened-PR notice uses trusted base policy (pull_request_target),
comment permission only, and no checkout/execution/interpolation of proposal head/body/title.
The comment explains mirror status, proposal acceptance, maintainer application in the source
repository, next-release delivery and release-note credit. It does not merge or close the PR.

Workflow structure is inspected locally; executing native builds, publishing to GHCR, GitHub
release upload and live PR comments require the actual GitHub workflow, not a fake-suite claim.

## Shared Git-container launcher

Farmy's own Git operations use one function that starts a fully configured Git container:
service checkout initialization, factory Git operations, repository Dockerfile/build-file
fetch, and dotfiles clone/pull. Sharing only a few environment-building utilities while
retaining separate launch implementations does not meet this requirement. Existing app
Git settings and agent/gate isolation continue to apply.

Before a Git process starts, its container joins the service/broker network and farmy
network, receives the applicable upper/lowercase HTTP/HTTPS/ALL_PROXY and NO_PROXY settings,
and can resolve the configured proxy and broker. SSH uses the configured proxy (SOCKS5
through mesh, HTTP CONNECT where configured), with remote-host resolution through that
proxy. Mount the loaded route broker's SSH agent socket and set SSH_AUTH_SOCK. Supply
applicable token and SSH insteadOf rules to every helper, including an HTTPS-to-SSH rewrite
for later operations after the initial clone. Never put private-key bytes in the Git
container's environment, arguments or filesystem.

The fake's cross-entry-point scenario observes every started Git helper and checks the
same transport requirements before allowing its mesh-only fake Git host to map to a real
local bare repository. It covers service clone, factory read/fetch/push, Dockerfile fetch,
dotfiles clone and dotfiles pull; each entry point must produce a nonempty observation.
The existing fake service-clone failure fixture applies to the shared helper as well as
the historical entrypoint simulation. Local file repositories still use real Git; illustrative
internet repositories keep the fake host's existing authentication and clone results.

## Exact public release identity exceptions

The privacy denylist still applies case-insensitively to complete tracked bytes, paths,
symlink targets, commit messages and tag messages. Public identity is not a globally
allowed string. Tree/staged/history scans and publication share this narrow policy:

- Read the active `work/release.yml` as the public policy. `scan-private` uses its working
  copy; `scan-private --staged` uses the index version; `scan-history` uses the current
  committed configuration at HEAD. Old commits cannot grant themselves exceptions through
  their own historical configuration. Missing/invalid identity fields grant no exception.
- In `work/release.yml`, allow only complete configured scalar values in `owner`,
  `maintainer_name`, `maintainer_email`, `github_url`, `issues_url`, `contributions_url`.
  Comments, extra keys, contribution prose and text outside those scalar values remain
  scanned. The exception is not a line-prefix or file-wide skip.
- Commit author and committer, and annotated-tag tagger, may use the exact configured
  `maintainer_name <maintainer_email>` pair followed by their timestamp/timezone. Match the
  complete pair, case-sensitively; the right name with a different email is not allowed.
  Parse real object headers only. Identity-shaped lines after the message separator are
  still messages and remain scanned.
- Root `LICENSE` may attribute copyright to exactly the configured maintainer name,
  optionally preceded by a standard year or year range after `Copyright (c)`. Only that
  attribution is exempt. Extra denied text on the line, any other attribution, and the
  rest of LICENSE remain checked; other files named LICENSE get no exception.
- Root `README.md` and `CONTRIBUTING.md` may contain the exact configured public repository,
  issues and contributions URLs, plus the prescribed installer/checksum links derived
  from `github_url`: `/releases/download/v<VERSION>/install`, the corresponding
  `SHA256SUMS`, and `/releases/latest/download/{install,SHA256SUMS}`. Exempt the complete
  URL token only. VERSION may be an earlier stable release recorded in public history;
  publishing a later release must not invalidate its predecessor's installer links.
  Do not exempt its label or surrounding prose. A URL with an extra suffix, query,
  fragment or different destination does not match. Those URLs in other files remain
  subject to the denylist. The owner explicitly approved this documentation exception.

Publication's missing/unreadable/empty-denylist refusal remains unchanged. Ordinary suite
verification still warns and skips without the private denylist; when present it invokes
the shipped tree scanner so the same exception policy is enforced. Tests use a generic
configured maintainer and a matching generic denylist term. Shipped-default checks compare
artifacts to the declared public configuration instead of copying the owner's denied name
into test source. No release identity is inferred from ambient Git settings.

## Run and pipeline liveness (record 2026-10-17-1300)

A run is alive while its `.work/<name>/runs/<id>/controller.lock` is held (an exclusive flock); a pipeline's
controller is alive while `.work/<name>/pipelines/<id>/controller.lock` is held. Whoever creates a run or
starts a controller takes that lock before the first `state.json` is saved and hands it to the process it
starts, so the lock is held from the moment the state exists until the process ends; the kernel releases it
when the process dies, killed or not. A controller judges a child it spawned itself by that child's process
handle, everything else by the lock. `launch.lock` in a run's folder orders a fresh run behind the process
that spawned it until its pid is recorded. The `pid` in a `state.json` is informational, never a liveness
signal. A run's resources are cleaned only once its lock can be taken (`cancel` cleans on purpose).
## Execs into a running app container (record 2026-10-16-2000)

An exec that runs the app container's entrypoint in a mode (`farmy-entrypoint --git-config`, `--home`,
…), as `farmy dotfiles pull` does, first checks that the container's image supports the mode, from its
labels or a probe that is itself time-limited. An image built before the mode is skipped without the
exec: `[<name>] built by an older farmy: farmy rebuild <name>` on stderr; the command goes on with the
other containers and exits 1. Each such exec is limited to `FARMY_EXEC_TIMEOUT` seconds (default 60);
on expiry it is stopped in the container too (not only the `docker exec` client) and reported as
`[<name>] … timed out after <n>s: <command>`. A failure is reported as `[<name>] <what> failed: exit <n>`
followed by the last lines of its stderr when there are any; the cause is never empty.

## Custom toolbox and farmy's entrypoint (record 2026-10-17-1800)

A `toolbox/` folder with a Dockerfile in the containers folder is built instead of farmy's toolbox, and
`start`/`rebuild` say so on stderr, naming the folder (`custom toolbox: <path>/toolbox`). Whatever toolbox
is built, farmy's layer comes last and installs farmy's own entrypoint at /usr/local/bin/farmy-entrypoint as
the image's ENTRYPOINT; a custom toolbox cannot replace it. The image's `farmy.entrypoint.modes` label lists
the modes of that installed entrypoint. A custom toolbox's own startup logic goes into `toolbox/start.sh`:
farmy's layer installs it with the image, and farmy's entrypoint runs it as dev at every container start,
after farmy's own startup, from the dev user's home; its failure is reported with its exit status and does
not stop the container. A custom `toolbox/entrypoint.sh` has no effect.

## On-demand verify (record 2026-10-21-1332)

```yaml
factory:
  work:
    base: main
    agent: claude
    writes: [src/]
    hidden: [test/]       # the agent cannot read test/ ...
    test: test
    verify: test          # ... and runs it whenever it likes: farmy-verify [args…]
```

`verify` names a command under `commands:`, in any profile (and in the legacy single block). `farmy start`
accepts the key without checking it; `farmy factory start` refuses a name that is not under `commands:`,
naming it and `commands:`, before any run container starts. Without `verify` nothing changes: no
`farmy-verify` in the agent's container, no `verifies` in `state.json`, no verify count in `show`.

**The program.** With `verify`, the agent's container has a program `farmy-verify` on its PATH. How it reaches
farmy is farmy's choice, within: no farmy binary, no Docker socket and no broker in the agent's container (it
works in api-key, token and login mode alike), and the agent on its run's internal network only. Nothing with a
way out or holding a secret joins that network for it; the control container never does. Under the tests it
runs as the fake runs an agent's command lines ("Docker in the tests": an agent's steps).

**A call**, `farmy-verify [args…]`, in this order:

1. **One at a time per run.** A call made while another verify of the run is running waits for it to end, then
   goes on as a call made at that moment. Calls are numbered `k` from 1 per iteration, in the order they run. At
   most `VERIFY_QUEUE_LIMIT` calls wait at a time ("Limits" below).
2. **The snapshot**, made as the iteration commit would be ("An iteration") without changing anything the agent
   sees: `protects` and `hidden` as at the run's starting commit (the protection baseline); under `writes` (all
   paths when `writes` is unset) the agent's current files, additions and deletions included; everything else as
   at the run branch's head; `.farmy/question.md` and `.farmy/answer.md` never in it. It is a commit that is not
   on the run branch and never pushed; the run branch, its index and every file of the agent's tree stay exactly
   as they were.
3. **The verify container** `<name>-run-<id>-verify-<i>-<k>`, labels `farmy.run=<id>`, `farmy.service=<name>`,
   `farmy.role=verify`, `farmy.iteration=<i>`, `farmy.verify=<k>`, made as the gate's test container: a new one
   per call, the run volume read-only at `/workspace`, the definition's `mounts:` read-only, `--tmpfs
   /scratch:exec`, the snapshot exported into `/scratch/tree` (`git -C /workspace archive <commit>`), run from
   there (or the definition's `workdir` inside it) with HOME and TMPDIR under `/scratch`, no proxy variables, no
   way out. Its sidecars: fresh copies in the compose project `<name>-run-<id>-verify`, made as a gate's are
   (internal networks, no published ports, the developer's and other runs' never joined, health checks waited for
   up to `gate.health_timeout`), removed when the verify ends. With the gate's network `none`: `--network none`
   and no sidecars. The profile's `gate_setup` runs first when it has one. Then the named command's line with each
   arg appended, shell-quoted as one word.
4. **What the agent gets.** The command's stdout on farmy-verify's stdout and its stderr on stderr, each as it
   comes, then farmy-verify exits with the command's exit code. For the command's exits 124 to 127 it adds one last
   line on stderr:

   | exit | line |
   |---|---|
   | 124 | `farmy-verify: the command exited 124: it timed out` |
   | 125 | `farmy-verify: the command exited 125: it could not be run` |
   | 126 | `farmy-verify: the command exited 126: a program it runs could not be executed` |
   | 127 | `farmy-verify: the command exited 127: a program it runs was not found` |

   When the verify could not run the command at all (the snapshot failed, Docker refused a container, a sidecar was
   not healthy within `gate.health_timeout`, `gate_setup` failed), it prints `farmy-verify: could not run:
   <reason>` on stderr, a sidecar named by its compose service (`sidecar postgres is not healthy`), and exits 125.
   It returns the command's output and exit code and nothing else: no file of the snapshot or of the verify
   container reaches anything the agent's container can see.

**Limits** (record 2026-10-21-1700). Three constants of farmy, not configurable:

| constant | value | counts |
|---|---|---|
| `VERIFY_OUTPUT_CAP` | 4 MiB (4,194,304 bytes) | the command's stdout and stderr together |
| `VERIFY_QUEUE_LIMIT` | 4 calls | calls of a run waiting for their turn (the running one not counted) |
| `VERIFY_PREPARE_OUTPUT_CAP` | 64 KiB (65,536 bytes) | stdout and stderr together that arrive from the verify container before the command starts (its preparation, `gate_setup`) |

Each ends a call as one that could not run, exit 125, with its own line on stderr. The line stands on a line of
its own: when what the agent got on stderr so far does not end with a newline, one comes first.

- **Output.** The first 4 MiB the command prints reach the agent as they come. With the first byte beyond them the
  command is stopped (its container and sidecars removed), nothing beyond is passed on or kept, and farmy-verify
  prints `farmy-verify: could not run: the output exceeded 4 MiB, so the verify was stopped`. A command that
  prints exactly 4 MiB is not stopped. The record keeps the same 4 MiB as its output, exit 125 and that reason.
  farmy never holds more of a verify's output than the cap.
- **Waiting calls.** A call that would be the fifth waiting fails at once: `farmy-verify: could not run: the verify
  queue is full (4 calls are waiting)`. It leaves nothing behind anywhere the agent's container can write, and is
  not a verify: no number `k`, no record file, not in the count. A waiting call costs farmy only its directory
  entry: its words are read when its turn comes, never while it waits.
- **Before the command.** Up to 64 KiB arriving before the command starts is held as before. With the first byte
  beyond it the verify ends (container and sidecars removed) and farmy-verify prints `farmy-verify: could not run:
  the verify container printed more than 64 KiB before the command started`; the command never runs. farmy never
  holds more than 64 KiB of it, and the agent gets no more than that.

**Time.** A verify runs while the agent waits: it counts toward `iteration_timeout` (the agent's `timeout`) and is
never an iteration. When the agent's container ends while a verify runs (it exited, it was stopped at
`iteration_timeout`, the run was cancelled), farmy stops that verify (its container and sidecars removed) before
the iteration's commit, and a call still waiting never runs; both are recorded with `reason: "stopped: the
agent's container ended"`. A verify takes no `factory.concurrency` slot of its own.

**The gate is unchanged.** A verify decides nothing; the gate tests the iteration's commit as before.

**The prompt.** With `verify`, the agent's prompt says it may run `farmy-verify [args…]` as often as it likes,
names the command line it runs (`sh test/check.sh`), says it tests a snapshot of the tree as the iteration commit
would make it (hidden folders included, though the agent cannot read them), and that its result decides nothing:
only the gate does. Supplied even when `factory/prompt.md` omits it, as the question instructions are.

**The record.** `iteration-<i>.verify-<k>.log` in the run's folder, one per call:

```
args: ["--name","only login"]
command: "sh test/check.sh --name 'only login'"
commit: 3f2c9a7d0e5b41c8a6f1d2e3b4c5a6978d0e1f23
started: 2026-10-21T09:14:03Z
ended: 2026-10-21T09:14:07Z
exit: 3
reason: "…"

<everything the command printed, stdout and stderr, in the order it came>
```

No header value spans a line (record 2026-10-21-1700): `args` is a JSON array, `command` and `reason` are JSON
strings, so a newline or control character in an argument is written as JSON writes it (`\n`, `\r`, `\u001b`)
and cannot start a header line; the other values hold no such character.

Header lines `key: value`: `args` a JSON array of the words farmy-verify was given; `command` the line run;
`commit` the snapshot (`-` when none was made); `started` and `ended` RFC 3339 in UTC; `exit` the code farmy-verify
exited with (137 for a verify that was stopped); `reason` only when the verify could not run, was stopped, or the command exited 124 to 127. Then one
blank line and the full output. `state.json` gains `verifies`: `[{"iteration": <i>, "count": <n>}]`, one entry per
iteration whose agent ran, 0 included. `farmy factory show` appends `  verifies <n>` to each iteration's line:
`  1  commit 9834b253c96e  exit 1  verifies 2`.
