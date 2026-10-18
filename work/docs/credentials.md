# Keys and secrets

A secret inside an app container is readable by anything that runs there: the agent, a dependency's
install script, a test. farmy keeps every secret out of the app containers and out of every file
it writes, and still lets the app use them: through the keys broker next to it.

**farmy never stores a secret on disk.** Not in `.env`, not under `.work/`, not in a container's
configuration, not in a file of its own. It obtains the secrets when it loads the brokers (`start`,
`restart`, `rebuild`, `farmy keys reload`, `farmy factory start`), hands them over, and forgets them.

## The pieces

- **A route** is a destination the app reaches through the broker: `http://keys:9181/<route>/<path>`
  is forwarded to the route's upstream with the secret added. Routes are yours, in `farmy.yml`
  under `keys:`; farmy ships no catalogue, only `farmy.example.yml` to copy from.
- **Where the secrets come from.** Without a secrets manager, from this machine: the shim asks for
  each route's secret (a prompt, the secret service, a command of yours, the Keychain) and pipes it
  to farmy. With one, a **provider**: a program farmy runs that turns a few values of its own (an
  Infisical token, say) into the routes' secrets.
- **The broker** (`<name>-keys`, the `farmy-keys` binary) starts with its routes and no secret.
  farmy loads it over a private socket as soon as the containers are up. The secrets live in its
  memory.

## Routes

```yaml
keys:
  github:
    secret: GITHUB_TOKEN           # the name farmy asks for (GITHUB_TOKEN_<OWNER> too, when a provider returns it)
    upstream: https://github.com   # the host this git route applies to
    auth: basic                    # basic (user:) | bearer | header (header:)
    user: x-access-token
    git: true                      # git in the app container is rewritten to this route for that host
  anthropic:
    secret: ANTHROPIC_API_KEY
    upstream: https://api.anthropic.com
    auth: header
    header: x-api-key
    # services: [shop]             # who may use it; absent: every service
```

`auth: basic` sends the user and the secret as the password, which is how git hosts take a token
over https. The user differs by host: GitHub takes any (`x-access-token` is the one it documents),
GitLab wants `oauth2`, Forgejo and Gitea your account's own user name, with the token as the
password. `bearer` sends `Authorization: Bearer <secret>`; `header` sends the secret in the named
header. The client's own `Authorization` and that header never reach the upstream. A redirect from
the upstream on its own origin (a renamed repository) is rewritten to the route, so it keeps going
through the broker. A route may also be `auth: ssh`, different in kind: see "SSH routes" below.

A route may give the app container variables: `expose` names one that gets the route's address,
`placeholder` one that gets the fixed value `via-farmy-keys`, for a client that insists on having a
key set; the broker replaces it with the real one on the way out. An agent in api-key mode gets
both from the route with its upstream without either being written ("Agents inside the container").

A definition may say which routes it uses, `keys: [github, anthropic]`; naming one it is not
granted is refused. The broker of a service gets only the routes granted to it, and only their
secrets. A route forwards to its configured upstream only: the caller chooses the path, never the
destination.

## Where the secrets come from: this machine

Without `secrets:` in `farmy.yml` there is no provider, and the routes' secrets are obtained on the
host. Before it hands `start`, `restart`, `rebuild`, `keys reload`, `keys --why` or `factory start`
to the control container, the shim asks it for the names (`farmy unlock-names`: here, every route's
secret) and obtains each from one source. Every source is equivalent:

- **a prompt**: whatever no other source has, the shim asks for on the terminal, hidden. Nothing to
  set up; you type each value once per control container (see "Held" below).
- **the Linux secret service** (GNOME Keyring, KWallet, through libsecret), when `secret-tool` is on
  the PATH. Store a value once:

  ```sh
  secret-tool store --label='farmy GITHUB_TOKEN' farmy farmy/GITHUB_TOKEN
  ```

  A secret service that answers with an error (a locked collection, which cannot be unlocked from a
  shell; no D-Bus session on a headless host) is named once and not asked again for that command;
  every value is asked for with the prompt instead.
- **a command of your own** in `FARMY_UNLOCK_COMMAND`: a shell line, run in the containers folder
  with the name as `$1` (`FARMY_UNLOCK_COMMAND='pass show farmy/$1'`), that prints the value. A
  line that does not mention `$1` gets the name appended as its last argument. When it is set, it
  is the source; the stores are not consulted.
- **the macOS Keychain**, when `security` is on the PATH. Store a value once, so that `security` can
  read it back without a dialog:

  ```sh
  security add-generic-password -a "$USER" -s farmy/GITHUB_TOKEN -w -T /usr/bin/security
  ```

  Reached over ssh, the login keychain is locked: the shim runs `security unlock-keychain` once,
  which asks for the login password on the terminal, and reads on.

The source is the command when `FARMY_UNLOCK_COMMAND` is set, else the Keychain when `security` is
on the PATH, else the secret service when `secret-tool` is, and the prompt for whatever the source
does not have. Both stores are asked for `<prefix><NAME>` (the secret service by the attribute
`farmy`, `secret-tool lookup farmy farmy/GITHUB_TOKEN`; the Keychain by service, `security
find-generic-password -s farmy/GITHUB_TOKEN -w`). The prefix is `FARMY_SECRET_PREFIX`, from the
environment or else from `.env` in the containers folder (so it need not be exported in every
shell; `FARMY_UNLOCK_COMMAND` is read the same way), default `farmy/`. That one name is all either store is asked for.

What the shim found or was told is piped to farmy, base64-encoded so that a multi-line value
arrives byte for byte, never on a command line. A value nobody could give (no source has it, no
terminal to ask on) is left out, named on stderr, and its routes read `locked`: the containers still
start, and the broker answers 503 for those routes until `farmy keys reload` brings the value (a git
route forwards without credentials meanwhile, so public repositories still clone).

**Held.** The control container keeps what the host gave it, in the memory of one process, for as long
as it runs: later `start`, `restart`, `rebuild`, `keys reload` and `factory start` take the values
from there, and the shim asks this machine only for the names it does not hold yet (`farmy
unlock-names --missing`). So the prompt, the Keychain or the secret service is asked once; a container
made anew without anyone at a terminal (the factory) still gets its secrets. A control container made
anew holds nothing: the next of those commands, `factory start` too, asks this machine again, the
store first and the prompt last. Nothing of it is written anywhere. `farmy lock` makes it
forget everything, and so does a restart of the control container (`docker restart farmy`, a reboot):
the next load asks this machine again. Anyone who can `docker exec` into the control container can ask
it; that is whoever runs Docker on this machine, who could read the brokers' memory too.

## Where the secrets come from: a provider

```yaml
secrets:
  provider: [providers/env]                     # the program and its arguments, run as given (no shell)
  unlock: [GITHUB_TOKEN, ANTHROPIC_API_KEY]     # the values the provider needs, obtained on this machine as above
```

With a provider, the shim obtains only the names under `unlock:` (the **unlocking values**) and they
go to the provider's environment and nowhere else; the provider answers with the routes' secrets.

- `providers/env` answers from its own environment: with the routes' secrets under `unlock`, it
  hands back what the shim found. It is what no provider at all amounts to, written out.
- `providers/infisical` wraps the Infisical CLI (`infisical secrets get <name> --plain …`, with the
  arguments you give it in `farmy.yml`, such as `--projectId <id> --env dev`) and needs
  `INFISICAL_TOKEN` under `unlock`, or, with `--client-id-from <name> --client-secret-from <name>`
  among its arguments, a machine identity's client id and secret under `unlock` (it logs in with
  universal auth first and keeps the token in its own process); `--domain <url>` for a self-hosted
  Infisical goes to the login and to every get. The control image has the CLI.
- **A program of your own**: anything that speaks the protocol below. A provider named with a path is
  looked for in the containers folder first, then next to farmy, so the two shipped ones work by
  those names and `bin/provider` of your own wins where it exists.

The protocol. farmy runs `secrets.provider` in the control container with the unlocking values in
its environment and this on stdin:

```json
{"version": 1, "secrets": ["GITHUB_TOKEN", "ANTHROPIC_API_KEY"]}
```

The provider answers on stdout and exits 0:

```json
{"version": 1, "secrets": {"GITHUB_TOKEN": "github_pat_…"}, "missing": ["ANTHROPIC_API_KEY"]}
```

or `{"version": 1, "error": "not logged in"}`. farmy asks only for the secrets the routes in play
need, never for everything. Stdout is secret-bearing data: it is never shown or logged. A provider
that exits non-zero, answers something else, takes longer than 30 seconds or prints more than 1 MB
has failed; farmy says so and names the provider, not its output, and its routes read `provider
failed` until the next `start` or `keys reload`. `farmy keys --why` runs it once and shows how it
ended and its stderr, every secret and unlocking value replaced by `[redacted]`. Extra secrets named
`<secret>_<OWNER>` (a token for one owner on the git host) are accepted and used for `/<owner>/…`
paths. The shipped providers escape every control character in their answer, so a multi-line value
survives.

**Values a manager stores base64.** Newlines rarely survive an environment variable or a secrets
manager's text field, so an SSH key is often stored base64-encoded (`base64 < ~/.ssh/id_ed25519 |
tr -d '\n'`). Say so on the route with `encoding: base64`, and farmy decodes the value before the
broker sees it. Without it, an SSH route's value that is not a key but decodes to one is not loaded,
and `farmy keys` says `rejected (it looks base64-encoded: encoding: base64 on the route)`. A value
stored as it is, multi-line, needs nothing.

## SSH routes

A route with `auth: ssh` names its host in `upstream: ssh://git@github.com` (the user before `@`;
`git` when there is none; a port when the host's SSH is not on 22): its secret is the text of an
OpenSSH private key, and the broker runs an SSH agent with it. The agent's socket is shared with the
app container on the volume `<name>-keys-agent`, mounted at `/run/farmy-keys`; the app gets
`SSH_AUTH_SOCK=/run/farmy-keys/agent.sock` and never the key. Anything that speaks to an SSH agent,
git first of all, signs through the broker.

```yaml
keys:
  github:
    secret: GITHUB_SSH_KEY
    upstream: ssh://git@github.com
    auth: ssh
    git: true
    # encoding: base64           # when the key is stored base64-encoded
```

With an SSH route marked `git: true` for a host, `repo: https://github.com/acme/shop.git` is cloned
from `ssh://git@github.com/acme/shop.git`: the pasted URL stays, the route decides the transport.
An upstream with a user and a port of its own (`ssh://forgejo@git.example.com:2222`) gives
`ssh://forgejo@git.example.com:2222/acme/shop.git`, and the app container's git gets an
`insteadOf` rule from `https://git.example.com/` to `ssh://forgejo@git.example.com:2222/`, so later
fetches, pushes and submodules named by the https URL take the same way. A `repo:` that is an
`ssh://` URL or `git@host:path` is taken as it is. The host's key is accepted at first contact.
farmy's own fetch of a Dockerfile (for `dockerfile:` definitions) uses a temporary agent in the
control container, loaded for that fetch and gone after it.

`loaded` in `farmy keys` is what a running broker holds (`farmy-keys loaded` in its container),
an SSH key only once the broker's agent took it. A broker made anew or restarted has lost what it
held: the route reads `not loaded (farmy keys reload)` until the next load, and every `start`,
`restart` and `rebuild` loads the brokers it makes.

## Loading the broker

The broker's container is started with `FARMY_ROUTES` and one `FARMY_ROUTE_<NAME>` per route in
its environment, and nothing else. As soon as it runs, before the clone, farmy runs

```
docker exec -i <name>-keys farmy-keys load
```

with `{"version": 1, "secrets": {"GITHUB_TOKEN": "…"}}` on that process's stdin. `farmy-keys load`
sends it to the broker over `/run/farmy-keys.sock`, a Unix socket inside the container; the broker
replaces what it holds. The port 9181 the app containers use has no endpoint that loads or changes
anything.

## The guarantee

farmy does not put a secret, unlocking or upstream, into a container's configuration
(`environment`, `-e`, labels), into a generated file (`.work/`), into a docker command line, or
into its output and logs. `docker inspect <name>-keys` shows the routes and no value; the agent
socket's volume holds a socket, not a key. This is not a guarantee against the Docker daemon's
administrator, who is the operator; and the broker's memory is memory, with whatever the host does
with memory.

## Lifecycle

| Event | What happens |
|---|---|
| `farmy start`, `farmy restart` | the secrets are obtained and loaded into the brokers of the services started |
| `farmy keys reload [<name>…]` | the same, for the running services named (all when none), without touching containers |
| `farmy stop`, then `farmy start` | the broker starts empty again and `start` loads it |
| attaching to the session, from any device | needs no secret: the brokers run with what they hold |
| a value is not given or the provider fails | the containers start with every granted route configured; the broker answers 503 for the unloaded ones until `farmy keys reload` loads them |

`farmy keys` prints every route: its upstream, its state (`loaded`; `locked` when its value, or an
unlocking value, was not given; `missing` when the provider has no such secret; `provider failed`;
`rejected …` for a value that does not decode; `not loaded (farmy keys reload)` when no running
broker holds it any more; `not resolved yet` before the first start), who may use it, and what it
exposes. A route's exposed variable reaches the app whenever the service may use the route, loaded
or not: a request through an unloaded route fails with 503 naming the route, and `farmy keys
reload` fixes that in place, without a new container.

## Agents inside the container

An agent is data: an entry of fields in farmy's catalogue (`agents.yml`: Claude Code, Codex, Gemini
CLI, OpenCode, Cursor, Copilot) or under `agents:` in your `farmy.yml`, with the same fields. How
an agent authenticates is a **mode**, per agent and per service: the entry's `mode` sets the
default (`subscription`), a definition's `agents:` overrides it for that service.

```yaml
# farmy.yml
agents:
  claude:
    mode: api-key                 # a catalogue entry, one field changed
  codex: {}                       # the catalogue entry as it is: subscription mode
```

```yaml
# services/shop.yml
agents: {claude: subscription, codex: off}   # this service: Claude with its own login, no Codex
```

**`api-key`** keeps the key out of the container: the route whose upstream is the agent's
(`api.upstream`, `https://api.anthropic.com` for Claude Code) gives the container the agent's
base-URL variable pointing at the route (`ANTHROPIC_BASE_URL=http://keys:9181/anthropic`) and its
key variable set to `via-farmy-keys`; the agent uses key auth, and the broker swaps the placeholder
for the real key. Billed per token, to the key. Without such a route `farmy start` refuses, naming
the agent and the upstream. An entry whose vendor documents no base-URL variable (Codex, Cursor,
Copilot) has `api: null` and cannot take this mode.

**`subscription`** means the agent's own login. Its login paths (`login`, `~/.claude` and
`~/.claude.json` for Claude Code) live on `farmy-shared`, so one login serves every container; log
in once, inside any container, with the command `farmy agents` prints (`claude setup-token`,
`codex login --device-auth`, …). An entry with a `token_env` can take a token from a provider
instead: Claude Code's `CLAUDE_CODE_OAUTH_TOKEN` is the token `claude setup-token` prints, valid
for a year, meant for scripts; stored where the provider finds it under that name, farmy puts it
into the app container's environment under that name. (Such a token is asked from a provider only,
never at the prompt, which would ask for it at every start.) Do not `/login` inside a container with
a credential that expires: an unattended session that outlives it stops until someone signs in
again.

A token in the container is **the one documented exception** to the rule that no secret is in a
container's configuration. The agent can read it, and nothing fixes that; what limits the damage
is egress control, an internal-only network with an allowlist, which is not built yet. In this
mode the container gets none of the agent's `api` variables (`ANTHROPIC_BASE_URL`,
`ANTHROPIC_API_KEY` for Claude Code), whatever the routes expose: those outrank a login, and a
route exposing them would silently turn the subscription into per-token billing.

**`off`**: not installed in that service's image, nothing linked, none of its variables.
`agents: []` in `farmy.yml` is off for every service.

Each agent's per-service state (`state`: Claude Code's `~/.claude/projects`, Codex's sessions)
lives on the service's own `<name>-agents` volume, so no service reads another's transcripts.

## How git reaches the host

A route marked `git: true` applies to the repositories whose clone URL has the host of its
`upstream`; one route per host, as many hosts as you like. The app container gets
`DEV_GIT_ROUTES`, space-separated `<upstream>=http://keys:9181/<route>/` pairs for every granted
http(s) git route; the entrypoint sets `url.<route>.insteadOf <upstream>/` for each, so clones,
fetches and pushes to that host go through the broker, which adds the token. Remotes keep their
normal https URLs. Farmy's service clone, factory operations, Dockerfile fetch and dotfiles
clone/pull use one Git-container launcher with these same routes. Token routes use the broker's
HTTP endpoint; SSH routes use its loaded agent socket. Neither secret enters a Git helper's
environment or filesystem. The helper joins both the service and `farmy` networks before Git
starts and receives the proxy settings and SSH ProxyCommand for mesh or HTTP CONNECT egress.

A host with no git route at all: only its public repositories clone, and `start` says so, naming the
host. A host whose git route has no secret loaded: the broker forwards git's requests without credentials
(the route's spec ends in `public`), so its public repositories clone and `start` says only those do
until the secret is given; a private one fails, and `start` names the route, its state and `farmy keys
reload`. A token the host refuses ends the clone with the host's words and the route's secret named.
Every Git helper sets `GIT_TERMINAL_PROMPT=0`, so git never waits for a user name.

## The broker's contract

So that it can run elsewhere: `farmy-keys serve` reads `FARMY_ROUTES` (route names, space-separated)
and `FARMY_ROUTE_<NAME>` = `<upstream> <auth> <user or header or -> <secret name> [public]`, listens on
`FARMY_PORT` (9181) and `FARMY_SOCKET` (`/run/farmy-keys.sock`); `FARMY_PUBLIC` is the origin used
when rewriting redirects (default: the request's `Host`). `/-/health` answers 200; a route not
loaded 503 naming the route, or, ending in `public`, forwarded without credentials; a path outside
the routes 404. `farmy-keys load` reads the JSON on
stdin and sends it to the socket; a bad payload exits 1. The broker logs method, path and status
and warns on a 401 or 403 from an upstream, naming the secret, never its value.

## Checking

- `farmy keys`: the routes and their states; `farmy keys --why`: what the provider said.
- `farmy start shop` prints `[shop] git: reaches github.com through the keys broker` when
  `git ls-remote` works from inside.
- `farmy run shop env | grep -c TOKEN` prints 0.
- `docker inspect shop-keys --format '{{.Config.Env}}'` shows routes, no values.
- `farmy logs shop` shows the broker's lines, `keys: GET /github/... 200`, and its warnings.
