# Getting started

From a machine with Docker to a running service in a session, with nothing installed on the
machine. The path below is the plainest one: a Linux host with Docker Engine, a private repository
on GitHub over https with a token, Claude Code with an API key, no secrets manager and no mesh.
Every other setup (a Mac, SSH keys, a secrets manager, a private mesh) is the same path with one
part swapped, and the end of this guide says where. Examples use the service `shop`, a Rails app at
`https://github.com/acme/shop.git` (a self-hosted Forgejo, Gitea or GitLab works the same way: the
clone URL is all farmy knows about a host).

## Prerequisites

- Docker, running. On Linux, Docker Engine, with your user in the `docker` group
  (`sudo usermod -aG docker "$USER"`, then log in again) so that `docker ps` works without `sudo`.
  On a Mac, Docker Desktop or OrbStack; colima works too.
  Windows with WSL2 and Docker Desktop is unverified: bind mounts from a WSL distro are believed to
  keep raw uids, and whether farmy can run as you there depends on the socket's group in Docker
  Desktop's VM. Try it, and tell us what you find; nothing in farmy refuses it.
- The standalone `bin/install` script and a registry that publishes farmy images; see
  [distribution](distribution.md) for registry login and local development alternatives.

That is all. Rust, git, tmux and compose live in the control image. The files farmy writes are
yours, whichever Docker you run.

## 1. Install farmy

```sh
FARMY_REGISTRY=ghcr.io/acme sh bin/install # substitute your publisher's registry and owner
export PATH="$HOME/.local/bin:$PATH"
```

There is no folder to make. farmy keeps its configuration (`farmy.yml`, the definitions under
`services/`, this machine's `.env`) in `~/.config/farmy` and its own state in `~/.local/state/farmy`,
on a Mac too; `XDG_CONFIG_HOME` and `XDG_STATE_HOME` move them. The first command sets
`~/.config/farmy` up: a `farmy.yml` with every default and a `.gitignore` that keeps `.env`,
`services/*.env`, `.work/` and farmy's temporary files out of git; on a terminal it asks once whether
to keep the folder in git (`farmy config git` does it later), unless it lies in a Git repository
already. Run farmy from any folder: `farmy config path` says which folder it uses. A folder that holds a `farmy.yml` is a project folder of its own, used whenever you run farmy in
it or below it; `farmy -C <dir>` and `FARMY_DIR` name one (README, "Where farmy keeps things").

The first command also pulls the control image matching the installed shim, tags it locally as
`farmy:local`, and starts the control container `farmy`, which stays.

## 2. `farmy init` (optional)

```sh
farmy init
```

You can skip it: the first `farmy start` writes `.env` itself from your host's git identity and says
so. `init` does more, and asks on a terminal. Four steps: Docker answers; `.env` is written with
`GIT_USER_NAME` and `GIT_USER_EMAIL` taken from your host's `git config --global` (asked for when
the host has none); the agents every app image
should carry are asked for (Claude Code, Codex, … from farmy's catalogue; none is a fine answer, and
without a terminal none is what you get) and written into `farmy.yml` as `agents:`; the services are
listed (none yet). It works in the folder in use, `~/.config/farmy`, and names it. `.env` holds that
identity and, optionally, `LAN_HOST` (see the end). No token goes in it.

## 3. Define a service

```sh
farmy add https://github.com/acme/shop.git --image ruby:3.4-slim
```

writes `~/.config/farmy/services/shop.yml` with the repository and the image. The rest is yours to
add; a Rails app with Postgres ends up as:

```yaml
repo: https://github.com/acme/shop.git
image: ruby:3.4-slim
ports: ["3100:3000"]              # host:container; without it nothing is published
env:
  DATABASE_URL: postgres://postgres:postgres@postgres:5432/shop_development
commands:
  setup: bin/setup --skip-server     # Rails' bin/setup starts the server without it
  start: bin/rails server -b 0.0.0.0
  test: bin/rails test
compose:
  postgres:
    image: postgres:18
    container_name: shop-pg
    environment:
      POSTGRES_PASSWORD: postgres
    volumes: [pgdata:/var/lib/postgresql]
    healthcheck:             # with one, the app container and its setup wait for it to be healthy
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
volumes:
  pgdata:
    name: shop-pg-data
```

`compose:` is plain compose: anything you would put next to an app in a compose file goes there as
it is, and the app reaches it by its service name (`postgres`). More examples, including a front
end with `start_after` and a CLI built from its own Dockerfile, are in the README under "Adding a
service". No repository yet? `repo: none` gives a workbench: an empty `/workspace` to clone into by
hand. `mounts:` keeps folders outside `/workspace` (a gem or npm cache) across restarts. Name an
official Debian image; the README's "Images" section says why, and why a generated Rails
Dockerfile is not a development image. The host port's hundred (`3100-3199`) is the service's
block: `${FARMY_PORT_32}` in a sidecar is 3132, and no other service may use that hundred.

## 4. A private repository: the token route

A public repository needs nothing more. For a private one, git inside the container goes through
the service's keys broker, which adds the token on the way out; the token never enters the app
container. Copy `farmy.example.yml` from farmy's folder over `~/.config/farmy/farmy.yml`; as shipped
it has what this path needs:

```yaml
keys:
  github:
    secret: GITHUB_TOKEN              # the name farmy asks for
    upstream: https://github.com      # the route applies to the repositories on this host
    auth: basic
    user: x-access-token
    git: true
  anthropic:                          # for Claude with an API key, step 7
    secret: ANTHROPIC_API_KEY
    upstream: https://api.anthropic.com
    auth: header
    header: x-api-key
```

The token: on GitHub, a fine-grained personal access token for the repository with "Contents"
read and write (write, so that you can push from inside). A repository on another host needs a
route of its own (`codeberg:` with `upstream: https://codeberg.org`), with that host's token.

## 5. Where the token comes from

farmy never stores a secret on disk. There is no `secrets:` section in this `farmy.yml`, so no
secrets manager: the first time a command loads the brokers (`start`, `restart`, `rebuild`, `farmy keys
reload`), the shim obtains each route's secret on this machine and pipes it to farmy, never on a
command line. The control container then holds the values in memory until `farmy lock` or until it
restarts, so the next starts ask nothing. The shim takes the first of:

- **a hidden prompt** on the terminal, when nothing else is set up. Nothing to install; you type the
  token once per control container.
- **the Linux secret service**, when `secret-tool` is installed (`libsecret-tools`) and a desktop
  session runs it. Store each value once:

  ```sh
  secret-tool store --label='farmy GITHUB_TOKEN' farmy farmy/GITHUB_TOKEN
  secret-tool store --label='farmy ANTHROPIC_API_KEY' farmy farmy/ANTHROPIC_API_KEY
  ```

  On a headless host without one, `secret-tool` answers with an error; farmy says so once and asks
  with the prompt instead.
- **a command of yours**, `FARMY_UNLOCK_COMMAND` in `.env` or the environment, run with the name as
  `$1`: `FARMY_UNLOCK_COMMAND='pass show "farmy/$1"'`.
- **the macOS Keychain** on a Mac:
  `security add-generic-password -a "$USER" -s farmy/GITHUB_TOKEN -w -T /usr/bin/security`.

Without a terminal (a script, a cron job) a value nothing yields is left out, and the routes that
need it read `locked`. `farmy keys` shows each route's state.

## 6. `farmy start shop`

```sh
farmy start shop
```

What happens, in order:

1. Checks: Docker, `.env` with the Git identity (written now when there is none and your host's git
   has one), the definition of `shop` (a clone URL, an image,
   host ports in one block that no other service has), no `app` or `keys` in the fragment.
2. Secrets: the values from step 5, for the routes `shop` may use.
3. Images: `farmy-keys:local` and `farmy-knowledge:local` when missing, then `farmy/shop:dev`: the
   toolbox on `ruby:3.4-slim`.
4. Containers: the compose project `shop` with `shop` (the app), `shop-keys` (the broker, with its
   routes), `shop-pg` from your fragment, and the shared knowledge container `farmy-knowledge`. The
   broker is loaded with the secrets as soon as it is up.
5. A Git helper clones the repository into `/workspace` on the volume `shop-src`, as dev through
   the broker. Because `postgres` has a healthcheck, `shop` is started only once it is
   healthy. Farmy waits for the helper, then runs `bin/setup --skip-server` in the checkout as the
   dev user. A failing setup is reported and `start` exits 1; the containers stay up. So is a setup
   still running after `setup_timeout` (`farmy.yml`, default `30m`): a setup has to end, which is
   what `--skip-server` is for.
6. `shop → http://localhost:3100`.

Without the token only public repositories clone, and `start` says so. When the clone fails, it says
why: a private repository behind a route whose token was not given (`locked`: give the token, then
`farmy keys reload`), a token GitHub refused (expired, or without access to the repository), a host
that does not resolve. The container stays up either
way. `farmy start shop` again on a running service leaves it alone. On a stopped one it starts the
containers again, unless the definition changed, in which case it makes them anew.

## 7. Claude Code inside

No agent is installed unless you said so: at `farmy init`, or with `agents:` in `farmy.yml`. Claude
Code with an API key is:

```yaml
agents:
  claude:
    mode: api-key                     # through the anthropic route of step 4
```

and the knowledge container is registered with it as an MCP server so that it can ask what is running.
`farmy add` says which agents a new service's image will carry.

The container then gets `ANTHROPIC_BASE_URL=http://keys:9181/anthropic` and
`ANTHROPIC_API_KEY=via-farmy-keys`; the broker swaps the placeholder for the real key, which never
enters the container. One service can differ: `agents: {claude: off}` or `agents: {claude:
subscription}` in its definition.

The default mode is `subscription`: no key, you log in once inside any container (`claude`, or
`claude setup-token` for a long-lived token), and the login lives on the shared volume
`farmy-shared` and serves every container. Each service keeps the agents' transcripts on its own
volume, `shop-agents`. `farmy agents` lists what the catalogue knows (Claude Code, Codex, Gemini
CLI, OpenCode, Cursor, Copilot), which are on, and how each logs in without a browser;
`agents: {claude: {}, codex: {}}` turns a second one on. A service whose agents should not share the
login with the others says `shared_logins: false` in its definition: its logins then live on its own
volume.

## 8. Day to day

```sh
farmy                      # the session: every service, every action, from any terminal
farmy run shop test         # a named command of shop, in the checkout
farmy run shop bin/rails c  # any words, the same way
farmy ssh shop              # a shell as dev, in /workspace (or the workdir)
farmy logs shop             # the containers' logs
farmy stop shop             # containers stopped, volumes kept
farmy restart shop          # after editing services/shop.yml or farmy.yml
farmy destroy shop          # containers and volumes gone; the definition stays
```

In the session, an action's output streams into a pane of the screen; a `bin/rails server` you
started with `c start` keeps running after you leave with `q` and is there when you come back
from another device over ssh. Nothing of tmux is for you: no keys, no status bar.

## Opening the app on a phone

Published ports listen on `127.0.0.1` only: the app is reachable from this machine and nowhere else.
Set `LAN_HOST` in `.env` to the host's name or address on the network (`studio.local`,
`10.0.40.101`) and they listen on every interface; `farmy url shop` and every `${url:shop}` in a
definition then use that name instead of `localhost`. `farmy status` says which it is. A running
service keeps what it was made with: `farmy restart shop` applies the change. On a server with a
public address, a firewall in front of it then decides who reaches the ports.

## An agent in a loop

With `factory:` in a definition, `farmy factory start shop --task …` lets an agent work on a run of
its own until a separate test run passes; only then is its branch pushed ([factory.md](factory.md)).

## Other setups

Each swaps one part of the path above:

- **SSH keys instead of a token.** Make the route `auth: ssh` with `upstream: ssh://git@github.com`
  (a port of its own: `ssh://git@git.example.com:2222`) and the secret `GITHUB_SSH_KEY`, the private
  key's text. The broker runs an SSH agent with it, the app container gets only the agent's socket,
  and an `https://` `repo:` on that host is cloned over SSH. Details in
  [credentials.md](credentials.md).
- **A secrets manager.** `secrets: {provider: [providers/infisical, …], unlock: [INFISICAL_TOKEN]}`:
  the shim then obtains only the manager's own credentials on this machine, and the provider fetches
  the routes' secrets. `providers/env`, `providers/infisical` and a program of your own speak the same
  protocol ([credentials.md](credentials.md), "Providers").
- **A corporate proxy.** `egress: {proxy: proxy.example.com:3128}` gives every container and the
  provider that proxy, git over SSH included ([mesh-egress.md](mesh-egress.md), "An existing proxy").
- **A private mesh.** `egress:` in `farmy.yml` runs one Tailscale node that every container and the
  provider reach their hosts through, for a git host or a secrets manager that is only on your
  tailnet ([mesh-egress.md](mesh-egress.md)).

All three together, on a Mac with the Keychain, Infisical and a Headscale mesh, are walked through
in [the worked example](worked-example.md).
