# Troubleshooting

Every refusal names what to look at: a file, a key, a command. What follows is the same list, with
what to do.

## The shim and the control container

- **`farmy: docker is not installed`**, **`Docker isn't running`**: Docker is the one thing farmy
  needs on the host. Start OrbStack, Docker Desktop or the engine, then try again.
- **The control image takes long**: the first `farmy` builds `farmy:local` (a Rust build in
  Docker, a few minutes). Afterwards it is instant. After a `git pull` of farmy, `farmy init` or
  `farmy update` builds it again when its inputs changed (the label `farmy.hash`).
- **`farmy` opens the wrong folder**: the control container is bound to the folder you ran the
  shim in; running it from another folder makes the container anew for that folder. One containers
  folder per machine is the intended use.
- **The session is gone**: `farmy update` or `docker rm farmy` removes the control container and
  its tmux session with it; the services keep running. `farmy` makes a new session.

## Before anything starts

- **`no .env in this folder — run: farmy init`**, **`GIT_USER_NAME is not set in .env`**: `farmy
  init` writes `.env` and fills the identity from `git config --global`; set it by hand otherwise.
- **`unknown service 'x' — known: notes shop`**: there is no `services/x.yml`; `farmy add <url>
  --image <image>` writes one.
- **`ports.yml is not read any more`**: the host ports went into each definition as
  `ports: ["3100:3000"]`; delete the file.
- **`services/shop.yml: no repo:`**, **`repo: acme/shop is not a clone URL`**: `repo:` is the full
  clone URL (`https://github.com/acme/shop.git`), or `none` for a workbench.
- **`shop and notes both have host ports in the block 3100-3199`**: a service owns the hundred its
  host ports lie in; give one of them another hundred.
- **`services/shop.yml: ports: the host port 5432 is outside the service's block`**: all of a
  service's host ports stay in one hundred.
- **`services/shop.yml: no ports: but services/notes.yml refers to it`** (a warning): farmy gave
  the service the next free block and wrote `ports: ["3100:3000"]` into the file; change the
  container port if the app does not listen on 3000.
- **`services/shop.yml: unknown key 'x'`**, **`farmy.yml: unknown key 'x'`**: a typo, or a key from
  an older version; the keys are listed in FORMATS.md.
- **`services/shop.yml: the compose fragment defines a service named 'app'`**: farmy adds `app` and
  `keys` itself; rename yours.
- **`services/shop.yml: keys: names 'anthropic', which is not granted to shop`**: the route has
  `services:` without shop; add shop there or drop it from the definition.

## Claude Code

- **Claude asks to log in inside the container**: subscription mode needs either a login on the
  shared volume (log in once, in any container) or the token from `claude setup-token` under
  `CLAUDE_CODE_OAUTH_TOKEN` (the entry's `token_env`); check
  `farmy keys` is not `locked` or `provider failed`, and that the provider has that name. Do not
  `/login` inside: it expires.
- **A subscription is billed per token**: the container has `ANTHROPIC_API_KEY` or
  `ANTHROPIC_BASE_URL` set, which outrank the login. In subscription mode farmy gives neither;
  look for them in `services/<name>.env` or the definition's `env:`.
- **Claude's sessions from another service show up**: they cannot, each service has its own
  `<name>-agents` volume for its transcripts; only the login is shared, on `farmy-shared`.

## Secrets

- **`the git route 'github' for github.com has no secret (locked) — public repositories only on that
  host`**: `GITHUB_TOKEN` was not given; until it is, the broker forwards git without credentials, so
  only public repositories clone. Without a
  `secrets:` section the shim asks for it on this machine: it was in none of the sources (a command
  in `FARMY_UNLOCK_COMMAND`, the Keychain or the secret service under `farmy/GITHUB_TOKEN`, or the
  prefix in `FARMY_SECRET_PREFIX`) and there was no terminal to ask on; the shim named it on stderr.
  Store it (credentials.md, "Where the secrets come from: this machine"), or run the command in a
  terminal and type it; then `farmy keys reload`. Once given, the control container holds it until
  `farmy lock` or a restart of the container; a changed token: `farmy lock`, then `farmy keys reload`. With a provider, `locked` means one of the values
  under `unlock:` was not given. A locked keychain over ssh is unlocked once by the shim, on the
  terminal.
- **`… has no secret (missing)`**: the provider did not return the secret: with Infisical, it must
  exist under that name in the project and environment given.
- **`[shop] the clone failed: fatal: Authentication failed …` and `github.com refused the secret
  GITHUB_TOKEN of the git route 'github'`**: the host turned the token down: expired, revoked, or
  without access to the repository (a fine-grained GitHub token needs the repository and "Contents").
  Make a new one, store it where the old one was, `farmy keys reload`, `farmy restart shop`.
- **`farmy: the secret service answers with an error, so it is not asked again`**: `secret-tool` is
  installed but no secret service answers (no D-Bus session on a headless host, or a locked
  collection, which cannot be unlocked from a shell). Every value is asked for at the prompt instead;
  on a headless host, `FARMY_UNLOCK_COMMAND` (`pass show "farmy/$1"`) is the store that works.
- **`the secrets provider bin/provider failed (exit 3) — run it yourself to see why`**: farmy
  never shows a provider's output while it loads. `farmy keys --why` runs the provider once, as a
  load would (the unlocking values from the shim, the egress node first), and prints how it ended,
  which secrets it answered and its stderr, with every secret and unlocking value replaced by
  `[redacted]`; it loads nothing.
- **`did not answer in the protocol`**: the provider printed something that is not the JSON of
  FORMATS.md.
- **`the keys broker could not be loaded`**: `farmy keys reload shop` tries again; `farmy logs shop`
  shows the broker's side.
- **SSH: `Permission denied (publickey)`** inside the container: the `auth: ssh` route is not loaded
  (`farmy keys`), or the key is not registered on the git host for that repository. The app sees
  `SSH_AUTH_SOCK=/run/farmy-keys/agent.sock`; `ssh-add -l` there lists the key's fingerprint when the
  broker holds it.
- **`the SSH agent could not take the key`** in `farmy logs shop`: the value is not an unencrypted
  OpenSSH private key. When it says the value looks base64-encoded, add `encoding: base64` to the
  route. `farmy keys --why` shows what the provider answered (redacted).
- **`not loaded (farmy keys reload)`**: the keys container was made anew or restarted and lost what
  it held; `farmy keys reload shop`.
- **A service clone fails** (`farmy start` names
  the line that names the cause, `Permission denied (publickey)` for a key the host does not know,
  `Error connecting to agent` when the broker held no key; the Git helper has already tried four
  times over about thirty seconds when the cause may pass, such as `General SOCKS server failure`
  right after the egress node was made anew): the git route for
  that host is not loaded (or there is none: `no git route for codeberg.org`), or the token lacks
  access. `farmy keys` for the state, `farmy keys reload shop`, then
  `farmy restart shop`.
- **`keys: WARN git answered 401`** in the logs: the token is expired, revoked or without access
  to that repository. Fix it at the source, then `farmy keys reload shop`.

## Mesh egress

- **`egress: this node is not registered on the mesh yet`** with a URL: open it, register the node
  on the control server; `farmy start` waits `join_timeout` and goes on. The next start says
  nothing: the state is on the volume `farmy-egress`. `farmy status` shows the URL again.
- **`egress.authkey names X, which is not under secrets.unlock`**: the auth key is an unlocking
  value, obtained by the shim; list it under `secrets.unlock` and store it where the others are.
- **The provider fails behind the mesh**: `farmy status` shows whether the node is registered;
  the provider runs with `HTTPS_PROXY` set, and the Infisical CLI honours it.
- **`lookup <name> on 127.0.0.11:53: no such host`** in the node's log: the node runs in userspace
  mode (`farmy status` says so), where only names under the tailnet's suffix resolve. Give the
  Docker daemon `/dev/net/tun` and let the container have `NET_ADMIN`, then `docker rm -f
  farmy-egress` and `farmy start <name>`.
- **`Could not resolve proxy: farmy-egress`**: a container that is not on the `farmy` network. The
  shim puts the control container there (and attaches one from an older farmy); the app container
  and, with `egress:`, the fragment's services are there too. `farmy restart <name>` for a service
  made before.
- **`ssh: not found` in a clone**: an app image from before the toolbox installed
  `openssh-client`; `farmy rebuild <name>`.
- **A clone fails while the node is unregistered**: the Git helper goes through the
  proxy for SSH hosts (`core.sshCommand`); register the node, then `farmy restart <name>`.

## Building

- **`couldn't clone https://github.com/acme/toolkit.git to read its Dockerfile`**: the git route's
  secret for that host (`farmy keys`), or `repo:` / `branch:` in the definition.
- **`build_files: 'Gemfile.lock' is not in acme/toolkit`**: a file the stage COPYs that is not
  in the repository on that branch.
- **`the toolbox did not build on ruby:3.4-alpine`**: `install.sh` needs apt or apk in the image;
  anything else needs a `toolbox/` of your own. The build's output is above the message.
- **`farmy toolbox: x has no install line for an apk base`**: the catalogue entry has no apk line
  (Cursor's installer is glibc-only); use a Debian image, or override `install` under `agents:`.
- **`agents: 'x' is not in the catalogue`**: a list under `agents:` names catalogue entries; an
  agent of your own goes under `agents:` as a map with its fields (`farmy agents` lists both).

## Running

- **`shop is already running`**: `start` leaves a running service alone. `farmy restart shop`
  applies a changed definition; `status` tells you when one changed.
- **`[shop] setup failed at: bin/setup --skip-server`**: the containers stay up; `farmy ssh shop` to look,
  then `farmy run shop setup` or `farmy restart shop`. A `db:prepare` that cannot reach Postgres means
  the fragment's `postgres` has no `healthcheck:`: with one, the app container waits for it.
- **`[shop] setup did not finish within 30m and was stopped`**: the setup command never ends. A Rails
  `bin/setup` starts the development server unless it gets `--skip-server`; a watcher or a server
  belongs under `start`, not `setup`. A slow but honest setup can get more time with
  `setup_timeout: 1h` in `farmy.yml`.
- **`shop is not running — farmy start shop`**: `run`, `ssh` and the session's commands need the app
  container up.
- **`[shop] note: the toolbox changed since this container was made`**: `farmy rebuild shop`.
- **Port already allocated**: another process on the host holds a port of the block; find it
  (`lsof -iTCP:3100 -sTCP:LISTEN` on the host) or give the service another block.
- **The knowledge container is missing**: `knowledge: false`, or its image failed to build (a
  note at `start`); `farmy stop` then `farmy start shop` builds it again.

## Starting over

- `farmy restart shop`: containers anew, volumes kept.
- `farmy rebuild shop`: images without cache, then the same.
- `farmy destroy shop`: containers and volumes gone, the definition stays.
- `rm -rf .work`: farmy's state; the next `start` writes it again.
- `farmy update`: the control image and container anew, when the checkout changed.
